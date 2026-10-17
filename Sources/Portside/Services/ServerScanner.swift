// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import Foundation

enum ServerScanner {
    private static let devCommands: Set<String> = [
        "node", "python", "python3", "ruby", "cargo",
        "go", "php", "java", "deno", "bun", "tsx", "npx",
        "next-serv", "uvicorn", "gunicorn", "puma", "hugo", "caddy"
    ]

    /// A listening process is a dev server if it is a known runtime, or a program built from a Go or
    /// Rust project (`go run`, `cargo run`, or compiled by hand): those have arbitrary names, so they
    /// are recognised by where the binary lives (see `BuildOutput`).
    static func isDevServer(_ port: ListeningPort) -> Bool {
        let command = port.command.lowercased()
        if devCommands.contains(command) || command.hasPrefix("python3.") { return true }
        guard let executable = ProcessResolver.executablePath(of: port.pid) else { return false }
        return BuildOutput.kind(ofExecutable: executable) != nil
            || BuildOutput.isProjectBinary(executable, in: ProcessResolver.currentDirectory(of: port.pid))
    }

    /// nil when the ports couldn't be listed: the caller keeps what it had instead of
    /// concluding that every server has stopped.
    static func scan() async -> [DevServer]? {
        guard let ports = await PortScanner.scan() else { return nil }

        var seenPorts = Set<Int>()
        var seenPIDs = Set<Int>()
        let uniquePorts = ports.filter(isDevServer).filter { port in
            seenPorts.insert(port.port).inserted && seenPIDs.insert(port.pid).inserted
        }
        ResolvedCache.keep(pids: Set(uniquePorts.map(\.pid)))

        return await withTaskGroup(of: DevServer?.self) { group in
            for port in uniquePorts {
                group.addTask {
                    let startedAt = ProcessResolver.startTime(of: port.pid)
                    guard let info = await ResolvedCache.info(pid: port.pid, startedAt: startedAt) else { return nil }
                    return DevServer(
                        pid: port.pid,
                        port: port.port,
                        command: port.command,
                        framework: ProcessResolver.detectFramework(from: info),
                        projectName: await ProjectNames.name(for: info.workingDirectory),
                        projectPath: info.workingDirectory,
                        startedAt: startedAt
                    )
                }
            }

            // Self-test only: limit the scan to a demo folder for clean screenshots.
            let demoRoot = ProcessInfo.processInfo.environment["PORTSIDE_DEMO_ROOT"]
            var results: [DevServer] = []
            for await server in group {
                guard let server, demoRoot.map({ server.projectPath.hasPrefix($0) }) ?? true else { continue }
                results.append(server)
            }
            return results.sorted { $0.port < $1.port }
        }
    }
}

/// `ps` and the working directory of a server are looked up once per process, not on every scan.
/// Keyed by start time as well, so a recycled PID is looked up again.
private enum ResolvedCache {
    private struct Key: Hashable {
        let pid: Int
        let startedAt: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Key: ResolvedProcess] = [:]

    static func info(pid: Int, startedAt: Date?) async -> ResolvedProcess? {
        let key = Key(pid: pid, startedAt: Int(startedAt?.timeIntervalSince1970 ?? 0))
        if let cached = lock.withLock({ entries[key] }) { return cached }
        guard let info = await ProcessResolver.resolve(pid: pid) else { return nil }
        // Without a start time the process can't be told apart from a later one with the same PID.
        if startedAt != nil { lock.withLock { entries[key] = info } }
        return info
    }

    static func keep(pids: Set<Int>) {
        lock.withLock { entries = entries.filter { pids.contains($0.key.pid) } }
    }
}

enum ProcessTree {
    // Every descendant, not only direct children: npm → sh → node → next-server.
    static func descendants(of root: Int) async -> [Int] {
        guard let output = await Shell.run("/bin/ps", arguments: ["-A", "-o", "pid=,ppid="]) else { return [] }
        var children: [Int: [Int]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int(parts[0]), let ppid = Int(parts[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        var result: [Int] = []
        var queue = children[root] ?? []
        while let next = queue.popLast() {
            result.append(next)
            queue.append(contentsOf: children[next] ?? [])
        }
        return result
    }

    static func kill(_ root: Int) {
        Task.detached {
            let all = [root] + (await descendants(of: root))
            for pid in all { Darwin.kill(pid_t(pid), SIGTERM) }
            try? await Task.sleep(for: .seconds(1.5))
            for pid in all where Darwin.kill(pid_t(pid), 0) == 0 {
                Darwin.kill(pid_t(pid), SIGKILL)
            }
        }
    }
}

// Reading package.json inside Desktop or Documents blocks until macOS's privacy
// prompt is answered. Never let that stall the scan: fall back to the folder name.
enum ProjectNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var inFlight: Set<String> = []

    static func name(for directory: String) async -> String {
        let (cached, alreadyLooking) = lock.withLock {
            (cache[directory], cache[directory] == nil && !inFlight.insert(directory).inserted)
        }
        if let cached { return cached }

        let fallback = ProcessResolver.folderName(directory)
        guard !alreadyLooking else { return fallback }

        return await withCheckedContinuation { continuation in
            let gate = Gate()
            DispatchQueue.global(qos: .utility).async {
                let name = ProcessResolver.resolveProjectName(from: directory)
                lock.lock()
                cache[directory] = name
                inFlight.remove(directory)
                lock.unlock()
                if gate.open() { continuation.resume(returning: name) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
                if gate.open() { continuation.resume(returning: fallback) }
            }
        }
    }

    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func open() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if used { return false }
            used = true
            return true
        }
    }
}
