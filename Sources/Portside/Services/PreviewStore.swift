import AppKit
import WebKit

// Small pictures of each server's page. The last one is kept after the server
// stops, so a closed server is recognisable at a glance.
@MainActor
@Observable
final class PreviewStore {
    static let shared = PreviewStore()

    var isEnabled: Bool = Defaults.bool("sitePreviews", default: true) {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "sitePreviews") }
    }

    /// Bumped after every capture so views that showed a placeholder redraw.
    private(set) var version = 0

    @ObservationIgnored private let cache = NSCache<NSString, NSImage>()
    @ObservationIgnored private var capturedAt: [String: Date] = [:]
    @ObservationIgnored private var queue: [(key: String, url: URL)] = []
    @ObservationIgnored private var isCapturing = false
    @ObservationIgnored private lazy var snapshotter = WebSnapshotter()

    static var directory: URL { HistoryStore.directory.appendingPathComponent("Previews", isDirectory: true) }

    static func file(for key: String) -> URL {
        directory.appendingPathComponent("\(key).jpg")
    }

    func image(for entryID: String) -> NSImage? {
        _ = version
        guard isEnabled else { return nil }
        let key = HistoryEntry.fileKey(for: entryID)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = NSImage(contentsOf: Self.file(for: key)) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    /// Queues a capture unless one was taken within `maxAge`.
    func capture(entryID: String, port: Int, maxAge: TimeInterval) {
        guard isEnabled, let url = URL(string: "http://localhost:\(port)/") else { return }
        let key = HistoryEntry.fileKey(for: entryID)
        if let last = capturedAt[key] ?? Self.fileDate(key), Date().timeIntervalSince(last) < maxAge { return }
        guard !queue.contains(where: { $0.key == key }) else { return }
        capturedAt[key] = Date()
        queue.append((key, url))
        drain()
    }

    func forget(entryID: String) {
        let key = HistoryEntry.fileKey(for: entryID)
        cache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: Self.file(for: key))
    }

    func removeAll() {
        cache.removeAllObjects()
        capturedAt.removeAll()
        try? FileManager.default.removeItem(at: Self.directory)
        version += 1
    }

    private static func fileDate(_ key: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(for: key).path))?[.modificationDate] as? Date
    }

    // One page at a time: a single hidden web view, emptied between captures so
    // no dev server keeps a hot-reload socket open to it.
    private func drain() {
        guard !isCapturing, !queue.isEmpty else { return }
        isCapturing = true
        let next = queue.removeFirst()
        Task {
            if let image = await snapshotter.capture(next.url), let data = image.jpegData() {
                try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
                try? data.write(to: Self.file(for: next.key), options: .atomic)
                cache.removeObject(forKey: next.key as NSString)
                version += 1
            }
            isCapturing = false
            drain()
        }
    }
}

@MainActor
private final class WebSnapshotter: NSObject, WKNavigationDelegate {
    private static let pageSize = NSSize(width: 1024, height: 640)
    private static let loadTimeout: TimeInterval = 10
    private static let settleDelay: Duration = .milliseconds(1200)

    private let webView: WKWebView
    private let window: NSWindow
    private var loaded: CheckedContinuation<Bool, Never>?
    private var attempt = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.pageSize), configuration: configuration)
        // WebKit only paints views that live in a window; this one sits far off screen.
        window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: Self.pageSize),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = webView
        window.orderBack(nil)
        webView.navigationDelegate = self
    }

    func capture(_ url: URL) async -> NSImage? {
        defer { webView.loadHTMLString("", baseURL: nil) }

        attempt += 1
        let current = attempt
        let ok = await withCheckedContinuation { continuation in
            loaded = continuation
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.loadTimeout))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.loadTimeout))
                // A late timer must not end the next page's load.
                if self?.attempt == current { self?.finish(false) }
            }
        }
        guard ok else { return nil }
        try? await Task.sleep(for: Self.settleDelay)

        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 640
        return try? await webView.takeSnapshot(configuration: configuration)
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
}

private extension NSImage {
    func jpegData() -> Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
