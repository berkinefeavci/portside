import SwiftUI

struct HistoryPage: View {
    let isVisible: Bool
    let back: () -> Void

    @Environment(AppState.self) private var appState
    @State private var query = ""
    @State private var confirmClear = false
    @FocusState private var searchFocused: Bool

    private var filtered: [HistoryEntry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return appState.allHistory }
        return appState.allHistory.filter { entry in
            let haystack = "\(entry.projectName) \(entry.projectPath) \(entry.port) \(entry.framework.displayName) \(entry.shellCommand)".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var groups: [(group: TimeText.DayGroup, entries: [HistoryEntry])] {
        let now = Date()
        let buckets = Dictionary(grouping: filtered) { entry in
            entry.isPinned ? .pinned : TimeText.dayGroup(entry.lastSeen, now: now)
        }
        return TimeText.DayGroup.allCases.compactMap { group in
            buckets[group].map { (group, $0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelPageHeader(title: "History", back: back)
            searchField
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            PanelDivider()

            if filtered.isEmpty {
                Group {
                    if query.isEmpty {
                        Text("No history yet.")
                    } else {
                        Text("No matching servers.")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Scrollable {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(groups, id: \.group) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: item.group.title)
                                    .font(.system(size: 10, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(.secondary.opacity(0.7))
                                    .padding(.horizontal, 4)
                                ForEach(item.entries) { HistoryRowView(entry: $0) }
                            }
                        }
                    }
                    .padding(12)
                }
            }

            PanelDivider()
            clearRow
        }
        .onChange(of: isVisible) { _, visible in
            if visible {
                searchFocused = true
            } else {
                query = ""
                confirmClear = false
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search project, port or command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private var clearRow: some View {
        if confirmClear {
            HStack(spacing: 10) {
                Text("Pinned servers stay. Clear the rest?")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel") { confirmClear = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                Button("Clear") {
                    appState.clearHistory()
                    confirmClear = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.alert)
            }
            .padding(.horizontal, 16)
            .frame(height: 34)
        } else {
            PanelRow("Clear History…", detail: String(localized: "\(appState.allHistory.count) servers")) {
                confirmClear = true
            }
        }
    }
}
