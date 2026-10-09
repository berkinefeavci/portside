import SwiftUI

// Right-click menus shared by the panel cards and the history rows.

struct ServerMenu: View {
    @Environment(AppState.self) private var appState
    let server: DevServer

    var body: some View {
        Button("Open in Browser") { appState.openInBrowser(server) }
        Button("Copy Address") { appState.copyToClipboard(text: "http://localhost:\(server.port)") }
        Divider()
        Button("Show in Finder") { appState.revealInFinder(server.projectPath) }
        Button("Open in Terminal") { appState.openInTerminal(server.projectPath) }
        if let entry = appState.entry(for: server) {
            Button("Copy Command") { appState.copyToClipboard(text: entry.shellCommand) }
            Button("Edit Command…") { appState.editingEntryID = entry.id }
            if entry.isPinned {
                Button("Unpin") { appState.togglePin(entry) }
            } else {
                Button("Pin") { appState.togglePin(entry) }
            }
        }
        Divider()
        Button("Restart") { appState.restart(server) }
        Button("Stop") { appState.stop(server) }
        Divider()
        Button("Hide This Project") { appState.ignore(projectPath: server.projectPath) }
    }
}

struct HistoryMenu: View {
    @Environment(AppState.self) private var appState
    let entry: HistoryEntry

    private var isRunning: Bool { appState.isRunning(entry) }

    var body: some View {
        if isRunning {
            Button("Open in Browser") { appState.reopen(entry) }
        } else {
            Button("Reopen") { appState.reopen(entry) }
        }
        Divider()
        Button("Show in Finder") { appState.revealInFinder(entry.projectPath) }
        Button("Open in Terminal") { appState.openInTerminal(entry.projectPath) }
        Button("Copy Command") { appState.copyToClipboard(text: entry.shellCommand) }
        Button("Edit Command…") { appState.editingEntryID = entry.id }
        if appState.logURL(for: entry) != nil {
            Button("Open Output Log") { appState.openLog(entry) }
        }
        Divider()
        if entry.isPinned {
            Button("Unpin") { appState.togglePin(entry) }
        } else {
            Button("Pin") { appState.togglePin(entry) }
        }
        Button("Hide This Project") { appState.ignore(projectPath: entry.projectPath) }
        if !isRunning {
            Button("Remove from History") { appState.forget(entry) }
        }
    }
}
