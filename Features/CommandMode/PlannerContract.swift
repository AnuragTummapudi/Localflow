import Foundation
import Shared

public enum PlannerValue: Codable, Equatable, Sendable {
    case string(String), integer(Int), boolean(Bool), array([PlannerValue]), object([String: PlannerValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let x = try? c.decode(Bool.self) { self = .boolean(x) }
        else if let x = try? c.decode(Int.self) { self = .integer(x) }
        else if let x = try? c.decode(String.self) { self = .string(x) }
        else if let x = try? c.decode([PlannerValue].self) { self = .array(x) }
        else { self = .object(try c.decode([String: PlannerValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .boolean(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var integer: Int? { if case .integer(let v) = self { return v }; return nil }
}
public enum PlannerMode: String, Codable, Sendable { case nonThinking, thinking }
public struct PlannerRequest: Codable, Equatable, Sendable {
    public let goal: String
    public let mode: PlannerMode
    public init(goal: String, mode: PlannerMode = .nonThinking) { self.goal = goal; self.mode = mode }
}
/// Versioned text-only boundary; a future observation can be an independent typed extension.
/// No screenshot permission, image field, coordinate action or screen capture is connected.
public struct PlannerContext: Codable, Equatable, Sendable {
    public var version = 1
    public var envelope: GoalEnvelope? = nil
    public var handles: [String: PlannerValue] = [:]
    public var goalSatisfied = false
    public var projects: [ProjectRecord]
    public var preferredApps: [String: String]
    public var receipts: [PlannerResult]
    public init(memory: AgentMemory, receipts: [PlannerResult] = []) {
        projects = memory.projects ?? []; preferredApps = memory.preferredApps; self.receipts = Array(receipts.suffix(16))
    }
}
public struct PlannerDependency: Codable, Equatable, Sendable {
    public let stepID: String
    public let requiresVerified: Bool
    public init(stepID: String, requiresVerified: Bool = true) { self.stepID = stepID; self.requiresVerified = requiresVerified }
}
public struct PlannerStep: Codable, Equatable, Sendable {
    public let id: String
    public let tool: String
    public let arguments: [String: PlannerValue]
    public let dependsOn: [PlannerDependency]
    public init(id: String, tool: String, arguments: [String: PlannerValue], dependsOn: [PlannerDependency] = []) {
        self.id = id; self.tool = tool; self.arguments = arguments; self.dependsOn = dependsOn
    }
}
public struct PlannerPlan: Codable, Equatable, Sendable {
    public let steps: [PlannerStep]
    public init(steps: [PlannerStep]) { self.steps = steps }
}
public struct PlannerResult: Codable, Equatable, Sendable {
    public let stepID: String
    public let tool: String
    public let arguments: [String: PlannerValue]
    public let status: String
    public let detail: String
    public let data: [String: PlannerValue]
    public init(stepID: String, tool: String, status: String, detail: String, data: [String: PlannerValue] = [:], arguments: [String: PlannerValue] = [:]) {
        self.stepID = stepID; self.tool = tool; self.status = status
        self.detail = String(detail.prefix(512)); self.data = data; self.arguments = arguments
    }
}
public struct PlannerArgumentSchema: Codable, Equatable, Sendable {
    public let type: String
    public let required: Bool
    public let values: [String]?
    public let maximum: Int
    public init(_ type: String = "string", required: Bool = true, values: [String]? = nil, maximum: Int = 4096) {
        self.type = type; self.required = required; self.values = values; self.maximum = maximum
    }
}
public struct PlannerToolSchema: Codable, Sendable {
    public let id: String
    public let purpose: String
    public let risk: String
    public let reversible: Bool
    public let verification: String
    public let contextRequirements: [String]
    public let arguments: [String: PlannerArgumentSchema]
    public func functionSchema() -> [String: PlannerValue] {
        let properties = arguments.mapValues { field -> PlannerValue in
            var object: [String: PlannerValue] = ["type": .string(field.type)]
            if let values = field.values { object["enum"] = .array(values.map(PlannerValue.string)) }
            if field.type == "integer" { object["minimum"] = .integer(1); object["maximum"] = .integer(field.maximum) }
            else { object["maxLength"] = .integer(field.maximum) }
            return .object(object)
        }
        return ["type": .string("function"), "function": .object([
            "name": .string(id), "description": .string(purpose + ". Risk: " + risk + ". " + verification),
            "parameters": .object(["type": .string("object"), "properties": .object(properties),
                "required": .array(arguments.filter { $0.value.required }.keys.sorted().map(PlannerValue.string)),
                "additionalProperties": .boolean(false)])])]
    }
}

/// Metadata is attached to registered IDs; internal/vision tools are absent by construction.
extension NativeToolID {
    public var plannerRetryable: Bool {
        [.projectResolve, .projectSearch, .fileSearch, .workflowList, .serviceWait, .serviceStatus, .editorRevealSymbol].contains(self)
    }
    public var plannerArguments: [String: PlannerArgumentSchema]? {
        switch self {
        case .uiObserve: return ["app": .init(maximum: 256)]
        case .uiFocus, .uiPress, .uiSelect, .uiRaiseWindow: return ["app": .init(maximum: 256), "elementID": .init(maximum: 80)]
        case .uiSetValue: return ["app": .init(maximum: 256), "elementID": .init(maximum: 80), "value": .init(maximum: 128)]
        case .uiScroll: return ["app": .init(maximum: 256), "elementID": .init(maximum: 80), "direction": .init(values: ["up", "down"])]
        case .openApplication, .focusApplication, .quitApplication: return ["application": .init()]
        case .openURL: return ["url": .init()]
        case .searchWeb, .searchProvider: return ["query": .init(), "provider": .init(values: SearchProviderRegistry.shared.plannerProviderNames)]
        case .mute, .unmute, .lockMac: return [:]
        case .projectResolve: return ["name": .init()]
        case .projectOpen, .editorOpenProject: return ["project": .init(), "preferredEditor": .init(required: false)]
        case .projectReveal, .workflowList, .serviceStatus: return ["project": .init()]
        case .projectSearch, .editorRevealSymbol: return ["project": .init(), "query": .init(maximum: 256)]
        case .projectOpenFile, .editorOpenFile: return ["project": .init(), "path": .init(), "line": .init("integer", required: false, maximum: 1_000_000)]
        case .fileSearch: return ["scope": .init(), "query": .init(maximum: 256)]
        case .fileOpen, .fileReveal: return ["project": .init(), "path": .init()]
        case .workflowRun, .workflowStop: return ["project": .init(), "workflowName": .init()]
        case .serviceWait: return ["project": .init(), "timeout": .init("integer", required: false, maximum: 120)]
        default: return nil
        }
    }
}
extension ToolRegistry {
    public var plannerSchemas: [PlannerToolSchema] {
        allTools.compactMap { tool in
            guard let arguments = tool.id.plannerArguments else { return nil }
            return PlannerToolSchema(id: tool.id.rawValue, purpose: tool.description, risk: tool.risk.rawValue,
                reversible: tool.risk == .reversible, verification: tool.id.argumentKind == .semantic ? "Native readback; launch acceptance alone remains unverified" : "Existing native receipt semantics",
                contextRequirements: tool.id.isAccessibility ? ["goal-grounded application; current ephemeral observation ID for actions; host classifies contextual risk"] : tool.id.argumentKind == .semantic ? ["explicit saved project; workflow.run requires saved approved workflow"] : [], arguments: arguments)
        }
    }
}

@MainActor public struct PlannerValidator {
    public let registry: ToolRegistry
    public let commands: CommandMode
    public let memory: AgentMemory
    public let receipts: [PlannerResult]
    public init(registry: ToolRegistry, commands: CommandMode, memory: AgentMemory, receipts: [PlannerResult] = []) { self.registry = registry; self.commands = commands; self.memory = memory; self.receipts = receipts }
    public func validate(_ plan: PlannerPlan) throws -> [(PlannerStep, AgentAction)] {
        guard (1...8).contains(plan.steps.count), Set(plan.steps.map(\.id)).count == plan.steps.count,
              plan.steps.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 80 && $0.dependsOn.count <= 8 }) else { throw ToolError.invalidArguments }
        let ids = Set(plan.steps.map(\.id))
        let graph = Dictionary(uniqueKeysWithValues: plan.steps.map { ($0.id, $0.dependsOn.map(\.stepID)) })
        func visit(_ id: String, _ ancestors: Set<String>) throws {
            guard !ancestors.contains(id) else { throw ToolError.invalidArguments }
            for next in graph[id] ?? [] { guard ids.contains(next) else { throw ToolError.invalidArguments }; try visit(next, ancestors.union([id])) }
        }
        for step in plan.steps { try visit(step.id, []) }
        return try plan.steps.map { step in
            guard let id = NativeToolID(rawValue: step.tool), let fields = registry.plannerSchemas.first(where: { $0.id == step.tool })?.arguments,
                  Set(step.arguments.keys).isSubset(of: Set(fields.keys)), fields.filter({ $0.value.required }).keys.allSatisfy({ step.arguments[$0] != nil }) else { throw ToolError.invalidArguments }
            for (key, value) in step.arguments {
                let field = fields[key]!
                if field.type == "integer" { guard let number = value.integer, (1...field.maximum).contains(number) else { throw ToolError.invalidArguments } }
                else { guard let text = value.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= field.maximum, !text.contains("\0"), field.values.map({ $0.contains(text) }) ?? true else { throw ToolError.invalidArguments } }
            }
            let args: ToolArguments
            func string(_ key: String) -> String { step.arguments[key]?.string ?? "" }
            switch id {
            case .openApplication, .focusApplication, .quitApplication:
                let name = string("application")
                let verb = id == .quitApplication ? "quit " : id == .focusApplication ? "switch to " : "open "
                switch commands.resolve(verb + name) {
                case .execute(let intent), .needsConfirmation(let intent):
                    guard intent.agentAction.toolID == id, case .application(let app, _) = intent.agentAction.arguments,
                          app.name.caseInsensitiveCompare(name) == .orderedSame || app.bundleIdentifier == name || app.alternateNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { throw ToolError.invalidArguments }
                    args = .application(app)
                case .notCommand: throw ToolError.invalidArguments
                }
            case .openURL:
                guard let url = URL(string: string("url")) else { throw ToolError.invalidArguments }
                if ["localhost", "127.0.0.1", "::1"].contains(url.host) {
                    guard let project = (memory.projects ?? []).first(where: { $0.serviceURL == url.absoluteString }) else {
                        throw ToolError.unavailable("Planner localhost URLs must exactly match an explicitly saved service.")
                    }
                    let ready = receipts.contains { $0.tool == NativeToolID.serviceWait.rawValue || $0.tool == NativeToolID.serviceStatus.rawValue ? $0.status == "verified" && $0.data["url"]?.string == url.absoluteString : false }
                    let plannedWait = plan.steps.contains { candidate in
                        candidate.tool == NativeToolID.serviceWait.rawValue && candidate.arguments["project"]?.string.flatMap({ try? memory.project(named: $0).name }) == project.name
                        && step.dependsOn.contains(where: { $0.stepID == candidate.id && $0.requiresVerified })
                    }
                    guard ready || plannedWait else { throw ToolError.unavailable("Saved service must verify ready before the planner opens localhost.") }
                }
                args = .url(url)
            case .searchWeb, .searchProvider: args = .search(query: string("query"), provider: string("provider"))
            case .mute, .unmute, .lockMac: args = .none
            default:
                let semantic = SemanticToolArguments(values: step.arguments)
                if !id.isAccessibility { try semantic.validate(for: id, memory: memory) }
                else { try semantic.validateShape(for: id) }
                args = .semantic(semantic)
            }
            try args.validate(for: id)
            return (step, AgentAction(toolID: id, arguments: args))
        }
    }
}

/// Parses only the model's documented tool-call grammar. No prose-to-action regex or recovery.
public enum QwenToolCallParser {
    public static func parse(_ output: String) throws -> PlannerPlan {
        guard output.utf8.count <= 65_536 else { throw ToolError.invalidArguments }
        var source = output[...]
        func take(_ literal: String) throws {
            source = source.drop(while: { $0.isWhitespace })
            guard source.hasPrefix(literal) else { throw ToolError.invalidArguments }
            source = source.dropFirst(literal.count)
        }
        // Thinking is discarded in the helper. This supports opt-in raw parser fixtures only.
        if source.hasPrefix("<think>") { guard let end = source.range(of: "</think>") else { throw ToolError.invalidArguments }; source = source[end.upperBound...] }
        var steps: [PlannerStep] = []
        while !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try take("<tool_call>")
            source = source.drop(while: { $0.isWhitespace })
            if source.hasPrefix("{") {
                guard let close = source.range(of: "</tool_call>"),
                      let data = String(source[..<close.lowerBound]).data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      Set(object.keys) == ["name", "arguments"], let name = object["name"] as? String,
                      let raw = object["arguments"] as? [String: Any] else { throw ToolError.invalidArguments }
                let arguments = try JSONDecoder().decode([String: PlannerValue].self, from: JSONSerialization.data(withJSONObject: raw))
                guard steps.count < 8 else { throw ToolError.invalidArguments }
                steps.append(.init(id: String(steps.count + 1), tool: name, arguments: arguments))
                source = source[close.upperBound...]; continue
            }
            try take("<function=")
            guard let end = source.firstIndex(of: ">") else { throw ToolError.invalidArguments }
            let name = String(source[..<end]); source = source[source.index(after: end)...]
            var arguments: [String: PlannerValue] = [:]
            while source.drop(while: { $0.isWhitespace }).hasPrefix("<parameter=") {
                try take("<parameter=")
                guard let keyEnd = source.firstIndex(of: ">") else { throw ToolError.invalidArguments }
                let key = String(source[..<keyEnd]); source = source[source.index(after: keyEnd)...]
                guard arguments[key] == nil, let valueEnd = source.range(of: "</parameter>") else { throw ToolError.invalidArguments }
                let text = source[..<valueEnd.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                if NativeToolID(rawValue: name)?.plannerArguments?[key]?.type == "integer" {
                    guard let value = Int(text) else { throw ToolError.invalidArguments }; arguments[key] = .integer(value)
                } else { arguments[key] = .string(text) }
                source = source[valueEnd.upperBound...]
            }
            try take("</function>"); try take("</tool_call>")
            guard steps.count < 8 else { throw ToolError.invalidArguments }
            // Calls emitted together are ordered by explicit accepted-receipt dependencies.
            let dependencies = steps.last.map { [PlannerDependency(stepID: $0.id, requiresVerified: $0.tool == NativeToolID.serviceWait.rawValue || $0.tool == NativeToolID.serviceStatus.rawValue)] } ?? []
            steps.append(PlannerStep(id: String(steps.count + 1), tool: name, arguments: arguments, dependsOn: dependencies))
        }
        guard !steps.isEmpty else { throw ToolError.invalidArguments }
        return PlannerPlan(steps: steps)
    }
    public static func decodeJSON(_ bytes: Data) throws -> PlannerPlan {
        guard bytes.count <= 65_536, let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              Set(object.keys) == ["steps"], let steps = object["steps"] as? [[String: Any]], steps.allSatisfy({
                  Set($0.keys).isSubset(of: ["id", "tool", "arguments", "dependsOn"])
                  && ($0["dependsOn"] as? [[String: Any]] ?? []).allSatisfy({ Set($0.keys) == ["stepID", "requiresVerified"] })
              }) else { throw ToolError.invalidArguments }
        return try JSONDecoder().decode(PlannerPlan.self, from: bytes)
    }
}

/// The pinned helper classifies EOS separately from native function envelopes.
/// An assistant stop is advisory, carries no prose and never manufactures a receipt.
public enum PlannerReplyDecoder {
    public static func decode(kind: String?, output: String) throws -> PlannerPlan? {
        switch kind {
        case "tool_calls": return try QwenToolCallParser.parse(output)
        case "finish", "ask_user", "abstain":
            guard output.isEmpty else { throw ToolError.invalidArguments }
            let tool = kind == "finish" ? "decision.finish" : kind == "ask_user" ? "decision.askUser" : "decision.abstain"
            return .init(steps: [.init(id: "1", tool: tool, arguments: [:])])
        case "assistant_stop":
            guard output.isEmpty else { throw ToolError.invalidArguments }
            return nil
        default: throw ToolError.invalidArguments
        }
    }
}
