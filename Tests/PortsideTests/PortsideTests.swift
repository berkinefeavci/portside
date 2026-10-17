import XCTest
@testable import Portside

final class HistoryEntryTests: XCTestCase {
    private func entry(executable: String? = "/usr/bin/python3",
                       arguments: [String] = ["-m", "http.server", "8000"],
                       custom: String? = nil) -> HistoryEntry {
        HistoryEntry(
            id: HistoryEntry.makeID(projectPath: "/tmp/site", executable: executable, arguments: arguments),
            projectName: "Site", projectPath: "/tmp/site", port: 8000, framework: .python,
            executable: executable, arguments: arguments, environment: ["SHELL": "/bin/bash"],
            displayCommand: "python3 -m http.server 8000", customCommand: custom,
            firstSeen: Date(), lastSeen: Date(), lastStopped: nil, lastStarted: nil, runCount: 1, isPinned: false
        )
    }

    func testIDIgnoresPortButNotCommand() {
        let a = HistoryEntry.makeID(projectPath: "/p", executable: "/bin/node", arguments: ["dev.js"])
        let b = HistoryEntry.makeID(projectPath: "/p", executable: "/bin/node", arguments: ["dev.js"])
        let c = HistoryEntry.makeID(projectPath: "/p", executable: "/bin/node", arguments: ["api.js"])
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testShellCommandQuotesOnlyWhenNeeded() {
        let e = entry(arguments: ["-m", "http.server", "--directory", "My Site", "it's"])
        XCTAssertEqual(e.shellCommand, #"/usr/bin/python3 -m http.server --directory 'My Site' 'it'\''s'"#)
    }

    func testCustomCommandRunsThroughSavedShell() {
        let e = entry(custom: "  npm run dev  ")
        XCTAssertTrue(e.hasCustomCommand)
        XCTAssertEqual(e.shellCommand, "  npm run dev  ")
        XCTAssertEqual(e.launchCommand?.executable, "/bin/bash")
        XCTAssertEqual(e.launchCommand?.arguments, ["-l", "-i", "-c", "  npm run dev  "])
    }

    func testBlankCustomCommandFallsBackToDetected() {
        let e = entry(custom: "   ")
        XCTAssertFalse(e.hasCustomCommand)
        XCTAssertEqual(e.launchCommand?.executable, "/usr/bin/python3")
    }

    func testNoCommandMeansNoRelaunch() {
        let e = entry(executable: nil, arguments: [])
        XCTAssertFalse(e.canRelaunch)
        XCTAssertNil(e.launchCommand)
        XCTAssertEqual(e.shellCommand, "python3 -m http.server 8000")
    }

    func testUnknownFrameworkInOldFileStillDecodes() throws {
        let json = #""Sunucu""#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(Framework.self, from: json), .unknown)
    }
}

final class HistoryStoreTests: XCTestCase {
    private var original: URL!
    private var temp: URL!

    override func setUp() {
        original = HistoryStore.directory
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("PortsideTests-\(UUID().uuidString)")
        HistoryStore.directory = temp
    }

    override func tearDown() {
        HistoryStore.directory = original
        try? FileManager.default.removeItem(at: temp)
    }

    func testRoundTripKeepsPinnedAndIsPrivate() throws {
        var entries: [String: HistoryEntry] = [:]
        for index in 0..<(HistoryStore.limit + 10) {
            let id = "server-\(index)"
            entries[id] = HistoryEntry(
                id: id, projectName: id, projectPath: "/p/\(index)", port: 3000 + index, framework: .vite,
                executable: "/bin/node", arguments: [], environment: [:], displayCommand: "node",
                customCommand: nil, firstSeen: Date(), lastSeen: Date(timeIntervalSince1970: TimeInterval(index)),
                lastStopped: nil, lastStarted: nil, runCount: 1, isPinned: index == 0
            )
        }
        HistoryStore.save(entries)
        let loaded = HistoryStore.load()

        XCTAssertEqual(loaded.count, HistoryStore.limit)
        XCTAssertNotNil(loaded["server-0"], "the oldest entry is pinned and must survive the limit")
        XCTAssertNil(loaded["server-1"], "the oldest unpinned entries age out")

        let permissions = try FileManager.default.attributesOfItem(atPath: HistoryStore.file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }
}

final class ProcessResolverTests: XCTestCase {
    func testWorkingDirectoryParsing() {
        XCTAssertEqual(ProcessResolver.parseCWD("p123\nfcwd\nn/Users/me/site\n"), "/Users/me/site")
        XCTAssertEqual(ProcessResolver.parseCWD(""), "")
    }

    func testFrameworkDetection() {
        func detect(_ args: String) -> Framework {
            ProcessResolver.detectFramework(from: ResolvedProcess(pid: 1, arguments: args, workingDirectory: "/"))
        }
        XCTAssertEqual(detect("node /app/node_modules/.bin/vite --port 5173"), .vite)
        XCTAssertEqual(detect("node /app/node_modules/.bin/next dev"), .nextjs)
        XCTAssertEqual(detect("python3 manage.py runserver"), .django)
        XCTAssertEqual(detect("python -m uvicorn main:app"), .fastapi)
        XCTAssertEqual(detect("python3 -m http.server 8000"), .python)
        XCTAssertEqual(detect("node server.js"), .unknown)
        XCTAssertEqual(detect("next-server (v14.2.3)"), .nextjs)
        XCTAssertEqual(detect("node /app/node_modules/next/dist/server/lib/start-server.js"), .nextjs)
        XCTAssertEqual(detect("node /Users/me/nextcloud-tools/server.js"), .unknown, "a path that merely contains 'next'")
        XCTAssertEqual(detect("/private/var/folders/zz/T/go-build123/b001/exe/api"), .go)
        XCTAssertEqual(detect("/Users/me/api/target/debug/api --port 8080"), .cargo)
    }

    func testFolderNameIsTitleCased() {
        XCTAssertEqual(ProcessResolver.folderName("/Users/me/my-cool-site"), "My Cool Site")
        XCTAssertEqual(ProcessResolver.folderName("/"), "Unknown")
    }

    func testOwnProcessLaunchInfo() {
        let info = ProcessResolver.launchInfo(pid: Int(getpid()))
        XCTAssertFalse(info.executablePath.isEmpty)
        XCTAssertFalse(info.argv.isEmpty)
        XCTAssertEqual(info.environment["HOME"], ProcessInfo.processInfo.environment["HOME"])
    }
}

final class SavedEnvironmentTests: XCTestCase {
    func testSecretsAndSessionValuesAreNotKept() {
        let kept = SavedEnvironment.filtered([
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "NODE_ENV": "development",
            "PORT": "3000",
            "NEXT_PUBLIC_API_URL": "http://localhost:4000",
            "OPENAI_API_KEY": "sk-123",
            "GITHUB_TOKEN": "ghp",
            "DB_PASSWORD": "x",
            "AWS_SECRET_ACCESS_KEY": "y",
            "AWS_ACCESS_KEY_ID": "z",
            "STRIPE_KEY": "k",
            "dbPass": "p",
            "SESSION_COOKIE": "c",
            "SENTRY_DSN": "https://abc@sentry.io/1",
            "DATABASE_URL": "postgres://localhost/app",
            "TERM_SESSION_ID": "abc",
            "PWD": "/somewhere",
            "__CF_USER_TEXT_ENCODING": "0x1F5",
        ])
        XCTAssertEqual(Set(kept.keys), ["PATH", "NODE_ENV", "PORT", "NEXT_PUBLIC_API_URL"])
    }

    func testValuesThatLookLikeSecretsAreNotKeptWhateverTheNameSays() {
        let kept = SavedEnvironment.filtered([
            "UPSTREAM": "postgres://app:hunter2@db.internal/app",
            "REDIS": "redis://:hunter2@cache:6379",
            "CLIENT": "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVP",
            "PEM": "-----BEGIN RSA PRIVATE KEY-----\nabc",
            "GH": "ghp_1234567890abcdefghijklmnopqrstuvwxyz",
            "LOCAL": "postgres://localhost:5432/app",
            "MONKEY": "banana",
            "KEYBOARD": "us",
        ])
        XCTAssertEqual(Set(kept.keys), ["LOCAL", "MONKEY", "KEYBOARD"])
    }

    func testVariablesOfTheStartingSessionAreNotKept() {
        let kept = SavedEnvironment.filtered([
            "PATH": "/usr/bin", "HOME": "/Users/me", "MY_FLAG": "1", "ANTHROPIC_BASE_URL": "http://localhost:8000",
            "TERM_PROGRAM": "vscode", "VSCODE_GIT_IPC_HANDLE": "/tmp/x", "ITERM_PROFILE": "Default",
            "CLAUDECODE": "1", "CLAUDE_CODE_USER_EMAIL": "me@example.com", "CODEX_THREAD_ID": "abc",
            "TMUX_PANE": "%1", "SSH_CONNECTION": "1.2.3.4 22", "CODEX_TASK_WORKSPACE_VERIFYING_IDENTITY": "x",
        ])
        XCTAssertEqual(Set(kept.keys), ["PATH", "HOME", "MY_FLAG", "ANTHROPIC_BASE_URL"])
    }

    func testMalformedNamesAndValuesAreDropped() {
        XCTAssertTrue(SavedEnvironment.filtered(["": "x", "A=B": "x", "OK": "a\0b", "FINE": "yes"]).keys.contains("FINE"))
        XCTAssertEqual(SavedEnvironment.filtered(["": "x", "A=B": "x", "OK": "a\0b"]).count, 0)
    }
}

final class BuildOutputTests: XCTestCase {
    func testGoRunAndCargoBinariesAreRecognisedByPath() {
        XCTAssertEqual(BuildOutput.kind(ofExecutable: "/private/var/folders/zz/abc/T/go-build2412837/b001/exe/api"), .goRun)
        XCTAssertEqual(BuildOutput.kind(ofExecutable: "/Users/me/Library/Caches/go-build/f2/f270ae107b90f596ed04b3de70636c432220babfbffe0143aeca839510b16a96-d/api"), .goRun,
                       "a repeated go run starts the linked copy from the build cache")
        XCTAssertEqual(BuildOutput.kind(ofExecutable: "/Users/me/api/target/debug/api"), .cargo)
        XCTAssertEqual(BuildOutput.kind(ofExecutable: "/Users/me/api/target/release/api --port 8080"), .cargo)
        XCTAssertEqual(BuildOutput.kind(ofExecutable: "/Users/me/api/target/aarch64-apple-darwin/release/api"), .cargo)
    }

    func testOrdinaryProgramsAreNotBuildOutputs() {
        XCTAssertNil(BuildOutput.kind(ofExecutable: "/opt/homebrew/bin/node"))
        XCTAssertNil(BuildOutput.kind(ofExecutable: "/Applications/Spotify.app/Contents/MacOS/Spotify"))
        XCTAssertNil(BuildOutput.kind(ofExecutable: "/Users/me/target/debug-tools/foo"))
        XCTAssertNil(BuildOutput.kind(ofExecutable: "/usr/local/go/bin/go"))
        XCTAssertNil(BuildOutput.kind(ofExecutable: "/Users/me/Library/Caches/go-build/trim.txt"))
    }

    func testBuilders() {
        XCTAssertTrue(BuildOutput.isBuilder("/opt/homebrew/bin/go"))
        XCTAssertTrue(BuildOutput.isBuilder("/Users/me/.cargo/bin/cargo"))
        XCTAssertFalse(BuildOutput.isBuilder("/bin/zsh"))
    }
}

final class PortScannerTests: XCTestCase {
    func testParsesLsofFieldOutput() {
        let output = "p101\ncnode\nn*:5173\nn[::1]:5174\np202\ncPython\nn127.0.0.1:8000\np303\ncpostgres\nn*:5432\n"
        let ports = PortScanner.parse(output)
        XCTAssertEqual(ports.map(\.port), [5173, 5174, 8000, 5432])
        XCTAssertEqual(ports.map(\.pid), [101, 101, 202, 303])
        XCTAssertEqual(ports[2].command, "Python")
    }
}

final class TimeTextTests: XCTestCase {
    func testDurations() {
        let now = Date()
        XCTAssertEqual(TimeText.duration(since: now.addingTimeInterval(-42), now: now), "42s")
        XCTAssertEqual(TimeText.duration(since: now.addingTimeInterval(-12 * 60), now: now), "12m")
        XCTAssertEqual(TimeText.duration(since: now.addingTimeInterval(-(3 * 3600 + 5 * 60)), now: now), "3h 5m")
        XCTAssertEqual(TimeText.duration(since: now.addingTimeInterval(-2 * 3600), now: now), "2h")
        XCTAssertEqual(TimeText.duration(since: now.addingTimeInterval(-3 * 86_400), now: now), "3d")
    }

    func testDayGroups() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-09T12:00:00Z")!
        XCTAssertEqual(TimeText.dayGroup(now.addingTimeInterval(-3600), now: now, calendar: calendar), .today)
        XCTAssertEqual(TimeText.dayGroup(now.addingTimeInterval(-86_400), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(TimeText.dayGroup(now.addingTimeInterval(-4 * 86_400), now: now, calendar: calendar), .thisWeek)
        XCTAssertEqual(TimeText.dayGroup(now.addingTimeInterval(-30 * 86_400), now: now, calendar: calendar), .older)
    }
}

final class LogTailTests: XCTestCase {
    func testTailStartsAtTheErrorAndDropsColours() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("portside-tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let log = "\u{1B}[32mready\u{1B}[0m\nlistening\nError: listen EADDRINUSE: address already in use :::3000\n    at Server.listen\n"
        try log.write(to: url, atomically: true, encoding: .utf8)

        let tail = LaunchedServer.tail(of: url)
        XCTAssertTrue(tail.hasPrefix("Error: listen EADDRINUSE"), tail)
        XCTAssertFalse(tail.contains("\u{1B}"))
    }
}

final class LogNameTests: XCTestCase {
    @MainActor
    func testLogNameIsStable() {
        let e = HistoryEntry(
            id: "/p\u{1F}/bin/node\u{1F}dev.js", projectName: "My Site", projectPath: "/p", port: 1, framework: .unknown,
            executable: "/bin/node", arguments: ["dev.js"], environment: [:], displayCommand: "", customCommand: nil,
            firstSeen: Date(), lastSeen: Date(), lastStopped: nil, lastStarted: nil, runCount: 1, isPinned: false
        )
        XCTAssertEqual(AppState.logName(for: e), AppState.logName(for: e))
        XCTAssertTrue(AppState.logName(for: e).hasPrefix("My-Site-"))
    }
}

final class RunCountTests: XCTestCase {
    @MainActor
    func testSameProcessIsNotCountedTwice() {
        let start = Date(timeIntervalSince1970: 1_000)
        var e = HistoryEntry(
            id: "x", projectName: "x", projectPath: "/x", port: 1, framework: .unknown, executable: "/bin/node",
            arguments: [], environment: [:], displayCommand: "", customCommand: nil, firstSeen: start,
            lastSeen: start, lastStopped: nil, lastStarted: start, runCount: 1, isPinned: false
        )
        e = AppState.counted(e, startedAt: start)
        XCTAssertEqual(e.runCount, 1, "Portside restarting must not look like a new server run")
        e = AppState.counted(e, startedAt: start.addingTimeInterval(60))
        XCTAssertEqual(e.runCount, 2)
    }
}

final class PreviewFallbackTests: XCTestCase {
    private var original: URL!
    private var temp: URL!

    override func setUp() {
        original = HistoryStore.directory
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("PortsideTests-\(UUID().uuidString)")
        HistoryStore.directory = temp
    }

    override func tearDown() {
        HistoryStore.directory = original
        try? FileManager.default.removeItem(at: temp)
    }

    private func entry(_ id: String, path: String = "/site", port: Int, seen: TimeInterval) -> HistoryEntry {
        HistoryEntry(
            id: id, projectName: "Site", projectPath: path, port: port, framework: .vite, executable: "/bin/node",
            arguments: [], environment: [:], displayCommand: "", customCommand: nil,
            firstSeen: Date(timeIntervalSince1970: seen), lastSeen: Date(timeIntervalSince1970: seen),
            lastStopped: nil, lastStarted: nil, runCount: 1, isPinned: false
        )
    }

    @MainActor
    private func writePreview(for id: String) throws {
        try FileManager.default.createDirectory(at: PreviewStore.directory, withIntermediateDirectories: true)
        let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.setFill(); rect.fill(); return true
        }
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .jpeg, properties: [:])!.write(to: PreviewStore.file(for: HistoryEntry.fileKey(for: id)))
    }

    @MainActor
    func testClosedServerBorrowsItsProjectsPicture() throws {
        let state = AppState(polling: false)
        let fresh = entry("fresh", port: 5174, seen: 300)
        state.history = [
            "fresh": fresh,
            "old-other-port": entry("old-other-port", port: 5173, seen: 100),
            "old-same-port": entry("old-same-port", port: 5174, seen: 50),
            "elsewhere": entry("elsewhere", path: "/other", port: 5174, seen: 200),
        ]
        XCTAssertEqual(state.previewID(for: fresh), "fresh", "nothing to borrow")

        try writePreview(for: "old-other-port")
        try writePreview(for: "old-same-port")
        try writePreview(for: "elsewhere")
        XCTAssertEqual(state.previewID(for: fresh), "old-same-port", "same folder, same port first; never another folder")

        try writePreview(for: "fresh")
        XCTAssertEqual(state.previewID(for: fresh), "fresh")
    }
}

final class ShellTests: XCTestCase {
    func testOutputLargerThanThePipeBufferIsNotLost() async {
        // 1 MB: far more than a pipe holds, so a reader that waits for the exit first would hang.
        let output = await Shell.run("/bin/sh", arguments: ["-c", "head -c 1000000 /dev/zero | tr '\\0' 'a'"], timeout: 20)
        XCTAssertEqual(output?.count, 1_000_000)
    }

    func testHungChildIsGivenUpOn() async {
        let started = Date()
        let output = await Shell.run("/bin/sleep", arguments: ["30"], timeout: 0.5)
        XCTAssertNil(output)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testRunsDoNotLeakFileDescriptors() async {
        func openDescriptors() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? 0 }
        _ = await Shell.run("/bin/echo")
        let before = openDescriptors()
        for _ in 0..<40 { _ = await Shell.run("/bin/echo", arguments: ["x"]) }
        XCTAssertLessThan(openDescriptors() - before, 5, "each run used to leave both ends of its pipe open")
    }

    func testAGrandchildKeepingThePipeOpenDoesNotHoldUpTheResult() async {
        let started = Date()
        let output = await Shell.run("/bin/sh", arguments: ["-c", "echo out; sleep 3 &"], timeout: 20)
        XCTAssertEqual(output, "out\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5)
    }

    func testMissingProgramIsNil() async {
        let output = await Shell.run("/nonexistent/program")
        XCTAssertNil(output)
    }

    func testErrorsAreOnlyMergedWhenAsked() async {
        let command = ["-c", "echo out; echo err 1>&2"]
        let plain = await Shell.run("/bin/sh", arguments: command)
        let merged = await Shell.run("/bin/sh", arguments: command, mergingErrors: true)
        XCTAssertEqual(plain, "out\n")
        XCTAssertEqual(Set((merged ?? "").split(separator: "\n")), ["out", "err"])
    }
}

@MainActor
private final class StubCapturer: PageCapturing {
    var results: [NSImage?]
    var calls: [URL] = []
    var holdFirst = false
    private var gate: CheckedContinuation<Void, Never>?

    init(results: [NSImage?] = []) { self.results = results }

    func capture(_ url: URL) async -> NSImage? {
        calls.append(url)
        if holdFirst, calls.count == 1 { await withCheckedContinuation { gate = $0 } }
        return results.isEmpty ? nil : results.removeFirst()
    }

    func release() {
        gate?.resume()
        gate = nil
    }
}

final class PreviewStoreTests: XCTestCase {
    private var original: URL!
    private var temp: URL!
    private var wasEnabled = true

    @MainActor
    override func setUp() {
        original = HistoryStore.directory
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("PortsideTests-\(UUID().uuidString)")
        HistoryStore.directory = temp
        wasEnabled = PreviewStore.shared.isEnabled
    }

    @MainActor
    override func tearDown() {
        PreviewStore.shared.isEnabled = wasEnabled
        HistoryStore.directory = original
        try? FileManager.default.removeItem(at: temp)
    }

    @MainActor
    private func picture() -> NSImage {
        NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.blue.setFill(); rect.fill(); return true
        }
    }

    @MainActor
    private func settle(_ store: PreviewStore) async {
        for _ in 0..<300 where !store.isIdle { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor
    private func waitForFirstCall(_ stub: StubCapturer) async {
        for _ in 0..<300 where stub.calls.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @MainActor
    func testTurningPreviewsOffStopsQueuedCaptures() async throws {
        let stub = StubCapturer(results: [picture(), picture(), picture()])
        stub.holdFirst = true
        let store = PreviewStore(capturer: stub)
        store.isEnabled = true

        for (index, port) in [3001, 3002, 3003].enumerated() {
            store.capture(entryID: "entry-\(index)", port: port, maxAge: 60)
        }
        await waitForFirstCall(stub)
        XCTAssertEqual(stub.calls.count, 1, "one page at a time")

        store.isEnabled = false
        store.removeAll()
        stub.release()
        await settle(store)

        XCTAssertEqual(stub.calls.count, 1, "the queued pages must not be loaded after previews are switched off")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: PreviewStore.directory.path)) ?? []
        XCTAssertTrue(files.isEmpty, "nothing is written after switching off: \(files)")
    }

    @MainActor
    func testFailedCaptureIsRetriedSoonAndASuccessIsNotRepeated() async throws {
        var clock = Date(timeIntervalSince1970: 1_000_000)
        let stub = StubCapturer(results: [nil, picture()])
        let store = PreviewStore(capturer: stub, now: { clock })
        store.isEnabled = true

        store.capture(entryID: "site", port: 5173, maxAge: 300)
        await settle(store)
        XCTAssertEqual(stub.calls.count, 1)

        store.capture(entryID: "site", port: 5173, maxAge: 300)
        XCTAssertEqual(stub.calls.count, 1, "backing off right after a failure")

        clock.addTimeInterval(16)
        store.capture(entryID: "site", port: 5173, maxAge: 300)
        await settle(store)
        XCTAssertEqual(stub.calls.count, 2, "retried well before maxAge")
        XCTAssertTrue(store.hasImage(for: "site"))

        clock.addTimeInterval(60)
        store.capture(entryID: "site", port: 5173, maxAge: 300)
        XCTAssertEqual(stub.calls.count, 2, "a successful capture counts from the success")
    }

    @MainActor
    func testForgettingAnEntryDuringItsCaptureWritesNothing() async throws {
        let stub = StubCapturer(results: [picture()])
        stub.holdFirst = true
        let store = PreviewStore(capturer: stub)
        store.isEnabled = true

        store.capture(entryID: "gone", port: 4000, maxAge: 60)
        await waitForFirstCall(stub)
        store.forget(entryID: "gone")
        stub.release()
        await settle(store)

        XCTAssertFalse(store.hasImage(for: "gone"))
    }

    @MainActor
    func testRetryDelayDoublesUpToAFiveMinuteCap() {
        XCTAssertEqual((1...8).map { PreviewStore.retryDelay(afterFailures: $0) }, [15, 30, 60, 120, 240, 300, 300, 300])
    }

    func testOnlyLoopbackPagesAreAllowed() {
        for allowed in ["http://localhost:3000/", "http://127.0.0.1:8080/x", "http://[::1]:5173/", "https://localhost/"] {
            XCTAssertTrue(PreviewTarget.isLoopback(URL(string: allowed)!), allowed)
        }
        for refused in ["http://example.com/", "http://localhost.evil.com/", "http://192.168.1.5:3000/",
                        "file:///etc/passwd", "ftp://localhost/", "http://127.0.0.1.nip.io/"] {
            XCTAssertFalse(PreviewTarget.isLoopback(URL(string: refused)!), refused)
        }
        XCTAssertNil(PreviewTarget.url(port: 0))
        XCTAssertNil(PreviewTarget.url(port: 70_000))
        XCTAssertEqual(PreviewTarget.url(port: 3000)?.absoluteString, "http://localhost:3000/")
    }
}

final class ScanStateTests: XCTestCase {
    private var original: URL!
    private var temp: URL!

    override func setUp() {
        original = HistoryStore.directory
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("PortsideTests-\(UUID().uuidString)")
        HistoryStore.directory = temp
    }

    override func tearDown() {
        HistoryStore.directory = original
        try? FileManager.default.removeItem(at: temp)
    }

    private func server(port: Int = 5199, pid: Int = Int(getpid())) -> DevServer {
        DevServer(pid: pid, port: port, command: "node", framework: .vite, projectName: "Site",
                  projectPath: "/tmp/site", startedAt: Date(timeIntervalSince1970: 1_000))
    }

    @MainActor
    func testAScanThatChangesNothingDoesNotNotifyViews() async {
        let state = AppState(polling: false)
        await state.apply(servers: [server()], simulators: [])
        XCTAssertEqual(state.servers, [server()])

        let fired = expectation(description: "a view was told something changed")
        fired.isInverted = true
        watch(state, server()) { fired.fulfill() }

        await state.apply(servers: [server()], simulators: [])
        await fulfillment(of: [fired], timeout: 0.3)
    }

    @MainActor
    func testAScanThatChangesSomethingDoesNotifyViews() async {
        let state = AppState(polling: false)
        await state.apply(servers: [server()], simulators: [])

        let fired = expectation(description: "a view was told something changed")
        watch(state, server()) { fired.fulfill() }

        await state.apply(servers: [server(), server(port: 5200, pid: 1)], simulators: [])
        await fulfillment(of: [fired], timeout: 2)
    }

    @MainActor
    private func watch(_ state: AppState, _ server: DevServer, onChange: @escaping @Sendable () -> Void) {
        withObservationTracking {
            _ = state.entry(for: server)
            _ = state.servers
            _ = state.simulators
            _ = state.history
            _ = state.restartStates
            _ = state.hasWorkInFlight
            _ = state.closedCards(limit: 4)
        } onChange: {
            onChange()
        }
    }

    // MARK: - A failed restart stays visible

    @MainActor
    func testRowsMidRestartOrFailedAreKeptWhileTheirProcessIsGone() {
        let gone = server(port: 3000, pid: 10)
        let other = server(port: 4000, pid: 20)
        let kept = AppState.preservingRestartingRows(
            scanned: [other], previous: [gone, other], restartStates: [3000: .failed("EADDRINUSE")]
        )
        XCTAssertEqual(kept.map(\.port), [3000, 4000], "the failed row stays so its reason can be read")

        let working = AppState.preservingRestartingRows(scanned: [], previous: [gone], restartStates: [3000: .working])
        XCTAssertEqual(working.map(\.port), [3000])

        let dismissed = AppState.preservingRestartingRows(scanned: [], previous: [gone], restartStates: [:])
        XCTAssertTrue(dismissed.isEmpty, "nothing keeps a row once the failure is dismissed")

        let back = AppState.preservingRestartingRows(
            scanned: [server(port: 3000, pid: 99)], previous: [gone], restartStates: [3000: .failed("x")]
        )
        XCTAssertEqual(back.map(\.pid), [99], "a server that is back replaces the old row")
    }

    @MainActor
    func testFailedRestartSurvivesScansUntilDismissed() async {
        let state = AppState(polling: false)
        let site = server()
        await state.apply(servers: [site], simulators: [])

        // This entry has no command to start again, so the restart fails at once.
        state.restart(site)
        guard case .failed = state.restartStates[site.port] else { return XCTFail("expected a failure") }

        await state.apply(servers: [site], simulators: [])
        guard case .failed = state.restartStates[site.port] else { return XCTFail("the next scan wiped the failure") }

        await state.apply(servers: [], simulators: [])
        XCTAssertEqual(state.servers, [site], "the card stays, with its failure, although the process is gone")
        guard case .failed = state.restartStates[site.port] else { return XCTFail("the failure disappeared with the process") }

        state.dismissFailed(site)
        XCTAssertTrue(state.servers.isEmpty)
        XCTAssertNil(state.restartStates[site.port])
    }

    @MainActor
    func testAFailedRowIsOnlyCountedAsRunningWhileItsProcessLives() async {
        let state = AppState(polling: false)
        // startedAt nil: whatever has this PID is taken to be the process; the xctest process is alive.
        let alive = DevServer(pid: Int(getpid()), port: 5301, command: "node", framework: .vite, projectName: "A",
                              projectPath: "/tmp/a", startedAt: nil)
        let gone = server(port: 5302, pid: 4_000_001)
        state.servers = [alive, gone]
        XCTAssertEqual(state.runningCount, 2)

        state.restartStates = [5301: .failed("x"), 5302: .failed("y")]
        XCTAssertEqual(state.runningCount, 1, "the row of the dead process is not running")
    }

    @MainActor
    func testAnotherProcessOnThePortClearsTheFailure() async {
        let state = AppState(polling: false)
        let site = server()
        await state.apply(servers: [site], simulators: [])
        state.restart(site)

        await state.apply(servers: [server(pid: 4_000_000)], simulators: [])
        XCTAssertNil(state.restartStates[site.port])
    }
}

/// Each test gets its own history, picture and log folders.
class IsolatedStoreTestCase: XCTestCase {
    var temp: URL!
    private var originalData: URL!
    private var originalLogs: URL!

    override func setUp() {
        originalData = HistoryStore.directory
        originalLogs = HistoryStore.logDirectory
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("PortsideTests-\(UUID().uuidString)")
        HistoryStore.directory = temp.appendingPathComponent("Data")
        HistoryStore.logDirectory = temp.appendingPathComponent("Logs")
    }

    override func tearDown() {
        HistoryStore.directory = originalData
        HistoryStore.logDirectory = originalLogs
        try? FileManager.default.removeItem(at: temp)
    }

    func entry(_ id: String, name: String = "Site", seen: TimeInterval = 100, pinned: Bool = false,
               environment: [String: String] = [:], executable: String? = "/bin/node") -> HistoryEntry {
        HistoryEntry(
            id: id, projectName: name, projectPath: "/p/\(id)", port: 3000, framework: .vite,
            executable: executable, arguments: [id], environment: environment, displayCommand: "node \(id)",
            customCommand: nil, firstSeen: Date(timeIntervalSince1970: seen), lastSeen: Date(timeIntervalSince1970: seen),
            lastStopped: nil, lastStarted: nil, runCount: 1, isPinned: pinned
        )
    }

    func permissions(_ url: URL) -> Int? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}

final class HistoryRecoveryTests: IsolatedStoreTestCase {
    func testUnreadableFileIsSetAsideNotOverwritten() throws {
        try write("{ this is not json", to: HistoryStore.file)

        let result = HistoryStore.read()
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNotNil(result.notice)
        XCTAssertFalse(exists(HistoryStore.file), "the damaged file is moved away, not left to be overwritten")

        HistoryStore.save(["a": entry("a")])
        let names = try FileManager.default.contentsOfDirectory(atPath: HistoryStore.directory.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("history.corrupt-") })
        XCTAssertEqual(try String(contentsOf: HistoryStore.directory.appendingPathComponent(aside), encoding: .utf8), "{ this is not json")
        XCTAssertEqual(HistoryStore.load().keys.sorted(), ["a"])
    }

    func testOneBrokenEntryDoesNotCostTheOthers() throws {
        HistoryStore.save(["good": entry("good")])
        var json = try String(contentsOf: HistoryStore.file, encoding: .utf8)
        json = "[" + json.dropFirst().dropLast() + ", {\"id\": \"broken\", \"port\": \"not a number\"}]"
        try write(json, to: HistoryStore.file)

        let result = HistoryStore.read()
        XCTAssertEqual(result.entries.keys.sorted(), ["good"])
        XCTAssertNotNil(result.notice)
        let names = try FileManager.default.contentsOfDirectory(atPath: HistoryStore.directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("history.corrupt-") }, "the original is kept for recovery")
    }

    func testMissingFileIsJustEmpty() {
        let result = HistoryStore.read()
        XCTAssertTrue(result.entries.isEmpty)
        XCTAssertNil(result.notice)
    }

    func testSecretsFromOlderVersionsAreDroppedAndRewritten() throws {
        HistoryStore.save(["a": entry("a", environment: ["PATH": "/usr/bin"])])
        // What an older version would have written: a secret in the environment.
        let json = try String(contentsOf: HistoryStore.file, encoding: .utf8)
            .replacingOccurrences(of: "\"environment\" : {", with: "\"environment\" : { \"STRIPE_KEY\" : \"sk_live_abcdefghijklmnop\", \"DATABASE_URL\" : \"postgres:\\/\\/u:p@h\\/db\",")
        try write(json, to: HistoryStore.file)
        XCTAssertTrue(try String(contentsOf: HistoryStore.file, encoding: .utf8).contains("STRIPE_KEY"))

        let loaded = HistoryStore.load()
        XCTAssertEqual(loaded["a"]?.environment, ["PATH": "/usr/bin"])
        let onDisk = try String(contentsOf: HistoryStore.file, encoding: .utf8)
        XCTAssertFalse(onDisk.contains("STRIPE_KEY"))
        XCTAssertFalse(onDisk.contains("postgres://"))
    }

    func testHistoryFileAndFolderArePrivate() {
        HistoryStore.save(["a": entry("a")])
        XCTAssertEqual(permissions(HistoryStore.file), 0o600)
        XCTAssertEqual(permissions(HistoryStore.directory), 0o700)
    }

    func testFoldersFromEarlierVersionsAreTightenedButOnlyWhenAsked() throws {
        let folder = HistoryStore.directory.appendingPathComponent("Previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let picture = folder.appendingPathComponent("abc.jpg")
        try write("x", to: picture)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: picture.path)

        // Writing into an existing folder doesn't change its mode...
        try PrivateFiles.write(Data("y".utf8), to: folder.appendingPathComponent("new.jpg"))
        XCTAssertEqual(permissions(folder), 0o755)

        PrivateFiles.tighten(folders: [folder])
        XCTAssertEqual(permissions(folder), 0o700)
        XCTAssertEqual(permissions(picture), 0o600)
        XCTAssertEqual(permissions(folder.appendingPathComponent("new.jpg")), 0o600)
    }

    func testWriteFailureIsReported() throws {
        try FileManager.default.createDirectory(at: HistoryStore.directory, withIntermediateDirectories: true)
        // A folder where the file should go.
        try FileManager.default.createDirectory(at: HistoryStore.file, withIntermediateDirectories: true)
        try write("x", to: HistoryStore.file.appendingPathComponent("blocker"))
        XCTAssertNotNil(HistoryStore.save(["a": entry("a")]))
    }
}

final class FilesFollowEntriesTests: IsolatedStoreTestCase {
    @MainActor
    private func addFiles(for entry: HistoryEntry) throws {
        let key = HistoryEntry.fileKey(for: entry.id)
        try write("jpeg", to: PreviewStore.file(for: key))
        try write("output", to: LogFiles.url(for: entry))
    }

    @MainActor
    private func hasFiles(of entry: HistoryEntry) -> (picture: Bool, log: Bool) {
        (exists(PreviewStore.file(for: HistoryEntry.fileKey(for: entry.id))), exists(LogFiles.url(for: entry)))
    }

    @MainActor
    func testForgettingAnEntryDeletesItsPictureAndLog() throws {
        let state = AppState(polling: false)
        let gone = entry("gone"), stays = entry("stays")
        state.history = ["gone": gone, "stays": stays]
        try addFiles(for: gone)
        try addFiles(for: stays)

        state.forget(gone)

        XCTAssertEqual(hasFiles(of: gone).picture, false)
        XCTAssertEqual(hasFiles(of: gone).log, false)
        XCTAssertEqual(hasFiles(of: stays).picture, true)
        XCTAssertEqual(hasFiles(of: stays).log, true)
    }

    @MainActor
    func testClearingHistoryDeletesFilesOfEverythingButPinned() throws {
        let state = AppState(polling: false)
        let pinned = entry("pinned", pinned: true), other = entry("other")
        state.history = ["pinned": pinned, "other": other]
        try addFiles(for: pinned)
        try addFiles(for: other)

        state.clearHistory()

        XCTAssertEqual(state.history.keys.sorted(), ["pinned"])
        XCTAssertEqual(hasFiles(of: other).picture, false)
        XCTAssertEqual(hasFiles(of: other).log, false)
        XCTAssertEqual(hasFiles(of: pinned).picture, true)
        XCTAssertEqual(hasFiles(of: pinned).log, true)
    }

    @MainActor
    func testEntriesPastTheLimitTakeTheirFilesWithThem() throws {
        let state = AppState(polling: false)
        var all: [String: HistoryEntry] = [:]
        for index in 0..<(HistoryStore.limit + 3) {
            all["e\(index)"] = entry("e\(index)", seen: TimeInterval(index))
        }
        state.history = all
        let oldest = try XCTUnwrap(all["e0"]), newest = try XCTUnwrap(all["e\(HistoryStore.limit + 2)"])
        try addFiles(for: oldest)
        try addFiles(for: newest)

        state.togglePin(newest)   // any change saves the history, and the save applies the limit

        XCTAssertEqual(state.history.count, HistoryStore.limit, "memory and file agree on what is kept")
        XCTAssertNil(state.history["e0"])
        XCTAssertEqual(hasFiles(of: oldest).picture, false)
        XCTAssertEqual(hasFiles(of: oldest).log, false)
        XCTAssertEqual(hasFiles(of: newest).picture, true)
    }

    @MainActor
    func testOrphansAreRemovedAndOtherFilesAreLeftAlone() throws {
        let kept = entry("kept"), orphan = entry("orphan")
        try addFiles(for: kept)
        try addFiles(for: orphan)
        try write("not ours", to: HistoryStore.logDirectory.appendingPathComponent("notes.txt"))
        try write("no key", to: HistoryStore.logDirectory.appendingPathComponent("plain.log"))

        LogFiles.removeOrphans(keeping: [HistoryEntry.fileKey(for: "kept")])

        XCTAssertEqual(hasFiles(of: orphan).picture, false)
        XCTAssertEqual(hasFiles(of: orphan).log, false)
        XCTAssertEqual(hasFiles(of: kept).log, true)
        XCTAssertTrue(exists(HistoryStore.logDirectory.appendingPathComponent("notes.txt")))
        XCTAssertTrue(exists(HistoryStore.logDirectory.appendingPathComponent("plain.log")))
    }
}

final class LogFileTests: IsolatedStoreTestCase {
    func testProjectNamesCannotLeaveTheLogFolder() {
        let sneaky = entry("x", name: "../../.ssh/authorized_keys")
        let url = LogFiles.url(for: sneaky)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, HistoryStore.logDirectory.standardizedFileURL.path)
        XCTAssertFalse(url.lastPathComponent.hasPrefix("."))
        XCTAssertEqual(LogFiles.safeBase("My Site"), "My-Site")
        XCTAssertEqual(LogFiles.safeBase("..."), "server")
        XCTAssertEqual(LogFiles.safeBase("a/b\\c:d"), "a-b-c-d")
    }

    func testKeyIsTheLastDashSeparatedPart() {
        let url = URL(fileURLWithPath: "/tmp/My-Cool-Site-1abc2d.log")
        XCTAssertEqual(LogFiles.key(of: url), "1abc2d")
        XCTAssertNil(LogFiles.key(of: URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertNil(LogFiles.key(of: URL(fileURLWithPath: "/tmp/plain.log")))
    }

    func testALogStartedByPortsideIsPrivateAndHoldsTheOutput() async throws {
        let server = try LaunchedServer(
            executable: "/bin/echo", arguments: ["hello log"], directory: "/tmp", environment: [:], logName: "Test-abc"
        )
        for _ in 0..<100 where server.isRunning { try await Task.sleep(for: .milliseconds(20)) }

        XCTAssertEqual(permissions(server.logURL), 0o600)
        XCTAssertEqual(permissions(HistoryStore.logDirectory), 0o700)
        XCTAssertEqual(LogFiles.contents(of: server.logURL), "hello log\n")
    }

    func testAnOversizedLogIsCutBackToItsEnd() throws {
        let url = HistoryStore.logDirectory.appendingPathComponent("Big-abc.log")
        try write(String(repeating: "x", count: 5_000) + "THE END", to: url)

        LogFiles.trimIfNeeded(url, limit: 1_000, keeping: 100)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("THE END"))
        XCTAssertEqual(text.count, 100)
        // And the file is still open for a server that appends to it.
        let appended = try PrivateFiles.openLog(url, truncating: false)
        try appended.write(contentsOf: Data("!".utf8))
        try appended.close()
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasSuffix("THE END!"))
    }

    func testContentsReadsTheWholeLogWithoutColourCodes() throws {
        let url = HistoryStore.logDirectory.appendingPathComponent("Full-abc.log")
        let lines = (1...40).map { "line \($0)" }
        try write("\u{1B}[31m" + lines.joined(separator: "\n") + "\u{1B}[0m\n", to: url)

        let text = try XCTUnwrap(LogFiles.contents(of: url))
        XCTAssertEqual(text, lines.joined(separator: "\n") + "\n", "all 40 lines, not a 12-line tail")
    }
}

final class LaunchSafetyTests: XCTestCase {
    func testOnlyInstalledShellsAreUsedForCustomCommands() {
        XCTAssertEqual(HistoryEntry.loginShell(saved: "/bin/bash"), "/bin/bash")
        XCTAssertEqual(HistoryEntry.loginShell(saved: "/tmp/evil"), "/bin/zsh")
        XCTAssertEqual(HistoryEntry.loginShell(saved: "bash"), "/bin/zsh")
        XCTAssertEqual(HistoryEntry.loginShell(saved: nil), "/bin/zsh")
    }
}

final class CustomCommandTests: IsolatedStoreTestCase {
    @MainActor
    func testSavingTheFilledInDetectedCommandIsNotACustomCommand() {
        let state = AppState(polling: false)
        let detected = entry("a")
        state.history = ["a": detected]

        state.setCustomCommand(detected.detectedShellCommand, for: detected)
        XCTAssertNil(state.history["a"]?.customCommand)

        state.setCustomCommand("npm run dev", for: detected)
        XCTAssertEqual(state.history["a"]?.customCommand, "npm run dev")
    }

    @MainActor
    func testAnEntryWithOnlyAProcessTitleHasNothingToFillIn() {
        let titleOnly = entry("n", executable: nil)
        XCTAssertNil(titleOnly.detectedShellCommand)
        XCTAssertEqual(titleOnly.shellCommand, "node n", "display and search still show the title")

        let state = AppState(polling: false)
        state.history = ["n": titleOnly]
        state.setCustomCommand("next-server (v14.2.3)", for: titleOnly)
        XCTAssertEqual(state.history["n"]?.customCommand, "next-server (v14.2.3)", "what the user types is theirs; nothing was filled in")
        state.setCustomCommand("", for: titleOnly)
        XCTAssertNil(state.history["n"]?.customCommand)
    }
}

final class SimulatorWindowMatchTests: XCTestCase {
    func testTheWholeNameBeforeTheSeparatorWins() {
        let titles = ["iPhone 15 Pro Max – iOS 17.5", "iPhone 15 Pro – iOS 17.5", "iPhone 15 – iOS 17.5"]
        XCTAssertEqual(SimulatorWindowMatch.index(in: titles, name: "iPhone 15", runtime: "iOS 17.5"), 2,
                       "'iPhone 15' is part of the other titles too")
        XCTAssertEqual(SimulatorWindowMatch.index(in: titles, name: "iPhone 15 Pro", runtime: "iOS 17.5"), 1)
    }

    func testSameNameOnTwoRuntimesUsesTheRuntime() {
        let titles = ["iPhone 15 – iOS 16.4", "iPhone 15 – iOS 17.5"]
        XCTAssertEqual(SimulatorWindowMatch.index(in: titles, name: "iPhone 15", runtime: "iOS 17.5"), 1)
    }

    func testOlderTitlesAreJustTheName() {
        XCTAssertEqual(SimulatorWindowMatch.index(in: ["iPad Air", "iPhone 15"], name: "iPhone 15", runtime: "iOS 17.5"), 1)
    }

    func testAmbiguousOrMissingMatchPicksNothing() {
        XCTAssertNil(SimulatorWindowMatch.index(in: ["iPhone 15 – iOS 16.4", "iPhone 15 – iOS 17.5"], name: "iPhone 15", runtime: "iOS 18.0"))
        XCTAssertNil(SimulatorWindowMatch.index(in: ["iPhone 15 Pro – iOS 17.5"], name: "iPhone 15", runtime: "iOS 17.5"))
        XCTAssertNil(SimulatorWindowMatch.index(in: [], name: "iPhone 15", runtime: "iOS 17.5"))
    }
}
