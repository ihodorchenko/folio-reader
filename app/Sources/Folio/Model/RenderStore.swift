import Foundation
import CoreGraphics

/// Cache of page and thumbnail renders.
///
/// Rendering happens in the background (the core is thread-safe, see CONTRACT.md §7); the result
/// goes into `NSCache` under a "page + scale" key with a ~120 MB limit. In snapshot mode
/// (`synchronous == true`) rendering runs synchronously on the calling thread so the
/// captured frame is guaranteed to contain page images.
final class RenderStore: @unchecked Sendable {
    static let shared = RenderStore()

    private final class Box {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var inflight = Set<String>()
    /// Who is waiting for an already running render. Previously a consumer that hit "already drawing"
    /// got nil with no callback and was left with a white page (a race with prefetch).
    private var waiters: [String: [Waiter]] = [:]

    private struct Waiter: @unchecked Sendable {
        let notify: @MainActor (CGImage?) -> Void
    }
    private let queue = DispatchQueue(label: "folio.render", qos: .userInitiated, attributes: .concurrent)

    /// Snapshot mode only: render synchronously, without the background queue.
    var synchronous = false

    /// Diagnostics for the debug report: how many renders failed and why.
    private(set) var errorCount = 0
    private(set) var lastError = "—"

    private func noteError(page: Int, scale: Double, error: Error?) {
        errorCount += 1
        lastError = String(format: "page=%d scale=%.2f: %@", page, scale, error.map { String(describing: $0) } ?? "nil")
        folioLog("render: ERROR \(lastError)")
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
        // Never leave waiters without an answer: let them request the render again.
        if !pending.isEmpty {
            Task { @MainActor in
                for group in pending.values {
                    for waiter in group { waiter.notify(nil) }
                }
            }
        }
    }

    /// Returns the image if it is already ready; otherwise starts a background render
    /// and calls `completion` on the main actor.
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
            // A render is already running (started by prefetch, for example) — subscribe to the result.
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

    /// Warm up neighboring pages (visible ±2).
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
