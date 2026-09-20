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
                    Text("Speech model not loaded. Open General → Download / Prepare Model (or finish onboarding) before dictating.")
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
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(filteredGroups, id: \.label) { group in
                            Section {
                                ForEach(group.items) { item in
                                    DictationHistoryRow(item: item) { id in
                                        pendingDeleteID = id
                                        showDeleteConfirm = true
                                    }
                                    Divider()
                                        .background(LocalFlowDesign.graphite.opacity(0.12))
                                        .padding(.leading, 20)
                                }
                            } header: {
                                Text(group.label.uppercased())
                                    .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                                    .tracking(0.8)
                                    .foregroundStyle(LocalFlowDesign.graphite)
                                    .padding(.horizontal, 28)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(LocalFlowDesign.canvas)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LocalFlowDesign.canvas)
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
        fmt.dateFormat = "MMM d, yyyy"

        return byDay.keys
            .sorted(by: >)
            .map { day in
                let label: String
                if day == today {
                    label = "Today"
                } else if day == yesterday {
                    label = "Yesterday"
                } else {
                    label = fmt.string(from: day)
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
    private let truncationThreshold = 160

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
    private var displayText: String {
        guard isTruncatable && !expanded else { return item.text }
        return String(item.text.prefix(truncationThreshold)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                // Timestamp
                Text(item.createdAt, format: .dateTime.hour().minute())
                    .font(LocalFlowDesign.fragmentMono(size: 11))
                    .foregroundStyle(LocalFlowDesign.graphite)
                    .frame(width: 62, alignment: .leading)

                // Transcribed text
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayText)
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .foregroundStyle(LocalFlowDesign.ink)
                        .fixedSize(horizontal: false, vertical: true)

                    if isTruncatable {
                        Button(expanded ? "Show less" : "Show more") {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                expanded.toggle()
                            }
                        }
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.signal)
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Action buttons
                HStack(spacing: 10) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.text, forType: .string)
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isCopied = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isCopied = false
                            }
                        }
                    } label: {
                        Image(systemName: effectiveCopied ? "checkmark" : "doc.on.doc")
                            .frame(width: 16, height: 16)
                            .foregroundStyle(effectiveCopied ? LocalFlowDesign.signal : LocalFlowDesign.graphite)
                    }
                    .buttonStyle(.plain)
                    .help(effectiveCopied ? "Copied" : "Copy")

                    Button {
                        onDelete(item.id)
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 16, height: 16)
                            .foregroundStyle(effectiveDeleteHover ? LocalFlowDesign.destructiveRed : LocalFlowDesign.graphite)
                            .scaleEffect(effectiveDeleteHover ? 1.05 : 1.0)
                            .animation(.easeInOut(duration: 0.15), value: effectiveDeleteHover)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    .onHover { isDeleteHovered = $0 }
                }
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    expanded ? LocalFlowDesign.card :
                    (effectiveRowHover ? LocalFlowDesign.canvasHover : Color.clear)
                )
        )
        .padding(.horizontal, 16)
        .onHover { isRowHovered = $0 }
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
