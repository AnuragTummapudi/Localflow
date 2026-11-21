import SwiftUI
import Shared

// MARK: - Dictation History Pane

/// The Dictation settings pane — shows the full local dictation history.
public struct DictationPane: View {
    /// The history store.
    @ObservedObject public var store: DictationHistoryStore
    /// The current hotkey display name (read from settings for the empty state).
    public let hotkeyName: String
    private let previewFocus: Bool
    @EnvironmentObject private var coordinator: DictationCoordinator

    @State private var query: String = ""
    @State private var pendingDeleteID: UUID? = nil
    @State private var showDeleteConfirm = false
    @State private var showClearAllConfirm = false
    @FocusState private var isSearchFocused: Bool

    public init(
        store: DictationHistoryStore,
        hotkeyName: String = "Right Option",
        initialQuery: String = "",
        previewFocus: Bool = false
    ) {
        self.store = store
        self.hotkeyName = hotkeyName
        self._query = State(initialValue: initialQuery)
        self.previewFocus = previewFocus
    }

    private var filteredGroups: [(label: String, items: [DictationHistoryItem])] {
        let results = store.search(query)
        return Self.grouped(results)
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                LFPaneTitle("Dictation")
                Spacer()
                if !store.items.isEmpty {
                    Button("Clear all") { showClearAllConfirm = true }
                        .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .buttonStyle(.plain)
                        .padding(.trailing, 4)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .frame(width: 16)
                    TextField("Search dictations…", text: $query)
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .foregroundStyle(LocalFlowDesign.ink)
                        .textFieldStyle(.plain)
                        .frame(width: 180)
                        .focused($isSearchFocused)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(LocalFlowDesign.graphite)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(LocalFlowDesign.card)
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(LocalFlowDesign.hairline, lineWidth: 1)
                        )
                        .signalCapsuleFocusRing(isFocused: isSearchFocused || previewFocus)
                )
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()
                .background(LocalFlowDesign.graphite.opacity(0.18))

            // ── Content ─────────────────────────────────────────────────
            if let err = coordinator.lastErrorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(LocalFlowDesign.marker)
                    Text(err)
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LocalFlowDesign.marker.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(LocalFlowDesign.marker.opacity(0.25), lineWidth: 1)
                        )
                )
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            }

            if !coordinator.isEngineReady {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(LocalFlowDesign.signal)
                    Text("Speech model not loaded. Open General → Apply & prepare (or finish onboarding) before dictating.")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LocalFlowDesign.cardBackground(cornerRadius: 12))
                .padding(.horizontal, 28)
                .padding(.bottom, 8)
            }

            if store.items.isEmpty {
                DictationEmptyState(hotkeyName: hotkeyName)
            } else if filteredGroups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Text("No matches for \"" + query + "\"")
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .foregroundStyle(LocalFlowDesign.graphite)
                    Button("Clear search") {
                        query = ""
                    }
                    .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                    .foregroundStyle(LocalFlowDesign.signal)
                    .buttonStyle(.plain)
                    Spacer()
                }
            } else {
                ScrollView {
                    // One card per day; rows inside share hairline dividers aligned to the text column.
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(filteredGroups, id: \.label) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(group.label)
                                    .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                                    .foregroundStyle(LocalFlowDesign.graphite)
                                    .padding(.leading, 4)
                                VStack(spacing: 0) {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 {
                                            Rectangle()
                                                .fill(LocalFlowDesign.hairline)
                                                .frame(height: 1)
                                                .padding(.leading, DictationHistoryRow.textInset)
                                        }
                                        DictationHistoryRow(item: item) { id in
                                            pendingDeleteID = id
                                            showDeleteConfirm = true
                                        }
                                    }
                                }
                                .background(LocalFlowDesign.cardBackground(cornerRadius: 14))
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LocalFlowDesign.canvas)
        .confirmationDialog(
            "Delete all \(store.items.count) dictations?",
            isPresented: $showClearAllConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { store.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("History is stored only on this Mac and cannot be recovered.")
        }
        .confirmationDialog(
            "Delete this dictation?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let id = pendingDeleteID {
                    store.remove(id: id)
                }
                pendingDeleteID = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteID = nil
            }
        } message: {
            Text("This is stored only on this Mac and cannot be recovered.")
        }
    }

    // Groups items by calendar day, most-recent group first.
    private static func grouped(_ items: [DictationHistoryItem]) -> [(label: String, items: [DictationHistoryItem])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        var byDay: [Date: [DictationHistoryItem]] = [:]
        for item in items {
            let day = cal.startOfDay(for: item.createdAt)
            byDay[day, default: []].append(item)
        }

        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d"
        let olderFmt = DateFormatter()
        olderFmt.dateFormat = "MMM d, yyyy"

        return byDay.keys
            .sorted(by: >)
            .map { day in
                let label: String
                if day == today {
                    label = "Today"
                } else if day == yesterday {
                    label = "Yesterday"
                } else if cal.isDate(day, equalTo: today, toGranularity: .year) {
                    label = fmt.string(from: day)
                } else {
                    label = olderFmt.string(from: day)
                }
                let sortedItems = byDay[day]!.sorted { $0.createdAt > $1.createdAt }
                return (label: label, items: sortedItems)
            }
    }
}

// MARK: - Row

public struct DictationHistoryRow: View {
    public let item: DictationHistoryItem
    public let previewCopied: Bool
    public let previewDeleteHover: Bool
    public let previewRowHover: Bool
    public let onDelete: (UUID) -> Void

    @State private var expanded = false
    @State private var isCopied = false
    @State private var isDeleteHovered = false
    @State private var isRowHovered = false
    private let truncationThreshold = 220
    /// Leading inset of the text column (row padding + time column + spacing); dividers align to it.
    static let textInset: CGFloat = 16 + 58 + 14

    public init(
        item: DictationHistoryItem,
        previewCopied: Bool = false,
        previewDeleteHover: Bool = false,
        previewRowHover: Bool = false,
        onDelete: @escaping (UUID) -> Void
    ) {
        self.item = item
        self.previewCopied = previewCopied
        self.previewDeleteHover = previewDeleteHover
        self.previewRowHover = previewRowHover
        self.onDelete = onDelete
    }

    private var effectiveCopied: Bool { isCopied || previewCopied }
    private var effectiveDeleteHover: Bool { isDeleteHovered || previewDeleteHover }
    private var effectiveRowHover: Bool { isRowHovered || previewRowHover }

    private var isTruncatable: Bool {
        item.text.count > truncationThreshold
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(item.createdAt, format: .dateTime.hour().minute())
                .font(LocalFlowDesign.fragmentMono(size: 11))
                .foregroundStyle(LocalFlowDesign.graphite)
                .frame(width: 58, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .font(LocalFlowDesign.generalSans(size: 13))
                    .foregroundStyle(LocalFlowDesign.ink)
                    .lineSpacing(2)
                    .lineLimit(expanded ? nil : 3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if isTruncatable {
                    Button(expanded ? "Show less" : "Show more") {
                        withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                    }
                    .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                    .foregroundStyle(LocalFlowDesign.signal)
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Actions appear on hover (and stay while "Copied" shows) to keep the list quiet.
            HStack(spacing: 4) {
                actionButton(systemName: effectiveCopied ? "checkmark" : "doc.on.doc",
                             help: effectiveCopied ? "Copied" : "Copy",
                             tint: effectiveCopied ? LocalFlowDesign.signal : LocalFlowDesign.graphite) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.text, forType: .string)
                    withAnimation(.easeInOut(duration: 0.15)) { isCopied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        withAnimation(.easeInOut(duration: 0.15)) { isCopied = false }
                    }
                }
                actionButton(systemName: "trash", help: "Delete",
                             tint: effectiveDeleteHover ? LocalFlowDesign.destructiveRed : LocalFlowDesign.graphite) {
                    onDelete(item.id)
                }
                .onHover { isDeleteHovered = $0 }
            }
            .opacity(effectiveRowHover || effectiveCopied ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: effectiveRowHover)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(effectiveRowHover ? LocalFlowDesign.canvasHover.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isRowHovered = $0 }
    }

    private func actionButton(systemName: String, help: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Empty state

private struct DictationEmptyState: View {
    let hotkeyName: String

    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("Nothing dictated yet.")
                .font(LocalFlowDesign.instrumentSerif(size: 28))
                .foregroundStyle(LocalFlowDesign.ink)
            Text("Hold \(hotkeyName) anywhere to start.")
                .font(LocalFlowDesign.generalSans(size: 14))
                .foregroundStyle(LocalFlowDesign.graphite)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
