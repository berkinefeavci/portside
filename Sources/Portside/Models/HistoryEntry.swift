import Foundation

// A dev server Portside has seen, kept with everything needed to start it again:
// the real binary, its arguments, the folder and the environment it ran in.
struct HistoryEntry: Identifiable, Codable, Hashable {
    // Folder + command, not the port: Vite and friends hop to the next free
    // port when theirs is taken, and that is still the same server.
    let id: String

    var projectName: String
    var projectPath: String
    var port: Int
    var framework: Framework
    var executable: String?
    var arguments: [String]
    var environment: [String: String]
    var displayCommand: String
    /// A command the user typed in; run through their login shell instead of `executable`.
    var customCommand: String?

    var firstSeen: Date
    var lastSeen: Date
    var lastStopped: Date?
    /// Start time of the process last seen running, so a Portside restart isn't counted as a new run.
    var lastStarted: Date?
    var runCount: Int
    var isPinned: Bool

    var hasCustomCommand: Bool {
        !(customCommand ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // No file checks here: views ask this on the main thread, and a stat inside
    // Desktop or Documents can block on the privacy prompt. Launch reports it instead.
    var canRelaunch: Bool { executable != nil || hasCustomCommand }

    /// The command Portside detected, as it would be typed into a terminal. Nil when only the
    /// process title was readable (Next.js and others rename themselves), which can't be run.
    var detectedShellCommand: String? {
        guard let executable else { return nil }
        return ([executable] + arguments).map(Self.quoted).joined(separator: " ")
    }

    /// What would be typed into a terminal to start this server again; for display and search,
    /// the process title when there is nothing better.
    var shellCommand: String {
        if hasCustomCommand, let customCommand { return customCommand }
        return detectedShellCommand ?? displayCommand
    }

    /// The program and arguments Portside actually launches.
    var launchCommand: (executable: String, arguments: [String])? {
        if hasCustomCommand, let customCommand {
            // A login, interactive shell reads the same profile files as a terminal (nvm, pyenv, …).
            return (Self.loginShell(saved: environment["SHELL"]), ["-l", "-i", "-c", customCommand])
        }
        guard let executable else { return nil }
        return (executable, arguments)
    }

    /// The saved SHELL if it is one of the system's installed shells, else zsh. The history
    /// file is data: it shouldn't be able to choose any program to run the user's command with.
    static func loginShell(saved: String?, installed: Set<String> = installedShells) -> String {
        if let saved, installed.contains(saved), FileManager.default.isExecutableFile(atPath: saved) { return saved }
        return "/bin/zsh"
    }

    static let installedShells: Set<String> = {
        let listed = (try? String(contentsOfFile: "/etc/shells", encoding: .utf8)) ?? ""
        return Set(listed.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("/") })
    }()

    var localhostURL: URL? { URL(string: "http://localhost:\(port)") }

    /// Short, stable name for files that belong to an entry (logs, previews).
    static func fileKey(for id: String) -> String {
        // Stable across launches, unlike `hashValue`.
        let hash = id.utf8.reduce(UInt32(2_166_136_261)) { ($0 ^ UInt32($1)) &* 16_777_619 }
        return String(hash, radix: 36)
    }

    static func makeID(projectPath: String, executable: String?, arguments: [String]) -> String {
        ([projectPath, executable ?? "?"] + arguments).joined(separator: "\u{1F}")
    }

    static func quoted(_ word: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if !word.isEmpty, word.unicodeScalars.allSatisfy(safe.contains) { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// Stored as a plain JSON file so it survives updates and reinstalls and is easy to back up.
enum HistoryStore {
    static let limit = 200
    private static let keptCorruptCopies = 3

    /// Overridden by tests, and by PORTSIDE_DATA_DIR so demo screenshots don't touch your history.
    nonisolated(unsafe) static var directory: URL = ProcessInfo.processInfo.environment["PORTSIDE_DATA_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Portside", isDirectory: true)

    /// Where the output of servers Portside started goes. Follows PORTSIDE_DATA_DIR too, so a
    /// demo or test run never touches (or cleans up) the real logs.
    nonisolated(unsafe) static var logDirectory: URL = ProcessInfo.processInfo.environment["PORTSIDE_DATA_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("Logs", isDirectory: true) }
        ?? FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Portside", isDirectory: true)

    static var file: URL { directory.appendingPathComponent("history.json") }

    /// Set when the history file was damaged and couldn't be moved aside: writing would destroy it.
    nonisolated(unsafe) private static var overwriteBlocked = false

    struct ReadResult {
        var entries: [String: HistoryEntry]
        /// Something the user should know: part or all of the file couldn't be read.
        var notice: String?
    }

    enum StoreError: LocalizedError {
        case damaged

        var errorDescription: String? {
            String(localized: "The history file is damaged and couldn't be set aside, so it is left alone.")
        }
    }

    static func load() -> [String: HistoryEntry] { read().entries }

    /// Reads the history. A file that can't be read is moved aside (history.corrupt-<date>.json)
    /// before starting fresh, so the next save can't erase it; entries that are fine are kept
    /// when only some of them are broken. Secrets that older versions stored are dropped.
    static func read() -> ReadResult {
        overwriteBlocked = false
        guard FileManager.default.fileExists(atPath: file.path) else { return ReadResult(entries: [:], notice: nil) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: file), let list = try? decoder.decode([Lossy].self, from: data) else {
            return ReadResult(entries: [:], notice: setAside(moving: true))
        }

        var notice: String?
        let decoded = list.compactMap(\.entry)
        if decoded.count < list.count { notice = setAside(moving: false) }

        var sanitised = false
        let entries = decoded.map { entry -> HistoryEntry in
            var clean = entry
            clean.environment = SavedEnvironment.filtered(entry.environment)
            if clean.environment != entry.environment { sanitised = true }
            return clean
        }
        let merged = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.lastSeen > b.lastSeen ? a : b })
        // Rewrite right away: the old file may still hold secrets an older version saved.
        if sanitised, !overwriteBlocked { save(merged) }
        return ReadResult(entries: merged, notice: notice)
    }

    /// One broken entry mustn't cost the others.
    private struct Lossy: Decodable {
        let entry: HistoryEntry?
        init(from decoder: Decoder) throws { entry = try? HistoryEntry(from: decoder) }
    }

    /// Keeps the unreadable file as history.corrupt-<date>.json; returns the message for the user.
    private static func setAside(moving: Bool) -> String {
        let fileManager = FileManager.default
        let stamp = DateFormatter.corruptStamp.string(from: Date())
        var target = directory.appendingPathComponent("history.corrupt-\(stamp).json")
        var counter = 1
        while fileManager.fileExists(atPath: target.path) {
            counter += 1
            target = directory.appendingPathComponent("history.corrupt-\(stamp)-\(counter).json")
        }

        let kept: Bool
        if moving {
            kept = (try? fileManager.moveItem(at: file, to: target)) != nil
            if !kept { overwriteBlocked = true }
        } else {
            kept = (try? Data(contentsOf: file)).flatMap { try? PrivateFiles.write($0, to: target) } != nil
        }
        pruneCorruptCopies()
        guard kept else { return String(localized: "The history file couldn't be read, and it couldn't be set aside either.") }
        return moving
            ? String(localized: "The history file couldn't be read, so history starts empty. The original is kept as \(target.lastPathComponent).")
            : String(localized: "Some history entries couldn't be read and were dropped. The original is kept as \(target.lastPathComponent).")
    }

    private static func pruneCorruptCopies() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        // The date is in the name, so sorted names are sorted by age.
        let copies = names.filter { $0.hasPrefix("history.corrupt-") }.sorted()
        for name in copies.dropLast(keptCorruptCopies) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The entries that fit the limit: pinned ones never age out, running ones stay while they run.
    static func trimmed(_ entries: [String: HistoryEntry], protecting protected: Set<String> = []) -> [String: HistoryEntry] {
        let sorted = entries.values.sorted { $0.lastSeen > $1.lastSeen }
        let always = sorted.filter { $0.isPinned || protected.contains($0.id) }
        let rest = sorted.filter { !$0.isPinned && !protected.contains($0.id) }.prefix(max(0, limit - always.count))
        return Dictionary(uniqueKeysWithValues: (always + rest).map { ($0.id, $0) })
    }

    /// Returns what went wrong, if anything.
    @discardableResult
    static func save(_ entries: [String: HistoryEntry]) -> Error? {
        if overwriteBlocked { return StoreError.damaged }

        let kept = trimmed(entries).values.sorted { $0.lastSeen > $1.lastSeen }.map { entry -> HistoryEntry in
            var clean = entry
            clean.environment = SavedEnvironment.filtered(entry.environment)
            return clean
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            // The saved environment is the user's own shell's; keep it readable by them only.
            try PrivateFiles.write(try encoder.encode(kept), to: file)
            return nil
        } catch {
            return error
        }
    }
}

private extension DateFormatter {
    static let corruptStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
