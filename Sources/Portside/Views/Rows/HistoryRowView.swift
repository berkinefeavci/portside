import SwiftUI

// A server from history: one click starts it again with the command,
// folder and environment it originally ran with.
struct HistoryRowView: View {
    @Environment(AppState.self) private var appState
    let entry: HistoryEntry

    @State private var isHovered = false

    private var state: AppState.ActionState? { appState.openStates[entry.id] }
    private var isOpening: Bool { state == .working }
    private var isRunning: Bool { appState.isRunning(entry) }

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

    private var barColor: Color {
        if failureMessage != nil { return .alert }
        if isRunning { return entry.framework.color }
        return entry.framework.color.opacity(0.35)
    }

    private var header: some View {
        HStack(spacing: 0) {
            ColorBar(color: barColor, isWorking: isOpening)

            PreviewThumb(entryID: entry.id, framework: entry.framework, port: entry.port, dimmed: !isRunning)
                .frame(width: 58)
                .padding(.trailing, 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(verbatim: entry.projectName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isRunning ? .primary : .secondary)
                        .lineLimit(1)
                    if entry.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel(Text("Pinned"))
                    }
                    if entry.hasCustomCommand {
                        Image(systemName: "terminal")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .help(Text("Starts with your own command"))
                    }
                }

                HStack(spacing: 6) {
                    Text(verbatim: ":\(entry.port)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    subtitle
                }
            }

            Spacer(minLength: 8)

            if isHovered && !isOpening {
                actions.transition(.opacity)
            }
        }
        .opacity(isOpening ? 0.5 : 1)
        .allowsHitTesting(!isOpening)
        .animation(.easeOut(duration: 0.2), value: isOpening)
        .hoverRow { isHovered = $0 }
        .onTapGesture {
            guard failureMessage == nil else { return }
            appState.reopen(entry)
        }
        .contextMenu { HistoryMenu(entry: entry) }
        .help(Text(verbatim: "\(entry.projectPath)\n\(entry.shellCommand)"))
    }

    @ViewBuilder
    private var subtitle: some View {
        if isOpening {
            Text("starting…").font(.system(size: 10)).foregroundStyle(.secondary)
        } else if failureMessage != nil {
            Text("couldn't start").font(.system(size: 10)).foregroundStyle(Color.alert)
        } else if isRunning {
            Text("running").font(.system(size: 10)).foregroundStyle(Color.running)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(verbatim: closedText(now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func closedText(now: Date) -> String {
        let when = TimeText.ago(entry.lastStopped ?? entry.lastSeen, now: now)
        let state = entry.canRelaunch ? String(localized: "closed \(when)") : String(localized: "\(when) · no command")
        return entry.framework == .unknown ? state : "\(entry.framework.displayName) · \(state)"
    }

    private var actions: some View {
        HStack(spacing: RowAction.spacing) {
            if failureMessage != nil {
                RowAction(symbol: "square.and.pencil", help: "Edit Command…") {
                    appState.editingEntryID = entry.id
                }
                RowAction(symbol: "xmark", help: "Dismiss", tint: .alert) {
                    appState.dismissOpenFailure(entry)
                }
            } else {
                if isRunning {
                    RowAction(symbol: "safari", help: "Open in Browser") { appState.reopen(entry) }
                } else {
                    RowAction(symbol: "play.fill", help: "Reopen") { appState.reopen(entry) }
                }
                if entry.isPinned {
                    RowAction(symbol: "pin.slash", help: "Unpin") { appState.togglePin(entry) }
                } else {
                    RowAction(symbol: "pin", help: "Pin") { appState.togglePin(entry) }
                }
            }
        }
    }

}
