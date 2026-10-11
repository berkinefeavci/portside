import AppKit
import SwiftUI

@MainActor
@Observable
final class AppState {
    var servers: [DevServer] = []
    var simulators: [Simulator] = []
    var isInitialLoad = true

    /// Everything Portside has ever seen, keyed by `HistoryEntry.id`.
    var history: [String: HistoryEntry] = [:]

    /// Why the history file could only be read in part, and why it couldn't be written; nil when all is well.
    var historyNotice: String?
    var historyWriteError: String?

    /// Running rows (by port) and history rows (by entry id) mid-action.
    var restartStates: [Int: ActionState] = [:]
    var openStates: [String: ActionState] = [:]
    var simulatorRestartStates: [String: ActionState] = [:]
    /// A short word about a simulator row that isn't a failure (it couldn't be brought to the front).
    var simulatorNotes: [String: String] = [:]

    /// The history entry whose command is open in the editor page, if any.
    var editingEntryID: String?

    var openBrowserAfterReopen: Bool = Defaults.bool("openBrowserAfterReopen", default: true) {
        didSet { UserDefaults.standard.set(openBrowserAfterReopen, forKey: "openBrowserAfterReopen") }
    }

    /// Project folders the user chose to hide.
    var ignoredPaths: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "ignoredPaths") ?? []) {
        didSet { UserDefaults.standard.set(Array(ignoredPaths).sorted(), forKey: "ignoredPaths") }
    }

    enum ActionState: Equatable {
        case working
        case failed(String)
    }

    /// Scanning spawns `lsof` and friends, so it is as rare as the screen allows: often while the
    /// panel is open or something is starting, slowly otherwise (the menu bar count only has to be roughly right).
    private static let openPollingInterval: TimeInterval = 3
    private static let idlePollingInterval: TimeInterval = 10
    private static let recentLimit = 5

    /// Set by the menu bar controller while the panel is on screen.
    @ObservationIgnored var isPanelOpen = false {
        didSet { if oldValue != isPanelOpen { restartPolling() } }
    }

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var isScanning = false

    // Running PID → history entry, and → the process that can be launched again.
    private var pidKeys: [Int: String] = [:]
    private var rootPIDs: [Int: Int] = [:]
    private var runningKeys: Set<String> = []

    @ObservationIgnored private var killedPIDs: Set<Int> = []
    @ObservationIgnored private var killedSimUDIDs: Set<String> = []
    @ObservationIgnored private var launched: [String: LaunchedServer] = [:]

    // Restarts: which history entry a port's row belongs to and which process it showed, kept
    // for as long as the row is on screen (a failed restart leaves no running process to ask).
    @ObservationIgnored private var restartEntryIDs: [Int: String] = [:]
    @ObservationIgnored private var restartedPIDs: [Int: Int] = [:]

    init(polling: Bool = true) {
        let loaded = HistoryStore.read()
        history = loaded.entries
        historyNotice = loaded.notice

        guard polling else { return }
        restartPolling(refreshingFirst: true)

        // Off the main thread: folders in the user's Library can be slow to answer.
        let tidiesDefaultFolders = ProcessInfo.processInfo.environment["PORTSIDE_DATA_DIR"] == nil
        // Pictures and logs of entries that no longer exist. Never when the history couldn't be read
        // properly: then the files are all that is left of it.
        let keys: Set<String>? = !loaded.entries.isEmpty && loaded.notice == nil
            ? Set(loaded.entries.keys.map(HistoryEntry.fileKey(for:))) : nil
        Task.detached(priority: .utility) {
            if tidiesDefaultFolders {
                PrivateFiles.tighten(folders: [
                    HistoryStore.directory,
                    HistoryStore.directory.appendingPathComponent("Previews", isDirectory: true),
                    HistoryStore.logDirectory,
                ])
            }
            if let keys { LogFiles.removeOrphans(keeping: keys) }
        }
    }

    // MARK: - Derived

    var visibleServers: [DevServer] { servers.filter { !ignoredPaths.contains($0.projectPath) } }

    var isActive: Bool { !visibleServers.isEmpty || !simulators.isEmpty }

    func entry(for server: DevServer) -> HistoryEntry? {
        pidKeys[server.pid].flatMap { history[$0] }
    }

    /// The entry whose page picture stands for `entry`: its own, or else the newest one
    /// taken in the same folder (same port first). A server started with other arguments
    /// is a new entry, and it shouldn't lose its picture for that.
    func previewID(for entry: HistoryEntry) -> String {
        let previews = PreviewStore.shared
        if previews.hasImage(for: entry.id) { return entry.id }
        return history.values
            .filter { $0.projectPath == entry.projectPath && $0.id != entry.id }
            .sorted { ($0.port == entry.port ? 1 : 0, $0.lastSeen) > ($1.port == entry.port ? 1 : 0, $1.lastSeen) }
            .first { previews.hasImage(for: $0.id) }?.id ?? entry.id
    }

    func isRunning(_ entry: HistoryEntry) -> Bool { runningKeys.contains(entry.id) }

    private var closed: [HistoryEntry] {
        history.values
            .filter { !runningKeys.contains($0.id) && !ignoredPaths.contains($0.projectPath) }
            .sorted { ($0.lastStopped ?? $0.lastSeen) > ($1.lastStopped ?? $1.lastSeen) }
    }

    var pinnedClosed: [HistoryEntry] {
        closed.filter(\.isPinned).sorted { $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending }
    }

    var recentlyClosed: [HistoryEntry] {
        Array(closed.filter { !$0.isPinned }.prefix(Self.recentLimit))
    }

    /// Pinned servers first, then the most recently closed ones.
    func closedCards(limit: Int) -> [HistoryEntry] {
        Array((pinnedClosed + recentlyClosed).prefix(limit))
    }

    var hasWorkInFlight: Bool {
        openStates.values.contains(.working) || restartStates.values.contains(.working)
    }

    var allHistory: [HistoryEntry] {
        history.values
            .filter { !ignoredPaths.contains($0.projectPath) }
            .sorted { $0.lastSeen > $1.lastSeen }
    }

    var lastClosed: HistoryEntry? { closed.first(where: \.canRelaunch) }

    // MARK: - Polling

    private var pollingInterval: TimeInterval {
        isPanelOpen || hasWorkInFlight ? Self.openPollingInterval : Self.idlePollingInterval
    }

    private func restartPolling(refreshingFirst: Bool = false) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            if refreshingFirst { await self?.refresh() }
            while !Task.isCancelled {
                guard let interval = self?.pollingInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { return }
                await self?.refresh()
            }
        }
    }

    func refresh() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }

        async let scannedServers = ServerScanner.scan()
        async let scannedSims = SimulatorMonitor.scan()
        let (newServers, newSims) = await (scannedServers, scannedSims)
        await apply(servers: newServers, simulators: newSims)
    }

    /// Takes the result of a scan into the state. Anything the scan didn't change is left
    /// alone, so views that watch it aren't redrawn every few seconds for nothing.
    func apply(servers newServers: [DevServer]?, simulators newSims: [Simulator]?) async {
        // A scan that couldn't finish says nothing about what is running: keep what is shown.
        if let newServers {
            killedPIDs.formIntersection(newServers.map(\.pid))

            let visible = newServers.filter { !killedPIDs.contains($0.pid) }
            await remember(visible)

            // A failed restart stays on screen until dismissed, or until something else serves that port.
            for server in visible {
                if case .failed = restartStates[server.port], restartedPIDs[server.port] != server.pid {
                    clearRestart(port: server.port)
                }
            }

            let merged = Self.preservingRestartingRows(scanned: visible, previous: servers, restartStates: restartStates)
            if servers != merged { servers = merged }
        }

        if let newSims {
            killedSimUDIDs.formIntersection(newSims.map(\.id))
            let sims = newSims.filter { !killedSimUDIDs.contains($0.id) }
            if simulators != sims { simulators = sims }
        }

        launched = launched.filter { $0.value.isRunning || runningKeys.contains($0.key) }
        for server in launched.values where server.isRunning { LogFiles.trimIfNeeded(server.logURL) }
        if isInitialLoad { isInitialLoad = false }
        refreshPreviews(maxAge: Self.backgroundPreviewAge)
    }

    // MARK: - Previews

    private static let backgroundPreviewAge: TimeInterval = 300
    private static let previewWarmUp: TimeInterval = 5

    /// Captures pages of running servers whose picture is older than `maxAge`,
    /// giving a fresh server a few seconds to finish its first build.
    func refreshPreviews(maxAge: TimeInterval) {
        let now = Date()
        for server in visibleServers {
            guard let id = pidKeys[server.pid] else { continue }
            if let started = server.startedAt, now.timeIntervalSince(started) < Self.previewWarmUp { continue }
            PreviewStore.shared.capture(entryID: id, port: server.port, maxAge: maxAge)
        }
    }

    /// A row whose restart is under way, or failed, stays in the list although its process is gone:
    /// it is where the progress, and the reason for a failure, are shown.
    static func preservingRestartingRows(
        scanned: [DevServer], previous: [DevServer], restartStates: [Int: ActionState]
    ) -> [DevServer] {
        var merged = scanned
        for port in restartStates.keys where !merged.contains(where: { $0.port == port }) {
            if let row = previous.first(where: { $0.port == port }) { merged.append(row) }
        }
        return merged.sorted { $0.port < $1.port }
    }

    // MARK: - History

    // New PIDs are resolved before the rows are published, so a running server
    // never flashes up under "Recently Closed" first.
    private func remember(_ scanned: [DevServer]) async {
        let now = Date()
        let fresh = scanned.filter { pidKeys[$0.pid] == nil && !$0.projectPath.isEmpty }
        var changed = false

        let targets = await withTaskGroup(of: (DevServer, ProcessResolver.RelaunchTarget?).self) { group in
            for server in fresh {
                group.addTask {
                    (server, await ProcessResolver.relaunchTarget(pid: server.pid, projectPath: server.projectPath))
                }
            }
            var results: [(DevServer, ProcessResolver.RelaunchTarget?)] = []
            for await pair in group { results.append(pair) }
            return results
        }

        let launchedRoots = Dictionary(launched.map { ($0.value.pid, $0.key) }, uniquingKeysWith: { a, _ in a })

        for (server, target) in targets {
            // Started by Portside: belongs to that entry whatever its command looks like
            // from the inside (a custom shell command, a wrapper that execs, …).
            if let (rootPID, id) = Self.launchedAncestor(of: server.pid, in: launchedRoots), history[id] != nil {
                pidKeys[server.pid] = id
                rootPIDs[server.pid] = rootPID
                history[id]?.port = server.port
                history[id]?.lastSeen = now
                history[id]?.lastStopped = nil
                if let entry = history[id] { history[id] = Self.counted(entry, startedAt: server.startedAt) }
                changed = true
                continue
            }

            let display = await ProcessResolver.resolve(pid: target?.pid ?? server.pid)?.arguments ?? server.command
            let id = HistoryEntry.makeID(
                projectPath: server.projectPath,
                executable: target?.executablePath,
                arguments: target?.arguments ?? [display]
            )
            pidKeys[server.pid] = id
            if let target { rootPIDs[server.pid] = target.pid }

            if var entry = history[id] {
                entry.port = server.port
                entry.projectName = server.projectName
                entry.framework = server.framework
                entry.lastSeen = now
                entry.lastStopped = nil
                entry = Self.counted(entry, startedAt: server.startedAt)
                if let target, !target.environment.isEmpty { entry.environment = target.environment }
                history[id] = entry
            } else {
                history[id] = HistoryEntry(
                    id: id,
                    projectName: server.projectName,
                    projectPath: server.projectPath,
                    port: server.port,
                    framework: server.framework,
                    executable: target?.executablePath,
                    arguments: target?.arguments ?? [],
                    environment: target?.environment ?? [:],
                    displayCommand: display,
                    customCommand: nil,
                    firstSeen: now,
                    lastSeen: now,
                    lastStopped: nil,
                    lastStarted: server.startedAt,
                    runCount: 1,
                    isPinned: false
                )
            }
            changed = true
        }

        let activePIDs = Set(scanned.map(\.pid))
        pidKeys = pidKeys.filter { activePIDs.contains($0.key) }
        rootPIDs = rootPIDs.filter { activePIDs.contains($0.key) }

        let nowRunning = Set(pidKeys.values)
        for id in runningKeys.subtracting(nowRunning) {
            history[id]?.lastStopped = now
            history[id]?.lastSeen = now
            changed = true
        }
        // Keep "last seen" honest for long-running servers without rewriting the file every scan.
        for id in nowRunning {
            if let seen = history[id]?.lastSeen, now.timeIntervalSince(seen) > 60 {
                history[id]?.lastSeen = now
                changed = true
            }
        }
        if runningKeys != nowRunning { runningKeys = nowRunning }

        if changed { persist() }
    }

    /// Counts a run only when the process really is a new one.
    static func counted(_ entry: HistoryEntry, startedAt: Date?) -> HistoryEntry {
        var entry = entry
        let isNewRun = startedAt == nil || entry.lastStarted == nil
            || abs(startedAt!.timeIntervalSince(entry.lastStarted!)) > 1
        if isNewRun { entry.runCount += 1 }
        entry.lastStarted = startedAt
        return entry
    }

    private static func launchedAncestor(of pid: Int, in roots: [Int: String]) -> (Int, String)? {
        guard !roots.isEmpty else { return nil }
        var current: Int? = pid
        for _ in 0..<12 {
            guard let candidate = current else { return nil }
            if let id = roots[candidate] { return (candidate, id) }
            current = ProcessResolver.parentPID(of: candidate)
        }
        return nil
    }

    func togglePin(_ entry: HistoryEntry) {
        history[entry.id]?.isPinned.toggle()
        persist()
    }

    func setCustomCommand(_ command: String?, for entry: HistoryEntry) {
        let trimmed = command?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Saving the text that was filled in for the user, unchanged, is not a custom command.
        let isDetected = trimmed == entry.detectedShellCommand
        history[entry.id]?.customCommand = (trimmed?.isEmpty ?? true) || isDetected ? nil : trimmed
        openStates[entry.id] = nil
        persist()
    }

    func forget(_ entry: HistoryEntry) {
        withAnimation(.easeOut(duration: 0.25)) {
            openStates[entry.id] = nil
            history[entry.id] = nil
        }
        removeFiles(of: entry)
        persist()
    }

    func clearHistory() {
        let kept = history.filter { $0.value.isPinned || runningKeys.contains($0.key) }
        let dropped = history.filter { kept[$0.key] == nil }.values
        withAnimation(.easeOut(duration: 0.25)) { history = kept }
        dropped.forEach(removeFiles(of:))
        persist()
    }

    /// Writes the history, within its limit. Entries that don't fit any more go, with their picture and log.
    private func persist() {
        let kept = HistoryStore.trimmed(history, protecting: runningKeys)
        if kept.count < history.count {
            let dropped = history.filter { kept[$0.key] == nil }.values
            history = kept
            dropped.forEach(removeFiles(of:))
        }
        historyWriteError = HistoryStore.save(history)?.localizedDescription
    }

    /// An entry's page picture and output log are deleted with it.
    private func removeFiles(of entry: HistoryEntry) {
        PreviewStore.shared.forget(entryID: entry.id)
        LogFiles.remove(entryKey: HistoryEntry.fileKey(for: entry.id))
    }

    func ignore(projectPath: String) {
        withAnimation(.easeOut(duration: 0.25)) { _ = ignoredPaths.insert(projectPath) }
    }

    func showIgnoredProjects() {
        withAnimation(.easeOut(duration: 0.25)) { ignoredPaths = [] }
    }

    // MARK: - Reopen

    func reopenLastClosed() {
        if let last = lastClosed { reopen(last) }
    }

    func reopen(_ entry: HistoryEntry) {
        guard openStates[entry.id] != .working else { return }

        if runningKeys.contains(entry.id) {
            if let server = servers.first(where: { pidKeys[$0.pid] == entry.id }) { openInBrowser(server) }
            return
        }

        guard let command = entry.launchCommand else {
            let reason = String(localized: "Portside couldn't read how this server was started. Use Edit Command… to tell it, or start it yourself:\n\(entry.displayCommand)")
            withAnimation(.easeOut(duration: 0.2)) { openStates[entry.id] = .failed(reason) }
            return
        }

        withAnimation(.easeOut(duration: 0.2)) { openStates[entry.id] = .working }

        Task {
            let failure = await launch(entry, command: command)
            withAnimation(.easeOut(duration: 0.25)) {
                openStates[entry.id] = failure.map { .failed($0) }
            }
            if failure == nil, openBrowserAfterReopen,
               let server = servers.first(where: { pidKeys[$0.pid] == entry.id }) {
                openInBrowser(server)
            }
        }
    }

    func dismissOpenFailure(_ entry: HistoryEntry) {
        withAnimation(.easeOut(duration: 0.2)) { openStates[entry.id] = nil }
    }

    private static let launchTimeout: TimeInterval = 60

    /// Starts the entry's command and waits until a server belonging to it is
    /// listening again — on whatever port it picks.
    private func launch(_ entry: HistoryEntry, command: (executable: String, arguments: [String])) async -> String? {
        let missing = await Task.detached { () -> String? in
            let fm = FileManager.default
            var isDirectory: ObjCBool = false
            if !fm.fileExists(atPath: entry.projectPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
                return String(localized: "The project folder is gone:\n\(entry.projectPath)")
            }
            if !fm.isExecutableFile(atPath: command.executable) {
                return String(localized: "The program is gone (was it updated or moved?). Use Edit Command… to start it another way:\n\(command.executable)")
            }
            return nil
        }.value
        if let missing { return missing }

        let server: LaunchedServer
        do {
            server = try LaunchedServer(
                executable: command.executable,
                arguments: command.arguments,
                directory: entry.projectPath,
                environment: entry.environment,
                logName: Self.logName(for: entry)
            )
        } catch {
            return String(localized: "Couldn't start: \(error.localizedDescription)")
        }
        launched[entry.id] = server

        let deadline = Date().addingTimeInterval(Self.launchTimeout)
        while Date() < deadline {
            try? await Task.sleep(for: .seconds(0.7))
            await refresh()
            if runningKeys.contains(entry.id) { return nil }

            if !server.isRunning {
                try? await Task.sleep(for: .seconds(1))
                await refresh()
                if runningKeys.contains(entry.id) { return nil }
                let tail = server.outputTail()
                return tail.isEmpty ? server.exitDescription : tail
            }
        }

        let tail = server.outputTail()
        return tail.isEmpty ? String(localized: "Running, but nothing is listening yet.") : tail
    }

    static func logName(for entry: HistoryEntry) -> String { LogFiles.name(for: entry) }

    func logURL(for entry: HistoryEntry) -> URL? {
        if let url = launched[entry.id]?.logURL { return url }
        let url = LogFiles.url(for: entry)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Running servers

    func stop(_ server: DevServer) {
        clearRestart(port: server.port)
        withAnimation(.easeOut(duration: 0.3)) {
            servers.removeAll { $0.port == server.port }
        }
        // A row left behind by a failed restart has no process any more; its PID may belong to another one.
        guard Self.isStillRunning(server) else { return }
        killedPIDs.insert(server.pid)
        if let id = pidKeys[server.pid] { history[id]?.lastStopped = Date() }
        ProcessTree.kill(rootPIDs[server.pid] ?? server.pid)
    }

    /// Whether `server` is still the process it was when scanned (a PID can be handed to a new process).
    static func isStillRunning(_ server: DevServer) -> Bool {
        guard let started = ProcessResolver.startTime(of: server.pid) else { return false }
        guard let known = server.startedAt else { return true }
        return abs(started.timeIntervalSince(known)) < 2
    }

    func stopAllServers() {
        for server in visibleServers { stop(server) }
    }

    func dismissFailed(_ server: DevServer) {
        withAnimation(.easeOut(duration: 0.3)) {
            clearRestart(port: server.port)
            servers.removeAll { $0.port == server.port }
        }
    }

    private func clearRestart(port: Int) {
        restartStates[port] = nil
        restartEntryIDs[port] = nil
        restartedPIDs[port] = nil
    }

    /// The history entry a running row (or one whose restart failed) belongs to.
    private func entryID(forRowOf server: DevServer) -> String? {
        pidKeys[server.pid] ?? restartEntryIDs[server.port]
    }

    func restart(_ server: DevServer) {
        guard restartStates[server.port] != .working else { return }
        restartedPIDs[server.port] = server.pid
        guard let id = entryID(forRowOf: server), let entry = history[id], let command = entry.launchCommand else {
            withAnimation { restartStates[server.port] = .failed(String(localized: "Couldn't read the original command.")) }
            return
        }
        restartEntryIDs[server.port] = id

        withAnimation(.easeOut(duration: 0.2)) { restartStates[server.port] = .working }

        Task {
            // Starting again after a failure: the old process is long gone, and its PID may be someone else's.
            if Self.isStillRunning(server) {
                killedPIDs.insert(server.pid)
                ProcessTree.kill(rootPIDs[server.pid] ?? server.pid)

                guard await waitForPortFree(server.port) else {
                    finishRestart(server.port, failure: String(localized: "Port \(server.port) never freed up."))
                    return
                }
            }

            let failure = await launch(entry, command: command)
            finishRestart(server.port, failure: failure)
        }
    }

    private func finishRestart(_ port: Int, failure: String?) {
        withAnimation(.easeOut(duration: 0.25)) {
            if let failure {
                restartStates[port] = .failed(failure)
            } else {
                clearRestart(port: port)
            }
        }
    }

    /// The server's output log, for the failure box under its card.
    func logURL(forRowOf server: DevServer) -> URL? {
        entryID(forRowOf: server).flatMap { history[$0] }.flatMap(logURL(for:))
    }

    private func waitForPortFree(_ port: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if !(await isListening(port)) { return true }
            try? await Task.sleep(for: .seconds(0.4))
        }
        return !(await isListening(port))
    }

    private func isListening(_ port: Int) async -> Bool {
        let output = await Shell.run("/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        return !(output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    // MARK: - Simulators

    func restartApp(in simulator: Simulator) {
        guard let app = simulator.runningApp, simulatorRestartStates[simulator.id] != .working else { return }
        withAnimation(.easeOut(duration: 0.2)) { simulatorRestartStates[simulator.id] = .working }
        Task {
            let failure = await SimulatorMonitor.relaunchApp(udid: simulator.id, bundleID: app.bundleID)
            withAnimation(.easeOut(duration: 0.25)) {
                simulatorRestartStates[simulator.id] = failure.map { .failed($0) }
            }
        }
    }

    func dismissSimulatorFailure(_ simulator: Simulator) {
        withAnimation(.easeOut(duration: 0.25)) { simulatorRestartStates[simulator.id] = nil }
    }

    func stopSimulator(_ simulator: Simulator) {
        simulatorRestartStates[simulator.id] = nil
        killedSimUDIDs.insert(simulator.id)
        withAnimation(.easeOut(duration: 0.3)) { simulators.removeAll { $0.id == simulator.id } }
        Task { await SimulatorMonitor.shutdown(udid: simulator.id) }
    }

    func shutDownAllSimulators() {
        for simulator in simulators { stopSimulator(simulator) }
    }

    // MARK: - Shortcuts

    func openInBrowser(_ server: DevServer) {
        if let url = server.localhostURL { NSWorkspace.shared.open(url) }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openInTerminal(_ path: String) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func copyToClipboard(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func openLog(_ entry: HistoryEntry) {
        if let url = logURL(for: entry) { NSWorkspace.shared.open(url) }
    }
}

enum Defaults {
    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}
