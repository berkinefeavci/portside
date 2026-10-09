import SwiftUI

struct SettingsPage: View {
    let isVisible: Bool
    let back: () -> Void
    let about: () -> Void

    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var shortcuts = HotKeys.isEnabled
    @State private var previews = PreviewStore.shared.isEnabled
    @State private var failure: String?
    @State private var accessibilityTrusted = AXAccess.isTrusted

    var body: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            PanelPageHeader(title: "Settings", back: back)
            PanelDivider()

            PanelToggleRow("Open at login", isOn: $launchAtLogin)
            if let failure {
                Text(verbatim: failure)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.alert)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            PanelDivider()

            PanelToggleRow("Open in browser after reopening", isOn: $appState.openBrowserAfterReopen)
            PanelDivider()

            PanelToggleRow("Site previews", note: "Pictures of each page, kept on this Mac", isOn: $previews)
            PanelDivider()

            PanelToggleRow("Keyboard shortcuts",
                           note: "⌃⌥⌘P panel · ⌃⌥⌘T reopen last closed",
                           isOn: $shortcuts)
            PanelDivider()

            if accessibilityTrusted {
                PanelStatusRow(title: "Simulator focus", detail: "Allowed")
            } else {
                PanelRow("Simulator focus", detail: String(localized: "Not allowed")) {
                    AXAccess.openSystemSettings()
                }
            }
            PanelDivider()

            if !appState.ignoredPaths.isEmpty {
                PanelRow("Show Hidden Projects", detail: "\(appState.ignoredPaths.count)") {
                    appState.showIgnoredProjects()
                }
                PanelDivider()
            }

            PanelRow("Show History File") {
                NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.file])
            }
            PanelDivider()
            PanelRow("Show Output Logs") {
                try? FileManager.default.createDirectory(at: HistoryStore.logDirectory, withIntermediateDirectories: true)
                NSWorkspace.shared.open(HistoryStore.logDirectory)
            }
            PanelDivider()
            PanelRow("About Portside", detail: AppInfo.version, action: about)
            PanelDivider()

            Spacer()

            PanelDivider()
            PanelRow("Quit Portside") { NSApplication.shared.terminate(nil) }
        }
        .onChange(of: launchAtLogin) { _, enabled in apply(enabled) }
        .onChange(of: shortcuts) { _, enabled in HotKeys.isEnabled = enabled }
        .onChange(of: previews) { _, enabled in
            PreviewStore.shared.isEnabled = enabled
            if enabled {
                appState.refreshPreviews(maxAge: 0)
            } else {
                PreviewStore.shared.removeAll()
            }
        }
        .onChange(of: isVisible) { _, visible in
            guard visible else { return }
            accessibilityTrusted = AXAccess.isTrusted
            launchAtLogin = LoginItem.isEnabled
            shortcuts = HotKeys.isEnabled
        }
    }

    private func apply(_ enabled: Bool) {
        guard enabled != LoginItem.isEnabled else { return }
        do {
            try LoginItem.setEnabled(enabled)
            failure = nil
        } catch {
            failure = error.localizedDescription
            launchAtLogin = LoginItem.isEnabled
        }
    }
}

struct AboutPage: View {
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelPageHeader(title: "About", back: back)
            PanelDivider()

            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(verbatim: "Portside")
                    .font(.system(size: 15, weight: .semibold))
                Text(verbatim: AppInfo.version)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Your local dev servers, with a memory. Free and open source under the MIT license.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(width: 260)
                    .padding(.top, 4)
            }
            .padding(.vertical, 18)

            PanelDivider()
            PanelRow("Source Code on GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
            PanelDivider()
            PanelRow("Check for Updates") { NSWorkspace.shared.open(AppInfo.releasesURL) }
            PanelDivider()
            PanelRow("Report an Issue") { NSWorkspace.shared.open(AppInfo.issuesURL) }
            PanelDivider()

            Spacer()

            Text("Inspired by Blink by mo.software (MIT).")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
    }
}
