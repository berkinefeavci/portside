import SwiftUI

// Adapted from Blink (MIT, mo.software).

struct PanelRow: View {
    private let title: LocalizedStringKey
    private let detail: String?
    private let action: () -> Void

    @State private var isHovered = false

    init(_ title: LocalizedStringKey, detail: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.detail = detail
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let detail {
                    Text(verbatim: detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.06) : .clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct PanelStatusRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }
}

struct PanelToggleRow: View {
    private let title: LocalizedStringKey
    private let note: LocalizedStringKey?
    private let isOn: Binding<Bool>

    init(_ title: LocalizedStringKey, note: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.note = note
        self.isOn = isOn
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(PanelToggleStyle())
        }
        .padding(.horizontal, 16)
        .frame(height: note == nil ? 34 : 42)
    }
}

struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [.clear, .secondary.opacity(0.2), .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

struct PanelPageHeader: View {
    let title: LocalizedStringKey
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(.primary.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(Text("Back"))

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }
}
