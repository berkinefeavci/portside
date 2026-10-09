import SwiftUI

// Lets the user say how a server should be started when the detected command
// is missing or wrong (a wrapper script, an `npm run` they prefer, …).
struct EditCommandPage: View {
    let isVisible: Bool

    @Environment(AppState.self) private var appState
    @State private var text = ""
    @FocusState private var focused: Bool

    private var entry: HistoryEntry? {
        appState.editingEntryID.flatMap { appState.history[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelPageHeader(title: "Edit Command") { appState.editingEntryID = nil }
            PanelDivider()

            if let entry {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: entry.projectName)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Text(verbatim: entry.projectPath)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    TextEditor(text: $text)
                        .font(.system(size: 11, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(height: 120)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .focused($focused)

                    Text("Runs in the project folder through your login shell, the same way Terminal would. Leave empty to use the command Portside detected.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if entry.executable != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detected command")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text(verbatim: detectedCommand(entry))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .lineLimit(3)
                                .textSelection(.enabled)
                        }
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: 8) {
                        if entry.hasCustomCommand {
                            Button("Use Detected") {
                                appState.setCustomCommand(nil, for: entry)
                                appState.editingEntryID = nil
                            }
                            .buttonStyle(PanelButtonStyle(prominent: false))
                        }
                        Spacer()
                        Button("Cancel") { appState.editingEntryID = nil }
                            .buttonStyle(PanelButtonStyle(prominent: false))
                            .keyboardShortcut(.cancelAction)
                        Button("Save") {
                            appState.setCustomCommand(text, for: entry)
                            appState.editingEntryID = nil
                        }
                        .buttonStyle(PanelButtonStyle(prominent: true))
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(16)
            }
        }
        .onChange(of: appState.editingEntryID) { _, _ in load() }
        .onChange(of: isVisible) { _, visible in
            if visible { load(); focused = true }
        }
    }

    private func load() {
        guard let entry else { return }
        text = entry.hasCustomCommand ? (entry.customCommand ?? "") : detectedCommand(entry)
    }

    private func detectedCommand(_ entry: HistoryEntry) -> String {
        var detected = entry
        detected.customCommand = nil
        return detected.shellCommand
    }
}

struct PanelButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(
                Capsule().fill(prominent ? Color.accent : Color.primary.opacity(0.10))
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
