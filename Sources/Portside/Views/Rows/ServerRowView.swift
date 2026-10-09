import SwiftUI

struct ServerRowView: View {
    @Environment(AppState.self) private var appState
    let server: DevServer

    @State private var isHovered = false

    private var state: AppState.ActionState? { appState.restartStates[server.port] }
    private var isRestarting: Bool { state == .working }

    private var failureMessage: String? {
        if case .failed(let message) = state { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if let failureMessage {
                FailureBox(message: failureMessage)
                    .padding(.leading, HoverRowStyle.horizontalPadding + ColorBar.gutter)
                    .padding(.trailing, HoverRowStyle.horizontalPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: failureMessage)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ColorBar(color: failureMessage == nil ? server.framework.color : Color.alert, isWorking: isRestarting)

            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: server.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(verbatim: ":\(server.port)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                    subtitle
                }
            }

            Spacer(minLength: 8)

            if isHovered && !isRestarting {
                actions.transition(.opacity)
            }
        }
        .opacity(isRestarting ? 0.4 : 1)
        .allowsHitTesting(!isRestarting)
        .animation(.easeOut(duration: 0.2), value: isRestarting)
        .hoverRow { isHovered = $0 }
        .onTapGesture {
            guard failureMessage == nil else { return }
            appState.openInBrowser(server)
        }
        .contextMenu { menu }
        .help(Text(verbatim: server.projectPath))
    }

    @ViewBuilder
    private var subtitle: some View {
        if isRestarting {
            Text("restarting…").font(.system(size: 10)).foregroundStyle(.secondary)
        } else if failureMessage != nil {
            Text("failed to restart").font(.system(size: 10)).foregroundStyle(Color.alert)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(verbatim: detail(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func detail(now: Date) -> String {
        let kind = server.framework == .unknown ? server.command : server.framework.displayName
        guard let started = server.startedAt else { return kind }
        return "\(kind) · \(TimeText.duration(since: started, now: now))"
    }

    private var actions: some View {
        HStack(spacing: RowAction.spacing) {
            RowAction(symbol: "arrow.clockwise", help: "Restart") {
                appState.restart(server)
            }
            if failureMessage == nil {
                RowAction(symbol: "xmark", help: "Stop", tint: .alert) { appState.stop(server) }
            } else {
                RowAction(symbol: "xmark", help: "Dismiss", tint: .alert) { appState.dismissFailed(server) }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
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
