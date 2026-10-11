// Adapted from Blink (MIT, mo.software). See THIRD_PARTY_NOTICES.md.
import SwiftUI

struct FailureBox: View {
    let message: String
    /// The server's output log, if it has one: copied in full, and one click from opening.
    var logURL: URL?

    @Environment(AppState.self) private var appState

    @State private var copied = false
    @State private var textHeight: CGFloat = 0

    private static let radius: CGFloat = 10
    private static let inset: CGFloat = 6
    private static let lineLimit = 3

    private static let lineHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    private var isSingleLine: Bool {
        textHeight > 0 && textHeight < Self.lineHeight * 1.5
    }

    var body: some View {
        HStack(alignment: isSingleLine ? .center : .top, spacing: 8) {
            Text(headline)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(Self.lineLimit)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: TextHeightKey.self, value: proxy.size.height)
                    }
                }

            HStack(spacing: 2) {
                copyButton
                if let logURL {
                    GlyphButton(symbol: "doc.text", color: nil, help: Text("Open Output Log")) {
                        NSWorkspace.shared.open(logURL)
                    }
                }
            }
        }
        .onPreferenceChange(TextHeightKey.self) { textHeight = $0 }
        .padding(Self.inset)
        .background {
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        }
    }

    private var copyButton: some View {
        GlyphButton(
            symbol: copied ? "checkmark" : "doc.on.doc",
            color: copied ? .green : nil,
            help: copied ? Text("Copied") : Text("Copy the full output")
        ) {
            // The whole log when there is one; `message` is only its last few lines.
            let full = logURL.flatMap { LogFiles.contents(of: $0) }.flatMap { $0.isEmpty ? nil : $0 }
            appState.copyToClipboard(text: full ?? message)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeInOut(duration: 0.15)) { copied = false }
            }
        }
    }

    private var headline: String {
        let lines = message.components(separatedBy: "\n")
        let body = lines.prefix { !$0.hasPrefix("at ") && !$0.hasPrefix("File \"") }
        guard !body.isEmpty else { return lines.first ?? message }

        var text = body.joined(separator: "\n")
        if let prefix = text.range(of: #"^Error:\s*"#, options: .regularExpression) {
            text.removeSubrange(prefix)
        }
        return text
    }
}

/// The small round-cornered glyph button at the end of a failure box.
private struct GlyphButton: View {
    let symbol: String
    let color: Color?
    let help: Text
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(color ?? (isHovering ? .primary : .secondary))
                .frame(width: 18, height: 18)
                .background {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(help)
    }
}

private struct TextHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
