// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registered, but macOS wants the user to allow it in System Settings → Login Items first.
    static var needsApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
