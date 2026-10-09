import Foundation

// Adapted from Blink (MIT, mo.software). Portside additionally reads the
// environment and start time, so a server can be reopened long after it stopped.

struct ResolvedProcess {
    let pid: Int
    let arguments: String
    let workingDirectory: String
}

enum ProcessResolver {
    // MARK: - Process Details

    static func resolve(pid: Int) async -> ResolvedProcess? {
        async let argsResult = Shell.run("/bin/ps", arguments: ["-p", "\(pid)", "-o", "args="])
        async let cwdResult = Shell.run("/usr/sbin/lsof", arguments: ["-d", "cwd", "-a", "-p", "\(pid)", "-Fn"])

        guard let args = await argsResult?.trimmingCharacters(in: .whitespacesAndNewlines),
              !args.isEmpty else { return nil }

        let cwd = await parseCWD(cwdResult ?? "")

        return ResolvedProcess(pid: pid, arguments: args, workingDirectory: cwd)
    }

    // MARK: - Real argv + environment

    struct LaunchInfo {
        let executablePath: String
        let argv: [String]
        let environment: [String: String]
    }

    static func launchInfo(pid: Int) -> LaunchInfo {
        let empty = LaunchInfo(executablePath: "", argv: [], environment: [:])
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0

        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return empty }

        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return empty }

        let argc = buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return empty }

        var index = MemoryLayout<Int32>.size

        func nextString() -> String {
            var bytes: [UInt8] = []
            while index < size, buffer[index] != 0 {
                bytes.append(buffer[index])
                index += 1
            }
            index += 1
            return String(decoding: bytes, as: UTF8.self)
        }

        let executable = nextString()
        while index < size, buffer[index] == 0 { index += 1 }

        var argv: [String] = []
        while index < size, argv.count < Int(argc) {
            argv.append(nextString())
        }

        // The environment follows argv and ends at the first empty string.
        var environment: [String: String] = [:]
        while index < size {
            let entry = nextString()
            guard !entry.isEmpty, let equals = entry.firstIndex(of: "=") else { break }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }

        return LaunchInfo(executablePath: executable, argv: argv, environment: environment)
    }

    // MARK: - Relaunch Target

    struct RelaunchTarget {
        let pid: Int
        let executablePath: String
        let arguments: [String]
        let environment: [String: String]
    }

    private static let maxAncestorHops = 5

    // Next.js and npm overwrite their own argv with a display title, so the
    // process holding the port often cannot be relaunched — walk up to one that can.
    static func relaunchTarget(pid: Int, projectPath: String) async -> RelaunchTarget? {
        var candidate: Int? = pid

        for _ in 0..<maxAncestorHops {
            guard let current = candidate else { return nil }

            let info = launchInfo(pid: current)
            let directory = await workingDirectory(pid: current)

            guard directory == projectPath else { return nil }

            if isRelaunchable(info) {
                return RelaunchTarget(
                    pid: current,
                    executablePath: info.executablePath,
                    arguments: Array(info.argv.dropFirst()),
                    environment: keepable(info.environment)
                )
            }

            candidate = parentPID(of: current)
        }

        return nil
    }

    private static func isRelaunchable(_ info: LaunchInfo) -> Bool {
        guard !info.executablePath.isEmpty,
              FileManager.default.isExecutableFile(atPath: info.executablePath),
              let first = info.argv.first,
              !first.contains(" ") else {
            return false
        }
        return !info.argv.dropFirst().contains(where: \.isEmpty)
    }

    // Secrets stay out of the history file; session-bound values would be stale anyway.
    private static let secretPattern = #"(SECRET|TOKEN|PASSWORD|PASSWD|API_?KEY|PRIVATE|CREDENTIAL|AUTH|COOKIE|SESSION)"#
    private static let staleKeys: Set<String> = [
        "_", "PWD", "OLDPWD", "SHLVL", "TERM_SESSION_ID", "ITERM_SESSION_ID",
        "SECURITYSESSIONID", "SSH_AUTH_SOCK", "LaunchInstanceID", "TMUX", "TMUX_PANE"
    ]

    static func keepable(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            !staleKeys.contains(key)
                && !key.hasPrefix("__CF")
                && !key.hasPrefix("XPC_")
                && key.uppercased().range(of: secretPattern, options: .regularExpression) == nil
        }
    }

    static func parentPID(of pid: Int) -> Int? {
        guard let info = kinfo(pid) else { return nil }
        let parent = Int(info.kp_eproc.e_ppid)
        return parent > 1 ? parent : nil
    }

    static func startTime(of pid: Int) -> Date? {
        guard let info = kinfo(pid) else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec))
    }

    private static func kinfo(_ pid: Int) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }

    static func workingDirectory(pid: Int) async -> String {
        let output = await Shell.run(
            "/usr/sbin/lsof",
            arguments: ["-d", "cwd", "-a", "-p", "\(pid)", "-Fn"]
        )
        return parseCWD(output ?? "")
    }

    // MARK: - Framework Detection

    static func detectFramework(from info: ResolvedProcess) -> Framework {
        let args = info.arguments.lowercased()

        if args.contains("next") { return .nextjs }
        if args.contains("vite") || args.contains("vitest") { return .vite }
        if args.contains("nuxt") { return .nuxt }
        if args.contains("remix") { return .remix }
        if args.contains("astro") { return .astro }
        if args.contains("webpack") { return .webpack }
        if args.contains("manage.py") || args.contains("django") { return .django }
        if args.contains("flask") { return .flask }
        if args.contains("uvicorn") || args.contains("fastapi") { return .fastapi }
        if args.contains("rails") || args.contains("puma") || args.contains("unicorn") { return .rails }
        if args.contains("cargo") { return .cargo }
        if args.contains("go run") || args.contains("go build") { return .go }
        if args.contains("php") || args.contains("artisan") { return .php }
        if args.contains("python") || args.contains("http.server") { return .python }

        return .unknown
    }

    // MARK: - Project Name

    static func resolveProjectName(from directory: String) -> String {
        let fm = FileManager.default

        let packageJSON = (directory as NSString).appendingPathComponent("package.json")
        if let data = fm.contents(atPath: packageJSON),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = json["name"] as? String, !name.isEmpty {
            return formatName(name)
        }

        let cargoToml = (directory as NSString).appendingPathComponent("Cargo.toml")
        if let content = try? String(contentsOfFile: cargoToml, encoding: .utf8),
           let range = content.range(of: #"name\s*=\s*"([^"]+)""#, options: .regularExpression) {
            let match = content[range]
            if let quoteStart = match.firstIndex(of: "\""),
               let quoteEnd = match[match.index(after: quoteStart)...].firstIndex(of: "\"") {
                return formatName(String(match[match.index(after: quoteStart)..<quoteEnd]))
            }
        }

        return folderName(directory)
    }

    static func folderName(_ directory: String) -> String {
        let name = (directory as NSString).lastPathComponent
        return formatName(name.isEmpty || name == "/" ? "Unknown" : name)
    }

    private static func formatName(_ name: String) -> String {
        let bare = name.hasPrefix("@") ? String(name.split(separator: "/").last ?? Substring(name)) : name
        return bare.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    static func parseCWD(_ output: String) -> String {
        for line in output.split(separator: "\n") where line.hasPrefix("n/") {
            return String(line.dropFirst())
        }
        return ""
    }
}
