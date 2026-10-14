// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import Foundation

enum Shell {
    /// Long enough for a busy `lsof` or `simctl`, short enough that a hung child can't freeze scanning.
    static let defaultTimeout: TimeInterval = 15

    /// Xcode's developer directory, if one is installed in the usual place (`simctl` needs it).
    private static let developerDirectory: String? = [
        "/Applications/Xcode.app/Contents/Developer",
        "/Applications/Xcode-beta.app/Contents/Developer"
    ].first(where: { FileManager.default.fileExists(atPath: $0) })

    /// Runs a program with an argument list (never through a shell) and returns what it printed,
    /// or nil if it couldn't start or didn't finish within `timeout` seconds.
    static func run(
        _ path: String,
        arguments: [String] = [],
        mergingErrors: Bool = false,
        timeout: TimeInterval = defaultTimeout
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = pipe
            process.standardError = mergingErrors ? pipe : FileHandle.nullDevice

            var env = ProcessInfo.processInfo.environment
            if let developerDirectory { env["DEVELOPER_DIR"] = developerDirectory }
            process.environment = env

            let reader = pipe.fileHandleForReading
            let job = Job(process: process, reader: reader, continuation: continuation)

            // Drain the pipe while the child runs: waiting for the exit first deadlocks as soon
            // as the output outgrows the pipe buffer (`ps -A`, `launchctl list`).
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    job.outputEnded()
                } else {
                    job.append(chunk)
                }
            }
            process.terminationHandler = { _ in job.exited() }

            do {
                try process.run()
            } catch {
                reader.readabilityHandler = nil
                try? pipe.fileHandleForWriting.close()
                job.finish(nil)
                return
            }
            // Our copy of the write end must go now: until it does, EOF never reaches the reader
            // (every call then waited for the 0.5 s fallback) and both fds leak, since no
            // autorelease pool drains on this thread.
            try? pipe.fileHandleForWriting.close()
            job.armWatchdog(after: timeout, reader: reader)
        }
    }
}

/// One run of a child process. Resumes its continuation exactly once: when the child has
/// exited and its output is complete, or when the watchdog gives up on it.
private final class Job: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let reader: FileHandle
    private var continuation: CheckedContinuation<String?, Never>?
    private var output = Data()
    private var hasExited = false
    private var isDrained = false
    private var watchdog: DispatchWorkItem?

    init(process: Process, reader: FileHandle, continuation: CheckedContinuation<String?, Never>) {
        self.process = process
        self.reader = reader
        self.continuation = continuation
    }

    func append(_ chunk: Data) {
        lock.withLock { output.append(chunk) }
    }

    func exited() {
        let drained = lock.withLock { () -> Bool in
            hasExited = true
            return isDrained
        }
        if drained {
            finish(text())
        } else {
            // A grandchild that inherited the pipe can keep it open after the child is gone.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in finish(text()) }
        }
    }

    func outputEnded() {
        let exited = lock.withLock { () -> Bool in
            isDrained = true
            return hasExited
        }
        if exited { finish(text()) }
    }

    func armWatchdog(after seconds: TimeInterval, reader: FileHandle) {
        let item = DispatchWorkItem { [self] in
            reader.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            finish(nil)
        }
        let alreadyDone = lock.withLock { () -> Bool in
            if continuation == nil { return true }
            watchdog = item
            return false
        }
        if !alreadyDone { DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item) }
    }

    func finish(_ result: String?) {
        let pending = lock.withLock { () -> CheckedContinuation<String?, Never>? in
            watchdog?.cancel()
            defer { continuation = nil }
            return continuation
        }
        guard let pending else { return }
        reader.readabilityHandler = nil
        try? reader.close()
        pending.resume(returning: result)
    }

    private func text() -> String? {
        String(data: lock.withLock { output }, encoding: .utf8)
    }
}
