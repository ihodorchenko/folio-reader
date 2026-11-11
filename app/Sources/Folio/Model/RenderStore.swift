import Foundation
import CoreGraphics

/// Кэш рендеров страниц и миниатюр.
///
/// Рендер идёт на фоне (ядро потокобезопасно, см. CONTRACT.md §7), результат кладётся
/// в `NSCache` с ключом «page + scale» и лимитом ~120 МБ. В снапшот-режиме
/// (`synchronous == true`) рендер выполняется синхронно на вызывающем потоке, чтобы
/// захваченный кадр гарантированно содержал изображения страниц.
final class RenderStore: @unchecked Sendable {
    static let shared = RenderStore()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var inflight = Set<String>()
    private let queue = DispatchQueue(label: "folio.render", qos: .userInitiated, attributes: .concurrent)

    /// Только для снапшот-режима: рендерить синхронно, без фоновой очереди.
    var synchronous = false

    private init() {
        cache.totalCostLimit = 120 * 1024 * 1024
        cache.countLimit = 512
    }

    static func key(_ prefix: String, _ page: Int, _ scale: Double) -> String {
        String(format: "%@:%d:%.3f", prefix, page, scale)
    }

    func cached(_ key: String) -> CGImage? {
        cache.object(forKey: key as NSString)?.image
    }

    private func store(_ key: String, _ image: CGImage) {
        let cost = max(1, image.width * image.height * 4)
        cache.setObject(Box(image), forKey: key as NSString, cost: cost)
    }

    func removeAll() {
        cache.removeAllObjects()
        lock.lock()
        inflight.removeAll()
        lock.unlock()
    }

    /// Возвращает изображение, если оно уже готово, иначе запускает фоновый рендер
    /// и вызывает `completion` на главном акторе.
    @discardableResult
    func image(page: Int,
               scale: Double,
               provider: any DocumentProviding,
               prefix: String = "page",
               completion: @escaping @MainActor (CGImage?) -> Void) -> CGImage? {
        let key = RenderStore.key(prefix, page, scale)
        if let cached = cached(key) { return cached }

        if synchronous {
            let rendered = try? provider.render(page, scale: scale)
            if let rendered { store(key, rendered) }
            else { folioLog("render: ошибка рендера страницы \(page) scale=\(scale)") }
            return rendered
        }

        lock.lock()
        let alreadyRunning = inflight.contains(key)
        if !alreadyRunning { inflight.insert(key) }
        lock.unlock()
        guard !alreadyRunning else { return nil }

        queue.async {
            let rendered = try? provider.render(page, scale: scale)
            self.lock.lock()
            self.inflight.remove(key)
            self.lock.unlock()
            if let rendered { self.store(key, rendered) }
            Task { @MainActor in completion(rendered) }
        }
        return nil
    }

    /// Тёплая подгрузка соседних страниц (видимые ±2).
    func prefetch(page: Int, scale: Double, provider: any DocumentProviding, prefix: String = "page") {
        guard !synchronous else { return }
        let key = RenderStore.key(prefix, page, scale)
        if cached(key) != nil { return }
        lock.lock()
        let running = inflight.contains(key)
        if !running { inflight.insert(key) }
        lock.unlock()
        guard !running else { return }
        queue.async {
            let rendered = try? provider.render(page, scale: scale)
            self.lock.lock()
            self.inflight.remove(key)
            self.lock.unlock()
            if let rendered { self.store(key, rendered) }
        }
    }
}
