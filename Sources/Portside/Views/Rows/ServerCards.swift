import SwiftUI

// MARK: - Preview

/// The page picture, or a framework-coloured stand-in until the first one exists.
struct PreviewThumb: View {
    let entryID: String?
    let framework: Framework
    let port: Int
    var dimmed = false

    static let aspect: CGFloat = 16.0 / 10.0

    var body: some View {
        let image = entryID.flatMap { PreviewStore.shared.image(for: $0) }
        Color.clear
            .aspectRatio(Self.aspect, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .saturation(dimmed ? 0 : 1)
                        .brightness(dimmed ? -0.12 : 0)
                } else {
                    placeholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [framework.color.opacity(dimmed ? 0.12 : 0.35), framework.color.opacity(dimmed ? 0.04 : 0.10)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Text(verbatim: ":\(port)")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(dimmed ? 0.35 : 0.8))
        }
    }
}

// MARK: - Card chrome

private struct CardChrome: ViewModifier {
    let isFailed: Bool
    @Binding var isHovered: Bool
    @Environment(ScrollActivity.self) private var scrollActivity

    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.11 : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(isFailed ? Color.alert.opacity(0.8) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(isHovered ? 1.015 : 1)
            .animation(.easeOut(duration: 0.15), value: isHovered)
            .onHover { hovering in
                if hovering && scrollActivity.isScrolling { return }
                isHovered = hovering
            }
    }
}

private struct CardCaption: View {
    let title: String
    let port: Int
    let subtitle: String
    var isLive = false
    var isPinned = false
    var subtitleColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                if isLive {
                    Circle().fill(Color.running).frame(width: 7, height: 7)
                        .shadow(color: Color.running.opacity(0.6), radius: 3)
                }
                if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.secondary)
                }
                Text(verbatim: title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text(verbatim: ":\(port)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Text(verbatim: subtitle)
                .font(.system(size: 10))
                .foregroundStyle(subtitleColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 2)
        .padding(.top, 6)
    }
}

private struct SmallGlassButton: View {
    let symbol: String
    let help: LocalizedStringKey
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Circle().fill((tint ?? Color.black).opacity(tint == nil ? 0.55 : 0.9)))
                .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Running

struct RunningCard: View {
    @Environment(AppState.self) private var appState
    let server: DevServer
    @State private var isHovered = false

    private var state: AppState.ActionState? { appState.restartStates[server.port] }
    private var isRestarting: Bool { state == .working }
    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewThumb(entryID: appState.entry(for: server)?.id, framework: server.framework, port: server.port)
                .overlay(alignment: .topTrailing) {
                    if isHovered && !isRestarting {
                        HStack(spacing: 4) {
                            SmallGlassButton(symbol: "arrow.clockwise", help: "Restart") { appState.restart(server) }
                            if isFailed {
                                SmallGlassButton(symbol: "xmark", help: "Dismiss", tint: .alert) { appState.dismissFailed(server) }
                            } else {
                                SmallGlassButton(symbol: "stop.fill", help: "Stop", tint: .alert) { appState.stop(server) }
                            }
                        }
                        .padding(5)
                        .transition(.opacity)
                    }
                }
                .overlay { if isRestarting { ProgressView().controlSize(.small) } }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                CardCaption(
                    title: server.projectName,
                    port: server.port,
                    subtitle: subtitle(now: context.date),
                    isLive: !isRestarting && !isFailed,
                    subtitleColor: isFailed ? .alert : .secondary
                )
            }
        }
        .opacity(isRestarting ? 0.6 : 1)
        .modifier(CardChrome(isFailed: isFailed, isHovered: $isHovered))
        .onTapGesture { if !isFailed { appState.openInBrowser(server) } }
        .contextMenu { ServerMenu(server: server) }
        .help(Text(verbatim: server.projectPath))
    }

    private func subtitle(now: Date) -> String {
        if isRestarting { return String(localized: "restarting…") }
        if isFailed { return String(localized: "failed to restart") }
        let kind = server.framework == .unknown ? server.command : server.framework.displayName
        guard let started = server.startedAt else { return kind }
        return "\(kind) · \(TimeText.duration(since: started, now: now))"
    }
}

// MARK: - Closed

struct ClosedCard: View {
    @Environment(AppState.self) private var appState
    let entry: HistoryEntry
    @State private var isHovered = false

    private var state: AppState.ActionState? { appState.openStates[entry.id] }
    private var isOpening: Bool { state == .working }
    private var isFailed: Bool { if case .failed = state { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PreviewThumb(entryID: entry.id, framework: entry.framework, port: entry.port, dimmed: true)
                .overlay {
                    if isOpening {
                        ProgressView().controlSize(.small)
                    } else if isHovered && !isFailed {
                        Label("Reopen", systemImage: "arrow.counterclockwise")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(.white))
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isHovered && isFailed {
                        HStack(spacing: 4) {
                            SmallGlassButton(symbol: "square.and.pencil", help: "Edit Command…") { appState.editingEntryID = entry.id }
                            SmallGlassButton(symbol: "xmark", help: "Dismiss", tint: .alert) { appState.dismissOpenFailure(entry) }
                        }
                        .padding(5)
                    }
                }

            TimelineView(.periodic(from: .now, by: 30)) { context in
                CardCaption(
                    title: entry.projectName,
                    port: entry.port,
                    subtitle: subtitle(now: context.date),
                    isPinned: entry.isPinned,
                    subtitleColor: isFailed ? .alert : .secondary
                )
            }
            .opacity(0.85)
        }
        .modifier(CardChrome(isFailed: isFailed, isHovered: $isHovered))
        .onTapGesture { if !isFailed { appState.reopen(entry) } }
        .contextMenu { HistoryMenu(entry: entry) }
        .help(Text(verbatim: "\(entry.projectPath)\n\(entry.shellCommand)"))
    }

    private func subtitle(now: Date) -> String {
        if isOpening { return String(localized: "starting…") }
        if isFailed { return String(localized: "couldn't start") }
        let when = TimeText.ago(entry.lastStopped ?? entry.lastSeen, now: now)
        return entry.canRelaunch ? String(localized: "closed \(when)") : String(localized: "\(when) · no command")
    }
}

// MARK: - Grid + failures

struct CardGrid<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(items) { card($0) }
        }
    }
}

/// Full error text under the grid; a card is too narrow to read it.
struct FailureNotes: View {
    let failures: [(id: String, title: String, message: String)]

    var body: some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(failures, id: \.id) { failure in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: failure.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.alert)
                        FailureBox(message: failure.message)
                    }
                }
            }
            .padding(.top, 8)
            .transition(.opacity)
        }
    }
}
