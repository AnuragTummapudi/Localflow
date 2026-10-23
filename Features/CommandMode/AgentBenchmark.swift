import Foundation

public struct AgentBenchmarkScenario: Identifiable, Sendable {
    public let id: Int
    public let instruction: String
    public let expectedCommands: [String]
    public static let daily = [
        AgentBenchmarkScenario(id: 1, instruction: "Open Notes", expectedCommands: ["Open Notes"]),
        AgentBenchmarkScenario(id: 2, instruction: "Create a new note, call it LocalFlow Benchmark", expectedCommands: ["Create note LocalFlow Benchmark"]),
        AgentBenchmarkScenario(id: 3, instruction: "Append to current note This is my dictated benchmark text.", expectedCommands: ["Append to current note This is my dictated benchmark text."]),
        AgentBenchmarkScenario(id: 4, instruction: "Open browser", expectedCommands: ["Open browser"]),
        AgentBenchmarkScenario(id: 5, instruction: "Search for Ada Lovelace", expectedCommands: ["Search for Ada Lovelace"]),
        AgentBenchmarkScenario(id: 6, instruction: "Open https://www.wikipedia.org", expectedCommands: ["Open https://www.wikipedia.org"]),
        AgentBenchmarkScenario(id: 7, instruction: "Open Photo Booth", expectedCommands: ["Open Photo Booth"]),
        AgentBenchmarkScenario(id: 8, instruction: "Open https://example.com", expectedCommands: ["Open https://example.com"]),
        AgentBenchmarkScenario(id: 9, instruction: "Create reminder Review LocalFlow benchmark", expectedCommands: ["Create reminder Review LocalFlow benchmark"]),
        AgentBenchmarkScenario(id: 10, instruction: "Open Notes then open browser then search for Swift actors", expectedCommands: ["Open Notes", "Open browser", "Search for Swift actors"])
    ]
    public func expectedActions(commands: CommandMode) throws -> [AgentAction] {
        try expectedCommands.map { text in
            switch commands.resolve(text) {
            case .execute(let intent), .needsConfirmation(let intent): return intent.agentAction
            case .notCommand: throw ToolError.unavailable("Benchmark requires configured browser and installed target apps.")
            }
        }
    }
}

/// Metadata only. Nil STT timing means batch-only/no partial, never a fabricated zero.
public struct AgentBenchmarkResult: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var date = Date()
    public let scenario: Int
    public let mode: String
    public let speechSource: String?
    public let decisionSources: [String]
    public let observedTools: [String]
    public let partialSTTMilliseconds: Double?
    public let decisionMilliseconds: Double?
    public let firstActionMilliseconds: Double?
    public let completionMilliseconds: Double?
    public let duplicateActionRate: Double
    public let incorrectActionRate: Double
    public let missingActions: Int
    public let unverifiedActions: Int
    public let failedActions: Int
    public let outOfOrderActions: Int
    public let cancelled: Bool

    public init(scenario: Int, mode: String, snapshot: VoiceAgentSnapshot, expected: [AgentAction]) {
        self.scenario = scenario; self.mode = mode
        speechSource = snapshot.speechSource; decisionSources = snapshot.decisionSources
        observedTools = snapshot.actions.filter(\.performed).map { $0.action.toolID.rawValue }
        partialSTTMilliseconds = snapshot.timings.first { $0.kind == .speechToPartial }?.milliseconds
        let decisions = snapshot.timings.filter { $0.kind == .decision }.map(\.milliseconds)
        decisionMilliseconds = decisions.isEmpty ? nil : decisions.reduce(0, +) / Double(decisions.count)
        firstActionMilliseconds = snapshot.timings.first { $0.kind == .actionStart }?.milliseconds
        completionMilliseconds = snapshot.timings.last { $0.kind == .totalCompletion }?.milliseconds
        let delivered = snapshot.actions.filter(\.performed)
        var remaining = expected
        var duplicate = 0, incorrect = 0, outOfOrder = 0
        func matches(_ lhs: AgentAction, _ rhs: AgentAction) -> Bool {
            guard lhs.toolID == rhs.toolID else { return false }
            if case .application(let l, _) = lhs.arguments, case .application(let r, _) = rhs.arguments {
                return l.id == r.id && l.url == r.url
            }
            return lhs.arguments == rhs.arguments
        }
        for record in delivered {
            if let index = remaining.firstIndex(where: { matches($0, record.action) }) {
                if index != 0 { outOfOrder += 1; incorrect += 1 }
                remaining.remove(at: index)
            }
            else if expected.contains(where: { matches($0, record.action) }) { duplicate += 1 }
            else { incorrect += 1 }
        }
        let denominator = Double(max(1, delivered.count))
        duplicateActionRate = Double(duplicate) / denominator
        incorrectActionRate = Double(incorrect) / denominator
        missingActions = remaining.count
        unverifiedActions = delivered.filter { $0.verification != .verified }.count
        failedActions = snapshot.actions.filter { $0.phase == .failed }.count
        outOfOrderActions = outOfOrder
        cancelled = snapshot.isCancelled
    }
}
