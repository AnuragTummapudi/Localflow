import CryptoKit
import Foundation

/// A bundled checksum authorizes only the locally prepared host lifetime guard.
/// It runs inside the workflow group, never as a planner-visible tool.
public enum PlannerWorkflowGuard {
    public static func verifiedExecutable() throws -> URL {
        guard let manifestURL = Bundle.module.url(forResource: "workflow-guard", withExtension: "json"),
              let bytes = try? Data(contentsOf: manifestURL), let manifest = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let expected = manifest["sha256"] as? String, let size = manifest["bytes"] as? Int else {
            throw ToolError.unavailable("Prepare the pinned workflow ownership guard with Scripts/prepare-planner.sh.")
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFlow/Models/qwen-runtime")
        let executable = root.appendingPathComponent("localflow-workflow-guard")
        let values = try executable.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == size,
              FileManager.default.isExecutableFile(atPath: executable.path), let content = try? Data(contentsOf: executable),
              SHA256.hash(data: content).map({ String(format: "%02x", $0) }).joined() == expected else {
            throw ToolError.unavailable("Workflow ownership guard checksum failed.")
        }
        return executable
    }
}
