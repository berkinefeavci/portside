import Foundation

// A server Portside started. Output goes to a log file rather than a pipe: a pipe
// dies with Portside and takes the server with it, a file does not.
// Adapted from Blink's RelaunchedServer (MIT, mo.software).
final class LaunchedServer {
    private let process = Process()
    private let startedAt = Date()
    let logURL: URL

    init(executable: String, arguments: [String], directory: String,
         environment saved: [String: String], logName: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: HistoryStore.logDirectory, withIntermediateDirectories: true)
        logURL = HistoryStore.logDirectory.appendingPathComponent("\(logName).log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log

        // The server's own shell environment wins over Portside's bare app one.
        var environment = ProcessInfo.processInfo.environment.merging(saved) { _, own in own }
        environment["PWD"] = directory
        let binDirectory = (executable as NSString).deletingLastPathComponent
        var path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for extra in [binDirectory, "/opt/homebrew/bin", "/usr/local/bin"]
        where !extra.isEmpty && !path.split(separator: ":").contains(Substring(extra)) {
            path = extra == binDirectory ? "\(extra):\(path)" : "\(path):\(extra)"
        }
        environment["PATH"] = path
        process.environment = environment

        try process.run()
        try? log.close()
    }

    var isRunning: Bool { process.isRunning }
    var pid: Int { Int(process.processIdentifier) }

    func outputTail() -> String { Self.tail(of: logURL) }

    var exitDescription: String {
        guard !process.isRunning else { return String(localized: "Stopped responding.") }

        let seconds = Int(Date().timeIntervalSince(startedAt))
        let status = Int(process.terminationStatus)
        if process.terminationReason == .uncaughtSignal {
            return seconds < 1
                ? String(localized: "Killed by signal \(status) immediately.")
                : String(localized: "Killed by signal \(status) after \(seconds)s.")
        }
        return seconds < 1
            ? String(localized: "Exited with code \(status) immediately.")
            : String(localized: "Exited with code \(status) after \(seconds)s.")
    }

    // MARK: - Log tail

    static func tail(of url: URL, lines limit: Int = 12) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 16_384 ? end - 16_384 : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)

        let cleaned = stripANSI(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { "^~".contains($0) } }

        return Array(leadingWithTheError(cleaned).suffix(limit)).joined(separator: "\n")
    }

    private static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
    }

    private static func leadingWithTheError(_ lines: [String]) -> [String] {
        let marker = #"^([A-Za-z_][A-Za-z0-9_.]*)?(Error|Exception)\b"#
        guard let start = lines.lastIndex(where: {
            $0.range(of: marker, options: .regularExpression) != nil
        }) else { return lines }
        return Array(lines[start...])
    }
}
