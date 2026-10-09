// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import Foundation

enum ServerScanner {
    private static let devCommands: Set<String> = [
        "node", "python", "python3", "ruby", "cargo",
        "go", "php", "java", "deno", "bun", "tsx", "npx",
        "next-serv", "uvicorn", "gunicorn", "puma", "hugo", "caddy"
    ]

    static func scan() async -> [DevServer] {
        let ports = await PortScanner.scan()

        let devPorts = ports.filter { port in
            let command = port.command.lowercased()
            return devCommands.contains(command) || command.hasPrefix("python3.")
        }

        var seenPorts = Set<Int>()
        var seenPIDs = Set<Int>()
        let uniquePorts = devPorts.filter { port in
            seenPorts.insert(port.port).inserted && seenPIDs.insert(port.pid).inserted
        }

        return await withTaskGroup(of: DevServer?.self) { group in
            for port in uniquePorts {
                group.addTask {
                    guard let info = await ProcessResolver.resolve(pid: port.pid) else { return nil }
                    return DevServer(
                        pid: port.pid,
                        port: port.port,
                        command: port.command,
                        framework: ProcessResolver.detectFramework(from: info),
                        projectName: await ProjectNames.name(for: info.workingDirectory),
                        projectPath: info.workingDirectory,
                        startedAt: ProcessResolver.startTime(of: port.pid)
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
