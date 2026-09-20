import Foundation
import Combine

/// A local JSON-backed store for transcription history.
public final class DictationHistoryStore: ObservableObject, @unchecked Sendable {
    /// The current in-memory history items.
    @Published public private(set) var items: [DictationHistoryItem] = []

    private let fileURL: URL
    private let queue = DispatchQueue(label: "LocalFlow.DictationHistoryStore")

    /// Creates a history store under Application Support.
    public convenience init() {
        self.init(fileURL: Self.defaultFileURL())
    }

    /// Creates a history store at a specific file URL.
    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    /// Appends a transcription to local history.
    public func append(text: String, bundleIdentifier: String?) {
        let item = DictationHistoryItem(text: text, bundleIdentifier: bundleIdentifier)
        items.insert(item, at: 0)
        save()
    }

    /// Removes the history item with the supplied identifier.
    public func remove(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Searches history using a case-insensitive substring match.
    public func search(_ query: String) -> [DictationHistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        return items.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Loads history from disk.
    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            items = []
            return
        }
        items = (try? JSONDecoder().decode([DictationHistoryItem].self, from: data)) ?? []
    }

    /// Persists history to disk.
    public func save() {
        let snapshot = items
        let fileURL = fileURL
        queue.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: fileURL, options: [.atomic])
            }
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LocalFlow", isDirectory: true).appendingPathComponent("history.json")
    }
}
