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
        guard let args = await Shell.run("/bin/ps", arguments: ["-p", "\(pid)", "-o", "args="])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !args.isEmpty else { return nil }

        return ResolvedProcess(pid: pid, arguments: args, workingDirectory: await workingDirectory(pid: pid))
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
    // A compiled program from `go run` or `cargo run` is only a build output: start the
    // command that built it instead (it rebuilds, and Go deletes its binary on exit).
    static func relaunchTarget(pid: Int, projectPath: String) async -> RelaunchTarget? {
        var candidate: Int? = pid
        var sawBuildOutput = false
        var cargoBinary: RelaunchTarget?

        for _ in 0..<maxAncestorHops {
            guard let current = candidate else { break }

            let info = launchInfo(pid: current)
            let directory = await workingDirectory(pid: current)

            guard directory == projectPath else { break }

            let kind = BuildOutput.kind(ofExecutable: info.executablePath)
            sawBuildOutput = sawBuildOutput || kind != nil

            if isRelaunchable(info) {
                let target = RelaunchTarget(
                    pid: current,
                    executablePath: info.executablePath,
                    arguments: Array(info.argv.dropFirst()),
                    environment: SavedEnvironment.filtered(info.environment)
                )
                if kind == .cargo {
                    cargoBinary = cargoBinary ?? target
                } else if kind == nil, !sawBuildOutput || BuildOutput.isBuilder(info.executablePath) {
                    return target
                }
            }

            candidate = parentPID(of: current)
        }

        // Without a `cargo run` above it, the compiled program itself is still a fine thing to start.
        return cargoBinary
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

    /// The folder a process runs in, asked of the kernel directly: no `lsof` to spawn.
    static func currentDirectory(of pid: Int) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(Int32(pid), PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    static func workingDirectory(pid: Int) async -> String {
        if let directory = currentDirectory(of: pid) { return directory }
        let output = await Shell.run(
            "/usr/sbin/lsof",
            arguments: ["-d", "cwd", "-a", "-p", "\(pid)", "-Fn"]
        )
        return parseCWD(output ?? "")
    }

    /// The program a process is running, without parsing its whole argument block.
    static func executablePath(of pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    // MARK: - Framework Detection

    static func detectFramework(from info: ResolvedProcess) -> Framework {
        let args = info.arguments.lowercased()

        if mentionsNext(args) { return .nextjs }
        if args.contains("vite") || args.contains("vitest") { return .vite }
        if args.contains("nuxt") { return .nuxt }
        if args.contains("remix") { return .remix }
        if args.contains("astro") { return .astro }
        if args.contains("webpack") { return .webpack }
        if args.contains("manage.py") || args.contains("django") { return .django }
        if args.contains("flask") { return .flask }
        if args.contains("uvicorn") || args.contains("fastapi") { return .fastapi }
        if args.contains("rails") || args.contains("puma") || args.contains("unicorn") { return .rails }
        if args.contains("cargo") || BuildOutput.kind(ofExecutable: args) == .cargo { return .cargo }
        if args.contains("go run") || args.contains("go build") || BuildOutput.kind(ofExecutable: args) == .goRun { return .go }
        if args.contains("php") || args.contains("artisan") { return .php }
        if args.contains("python") || args.contains("http.server") { return .python }

        return .unknown
    }

    /// "next" as a program or package name (`.bin/next dev`, `node_modules/next/…`, `next-server (v14)`),
    /// not as part of a path such as `/Users/me/nextcloud/`.
    private static func mentionsNext(_ args: String) -> Bool {
        args.range(of: #"(^|[\s/])next(-[a-z]+)*([\s/]|$)"#, options: .regularExpression) != nil
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
