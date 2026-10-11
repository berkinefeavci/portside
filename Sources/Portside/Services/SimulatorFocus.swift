// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import AppKit
import SwiftUI

enum AXAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Which of Simulator.app's windows belongs to which simulator.
enum SimulatorWindowMatch {
    private static let separators = [" – ", " — ", " - "]

    /// Simulator titles its windows "<device> – <runtime>" ("iPhone 15 – iOS 17.5"), older versions
    /// just "<device>". `contains` would take "iPhone 15" for "iPhone 15 Pro", so the name has to be
    /// the whole title or the part before the separator; a name that fits several windows picks none.
    static func index(in titles: [String], name: String, runtime: String) -> Int? {
        let exact = [name] + separators.map { "\(name)\($0)\(runtime)" }
        if let index = titles.firstIndex(where: exact.contains) { return index }

        let named = titles.indices.filter { index in separators.contains { titles[index].hasPrefix("\(name)\($0)") } }
        return named.count == 1 ? named[0] : nil
    }
}

extension AppState {
    func focusSimulator(_ simulator: Simulator) {
        simulatorNotes[simulator.id] = nil
        guard let simApp = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.iphonesimulator"
        ).first else { return }

        // Windows can only be raised with the Accessibility permission. Without it the app still
        // comes forward, and the row says what is missing instead of doing nothing.
        let trusted = AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        )
        guard trusted else {
            simApp.activate()
            showSimulatorNote(simulator, String(localized: "To show this simulator, allow Portside in Accessibility settings."))
            return
        }

        let appRef = AXUIElementCreateApplication(simApp.processIdentifier)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            let titles = windows.map { window -> String in
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
                return titleRef as? String ?? ""
            }
            if let index = SimulatorWindowMatch.index(in: titles, name: simulator.name, runtime: simulator.runtime) {
                AXUIElementSetAttributeValue(windows[index], kAXMinimizedAttribute as CFString, false as CFTypeRef)
                AXUIElementPerformAction(windows[index], kAXRaiseAction as CFString)
            }
        }

        if !simApp.isActive {
            simApp.activate()
        }
    }

    private func showSimulatorNote(_ simulator: Simulator, _ note: String) {
        withAnimation(.easeOut(duration: 0.2)) { simulatorNotes[simulator.id] = note }
        Task {
            try? await Task.sleep(for: .seconds(8))
            withAnimation(.easeOut(duration: 0.25)) {
                if simulatorNotes[simulator.id] == note { simulatorNotes[simulator.id] = nil }
            }
        }
    }
}
