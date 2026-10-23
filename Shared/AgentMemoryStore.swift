import Combine
import Foundation

/// Only explicitly configured operational data. No conversation, audio, or transcript fields.
public struct AgentMemory: Codable, Equatable, Sendable {
    public var version = 1
    /// Optional for backward-compatible v1 JSON; explicit project configuration only.
    public var projects: [ProjectRecord]? = nil
    public var realTimeEnabled = true
    public var confirmAllActions = false
    public var preferredApps: [String: String] = [:]
    public var applicationAliases: [String: String] = [:]
    public var folders: [String: String] = [:]
    public var websites: [String: String] = [:]
    public var workflows: [String: [String]] = [:]
    public var approvedCommands: [String: String] = [:]
    /// Explicit literal-to-literal payload mappings. Absent in existing v1 memory.
    /// These never rewrite a command header or choose an action.
    public var payloadVocabulary: [String: String]? = nil
    public init() {}
    public static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    public func validate() throws {
        let terms = payloadVocabulary ?? [:]
        guard terms.count <= 200, Set(terms.keys.map(Self.key)).count == terms.count,
              terms.allSatisfy({ !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.key.count <= 160 && !$0.key.contains("\n") && !$0.key.contains("\0")
                  && !$0.value.isEmpty && $0.value.count <= 2000 && !$0.value.contains("\0") }) else {
            throw AgentMemoryError.invalid("Payload vocabulary needs unique, nonempty explicit mappings.")
        }
        let records = projects ?? []
        guard records.count <= 100, Set(records.map { Self.key($0.name) }).count == records.count else {
            throw AgentMemoryError.invalid("Project names must be unique; at most 100 projects.")
        }
        for record in records { try record.validate() }
        guard version == 1 else { throw AgentMemoryError.invalid("Unsupported memory version.") }
        let groups = [applicationAliases.keys.map { $0 }, folders.keys.map { $0 }, websites.keys.map { $0 }, workflows.keys.map { $0 }, approvedCommands.keys.map { $0 }]
        let keys = groups.flatMap { $0 }.map(Self.key)
        guard keys.count <= 500, Set(keys).count == keys.count,
              keys.allSatisfy({ !$0.isEmpty && $0.count <= 160 && !$0.contains("\n") }),
              Set(preferredApps.keys).isSubset(of: ["browser", "editor", "terminal"]) else {
            throw AgentMemoryError.invalid("Use unique aliases and browser, editor, or terminal preferences.")
        }
        for value in Array(applicationAliases.values) + Array(preferredApps.values) {
            guard !Self.key(value).isEmpty, value.count <= 256 else { throw AgentMemoryError.invalid("Choose an application name or bundle identifier.") }
        }
        for path in folders.values {
            guard path.hasPrefix("/"), !path.contains("\0") else { throw AgentMemoryError.invalid("Folders need an absolute path.") }
        }
        for value in websites.values {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host?.isEmpty == false, url.user == nil, url.password == nil else {
                throw AgentMemoryError.invalid("Websites need an HTTP(S) URL without credentials.")
            }
        }
        for commands in workflows.values {
            guard (1...20).contains(commands.count), commands.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100_000 }) else {
                throw AgentMemoryError.invalid("Workflows need 1–20 supported commands.")
            }
        }
        guard approvedCommands.values.allSatisfy({ !Self.key($0).isEmpty && $0.utf8.count <= 100_000 }) else {
            throw AgentMemoryError.invalid("Approved mappings need a nonempty supported command.")
        }
    }
}

public enum AgentMemoryError: Error, LocalizedError {
    case invalid(String), externalEdit
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): return detail
        case .externalEdit: return "Memory changed on disk. Reload before saving."
        }
    }
}

public struct AgentActivity: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public let tool: String
    public let outcome: String
    public let milliseconds: Double
    public init(tool: String, outcome: String, milliseconds: Double) {
        self.tool = tool; self.outcome = outcome; self.milliseconds = milliseconds
    }
}

/// One main-actor owner; atomic JSON writes, conflict detection, and bounded metadata history.
@MainActor public final class AgentMemoryStore: ObservableObject {
    @Published public private(set) var memory = AgentMemory()
    @Published public private(set) var activity: [AgentActivity] = []
    @Published public private(set) var error: String?
    public let fileURL: URL
    public let activityURL: URL
    private var loadedBytes: Data?
    public init(directory: URL? = nil) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFlow/Agent", isDirectory: true)
        fileURL = root.appendingPathComponent("memory.json")
        activityURL = root.appendingPathComponent("activity.json")
        reload()
    }
    public func reload() {
        do {
            let bytes = try diskBytes()
            let value = try bytes.map { try JSONDecoder().decode(AgentMemory.self, from: $0) } ?? AgentMemory()
            try value.validate()
            memory = value; loadedBytes = bytes; error = nil
            if FileManager.default.fileExists(atPath: activityURL.path) {
                let events = try JSONDecoder().decode([AgentActivity].self, from: Data(contentsOf: activityURL))
                guard events.allSatisfy({ $0.milliseconds.isFinite && (0...86_400_000).contains($0.milliseconds) }) else {
                    throw AgentMemoryError.invalid("Activity contains invalid timing values.")
                }
                activity = Array(events.suffix(200))
            }
        } catch { self.error = error.localizedDescription }
    }
    public func save(_ value: AgentMemory) throws {
        try value.validate()
        guard try diskBytes() == loadedBytes else { throw AgentMemoryError.externalEdit }
        let bytes = try Self.encode(value)
        guard bytes.count <= 2_000_000 else { throw AgentMemoryError.invalid("Memory exceeds 2 MB.") }
        try write(bytes, to: fileURL)
        memory = value; loadedBytes = bytes; error = nil
    }
    public func editableJSON() throws -> String {
        String(decoding: try Self.encode(memory), as: UTF8.self)
    }
    public func record(_ event: AgentActivity) {
        guard event.milliseconds.isFinite, (0...86_400_000).contains(event.milliseconds) else { return }
        activity.append(event); activity = Array(activity.suffix(200))
        do { try write(Self.encode(activity), to: activityURL) }
        catch { self.error = error.localizedDescription }
    }
    public func reset() throws {
        // Explicit reset also recovers invalid/manual edits, without touching other app data.
        let bytes = try Self.encode(AgentMemory())
        try write(bytes, to: fileURL)
        memory = AgentMemory(); loadedBytes = bytes
        activity = []; try write(Self.encode(activity), to: activityURL); error = nil
    }
    private func diskBytes() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let bytes = try Data(contentsOf: fileURL)
        guard bytes.count <= 2_000_000 else { throw AgentMemoryError.invalid("Memory exceeds 2 MB.") }
        return bytes
    }
    private func write(_ bytes: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
