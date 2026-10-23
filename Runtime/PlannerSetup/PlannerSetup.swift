import Foundation
import Darwin
import ModelManager
import CommandMode

/// Explicit local developer setup; never called by tests, voice, or app startup.
@main struct PlannerSetup {
    @MainActor static func main() async {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            let importing = args.count == 2 && args[0] == "--install-candidate" && args[1].hasPrefix("/")
            guard importing || args == ["--health"] else {
                throw ToolError.unavailable("Usage: localflow-planner-setup --install-candidate /absolute/verified/candidate | --health")
            }
            let manager = PlannerModelManager()
            if importing { try await manager.install(from: URL(fileURLWithPath: args[1])) }
            await manager.refreshDiskUsage()
            try await manager.prepare(schemas: ToolRegistry().plannerSchemas)
            var evidence: [String: Any] = ["installed": manager.isInstalled, "status": manager.status.rawValue,
                "revision": manager.revision, "modelBytes": manager.diskBytes,
                "experimentalEnabled": manager.experimentalEnabled, "residentDuringHealthProbe": manager.resident]
            if let metrics = manager.runtimeMetrics {
                evidence["runtime"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metrics))
            }
            await manager.unload()
            evidence["residentAfterSetup"] = manager.resident
            let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            FileHandle.standardOutput.write(data + Data([10]))
        } catch {
            FileHandle.standardError.write(Data(("Planner setup failed: " + error.localizedDescription + "\n").utf8)); exit(1)
        }
    }
}
