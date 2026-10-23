import Foundation

/// Saved only through an explicit memory edit/approval. No inferred executable or shell text.
public struct ApprovedWorkflow: Codable, Equatable, Sendable {
    public var name: String
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String
    public var approvedByUser: Bool
    public init(name: String, executable: String, arguments: [String] = [], workingDirectory: String, approvedByUser: Bool) {
        self.name = name; self.executable = executable; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.approvedByUser = approvedByUser
    }
    public func validate(root: String) throws {
        let denied = ["sh", "bash", "zsh", "fish", "csh", "tcsh", "sudo", "osascript", "env"]
        guard !AgentMemory.key(name).isEmpty, name.count <= 80, executable.hasPrefix("/"), !executable.contains("\0"),
              !denied.contains(URL(fileURLWithPath: executable).lastPathComponent),
              arguments.count <= 64, arguments.allSatisfy({ $0.utf8.count <= 4096 && !$0.contains("\0") }),
              workingDirectory.hasPrefix("/"), ProjectRecord.contains(workingDirectory, in: root), approvedByUser else {
            throw AgentMemoryError.invalid("Workflows require an explicitly approved executable, arguments and project working directory. Shell interpreters are not supported.")
        }
    }
}

public struct ProjectRecord: Codable, Equatable, Sendable {
    public var name: String
    public var aliases: [String]
    public var folder: String
    public var preferredEditor: String?
    public var websiteURL: String?
    public var serviceURL: String?
    public var workflows: [ApprovedWorkflow]
    public var importantFiles: [String: String]
    public init(name: String, aliases: [String] = [], folder: String, preferredEditor: String? = nil,
                websiteURL: String? = nil, serviceURL: String? = nil, workflows: [ApprovedWorkflow] = [], importantFiles: [String: String] = [:]) {
        self.name = name; self.aliases = aliases; self.folder = folder; self.preferredEditor = preferredEditor
        self.websiteURL = websiteURL; self.serviceURL = serviceURL; self.workflows = workflows; self.importantFiles = importantFiles
    }
    public static func contains(_ path: String, in root: String) -> Bool {
        let base = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return target == base || target.hasPrefix(base + "/")
    }
    public func validate() throws {
        let canonicalFolder = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        let keys = ([name] + aliases).map(AgentMemory.key)
        guard !name.isEmpty, aliases.count <= 20, keys.allSatisfy({ !$0.isEmpty && $0.count <= 160 && !$0.contains("\n") && !$0.contains("\0") }),
              Set(keys).count == keys.count, folder.hasPrefix("/"), folder.count <= 4096, !folder.contains("\0"),
              canonicalFolder != "/", canonicalFolder != NSHomeDirectory(), workflows.count <= 20,
              Set(workflows.map { AgentMemory.key($0.name) }).count == workflows.count,
              importantFiles.count <= 50, importantFiles.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 160 && !$0.value.isEmpty && $0.value.utf8.count <= 4096 && !$0.value.contains("\0") && !$0.value.hasPrefix("/") && Self.contains(folder + "/" + $0.value, in: folder) }),
              preferredEditor.map({ !$0.isEmpty && $0.count <= 256 && !$0.contains("\0") }) ?? true else {
            throw AgentMemoryError.invalid("Invalid project record. Choose an explicit bounded project folder and unique names.")
        }
        if let websiteURL {
            guard websiteURL.utf8.count <= 4096, !websiteURL.contains("\0"), let url = URL(string: websiteURL),
                  ["http", "https"].contains(url.scheme), url.host?.isEmpty == false,
                  url.user == nil, url.password == nil else {
                throw AgentMemoryError.invalid("Project websites require an explicit HTTP(S) URL without credentials.")
            }
        }
        if let serviceURL {
            guard serviceURL.utf8.count <= 4096, !serviceURL.contains("\0"), let url = URL(string: serviceURL), ["http", "https"].contains(url.scheme),
                  ["localhost", "127.0.0.1", "::1"].contains(url.host), url.user == nil, url.password == nil else {
                throw AgentMemoryError.invalid("Project services require a loopback HTTP(S) URL without credentials.")
            }
        }
        for workflow in workflows { try workflow.validate(root: folder) }
    }
}

extension AgentMemory {
    public func project(named name: String) throws -> ProjectRecord {
        let matches = (projects ?? []).filter { ([$0.name] + $0.aliases).map(Self.key).contains(Self.key(name)) }
        guard matches.count == 1, let result = matches.first else {
            throw AgentMemoryError.invalid(matches.isEmpty ? "Project is not saved. Add it in Settings." : "Project alias is ambiguous. Choose its full name.")
        }
        try result.validate()
        return result
    }
}
