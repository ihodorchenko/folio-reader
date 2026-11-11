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
    /// Кто ждёт уже запущенный рендер. Раньше потребитель, попавший в «уже рисуется»,
    /// получал nil без колбэка и оставался с белой страницей (гонка с prefetch).
    private var waiters: [String: [Waiter]] = [:]

    private struct Waiter: @unchecked Sendable {
        let notify: @MainActor (CGImage?) -> Void
    }
    private let queue = DispatchQueue(label: "folio.render", qos: .userInitiated, attributes: .concurrent)

    /// Только для снапшот-режима: рендерить синхронно, без фоновой очереди.
    var synchronous = false

    /// Диагностика для отладочного отчёта: сколько рендеров упало и почему.
    private(set) var errorCount = 0
    private(set) var lastError = "—"

    private func noteError(page: Int, scale: Double, error: Error?) {
        errorCount += 1
        lastError = String(format: "page=%d scale=%.2f: %@", page, scale, error.map { String(describing: $0) } ?? "nil")
        folioLog("render: ОШИБКА \(lastError)")
    }

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
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        // Не оставляем ожидающих без ответа: пусть перезапросят рендер.
        if !pending.isEmpty {
            Task { @MainActor in
                for group in pending.values {
                    for waiter in group { waiter.notify(nil) }
                }
            }
        }
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
            do {
                let rendered = try provider.render(page, scale: scale)
                store(key, rendered)
                return rendered
            } catch {
                noteError(page: page, scale: scale, error: error)
                return nil
            }
        }

        lock.lock()
        if inflight.contains(key) {
            // Рендер уже идёт (например, его начал prefetch) — подписываемся на результат.
            waiters[key, default: []].append(Waiter(notify: completion))
            lock.unlock()
            return nil
        }
        inflight.insert(key)
        lock.unlock()

        queue.async {
            let rendered: CGImage?
            do {
                rendered = try provider.render(page, scale: scale)
            } catch {
                self.noteError(page: page, scale: scale, error: error)
                rendered = nil
            }
            self.lock.lock()
            self.inflight.remove(key)
            let pending = self.waiters.removeValue(forKey: key) ?? []
            self.lock.unlock()
            if let rendered { self.store(key, rendered) }
            Task { @MainActor in
                completion(rendered)
                for waiter in pending { waiter.notify(rendered) }
            }
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
            let rendered: CGImage?
            do {
                rendered = try provider.render(page, scale: scale)
            } catch {
                self.noteError(page: page, scale: scale, error: error)
                rendered = nil
            }
            self.lock.lock()
            self.inflight.remove(key)
            let pending = self.waiters.removeValue(forKey: key) ?? []
            self.lock.unlock()
            if let rendered { self.store(key, rendered) }
            if !pending.isEmpty {
                Task { @MainActor in
                    for waiter in pending { waiter.notify(rendered) }
                }
            }
        }
    }
}
