// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import Foundation

struct Simulator: Identifiable, Hashable {
    var id: String { udid }

    let udid: String
    let name: String
    let runtime: String
    let runningApp: AppInfo?

    struct AppInfo: Hashable {
        let bundleID: String
        let displayName: String
    }
}
