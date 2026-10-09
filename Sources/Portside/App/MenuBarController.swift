// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import SwiftUI

// Borderless panels refuse key status by default; search and the command editor need it.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var appState: AppState!
    private let scrollActivity = ScrollActivity()
    private weak var panelContentView: NSView?

    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var scrollMonitor: Any?
    private var lastIconActive: Bool?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The panel floats over an uncontrolled wallpaper: a light appearance
        // drops its labels to near-black and they vanish into the material.
        NSApp.appearance = NSAppearance(named: .darkAqua)

        appState = AppState()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
            button.setAccessibilityLabel("Portside")
        }
        updateIcon()

        let hostingView = NSHostingView(rootView:
            PanelView()
                .environment(appState)
                .environment(scrollActivity)
        )

        panel = KeyablePanel(
            contentRect: NSRect(origin: .zero, size: PanelView.panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panelContentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }

        HotKeys.install([
            .togglePanel: { [weak self] in self?.togglePanel() },
            .reopenLastClosed: { [weak self] in self?.appState.reopenLastClosed() },
        ])

        if SelfTest.runIfRequested(appState, scrollActivity) { return }

        // First launch: show where Portside lives instead of a silent icon.
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.openPanel() }
        }
    }

    private func updateIcon() {
        let active = appState?.isActive ?? false
        guard active != lastIconActive, let button = statusItem.button else { return }
        lastIconActive = active
        let image = NSImage(systemSymbolName: active ? "sailboat.fill" : "sailboat",
                            accessibilityDescription: "Portside")
        image?.isTemplate = true
        button.image = image?.withSymbolConfiguration(.init(pointSize: 14, weight: .medium))
    }

    @objc private func togglePanel() {
        panel.isVisible && panel.alphaValue > 0 ? closePanel() : openPanel()
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - PanelView.panelSize.width / 2
        if let screen = buttonWindow.screen {
            x = min(max(x, screen.visibleFrame.minX + 8), screen.visibleFrame.maxX - PanelView.panelSize.width - 8)
        }
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: buttonFrame.minY - 4))

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        growFromMenuBar()
        Task { await appState.refresh() }

        removeMonitors()
        // Global monitors never see clicks on our own status item, so a
        // second click on the icon reaches togglePanel instead of racing it.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.closePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // Esc
            Task { @MainActor in self?.closePanel() }
            return nil
        }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in self?.scrollActivity.noteScroll() }
            return event
        }
    }

    private func growFromMenuBar() {
        guard let layer = panelContentView?.layer else { return }
        let frame = layer.frame
        layer.anchorPoint = CGPoint(x: 0.5, y: 1)
        layer.frame = frame

        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 0.94
        spring.toValue = 1
        spring.stiffness = 260
        spring.damping = 20
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        removeMonitors()
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                // Reopened mid-fade: leave it on screen.
                guard let self, self.panel.alphaValue == 0 else { return }
                self.panel.orderOut(nil)
                NotificationCenter.default.post(name: .panelClosed, object: nil)
            }
        })
    }

    private func removeMonitors() {
        for monitor in [clickMonitor, keyMonitor, scrollMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitor = nil
        keyMonitor = nil
        scrollMonitor = nil
    }
}
