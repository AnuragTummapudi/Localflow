import Foundation
import Shared

/// Immutable capability boundary derived only from the initiating goal and explicit saved memory.
/// Receipts can supply bounded file handles and satisfaction evidence, never expand this boundary.
public struct GoalEnvelope: Codable, Equatable, Sendable {
    public let uiGoal: SemanticUIGoal?
    public let projects: [String: String]
    public let applications: [String: String]
    public let domains: [String]
    public let workflowRequested: Bool
    public let stopWorkflow: Bool
    public let workflowOperation: String
    public let requestedWorkflowNames: [String]
    public let browserRequested: Bool
    public let projectOpenRequested: Bool
    public let fileOpenRequested: Bool
    public let serviceRequested: Bool
    public let subject: String?
    public let websites: [String]
    public let issue: String?
    public let supported: Bool

    public init(goal: String, memory: AgentMemory, frontmostApplication: String? = nil) {
        // Negative clauses cannot grant a capability. Quoted result text is never passed here.
        let operative = goal.components(separatedBy: CharacterSet(charactersIn: ";\n"))
            .map { part -> String in
                var value = part
                for boundary in ["do not", "don't", "without", "never"] {
                    if let range = value.range(of: boundary, options: .caseInsensitive) { value = String(value[..<range.lowerBound]) }
                }
                return value
            }.joined(separator: " ")
        let ui = SemanticUIGoal(goal: operative, frontmostApplication: frontmostApplication)
        uiGoal = ui
        let lower = operative.lowercased()
        func has(_ values: [String]) -> Bool { values.contains { lower.contains($0) } }
        let clauses = lower.replacingOccurrences(of: " then ", with: " and ").components(separatedBy: " and ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func requests(_ nouns: [String], verbs: [String]) -> Bool {
            clauses.contains { clause in verbs.contains(where: { clause.hasPrefix($0 + " ") }) && nouns.contains(where: { clause.contains($0) }) }
        }
        let saved = (memory.projects ?? []).sorted { $0.name < $1.name }
        let matches = saved.filter { project in
            ([project.name] + project.aliases).contains { name in
                let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])"
                return lower.range(of: pattern, options: .regularExpression) != nil
            }
        }
        var selected = matches
        let unknownNamed = lower.range(of: "(?:find|resolve|open)\\s+(?:my\\s+)?[\\p{L}\\p{N}_-]+\\s+project", options: .regularExpression) != nil && matches.isEmpty && !has(["my project", "the project"])
        if selected.isEmpty && saved.count == 1 && !unknownNamed { selected = saved }
        projects = ui == nil ? Dictionary(uniqueKeysWithValues: selected.enumerated().map { ("p\($0.offset + 1)", $0.element.name) }) : [:]
        issue = ui != nil ? nil : selected.count > 1 ? "Project is ambiguous; ask which saved project." : selected.isEmpty ? "Project is not explicitly saved or is unknown; ask the user." : nil
        workflowRequested = requests(["development", "workflow", " dev"], verbs: ["start", "run", "stop", "list", "show"])
        stopWorkflow = workflowRequested && has(["stop "])
        workflowOperation = has(["stop "]) ? "stop" : has(["start ", "run ", "development"]) ? "run" : "list"
        let knownWorkflows = selected.flatMap { $0.workflows.map(\.name) }
        requestedWorkflowNames = knownWorkflows.filter { name in
            lower.range(of: "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: name) + "(?![\\p{L}\\p{N}])", options: .regularExpression) != nil
                || (name == "dev" && has(["development", "start dev", "run dev", "stop dev"]))
        }
        browserRequested = requests(["browser", "website", "localhost", "the site", "http", "safari"], verbs: ["open"])
        serviceRequested = requests(["localhost", "service"], verbs: ["open", "wait", "check", "start"])
        fileOpenRequested = has(["open file", "open the file", "open agent.swift", "open voiceagentcoordinator", "show me the file"]) || lower.range(of: "open .*\\.(swift|md|json|txt)", options: .regularExpression) != nil
        projectOpenRequested = ui == nil && (!fileOpenRequested && has(["open ", "editor"]) && !has(["open localhost", "open the site", "open http", "website"])
            || has(["open localflow project", "open project", "open my project"]))
        let search = fileOpenRequested || has(["search", "code", "files", "symbol", "voiceagentcoordinator", "continuation", "related to", "find where", "find agent", "find planner"])
        var value: String?
        if let file = operative.range(of: "[\\p{L}\\p{N}_-]+\\.(swift|md|json|txt)", options: [.regularExpression, .caseInsensitive]) { value = String(operative[file]) }
        if let range = operative.range(of: "related to ", options: .caseInsensitive) { value = String(operative[range.upperBound...]) }
        else if let range = operative.range(of: "find where ", options: .caseInsensitive) { value = String(operative[range.upperBound...]).replacingOccurrences(of: " is implemented", with: "", options: .caseInsensitive) }
        else if let range = operative.range(of: "(?:find|search(?: project \\S+ for)?(?: for)?)\\s+", options: [.regularExpression, .caseInsensitive]) {
            value = String(operative[range.upperBound...])
            if let end = value?.range(of: " in ", options: .caseInsensitive) { value = String(value![..<end.lowerBound]) }
        }
        if search {
            if lower.contains("voiceagentcoordinator") { value = "VoiceAgentCoordinator" }
            else if lower.contains("command continuation") { value = "continuation" }
            else if lower.contains("planner") { value = "Planner" }
            else if lower.contains("voice-agent") || lower.contains("voice agent") { value = "VoiceAgent" }
        }
        subject = ui == nil && search ? value?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        var capability = ["project"]
        if search || fileOpenRequested { capability += ["file"] }
        if projectOpenRequested || fileOpenRequested { capability += ["editor"] }
        if workflowRequested { capability += ["workflow"] }
        if serviceRequested { capability += ["service"] }
        if browserRequested { capability += ["browser"] }
        var apps: [String: String] = [:]
        for name in ["Notes", "Safari", "VS Code"] where requests([name.lowercased()], verbs: ["open", "focus"]) { apps["a\(apps.count + 1)"] = name }
        if !apps.isEmpty { capability += ["application"] }
        if let ui { apps = ["a1": ui.applicationName] }
        applications = apps
        domains = ui == nil ? capability : ["application", "ui"]
        websites = selected.flatMap { p -> [String] in
            var urls: [String] = []
            if has(["open localhost", "local service", "open http://127.0.0.1", "open http://localhost"]) { if let url = p.serviceURL { urls.append(url) } }
            if has(["website", "open the site", "browser"]) && !has(["localhost", "local service"]) { if let url = p.websiteURL { urls.append(url) } }
            return urls
        }
        let rejectedUI = ui == nil && has(["system settings", "finder", "search field", " tab"]) && ["open ", "show ", "focus ", "set ", "select ", "enable ", "disable ", "scroll ", "raise ", "observe ", "inspect "].contains(where: { lower.hasPrefix($0) })
        supported = !rejectedUI && !has(["delete", "remove all", "shell", "bash ", "terminal command", "screenshot", "click ", "screen", "spotify", "reminder", "mute", "volume", "lock mac"])
            && (ui != nil || has(["project", "localflow", "development", "workflow", "localhost"]) || search || !matches.isEmpty)
    }

    public func satisfied(by receipts: [PlannerResult]) -> Bool {
        guard supported, issue == nil, !receipts.isEmpty else { return false }
        if let uiGoal { return uiGoal.satisfied(by: receipts) }
        func completed(_ tools: [String], verified: Bool = false) -> Bool {
            receipts.contains { tools.contains($0.tool) && (verified ? $0.status == "verified" : ["verified", "unverified"].contains($0.status)) }
        }
        if subject != nil && !completed(["project.search", "file.search", "editor.revealSymbol"], verified: true) { return false }
        if fileOpenRequested && !completed(["project.openFile", "editor.openFile", "file.open"]) { return false }
        if projectOpenRequested && !fileOpenRequested && !completed(["project.open", "editor.openProject"]) { return false }
        if workflowRequested && !completed([workflowOperation == "list" ? "workflow.list" : stopWorkflow ? "workflow.stop" : "workflow.run"]) { return false }
        if serviceRequested && !completed(["service.wait", "service.status"], verified: true) { return false }
        if browserRequested && !completed(["web.open_url"]) { return false }
        if !applications.isEmpty && !completed(["application.open", "application.focus"]) { return false }
        if subject != nil || fileOpenRequested || projectOpenRequested || workflowRequested || serviceRequested || browserRequested || !applications.isEmpty { return true }
        return completed(["project.resolve"], verified: true)
    }
}

public enum PlannerDecision: String, Codable, Sendable { case toolCall = "TOOL_CALL", finish = "FINISH", askUser = "ASK_USER", abstain = "ABSTAIN" }

/// Per-turn stable handles. Native paths/argv stay behind the host resolver.
@MainActor public struct PlannerTurnScope {
    public let envelope: GoalEnvelope
    public let context: PlannerContext
    public let schemas: [PlannerToolSchema]
    private let files: [String: (project: String, path: String, line: Int?)]
    private let workflows: [String: (project: String, name: String)]
    private let services: [String: String]

    public init(envelope: GoalEnvelope, memory: AgentMemory, receipts: [PlannerResult], registry: ToolRegistry) {
        self.envelope = envelope
        let relevant = receipts.filter { r in
            if let app = r.arguments["app"]?.string { return app == envelope.uiGoal?.application }
            let project = r.arguments["project"]?.string ?? r.arguments["scope"]?.string ?? r.arguments["name"]?.string
            if let project { return envelope.projects.values.contains(project) || envelope.projects.keys.contains(project) }
            if let url = r.arguments["url"]?.string { return envelope.websites.contains(url) }
            if let app = r.arguments["application"]?.string { return envelope.applications.values.contains(app) }
            return false
        }
        var handles: [String: (project: String, path: String, line: Int?)] = [:]
        for r in relevant where r.status == "verified" && ["project.search", "file.search", "editor.revealSymbol"].contains(r.tool) {
            if case .array(let matches) = r.data["matches"] {
                for match in matches.prefix(20) {
                    guard case .object(let fields) = match, let path = fields["path"]?.string,
                          let project = r.arguments["project"]?.string ?? r.arguments["scope"]?.string,
                          !handles.values.contains(where: { $0.project == project && $0.path == path }) else { continue }
                    handles["f\(handles.count + 1)"] = (project, path, fields["line"]?.integer)
                }
            }
        }
        files = handles
        var wf: [String: (project: String, name: String)] = [:], urls: [String: String] = [:]
        for name in envelope.projects.values.sorted() {
            guard let p = try? memory.project(named: name) else { continue }
            if envelope.workflowRequested { for w in p.workflows where w.approvedByUser && envelope.requestedWorkflowNames.contains(w.name) { wf["w\(wf.count + 1)"] = (p.name, w.name) } }
            if envelope.browserRequested { for url in [p.websiteURL, p.serviceURL].compactMap({ $0 }) where envelope.websites.contains(url) { urls["s\(urls.count + 1)"] = url } }
        }
        workflows = wf; services = urls
        var c = PlannerContext(memory: AgentMemory(), receipts: [])
        c.envelope = envelope
        c.handles = ["projects": .object(envelope.projects.mapValues(PlannerValue.string)), "subject": envelope.subject.map { .object(["q1": .string($0)]) } ?? .object([:]),
            "files": .object(handles.mapValues { .object(["path": .string($0.path), "project": .string("p1")]) }),
            "workflows": .object(wf.mapValues { .string($0.name) }), "services": .object(urls.mapValues(PlannerValue.string)), "applications": .object(envelope.applications.mapValues(PlannerValue.string))]
        c.goalSatisfied = envelope.satisfied(by: relevant)
        // No raw details or file contents. Keep only effect identifiers/status and bounded read matches.
        c.receipts = Array(relevant.suffix(6)).map { r in
            var args = r.arguments
            for key in ["project", "scope", "name"] { if let name = args[key]?.string, let id = envelope.projects.first(where: { $0.value == name })?.key { args[key] = .string(id) } }
            if args["query"] != nil { args["query"] = .string("q1") }
            var data: [String: PlannerValue] = [:]
            if let ready = r.data["url"]?.string, let id = urls.first(where: { $0.value == ready })?.key { data["service"] = .string(id) }
            if ["project.search", "file.search", "editor.revealSymbol"].contains(r.tool) { data["fileIDs"] = .array(handles.keys.sorted().map(PlannerValue.string)) }
            return PlannerResult(stepID: r.stepID, tool: r.tool, status: r.status, detail: "", data: data, arguments: args)
        }
        let uiObservation = relevant.reversed().compactMap { SemanticUIObservation.decode($0.data["observation"]) }.first
        let latestUIFailed = relevant.last.map { $0.tool.hasPrefix("ui.") && $0.status == "failed" } ?? false
        let observed = latestUIFailed ? nil : uiObservation.flatMap { observation -> SemanticUIObservation? in
            guard observation.application == envelope.uiGoal?.application, observation.elements.count <= 80, observation.elements.allSatisfy({ $0.id.hasPrefix("ax:" + observation.id + ":") && $0.label.count <= 128 }) else { return nil }; return observation
        }
        if var compact = observed, let ui = envelope.uiGoal {
            compact.elements = Array(compact.elements.filter { node in NativeToolID.allCases.contains { $0.isAccessibility && ui.allows($0, element: node) } }.prefix(16))
            c.handles["uiObservation"] = compact.plannerValue
        }
        context = c
        var ids: Set<String> = ["project.resolve"]
        if envelope.subject != nil { ids.formUnion(["project.search", "file.search"]) }
        if envelope.projectOpenRequested { ids.insert("project.open") }
        if envelope.fileOpenRequested { ids.formUnion(["project.openFile", "editor.openFile"]) }
        if envelope.workflowRequested {
            if envelope.workflowOperation == "list" { ids.insert("workflow.list") }
            else if !wf.isEmpty { ids.insert(envelope.stopWorkflow ? "workflow.stop" : "workflow.run") }
        }
        if envelope.serviceRequested { ids.formUnion(["service.status", "service.wait"]) }
        if envelope.browserRequested { ids.insert("web.open_url") }
        if !envelope.applications.isEmpty { ids.insert("application.open") }
        if let ui = envelope.uiGoal {
            ids = observed == nil ? ["ui.observe"] : []
            if ui.openRequested { ids.insert("application.open") }
            if let observed { for id in NativeToolID.allCases where id.isAccessibility && id != .uiObserve {
                if observed.elements.contains(where: { node in ui.allows(id, element: node) && !relevant.contains(where: { ($0.tool == id.rawValue || [.uiSelect, .uiPress].contains(id) && ["ui.select", "ui.press"].contains($0.tool)) && ["verified", "unverified"].contains($0.status) && $0.data["label"]?.string == node.label && $0.data["role"]?.string == node.role }) }) { ids.insert(id.rawValue) }
            } }
        }
        if !envelope.supported || envelope.issue != nil || c.goalSatisfied { ids = [] }
        var tools = registry.plannerSchemas.filter { ids.contains($0.id) }.map { schema in
            var args = schema.arguments
            if let ui = envelope.uiGoal, let id = NativeToolID(rawValue: schema.id), id.isAccessibility {
                args["app"] = .init(values: ["a1"])
                if args["elementID"] != nil { args["elementID"] = .init(values: observed?.elements.filter { ui.allows(id, element: $0) }.map(\.id) ?? []) }
                if args["value"] != nil { args["value"] = .init(values: [ui.value].compactMap { $0 }) }
                if args["direction"] != nil { args["direction"] = .init(values: [ui.direction].compactMap { $0 }) }
            }
            for key in ["project", "scope", "name"] where args[key] != nil { args[key] = .init(values: envelope.projects.keys.sorted()) }
            if args["query"] != nil { args["query"] = .init(values: ["q1"] + [envelope.subject].compactMap { $0 }) }
            if args["path"] != nil { args["path"] = .init(values: handles.keys.sorted()) }
            if args["workflowName"] != nil { args["workflowName"] = .init(values: wf.keys.sorted() + wf.values.map(\.name).sorted()) }
            if args["url"] != nil { args["url"] = .init(values: urls.keys.sorted()) }
            if args["application"] != nil { args["application"] = .init(values: envelope.applications.keys.sorted()) }
            // Editor/line are frozen by the host, not regenerated by the model.
            args.removeValue(forKey: "preferredEditor"); args.removeValue(forKey: "line")
            return PlannerToolSchema(id: schema.id, purpose: schema.purpose, risk: schema.risk, reversible: schema.reversible, verification: "Host verifies native receipt", contextRequirements: [], arguments: args)
        }
        for name in ["decision.finish", "decision.askUser", "decision.abstain"] {
            tools.append(PlannerToolSchema(id: name, purpose: name == "decision.finish" ? "FINISH only if goalSatisfied" : name == "decision.askUser" ? "ASK_USER when missing or ambiguous context or a failed action prevents progress" : "ABSTAIN when unsupported", risk: "none", reversible: false, verification: "No native effect", contextRequirements: [], arguments: [:]))
        }
        // Too broad requests fail closed rather than arbitrarily dropping a requested domain.
        let delivered = Set(relevant.filter { ["verified", "unverified"].contains($0.status) }.map(\.tool))
        let failed = Set(relevant.filter { $0.status == "failed" }.map(\.tool))
        let searchDone = !delivered.isDisjoint(with: ["project.search", "file.search", "editor.revealSymbol"])
        let workflowDone = !delivered.isDisjoint(with: ["workflow.run", "workflow.stop", "workflow.list"])
        let serviceDone = relevant.contains { ["service.wait", "service.status"].contains($0.tool) && $0.status == "verified" }
        schemas = tools.count <= 12 ? tools.filter {
            ($0.id.hasPrefix("ui.") || !delivered.contains($0.id) && !failed.contains($0.id))
                && !(searchDone && ["project.search", "file.search"].contains($0.id))
                && !(workflowDone && $0.id.hasPrefix("workflow."))
                && !(serviceDone && $0.id.hasPrefix("service."))
        } : Array(tools.suffix(3))
    }

    public func resolve(_ plan: PlannerPlan) throws -> (PlannerDecision, PlannerPlan?) {
        guard plan.steps.count == 1, let step = plan.steps.first, step.dependsOn.isEmpty,
              let schema = schemas.first(where: { $0.id == step.tool }),
              Set(step.arguments.keys).isSubset(of: Set(schema.arguments.keys)),
              schema.arguments.filter({ $0.value.required }).keys.allSatisfy({ step.arguments[$0] != nil }) else { throw ToolError.unavailable("Action is outside the original goal or is not a single action.") }
        if step.tool.hasPrefix("decision.") {
            guard step.arguments.isEmpty else { throw ToolError.invalidArguments }
            if step.tool == "decision.finish" { guard context.goalSatisfied else { throw ToolError.unavailable("Goal has not been satisfied.") }; return (.finish, nil) }
            return (step.tool == "decision.askUser" ? .askUser : .abstain, nil)
        }
        guard !context.goalSatisfied, envelope.supported, envelope.issue == nil else { throw ToolError.invalidArguments }
        var args = step.arguments
        for (key, field) in schema.arguments {
            if let v = args[key] { if field.type == "integer" { guard let n = v.integer, (1...field.maximum).contains(n) else { throw ToolError.invalidArguments } }
                else { guard let s = v.string, field.values?.contains(s) ?? true else { throw ToolError.invalidArguments } } }
        }
        if let app = args["app"]?.string { guard app == "a1", let ui = envelope.uiGoal else { throw ToolError.invalidArguments }; args["app"] = .string(ui.application) }
        var project: String?
        for key in ["project", "scope", "name"] {
            if let id = args[key]?.string { guard let name = envelope.projects[id] else { throw ToolError.invalidArguments }; args[key] = .string(name); project = name }
        }
        if args["query"] != nil { guard let subject = envelope.subject else { throw ToolError.invalidArguments }; args["query"] = .string(subject) }
        if let id = args["path"]?.string { guard let file = files[id], file.project == project else { throw ToolError.invalidArguments }; args["path"] = .string(file.path); if let line = file.line, step.tool != "file.open" { args["line"] = .integer(line) } }
        if let id = args["workflowName"]?.string { guard let w = workflows[id] ?? workflows.values.first(where: { $0.name == id && $0.project == project }), w.project == project else { throw ToolError.invalidArguments }; args["workflowName"] = .string(w.name) }
        if let id = args["url"]?.string { guard let url = services[id], envelope.websites.contains(url) else { throw ToolError.invalidArguments }; args["url"] = .string(url) }
        if let id = args["application"]?.string { guard let app = envelope.applications[id] else { throw ToolError.invalidArguments }; args["application"] = .string(app) }
        return (.toolCall, PlannerPlan(steps: [.init(id: step.id, tool: step.tool, arguments: args)]))
    }
}
