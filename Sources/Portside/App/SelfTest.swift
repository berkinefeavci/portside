import SwiftUI

// Headless checks, used only when the binary is started with these variables:
//   PORTSIDE_REOPEN=<project name>   reopen that history entry after the first scan, print the result
//   PORTSIDE_SNAPSHOT=<file.png>     render the panel to a PNG
//   PORTSIDE_PAGE=history|settings|about  which panel page to render (default: main)
//   PORTSIDE_DEMO_ROOT=<folder>      only list servers under that folder (clean screenshots)
// The app quits when done.
@MainActor
enum SelfTest {
    static func runIfRequested(_ appState: AppState, _ scrollActivity: ScrollActivity) -> Bool {
        let env = ProcessInfo.processInfo.environment
        guard env["PORTSIDE_REOPEN"] != nil || env["PORTSIDE_SNAPSHOT"] != nil else { return false }

        Task {
            while appState.isInitialLoad { try? await Task.sleep(for: .milliseconds(200)) }

            if let name = env["PORTSIDE_REOPEN"] {
                if let entry = appState.allHistory.first(where: { $0.projectName == name }) {
                    let openBrowser = appState.openBrowserAfterReopen
                    appState.openBrowserAfterReopen = false
                    defer { appState.openBrowserAfterReopen = openBrowser }
                    appState.reopen(entry)
                    try? await Task.sleep(for: .milliseconds(300))
                    while appState.openStates[entry.id] == .working { try? await Task.sleep(for: .milliseconds(200)) }
                    print("reopen:", appState.openStates[entry.id].map { "\($0)" } ?? "ok", "running:", appState.isRunning(entry))
                } else {
                    print("reopen: no history entry named \(name)")
                }
            }

            if let path = env["PORTSIDE_SNAPSHOT"] {
                snapshot(appState, scrollActivity, page: env["PORTSIDE_PAGE"], to: path)
            }
            fflush(stdout)
            NSApp.terminate(nil)
        }
        return true
    }

    private static func snapshot(_ appState: AppState, _ scrollActivity: ScrollActivity, page: String?, to path: String) {
        let view = SnapshotHost(page: page)
            .environment(appState)
            .environment(scrollActivity)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

private struct SnapshotHost: View {
    let page: String?
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch page {
            case "history": HistoryPage(isVisible: true) {}
            case "settings": SettingsPage(isVisible: true, back: {}, about: {})
            case "about": AboutPage {}
            default: PanelView()
            }
        }
        .frame(width: PanelView.panelSize.width, height: PanelView.panelSize.height, alignment: .top)
        .background(Color.panelGround)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
