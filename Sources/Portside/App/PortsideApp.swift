import SwiftUI

enum AppInfo {
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(short)"
    }

    static let repositoryURL = URL(string: "https://github.com/berkinefeavci/portside")!
    static let releasesURL = URL(string: "https://github.com/berkinefeavci/portside/releases/latest")!
    static let issuesURL = URL(string: "https://github.com/berkinefeavci/portside/issues/new/choose")!
}

@main
struct PortsideApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBar

    var body: some Scene {
        Settings { EmptyView() }
    }
}
