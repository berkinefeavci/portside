import Foundation

/// Everything Portside keeps on disk can hold things the user wouldn't hand out: the commands
/// they ran, pictures of their pages, what their servers printed. Files are readable by the
/// user only (0600) from the moment they exist, folders likewise (0700).
enum PrivateFiles {
    /// Creates the folder (0700) if it isn't there; one that exists is left as it is.
    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Folders and files made by earlier versions are readable by others (0755/0644). Tightens
    /// Portside's own: only ever called for the default locations, never for a folder the user chose.
    static func tighten(folders: [URL]) {
        let fileManager = FileManager.default
        for folder in folders where fileManager.fileExists(atPath: folder.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            for file in (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? [] {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }

    /// Replaces the file atomically: the data goes to a private temporary file that is renamed over it.
    static func write(_ data: Data, to url: URL) throws {
        try createDirectory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, url.path) == 0 else { throw posixError() }
        } catch {
            try? handle.close()
            unlink(temporary.path)
            throw error
        }
    }

    /// A log for a child process to write to. Opened for appending, so the file can be
    /// shortened while the child still has it open.
    static func openLog(_ url: URL, truncating: Bool) throws -> FileHandle {
        try createDirectory(url.deletingLastPathComponent())
        let flags = O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | (truncating ? O_TRUNC : 0)
        let descriptor = open(url.path, flags, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        fchmod(descriptor, 0o600)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private static func posixError() -> Error {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
