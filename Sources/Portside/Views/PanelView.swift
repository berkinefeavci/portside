import SwiftUI

struct PanelView: View {
    static let panelSize = CGSize(width: 340, height: 500)
    static let cornerRadius: CGFloat = 22

    @Environment(AppState.self) private var appState
    @State private var page: Page = .main
    @State private var returnPage: Page = .main

    enum Page { case main, history, settings, about, editCommand }

    var body: some View {
        ZStack(alignment: .topLeading) {
            mainPage
                .panelPage(isActive: page == .main, restingOffset: -24)

            HistoryPage(isVisible: page == .history) { page = .main }
                .frame(maxHeight: .infinity, alignment: .top)
                .panelPage(isActive: page == .history, restingOffset: 24)

            SettingsPage(isVisible: page == .settings, back: { page = .main }, about: { page = .about })
                .frame(maxHeight: .infinity, alignment: .top)
                .panelPage(isActive: page == .settings, restingOffset: 24)

            AboutPage { page = .settings }
                .frame(maxHeight: .infinity, alignment: .top)
                .panelPage(isActive: page == .about, restingOffset: 24)

            EditCommandPage(isVisible: page == .editCommand)
                .frame(maxHeight: .infinity, alignment: .top)
                .panelPage(isActive: page == .editCommand, restingOffset: 24)
        }
        .frame(width: Self.panelSize.width, height: Self.panelSize.height)
        .modifier(PanelGlass(cornerRadius: Self.cornerRadius))
        .onChange(of: appState.editingEntryID) { previous, editing in
            if editing != nil {
                returnPage = page == .editCommand ? returnPage : page
                page = .editCommand
            } else if previous != nil {
                page = returnPage
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .panelClosed)) { _ in
            appState.editingEntryID = nil
            page = .main
        }
    }
}

extension Notification.Name {
    static let panelClosed = Notification.Name("PortsidePanelClosed")
}

/// Liquid Glass on macOS 26 and later, the same as the other menu bar apps;
/// a dark material before that.
struct PanelGlass: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *), !SelfTest.isSnapshot {
            content
                .clipShape(shape)
                .glassEffect(.regular.tint(.black.opacity(0.22)), in: shape)
        } else {
            content
                .background {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(Color.panelGround.opacity(0.80))
                }
                .clipShape(shape)
        }
    }
}

// MARK: - Main page

private extension PanelView {
    static let closedCardLimit = 4

    var mainPage: some View {
        VStack(spacing: 0) {
            header
            content
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Portside")
                .font(.system(size: 14, weight: .semibold))

            if !appState.visibleServers.isEmpty {
                Text("\(appState.visibleServers.count) running")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Color.running)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 6) {
                if let last = appState.lastClosed {
                    HeaderButton(symbol: "arrow.uturn.backward", help: "Reopen last closed: \(last.projectName)") {
                        appState.reopenLastClosed()
                    }
                }
                HeaderButton(symbol: "magnifyingglass", help: "History") { page = .history }
                HeaderButton(symbol: "gearshape.fill", help: "Settings") { page = .settings }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    @ViewBuilder
    var content: some View {
        if appState.isInitialLoad {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if appState.visibleServers.isEmpty && appState.simulators.isEmpty && appState.allHistory.isEmpty {
            EmptyStateView()
                .transition(.opacity)
        } else {
            Scrollable {
                VStack(alignment: .leading, spacing: 16) {
                    runningSection
                    closedSection
                    simulatorSection
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
                .padding(.bottom, 14)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.4), location: 0),
                        .init(color: .black, location: 0.025),
                        .init(color: .black, location: 0.94),
                        .init(color: .black.opacity(0.3), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .transition(.opacity)
        }
    }

    @ViewBuilder
    var runningSection: some View {
        let servers = appState.visibleServers
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("RUNNING", action: servers.count > 1 ? "Stop All" : nil, tint: .alert) {
                appState.stopAllServers()
            }
            if servers.isEmpty {
                Text("No dev servers running right now.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            } else {
                CardGrid(items: servers) { RunningCard(server: $0) }
                FailureNotes(failures: servers.compactMap { server in
                    guard case .failed(let message) = appState.restartStates[server.port] else { return nil }
                    return ("\(server.port)", server.projectName, message)
                })
            }
        }
    }

    @ViewBuilder
    var closedSection: some View {
        let closed = appState.closedCards(limit: Self.closedCardLimit)
        if !closed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("RECENTLY CLOSED", action: "History ›", tint: .accent) { page = .history }
                CardGrid(items: closed) { ClosedCard(entry: $0) }
                FailureNotes(failures: closed.compactMap { entry in
                    guard case .failed(let message) = appState.openStates[entry.id] else { return nil }
                    return (entry.id, entry.projectName, message)
                })
            }
        }
    }

    @ViewBuilder
    var simulatorSection: some View {
        if !appState.simulators.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionHeader("SIMULATORS", action: appState.simulators.count > 1 ? "Shut Down All" : nil, tint: .alert) {
                    appState.shutDownAllSimulators()
                }
                ForEach(appState.simulators) { SimulatorRowView(simulator: $0) }
            }
        }
    }

    func sectionHeader(
        _ title: LocalizedStringKey,
        action: LocalizedStringKey?,
        tint: Color,
        perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if let action {
                Button(action: perform) {
                    Text(action)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Round toolbar button; glass on macOS 26 and later.
struct HeaderButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(isHovered ? 0.16 : 0.09)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: MenuBarIconRenderer.image(MenuBarIconState(), size: NSSize(width: 44, height: 32)))
                .renderingMode(.template)
                .foregroundStyle(.tertiary)
            Text("Nothing running")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Start a dev server and it shows up here. When it stops, it stays in your history, one click away from running again.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(width: 250)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// ImageRenderer leaves ScrollView blank, so the self-test snapshot lays it out flat.
struct Scrollable<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        if SelfTest.isSnapshot {
            content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            // The panel is small and the edges already fade, so no scroller.
            ScrollView { content }
                .scrollIndicators(.never)
        }
    }
}
