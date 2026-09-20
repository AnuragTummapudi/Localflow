import SwiftUI
import Shared

// MARK: - Dictionary Pane

/// The Dictionary settings pane — manage custom vocabulary and shortcuts LocalFlow uses during transcription.
public struct DictionaryPane: View {
    @ObservedObject public var store: VocabularyStore
    public var hoveredEntryId: UUID? = nil

    @State private var query: String = ""
    @State private var sheetTarget: SheetTarget?
    @FocusState private var isSearchFocused: Bool

    public init(store: VocabularyStore, hoveredEntryId: UUID? = nil) {
        self.store = store
        self.hoveredEntryId = hoveredEntryId
    }

    public enum SheetTarget: Identifiable {
        case add
        case edit(VocabularyEntry)

        public var id: String {
            switch self {
            case .add:
                return "add"
            case .edit(let entry):
                return "edit-\(entry.id)"
            }
        }
    }

    private var sortedEntries: [VocabularyEntry] {
        store.entries
    }

    private var filteredEntries: [VocabularyEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return sortedEntries }
        return sortedEntries.filter {
            $0.phrase.localizedCaseInsensitiveContains(q) ||
            $0.replacement.localizedCaseInsensitiveContains(q)
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                LFPaneTitle("Dictionary")
                Spacer()

                // Search Bar
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .frame(width: 14)
                    TextField("Search words…", text: $query)
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .foregroundStyle(LocalFlowDesign.ink)
                        .textFieldStyle(.plain)
                        .frame(width: 160)
                        .focused($isSearchFocused)
                    if !query.isEmpty {
                        Button { query = "" } label: {
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
                        .overlay(Capsule(style: .continuous).strokeBorder(LocalFlowDesign.hairline, lineWidth: 1))
                        .signalCapsuleFocusRing(isFocused: isSearchFocused)
                )

                LFPrimaryButton("Add Word") {
                    sheetTarget = .add
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()
                .background(LocalFlowDesign.hairline)

            // Content List
            if store.entries.isEmpty {
                DictionaryEmptyState {
                    store.entries.forEach { _ in }
                    for entry in VocabularyStore.defaultSeedEntries {
                        store.add(
                            phrase: entry.phrase,
                            replacement: entry.replacement,
                            isFavorite: entry.isFavorite,
                            hasSparkle: entry.hasSparkle
                        )
                    }
                }
            } else if filteredEntries.isEmpty {
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
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            DictionaryEntryRow(
                                entry: entry,
                                initialHover: (hoveredEntryId == entry.id),
                                onEdit: {
                                    sheetTarget = .edit(entry)
                                },
                                onDelete: {
                                    store.remove(id: entry.id)
                                },
                                onToggleFavorite: {
                                    store.toggleFavorite(id: entry.id)
                                }
                            )
                            Divider()
                                .background(LocalFlowDesign.hairline)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LocalFlowDesign.canvas)
        .sheet(item: $sheetTarget) { target in
            switch target {
            case .add:
                WordEditSheet(store: store, entryToEdit: nil)
            case .edit(let entry):
                WordEditSheet(store: store, entryToEdit: entry)
            }
        }
    }
}

// MARK: - Entry Row (Matches Wispr Flow Screenshot)

public struct DictionaryEntryRow: View {
    public let entry: VocabularyEntry
    public let onEdit: () -> Void
    public let onDelete: () -> Void
    public let onToggleFavorite: () -> Void

    @State private var isHovering: Bool
    @State private var isPencilHovering = false
    @State private var isTrashHovering = false
    @State private var isStarHovering = false

    public init(
        entry: VocabularyEntry,
        initialHover: Bool = false,
        onEdit: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onToggleFavorite: @escaping () -> Void = {}
    ) {
        self.entry = entry
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onToggleFavorite = onToggleFavorite
        self._isHovering = State(initialValue: initialHover)
    }

    public var body: some View {
        HStack(spacing: 8) {
            // Main Text / Replacement representation
            if entry.isShortcut {
                HStack(spacing: 6) {
                    Text(entry.phrase)
                        .font(LocalFlowDesign.generalSans(size: 14))
                        .foregroundStyle(LocalFlowDesign.ink)
                    Text("→")
                        .font(.system(size: 13, weight: .light))
                        .foregroundStyle(LocalFlowDesign.graphite)
                    Text(entry.replacement)
                        .font(LocalFlowDesign.generalSans(size: 14))
                        .foregroundStyle(LocalFlowDesign.ink)
                }
            } else {
                HStack(spacing: 4) {
                    Text(entry.phrase)
                        .font(LocalFlowDesign.generalSans(size: 14))
                        .foregroundStyle(LocalFlowDesign.ink)
                    if entry.hasSparkle {
                        Text("Learned")
                            .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(LocalFlowDesign.canvasHover))
                    }
                }
            }

            Spacer()

            // Row Action Icons on Hover (Pencil, Trash, Star)
            if isHovering {
                HStack(spacing: 16) {
                    // 1. Edit (Pencil)
                    Button {
                        onEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(isPencilHovering ? LocalFlowDesign.ink : LocalFlowDesign.graphite)
                    }
                    .buttonStyle(.plain)
                    .help("Edit")
                    .onHover { isPencilHovering = $0 }

                    // 2. Delete (Trash)
                    Button {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(isTrashHovering ? LocalFlowDesign.destructiveRed : LocalFlowDesign.graphite)
                    }
                    .buttonStyle(.plain)
                    .help("Delete")
                    .onHover { isTrashHovering = $0 }

                    // 3. Star (Favorite)
                    Button {
                        onToggleFavorite()
                    } label: {
                        Image(systemName: entry.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(entry.isFavorite || isStarHovering ? Color.orange : LocalFlowDesign.graphite)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isFavorite ? "Unstar" : "Star / Priority")
                    .onHover { isStarHovering = $0 }
                }
                .transition(.opacity)
            } else if entry.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.orange)
                    .padding(.trailing, 4)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 15)
        .frame(minHeight: 48)
        .contentShape(Rectangle())
        .background(isHovering ? LocalFlowDesign.sidebarHighlight.opacity(0.4) : Color.clear)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Empty state

private struct DictionaryEmptyState: View {
    let onRestoreDefaults: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("No custom words yet.")
                .font(LocalFlowDesign.instrumentSerif(size: 26))
                .foregroundStyle(LocalFlowDesign.ink)
            Text("Add words, names, acronyms, or shortcuts LocalFlow should recognize.")
                .font(LocalFlowDesign.generalSans(size: 13))
                .foregroundStyle(LocalFlowDesign.graphite)
                .multilineTextAlignment(.center)
            Button("Load Example Vocabulary") {
                onRestoreDefaults()
            }
            .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
            .foregroundStyle(LocalFlowDesign.signal)
            .buttonStyle(.plain)
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Unified Add / Edit Word Sheet

public struct WordEditSheet: View {
    @ObservedObject public var store: VocabularyStore
    public let entryToEdit: VocabularyEntry?
    @Environment(\.dismiss) private var dismiss

    @State private var mode: EntryType = .customWord
    @State private var phrase: String = ""
    @State private var replacement: String = ""
    @State private var hasSparkle: Bool = true
    @State private var isFavorite: Bool = false

    @FocusState private var phraseFieldFocused: Bool
    @FocusState private var replacementFieldFocused: Bool

    public enum EntryType: String, CaseIterable {
        case customWord = "Word / Name"
        case shortcut = "Shortcut / Expansion"
    }

    private var isEditing: Bool {
        entryToEdit != nil
    }

    private var canSave: Bool {
        let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        if mode == .customWord {
            return !p.isEmpty
        } else {
            let r = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            return !p.isEmpty && !r.isEmpty
        }
    }

    public init(store: VocabularyStore, entryToEdit: VocabularyEntry?) {
        self.store = store
        self.entryToEdit = entryToEdit
        if let entry = entryToEdit {
            _mode = State(initialValue: entry.isShortcut ? .shortcut : .customWord)
            _phrase = State(initialValue: entry.phrase)
            _replacement = State(initialValue: entry.replacement)
            _hasSparkle = State(initialValue: entry.hasSparkle)
            _isFavorite = State(initialValue: entry.isFavorite)
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isEditing ? "Edit Dictionary Entry" : "Add to Dictionary")
                .font(LocalFlowDesign.instrumentSerif(size: 24))
                .foregroundStyle(LocalFlowDesign.ink)

            // Custom Segmented Pill Switcher (Eliminates system segmented control white-text contrast bug)
            HStack(spacing: 4) {
                ForEach(EntryType.allCases, id: \.self) { type in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            mode = type
                        }
                    } label: {
                        Text(type.rawValue)
                            .font(LocalFlowDesign.generalSans(size: 13, weight: mode == type ? .semibold : .medium))
                            .foregroundStyle(mode == type ? Color.white : LocalFlowDesign.ink)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .frame(maxWidth: .infinity)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(mode == type ? LocalFlowDesign.ink : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LocalFlowDesign.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(LocalFlowDesign.hairline, lineWidth: 1)
                    )
            )

            if mode == .customWord {
                // Word / Name Field
                VStack(alignment: .leading, spacing: 6) {
                    Text("Word, Name, or Acronym")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                    ZStack(alignment: .leading) {
                        if phrase.isEmpty {
                            Text("e.g. Anurag Tummapudi, INR, ABGen")
                                .font(LocalFlowDesign.generalSans(size: 14))
                                .foregroundStyle(LocalFlowDesign.graphite.opacity(0.6))
                        }
                        TextField("", text: $phrase)
                            .font(LocalFlowDesign.generalSans(size: 14))
                            .foregroundStyle(LocalFlowDesign.ink)
                            .textFieldStyle(.plain)
                            .focused($phraseFieldFocused)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LocalFlowDesign.card)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LocalFlowDesign.hairline, lineWidth: 1))
                    )
                    .signalFocusRing(isFocused: phraseFieldFocused, cornerRadius: 10)
                }

                Button {
                    hasSparkle.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: hasSparkle ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(hasSparkle ? LocalFlowDesign.signal : LocalFlowDesign.graphite.opacity(0.6))
                        Text("Smart Phonetic Recognition")
                            .font(LocalFlowDesign.generalSans(size: 13))
                            .foregroundStyle(LocalFlowDesign.ink)
                        Text("Learned")
                            .font(LocalFlowDesign.generalSans(size: 11, weight: .medium))
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(LocalFlowDesign.canvasHover))
                    }
                }
                .buttonStyle(.plain)

                Text("LocalFlow will enforce this exact spelling and capitalization during transcription.")
                    .font(LocalFlowDesign.generalSans(size: 11))
                    .foregroundStyle(LocalFlowDesign.graphite.opacity(0.8))
            } else {
                // Shortcut Fields
                VStack(alignment: .leading, spacing: 6) {
                    Text("When you say")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                    ZStack(alignment: .leading) {
                        if phrase.isEmpty {
                            Text("e.g. btw")
                                .font(LocalFlowDesign.generalSans(size: 14))
                                .foregroundStyle(LocalFlowDesign.graphite.opacity(0.6))
                        }
                        TextField("", text: $phrase)
                            .font(LocalFlowDesign.generalSans(size: 14))
                            .foregroundStyle(LocalFlowDesign.ink)
                            .textFieldStyle(.plain)
                            .focused($phraseFieldFocused)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LocalFlowDesign.card)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LocalFlowDesign.hairline, lineWidth: 1))
                    )
                    .signalFocusRing(isFocused: phraseFieldFocused, cornerRadius: 10)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Expand to")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                    ZStack(alignment: .leading) {
                        if replacement.isEmpty {
                            Text("e.g. by the way")
                                .font(LocalFlowDesign.generalSans(size: 14))
                                .foregroundStyle(LocalFlowDesign.graphite.opacity(0.6))
                        }
                        TextField("", text: $replacement)
                            .font(LocalFlowDesign.generalSans(size: 14))
                            .foregroundStyle(LocalFlowDesign.ink)
                            .textFieldStyle(.plain)
                            .focused($replacementFieldFocused)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LocalFlowDesign.card)
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(LocalFlowDesign.hairline, lineWidth: 1))
                    )
                    .signalFocusRing(isFocused: replacementFieldFocused, cornerRadius: 10)
                }

                Text("When you dictate the shortcut, LocalFlow will expand it seamlessly.")
                    .font(LocalFlowDesign.generalSans(size: 11))
                    .foregroundStyle(LocalFlowDesign.graphite.opacity(0.8))
            }

            Button {
                isFavorite.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isFavorite ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isFavorite ? Color.orange : LocalFlowDesign.graphite.opacity(0.6))
                    Text("Star / Priority")
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .foregroundStyle(LocalFlowDesign.ink)
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 12))
                        .foregroundStyle(isFavorite ? Color.orange : LocalFlowDesign.graphite)
                }
            }
            .buttonStyle(.plain)

            HStack {
                LFSecondaryButton("Cancel") { dismiss() }
                Spacer()
                LFPrimaryButton(isEditing ? "Save" : "Add Word", enabled: canSave) {
                    let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
                    let r = mode == .shortcut ? replacement.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard !p.isEmpty else { return }

                    if let existing = entryToEdit {
                        var updated = existing
                        updated.phrase = p
                        updated.replacement = r
                        updated.hasSparkle = (mode == .customWord) ? hasSparkle : false
                        updated.isFavorite = isFavorite
                        store.update(entry: updated)
                    } else {
                        store.add(
                            phrase: p,
                            replacement: r,
                            isFavorite: isFavorite,
                            hasSparkle: (mode == .customWord) ? hasSparkle : false
                        )
                    }
                    dismiss()
                }
            }
        }
        .padding(28)
        .frame(width: 400)
        .background(LocalFlowDesign.canvas)
        .preferredColorScheme(.light)
        .onAppear { phraseFieldFocused = true }
    }
}
