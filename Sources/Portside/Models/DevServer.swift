// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import Foundation
import SwiftUI

struct DevServer: Identifiable, Hashable {
    // Identity is the port: a restart swaps the PID, the row must survive it.
    var id: Int { port }

    let pid: Int
    let port: Int
    let command: String
    let framework: Framework
    let projectName: String
    let projectPath: String
    var startedAt: Date?

    var localhostURL: URL? {
        URL(string: "http://localhost:\(port)")
    }
}

// MARK: - Framework

enum Framework: String, Codable {
    case nextjs = "Next.js"
    case vite = "Vite"
    case nuxt = "Nuxt"
    case remix = "Remix"
    case astro = "Astro"
    case webpack = "Webpack"
    case django = "Django"
    case flask = "Flask"
    case fastapi = "FastAPI"
    case rails = "Rails"
    case cargo = "Cargo"
    case go = "Go"
    case php = "PHP"
    case python = "Python"
    case unknown = "Server"

    // Unknown or renamed values in an older history file must not make the whole file unreadable.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Framework(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        self == .unknown ? String(localized: "Server") : rawValue
    }

    var color: Color {
        switch self {
        case .nextjs:  .primary
        case .vite:    Color(hex: 0x646CFF)
        case .nuxt:    Color(hex: 0x00DC82)
        case .remix:   Color(hex: 0x4F82FF)
        case .astro:   Color(hex: 0xFF5D01)
        case .webpack: Color(hex: 0x8DD6F9)
        case .django:  Color(hex: 0x2BA977)
        case .flask:   .secondary
        case .fastapi: Color(hex: 0x05998B)
        case .rails:   Color(hex: 0xCC0000)
        case .cargo:   Color(hex: 0xCE422B)
        case .go:      Color(hex: 0x00ADD8)
        case .php:     Color(hex: 0x777BB4)
        case .python:  Color(hex: 0xFFD43B)
        case .unknown: .secondary
        }
    }
}
