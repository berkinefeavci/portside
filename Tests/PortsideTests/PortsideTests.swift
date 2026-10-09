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
    func testSecretsAndSessionValuesAreNotKept() {
        let kept = ProcessResolver.keepable([
            "PATH": "/opt/homebrew/bin:/usr/bin",
            "NODE_ENV": "development",
            "OPENAI_API_KEY": "sk-123",
            "GITHUB_TOKEN": "ghp",
            "DB_PASSWORD": "x",
            "AWS_SECRET_ACCESS_KEY": "y",
            "TERM_SESSION_ID": "abc",
            "PWD": "/somewhere",
            "__CF_USER_TEXT_ENCODING": "0x1F5",
        ])
        XCTAssertEqual(Set(kept.keys), ["PATH", "NODE_ENV"])
    }

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
