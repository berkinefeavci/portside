import SwiftUI

struct PanelView: View {
    static let panelSize = CGSize(width: 340, height: 480)

    @Environment(AppState.self) private var appState
    @State private var page: Page = .main

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
        // Material alone takes the wallpaper's colour; the ground pins the
        // panel to something the wallpaper only tints.
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.panelGround.opacity(0.80))
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    @State private var returnPage: Page = .main
}

extension Notification.Name {
    static let panelClosed = Notification.Name("PortsidePanelClosed")
}

// MARK: - Main page

private extension PanelView {
    var mainPage: some View {
        VStack(spacing: 0) {
            header
            PanelDivider()
            content
            PanelDivider()
            footer
        }
    }

    var header: some View {
        HStack(spacing: 8) {
            Text(verbatim: "Portside")
                .font(.system(size: 13, weight: .semibold))

            if !appState.visibleServers.isEmpty {
                Text("\(appState.visibleServers.count) running")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.running)
                    .lineLimit(1)
            }

            Spacer()

            if let last = appState.lastClosed {
                Button {
                    appState.reopenLastClosed()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(.primary.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(Text("Reopen last closed: \(last.projectName)"))
                .accessibilityLabel(Text("Reopen last closed"))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
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
                VStack(spacing: 14) {
                    if !appState.visibleServers.isEmpty {
                        section("RUNNING", icon: "bolt.horizontal",
                                action: appState.visibleServers.count > 1 ? "Stop All" : nil,
                                tint: .alert) { appState.stopAllServers() } rows: {
                            ForEach(appState.visibleServers) { ServerRowView(server: $0).transition(rowTransition) }
                        }
                    } else {
                        Text("No dev servers running right now.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }

                    if !appState.pinnedClosed.isEmpty {
                        section("PINNED", icon: "pin", action: nil) {} rows: {
                            ForEach(appState.pinnedClosed) { HistoryRowView(entry: $0).transition(rowTransition) }
                        }
                    }

                    if !appState.recentlyClosed.isEmpty {
                        section("RECENTLY CLOSED", icon: "clock.arrow.circlepath",
                                action: "Show All", tint: .accent) { page = .history } rows: {
                            ForEach(appState.recentlyClosed) { HistoryRowView(entry: $0).transition(rowTransition) }
                        }
                    }

                    if !appState.simulators.isEmpty {
                        section("SIMULATORS", icon: "iphone",
                                action: appState.simulators.count > 1 ? "Shut Down All" : nil,
                                tint: .alert) { appState.shutDownAllSimulators() } rows: {
                            ForEach(appState.simulators) { SimulatorRowView(simulator: $0).transition(rowTransition) }
                        }
                    }
                }
                .padding(12)
            }
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.965),
                        .init(color: .black.opacity(0.55), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .transition(.opacity)
        }
    }

    var rowTransition: AnyTransition {
        .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
    }

    func section<Rows: View>(
        _ title: LocalizedStringKey,
        icon: String,
        action: LocalizedStringKey?,
        tint: Color = .alert,
        perform: @escaping () -> Void,
        @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .frame(width: 12)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .tracking(0.8)
                    .lineLimit(1)
                Spacer()
                if let action {
                    Button(action: perform) {
                        Text(action)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(tint)
                            .lineLimit(1)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(.secondary.opacity(0.7))
            .padding(.horizontal, 4)

            rows()
        }
    }

    var footer: some View {
        VStack(spacing: 0) {
            PanelRow("History", detail: appState.allHistory.isEmpty ? nil : "\(appState.allHistory.count)") { page = .history }
            PanelDivider()
            PanelRow("Settings") { page = .settings }
            PanelDivider()
            PanelRow("Quit Portside") { NSApplication.shared.terminate(nil) }
        }
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sailboat")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing in port")
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
    private static var flat: Bool { ProcessInfo.processInfo.environment["PORTSIDE_SNAPSHOT"] != nil }

    var body: some View {
        if Self.flat {
            content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped()
        } else {
            ScrollView { content }
        }
    }
}
