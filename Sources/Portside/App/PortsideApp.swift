import AppKit

enum AppInfo {
    static var version: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        return "v\(short)"
    }

    static let repositoryURL = URL(string: "https://github.com/berkinefeavci/portside")!
    static let releasesURL = URL(string: "https://github.com/berkinefeavci/portside/releases/latest")!
    static let issuesURL = URL(string: "https://github.com/berkinefeavci/portside/issues/new/choose")!
}

// Plain AppKit entry point: a SwiftUI `App` needs a scene, and its empty Settings
// window could be restored or opened with ⌘, as a blank "Portside Settings" window.
@main
@MainActor
enum PortsideApp {
    private static let menuBar = MenuBarController()

    static func main() {
        let app = NSApplication.shared
        app.delegate = menuBar
        app.mainMenu = editMenu()
        app.run()
    }

    /// Never shown (Portside has no menu bar of its own), but key equivalents like ⌘V
    /// in the search field and the command editor are found through it.
    private static func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let main = NSMenu()
        let appItem = NSMenuItem()   // the application menu slot
        appItem.submenu = NSMenu()
        main.addItem(appItem)
        let item = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        item.submenu = edit
        return main
    }
}
