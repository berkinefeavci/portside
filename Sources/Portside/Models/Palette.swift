// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    static let panelGround = Color(hex: 0x17171D)
    static let xcode = Color(hex: 0x338FF0)
    static let alert = Color(hex: 0xFA5773)
}

extension Color {
    static let accent = Color(hex: 0x4F8DFF)
    static let running = Color(hex: 0x3DDC97)
}
