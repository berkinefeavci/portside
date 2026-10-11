import AppKit
import WebKit

/// Something that can take a picture of a page. The store uses a hidden web view; tests use a stand-in.
@MainActor
protocol PageCapturing: AnyObject {
    func capture(_ url: URL) async -> NSImage?
}

/// Which pages a preview may load: the server's own port on this Mac, nothing else.
enum PreviewTarget {
    static func url(port: Int) -> URL? {
        guard (1...65_535).contains(port) else { return nil }
        return URL(string: "http://localhost:\(port)/")
    }

    /// `http(s)://localhost`, `127.0.0.1` or `[::1]` (any port): where a page may take the preview.
    static func isLoopback(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

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
    /// When each picture was last taken successfully.
    @ObservationIgnored private var capturedAt: [String: Date] = [:]
    /// Failed captures: how many in a row, and when to try again.
    @ObservationIgnored private var failures: [String: (count: Int, retryAt: Date)] = [:]
    @ObservationIgnored private var queue: [(key: String, url: URL)] = []
    @ObservationIgnored private var capturing: String?
    /// Entries forgotten while their picture was being taken: it must not be written afterwards.
    @ObservationIgnored private var discarded: Set<String> = []
    @ObservationIgnored private var capturer: (any PageCapturing)?
    @ObservationIgnored private let now: () -> Date

    init(capturer: (any PageCapturing)? = nil, now: @escaping () -> Date = Date.init) {
        self.capturer = capturer
        self.now = now
    }

    static var directory: URL { HistoryStore.directory.appendingPathComponent("Previews", isDirectory: true) }

    static func file(for key: String) -> URL {
        directory.appendingPathComponent("\(key).jpg")
    }

    /// Nothing waiting and nothing being captured.
    var isIdle: Bool { capturing == nil && queue.isEmpty }

    func image(for entryID: String) -> NSImage? {
        _ = version
        guard isEnabled else { return nil }
        let key = HistoryEntry.fileKey(for: entryID)
        if let cached = cache.object(forKey: key as NSString) { return cached }
        guard let image = NSImage(contentsOf: Self.file(for: key)) else { return nil }
        cache.setObject(image, forKey: key as NSString)
        return image
    }

    func hasImage(for entryID: String) -> Bool {
        _ = version
        guard isEnabled else { return false }
        let key = HistoryEntry.fileKey(for: entryID)
        return cache.object(forKey: key as NSString) != nil
            || FileManager.default.fileExists(atPath: Self.file(for: key).path)
    }

    /// Queues a capture unless one was taken within `maxAge`. A page that couldn't be captured
    /// is tried again after a short, growing pause; `maxAge` 0 means "now, whatever happened".
    func capture(entryID: String, port: Int, maxAge: TimeInterval) {
        guard isEnabled, let url = PreviewTarget.url(port: port) else { return }
        let key = HistoryEntry.fileKey(for: entryID)
        let current = now()
        if maxAge > 0, let retryAt = failures[key]?.retryAt, current < retryAt { return }
        if let last = capturedAt[key] ?? Self.fileDate(key), current.timeIntervalSince(last) < maxAge { return }
        guard capturing != key, !queue.contains(where: { $0.key == key }) else { return }
        queue.append((key, url))
        drain()
    }

    func forget(entryID: String) {
        let key = HistoryEntry.fileKey(for: entryID)
        queue.removeAll { $0.key == key }
        if capturing == key { discarded.insert(key) }
        capturedAt[key] = nil
        failures[key] = nil
        cache.removeObject(forKey: key as NSString)
        try? FileManager.default.removeItem(at: Self.file(for: key))
    }

    func removeAll() {
        queue.removeAll()
        if let capturing { discarded.insert(capturing) }
        cache.removeAllObjects()
        capturedAt.removeAll()
        failures.removeAll()
        try? FileManager.default.removeItem(at: Self.directory)
        version += 1
    }

    /// 15 s after the first failure, doubling up to 5 minutes.
    static func retryDelay(afterFailures count: Int) -> TimeInterval {
        min(15 * pow(2, Double(max(count, 1) - 1)), 300)
    }

    private static func fileDate(_ key: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file(for: key).path))?[.modificationDate] as? Date
    }

    // One page at a time: a single hidden web view, emptied between captures so
    // no dev server keeps a hot-reload socket open to it.
    private func drain() {
        guard capturing == nil else { return }
        guard isEnabled else { queue.removeAll(); return }
        guard !queue.isEmpty else { return }
        let next = queue.removeFirst()
        capturing = next.key
        let page = pageCapturer()
        Task {
            let image = await page.capture(next.url)
            finish(next.key, image: image)
            capturing = nil
            drain()
        }
    }

    private func pageCapturer() -> any PageCapturing {
        if let capturer { return capturer }
        let made = WebSnapshotter()
        capturer = made
        return made
    }

    private func finish(_ key: String, image: NSImage?) {
        // Switched off, or forgotten, while the page was loading: write nothing.
        let wasForgotten = discarded.remove(key) != nil
        guard isEnabled, !wasForgotten else { return }

        if let image, let data = image.jpegData(), (try? PrivateFiles.write(data, to: Self.file(for: key))) != nil {
            capturedAt[key] = now()
            failures[key] = nil
            cache.removeObject(forKey: key as NSString)
            version += 1
        } else {
            let count = (failures[key]?.count ?? 0) + 1
            failures[key] = (count, now().addingTimeInterval(Self.retryDelay(afterFailures: count)))
        }
    }
}

/// One hidden web view that takes the pictures. It only ever loads the server's own page on
/// this Mac: no navigation away from loopback, no new windows, no camera or microphone, no
/// downloads, nothing kept between pages.
@MainActor
private final class WebSnapshotter: NSObject, PageCapturing, WKNavigationDelegate, WKUIDelegate {
    private static let pageSize = NSSize(width: 1024, height: 640)
    private static let loadTimeout: TimeInterval = 10
    private static let snapshotTimeout: TimeInterval = 8
    private static let settleDelay: Duration = .milliseconds(1200)

    private let webView: WKWebView
    private let window: NSWindow
    private var loaded: CheckedContinuation<Bool, Never>?
    private var attempt = 0

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: NSRect(origin: .zero, size: Self.pageSize), configuration: configuration)
        // WebKit only paints views that live in a window. Parking it off screen is not
        // enough: macOS pulls such windows back on screen when displays change, where it
        // showed up as a blank white rectangle. So it is fully transparent, click-through,
        // and only ordered in while a capture runs. It sits on a real screen and above other
        // windows because WebKit pauses animation frames for views it can't see.
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.pageSize),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        super.init()
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.alphaValue = 0
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func capture(_ url: URL) async -> NSImage? {
        guard PreviewTarget.isLoopback(url) else { return nil }
        window.setFrameOrigin(.zero)
        window.orderFrontRegardless()
        defer {
            webView.loadHTMLString("", baseURL: nil)
            window.orderOut(nil)
        }

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
        return await snapshot()
    }

    /// The snapshot, or nil if WebKit hasn't produced one in time (a view it stopped painting never answers).
    private func snapshot() async -> NSImage? {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 640
        let race = Race()
        return await withCheckedContinuation { continuation in
            Task { [webView] in
                let image = try? await webView.takeSnapshot(configuration: configuration)
                if race.claim() { continuation.resume(returning: image) }
            }
            Task {
                try? await Task.sleep(for: .seconds(Self.snapshotTimeout))
                if race.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Lets whichever of two tasks finishes first resume the continuation, and the other do nothing.
    @MainActor
    private final class Race {
        private var claimed = false
        func claim() -> Bool {
            defer { claimed = true }
            return !claimed
        }
    }

    private func finish(_ ok: Bool) {
        loaded?.resume(returning: ok)
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }

    // MARK: - Staying on this Mac

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // The page may embed what it likes; the page itself must stay on loopback.
        guard navigationAction.targetFrame?.isMainFrame ?? false else {
            decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
            return
        }
        let url = navigationAction.request.url
        let isBlank = url?.absoluteString == "about:blank"
        decisionHandler(isBlank || url.map(PreviewTarget.isLoopback) == true ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A file download is not a page.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? { nil }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}

private extension NSImage {
    func jpegData() -> Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
