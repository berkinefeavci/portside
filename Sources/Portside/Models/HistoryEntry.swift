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

    /// What would be typed into a terminal to start this server again.
    var shellCommand: String {
        if hasCustomCommand, let customCommand { return customCommand }
        guard let executable else { return displayCommand }
        return ([executable] + arguments).map(Self.quoted).joined(separator: " ")
    }

    /// The program and arguments Portside actually launches.
    var launchCommand: (executable: String, arguments: [String])? {
        if hasCustomCommand, let customCommand {
            let shell = environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            // A login, interactive shell reads the same profile files as a terminal (nvm, pyenv, …).
            return (shell, ["-l", "-i", "-c", customCommand])
        }
        guard let executable else { return nil }
        return (executable, arguments)
    }

    var localhostURL: URL? { URL(string: "http://localhost:\(port)") }

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

    /// Overridden by tests.
    nonisolated(unsafe) static var directory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Portside", isDirectory: true)

    static var logDirectory: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Portside", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent("history.json") }

    static func load() -> [String: HistoryEntry] {
        migrateFromLiman()
        guard let data = try? Data(contentsOf: file) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([HistoryEntry].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.lastSeen > b.lastSeen ? a : b })
    }

    static func save(_ entries: [String: HistoryEntry]) {
        // Pinned entries never age out.
        let sorted = entries.values.sorted { $0.lastSeen > $1.lastSeen }
        let pinned = sorted.filter(\.isPinned)
        let rest = sorted.filter { !$0.isPinned }.prefix(max(0, limit - pinned.count))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(pinned + rest) else { return }

        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // The saved environment is the user's own shell's; keep it readable by them only.
        if (try? data.write(to: file, options: .atomic)) != nil {
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    /// Portside was called Liman during development; keep that history.
    private static func migrateFromLiman() {
        let fm = FileManager.default
        let old = directory.deletingLastPathComponent().appendingPathComponent("Liman/history.json")
        guard directory.lastPathComponent == "Portside",
              !fm.fileExists(atPath: file.path), fm.fileExists(atPath: old.path) else { return }
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.copyItem(at: old, to: file)
    }
}
