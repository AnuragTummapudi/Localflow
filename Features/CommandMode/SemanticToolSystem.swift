import AppKit
import Foundation
import Shared

public struct SemanticToolArguments: Equatable, Sendable {
    public let values: [String: PlannerValue]
    /// Frozen by native preparation, never accepted from planner JSON.
    public var preparedUILabel: String?
    public var preparedProject: ProjectRecord?
    public var preparedCanonicalFolder: String?
    public var preparedWorkflowDirectory: String?
    public var preparedExecutablePath: String?
    public init(values: [String: PlannerValue]) { self.values = values }
    public func string(_ key: String) -> String { values[key]?.string ?? "" }
    public func validateShape(for id: NativeToolID) throws {
        guard id.argumentKind == .semantic, let fields = id.plannerArguments,
              Set(values.keys).isSubset(of: Set(fields.keys)), fields.filter({ $0.value.required }).keys.allSatisfy({ values[$0] != nil }) else { throw ToolError.invalidArguments }
        for (key, value) in values {
            let field = fields[key]!
            if field.type == "integer" { guard let n = value.integer, (1...field.maximum).contains(n) else { throw ToolError.invalidArguments } }
            else { guard let s = value.string, !s.isEmpty, s.utf8.count <= field.maximum, !s.contains("\0"), field.values.map({ $0.contains(s) }) ?? true else { throw ToolError.invalidArguments } }
        }
    }
    public func project(for id: NativeToolID, memory: AgentMemory) throws -> ProjectRecord {
        try memory.project(named: string(id == .projectResolve ? "name" : id == .fileSearch ? "scope" : "project"))
    }
    public func validate(for id: NativeToolID, memory: AgentMemory) throws {
        try validateShape(for: id)
        let record = try project(for: id, memory: memory)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: record.folder, isDirectory: &directory), directory.boolValue,
              FileManager.default.isReadableFile(atPath: record.folder) else { throw ToolError.unavailable("Saved project folder is inaccessible.") }
        if let preparedProject, preparedProject != record { throw ToolError.changedTarget }
        if let preparedCanonicalFolder, preparedCanonicalFolder != URL(fileURLWithPath: record.folder).standardizedFileURL.resolvingSymlinksInPath().path { throw ToolError.changedTarget }
        if id == .workflowRun || id == .workflowStop {
            guard record.workflows.contains(where: { AgentMemory.key($0.name) == AgentMemory.key(string("workflowName")) && $0.approvedByUser }) else { throw ToolError.unavailable("Workflow is not explicitly saved and approved.") }
        }
        if values["path"] != nil { _ = try file(in: record) }
        if id == .serviceWait || id == .serviceStatus { guard record.serviceURL != nil else { throw ToolError.unavailable("No loopback service is saved for this project.") } }
        if let editor = values["preferredEditor"]?.string {
            guard editor == record.preferredEditor || editor == memory.preferredApps["editor"] else { throw ToolError.invalidArguments }
        }
    }
    public func file(in project: ProjectRecord) throws -> URL {
        let path = string("path")
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: project.folder).appendingPathComponent(path)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard !path.isEmpty, ProjectRecord.contains(resolved.path, in: project.folder),
              FileManager.default.fileExists(atPath: resolved.path), FileManager.default.isReadableFile(atPath: resolved.path),
              !["app", "command", "sh", "scpt", "workflow"].contains(resolved.pathExtension.lowercased()),
              !FileManager.default.isExecutableFile(atPath: resolved.path) else { throw ToolError.unavailable("File is inaccessible, executable or outside the saved project.") }
        return resolved
    }
}

@MainActor public final class SemanticToolSystem {
    private let memory: @MainActor () -> AgentMemory
    private let workflowGuard: @MainActor () throws -> URL
    private var processes: [String: OwnedWorkflowProcess] = [:]
    public init(memory: @escaping @MainActor () -> AgentMemory, workflowGuard: @escaping @MainActor () throws -> URL = PlannerWorkflowGuard.verifiedExecutable) { self.memory = memory; self.workflowGuard = workflowGuard }
    public func prepare(_ action: AgentAction) throws -> AgentAction {
        guard case .semantic(var args) = action.arguments else { throw ToolError.invalidArguments }
        let current = memory(); try args.validate(for: action.toolID, memory: current)
        let project = try args.project(for: action.toolID, memory: current)
        args.preparedProject = project
        args.preparedCanonicalFolder = URL(fileURLWithPath: project.folder).standardizedFileURL.resolvingSymlinksInPath().path
        if action.toolID == .workflowRun, let workflow = project.workflows.first(where: { AgentMemory.key($0.name) == AgentMemory.key(args.string("workflowName")) }) {
            args.preparedWorkflowDirectory = URL(fileURLWithPath: workflow.workingDirectory).standardizedFileURL.resolvingSymlinksInPath().path
            args.preparedExecutablePath = URL(fileURLWithPath: workflow.executable).standardizedFileURL.resolvingSymlinksInPath().path
        }
        return action.prepared(arguments: .semantic(args))
    }
    public func stopAllImmediately() { for process in processes.values { process.stopImmediately() }; processes.removeAll() }
    public func stopAll() async {
        let owned = processes; processes.removeAll()
        for process in owned.values { await process.stop() }
    }
    public func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
        guard case .semantic(let args) = arguments else { throw ToolError.invalidArguments }
        let current = memory(); try args.validate(for: id, memory: current)
        let project = try args.project(for: id, memory: current)
        try Task.checkCancellation()
        switch id {
        case .projectResolve:
            return ToolExecution(message: "Resolved \(project.name)", output: .semantic(["project": .string(project.name), "folder": .string(project.folder)]), verification: .verified)
        case .projectSearch, .fileSearch, .editorRevealSymbol:
            let worker = Task.detached(priority: .userInitiated) { try Self.search(project: project, query: args.string("query")) }
            let results = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            return ToolExecution(message: results.isEmpty ? "No project matches" : "Found \(results.count) project matches", output: .semantic(["matches": .array(results)]), verification: .verified)
        case .projectOpen, .editorOpenProject, .projectOpenFile, .editorOpenFile, .fileOpen:
            let target = id == .projectOpen || id == .editorOpenProject ? URL(fileURLWithPath: project.folder) : try args.file(in: project)
            let editor = args.values["preferredEditor"]?.string ?? project.preferredEditor ?? current.preferredApps["editor"]
            guard let editor, let app = Self.editorURL(editor) else { throw ToolError.unavailable("Preferred editor is unavailable. Configure it in Settings.") }
            // Files are data URLs to the configured app, never executable launches or custom URI schemes.
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
            if let line = args.values["line"]?.integer, line > 1 {
                guard Bundle(url: app)?.bundleIdentifier == "com.microsoft.VSCode" else { throw ToolError.unavailable("This editor does not support verified line navigation. Open the file without a line.") }
                configuration.arguments = ["--goto", target.path + ":" + String(line)]
            }
            _ = try await NSWorkspace.shared.open([target], withApplicationAt: app, configuration: configuration)
            return ToolExecution(message: "Opening \(target.lastPathComponent)", output: .file(target), verification: .unverified("Editor accepted the file/project request; file and line selection are not read back."))
        case .projectReveal, .fileReveal:
            let target = id == .projectReveal ? URL(fileURLWithPath: project.folder) : try args.file(in: project)
            NSWorkspace.shared.activateFileViewerSelecting([target])
            return ToolExecution(message: "Revealing \(target.lastPathComponent)", output: .file(target), verification: .unverified("Finder selection is not read back."))
        case .workflowList:
            return ToolExecution(message: "\(project.workflows.count) saved workflows", output: .semantic(["workflows": .array(project.workflows.map { .string($0.name) })]), verification: .verified)
        case .workflowRun:
            let workflow = project.workflows.first { AgentMemory.key($0.name) == AgentMemory.key(args.string("workflowName")) }!
            if let prepared = args.preparedWorkflowDirectory, prepared != URL(fileURLWithPath: workflow.workingDirectory).standardizedFileURL.resolvingSymlinksInPath().path { throw ToolError.changedTarget }
            if let prepared = args.preparedExecutablePath, prepared != URL(fileURLWithPath: workflow.executable).standardizedFileURL.resolvingSymlinksInPath().path { throw ToolError.changedTarget }
            let key = project.folder + ":" + AgentMemory.key(workflow.name)
            guard processes[key] == nil else { throw ToolError.unavailable("Workflow is already owned. Stop it before restarting.") }
            guard FileManager.default.isExecutableFile(atPath: workflow.executable), ProjectRecord.contains(workflow.workingDirectory, in: project.folder) else { throw ToolError.unavailable("Saved workflow executable or working directory is unavailable.") }
            let process = try OwnedWorkflowProcess(workflow: workflow, guardExecutable: try workflowGuard()); processes[key] = process
            if Task.isCancelled { await process.stop(); processes.removeValue(forKey: key); throw CancellationError() }
            // VERIFIED means process ownership/start, never service readiness or command completion.
            return ToolExecution(message: "Started \(workflow.name)", output: .semantic(["pid": .integer(Int(process.processID)), "state": .string("started")]), verification: .verified)
        case .workflowStop:
            let key = project.folder + ":" + AgentMemory.key(args.string("workflowName"))
            guard let process = processes.removeValue(forKey: key) else { throw ToolError.unavailable("No LocalFlow-owned workflow is running.") }
            await process.stop()
            return ToolExecution(message: "Stopped owned workflow", verification: .verified)
        case .serviceStatus, .serviceWait:
            let url = URL(string: project.serviceURL!)!
            let timeout = id == .serviceWait ? args.values["timeout"]?.integer ?? 30 : 1
            let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil; config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: NoServiceRedirects(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            repeat {
                try Task.checkCancellation()
                var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.timeoutInterval = 1
                if let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse, (200...399).contains(http.statusCode) {
                    try Task.checkCancellation()
                    return ToolExecution(message: "Local service ready", output: .semantic(["url": .string(url.absoluteString), "state": .string("ready")]), verification: .verified)
                }
                try Task.checkCancellation()
                if id == .serviceStatus { break }
                try await Task.sleep(for: .milliseconds(200))
            } while ContinuousClock.now < deadline
            throw ToolError.unavailable("Local service is not ready.")
        default: throw ToolError.invalidArguments
        }
    }
    private static func editorURL(_ name: String) -> URL? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) { return url }
        let matches = LaunchServicesApplicationCatalog().installedApplications().filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        return matches.count == 1 ? matches[0].url : nil
    }
    nonisolated private static func search(project: ProjectRecord, query: String) throws -> [PlannerValue] {
        let root = URL(fileURLWithPath: project.folder).standardizedFileURL.resolvingSymlinksInPath()
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { throw ToolError.unavailable("Cannot search project.") }
        var results: [PlannerValue] = []; var visited = 0; var readBytes = 0
        for case let file as URL in iterator {
            try Task.checkCancellation(); visited += 1
            if visited > 5000 || results.count >= 20 || readBytes > 8_000_000 { break }
            if ["node_modules", "build", "dist", "vendor"].contains(file.lastPathComponent) { iterator.skipDescendants(); continue }
            guard ProjectRecord.contains(file.path, in: root.path), let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), info.isSymbolicLink != true, info.isRegularFile == true else { continue }
            let resolvedFile = file.standardizedFileURL.resolvingSymlinksInPath()
            let relative = String(resolvedFile.path.dropFirst(root.path.count + (root.path.hasSuffix("/") ? 0 : 1)))
            if relative.localizedCaseInsensitiveContains(query) { results.append(.object(["path": .string(relative), "line": .integer(1)])); continue }
            guard let size = info.fileSize, size <= 256_000 else { continue }
            readBytes += size
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let match = text.components(separatedBy: .newlines).enumerated().first(where: { $0.element.localizedCaseInsensitiveContains(query) }) {
                results.append(.object(["path": .string(relative), "line": .integer(match.offset + 1)]))
            }
        }
        return results
    }
}
/// A loopback readiness check cannot follow a redirect to an external host.
private final class NoServiceRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
