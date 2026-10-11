import Foundation

/// The output of servers Portside started, one file per history entry in `HistoryStore.logDirectory`.
/// They can hold anything a server prints, secrets included, so they are private (0600), capped
/// in size and removed together with their entry.
enum LogFiles {
    /// A running server's log is cut back to its end once it grows past this.
    static let sizeLimit = 8_000_000
    static let keptWhenTrimmed = 256_000
    /// What "copy the full output" reads at most.
    static let copyLimit = 8_000_000

    static func name(for entry: HistoryEntry) -> String {
        "\(safeBase(entry.projectName))-\(HistoryEntry.fileKey(for: entry.id))"
    }

    static func url(for entry: HistoryEntry) -> URL {
        HistoryStore.logDirectory.appendingPathComponent("\(name(for: entry)).log")
    }

    /// A project name comes from the project's own package.json or Cargo.toml: it must never be
    /// able to point the log somewhere else (`../../…`), or start with a dot.
    static func safeBase(_ projectName: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.whitespaces)
        var base = projectName.unicodeScalars.map { unsafe.contains($0) ? "-" : String($0) }.joined()
        while base.hasPrefix(".") { base.removeFirst() }
        base = String(base.prefix(60))
        return base.isEmpty ? "server" : base
    }

    /// The entry key a log file name ends with (`My-Site-1abc2d.log` → `1abc2d`); nil for anything else.
    static func key(of file: URL) -> String? {
        guard file.pathExtension == "log" else { return nil }
        let name = file.deletingPathExtension().lastPathComponent
        guard let dash = name.lastIndex(of: "-") else { return nil }
        let key = String(name[name.index(after: dash)...])
        return key.isEmpty ? nil : key
    }

    private static func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: HistoryStore.logDirectory, includingPropertiesForKeys: nil)) ?? []
    }

    /// Deletes the log of the entry with this file key (whatever its project was called at the time).
    static func remove(entryKey: String) {
        for file in files() where key(of: file) == entryKey {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Deletes logs and pictures whose entry is gone: history is capped, and older versions never cleaned up.
    static func removeOrphans(keeping entryKeys: Set<String>) {
        for file in files() {
            if let key = key(of: file), !entryKeys.contains(key) { try? FileManager.default.removeItem(at: file) }
        }
        let previews = HistoryStore.directory.appendingPathComponent("Previews", isDirectory: true)
        let pictures = (try? FileManager.default.contentsOfDirectory(at: previews, includingPropertiesForKeys: nil)) ?? []
        for file in pictures where file.pathExtension == "jpg" && !entryKeys.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Cuts a log that has grown past the limit back to its last lines. The server keeps the file
    /// open for appending, so it simply carries on writing at the new end.
    static func trimIfNeeded(_ url: URL, limit: Int = sizeLimit, keeping: Int = keptWhenTrimmed) {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size > limit, let reader = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? reader.close() }
        try? reader.seek(toOffset: UInt64(max(0, size - keeping)))
        let tail = reader.readDataToEndOfFile()
        guard truncate(url.path, 0) == 0, let writer = try? PrivateFiles.openLog(url, truncating: false) else { return }
        try? writer.write(contentsOf: tail)
        try? writer.close()
    }

    /// The whole log as text (the last `copyLimit` bytes if it is longer), without colour codes.
    static func contents(of url: URL, limit: Int = copyLimit) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(limit) ? end - UInt64(limit) : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        return LaunchedServer.stripANSI(text)
    }
}
