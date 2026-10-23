import XCTest
import CryptoKit
@testable import ModelManager
import Shared

@MainActor final class PlannerModelManagerTests: XCTestCase {
    private var root: URL!
    private var settings: LocalFlowSettings!
    private var suite: String!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = UUID().uuidString; settings = LocalFlowSettings(defaults: UserDefaults(suiteName: suite)!)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
    private func fixture() throws -> (URL, PlannerModelManifest) {
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("test-owned model fixture".utf8); try bytes.write(to: source.appendingPathComponent("weights.bin"))
        return (source, PlannerModelManifest(version: 1, upstream: "fixture", upstreamRevision: String(repeating: "a", count: 40), repository: "fixture/model", revision: String(repeating: "b", count: 40), files: [PlannerAsset(name: "weights.bin", sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), bytes: Int64(bytes.count))]))
    }
    func testDefaultOffAbsentNoImplicitDownloadPrepareFails() async {
        let manager = PlannerModelManager(directory: root.appendingPathComponent("missing"), settings: settings)
        XCTAssertFalse(manager.experimentalEnabled); XCTAssertFalse(manager.isInstalled); XCTAssertFalse(manager.resident)
        do { try await manager.prepare(); XCTFail("Loaded missing model") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.directory.path))
    }
    func testExplicitInstallVerifyDiskUsageUnloadRemoveAndReinstall() async throws {
        let (source, manifest) = try fixture()
        let manager = PlannerModelManager(directory: root.appendingPathComponent("install"), runtimeDirectory: root.appendingPathComponent("runtime"), manifest: manifest, settings: settings)
        try await manager.install(from: source)
        XCTAssertTrue(manager.isInstalled); XCTAssertEqual(manager.revision, manifest.revision)
        await manager.refreshDiskUsage(); XCTAssertGreaterThan(manager.diskBytes, 0)
        await manager.unload(); XCTAssertFalse(manager.resident)
        try await manager.remove(); XCTAssertFalse(manager.isInstalled)
        try await manager.remove(); try await manager.install(from: source); XCTAssertTrue(manager.isInstalled)
    }
    func testChecksumFailurePreservesExistingInstallation() async throws {
        let (source, manifest) = try fixture()
        let manager = PlannerModelManager(directory: root.appendingPathComponent("install"), manifest: manifest, settings: settings)
        try await manager.install(from: source)
        let before = try Data(contentsOf: manager.directory.appendingPathComponent("weights.bin"))
        try Data(repeating: 0, count: before.count).write(to: source.appendingPathComponent("weights.bin"))
        do { try await manager.install(from: source); XCTFail("Bad hash installed") } catch {}
        XCTAssertEqual(try Data(contentsOf: manager.directory.appendingPathComponent("weights.bin")), before)
    }
    func testVerifierRejectsTraversalSymlinkAndBadVersion() throws {
        let (source, manifest) = try fixture()
        let asset = manifest.files[0]
        let bad = PlannerModelManifest(version: 1, upstream: manifest.upstream, upstreamRevision: manifest.upstreamRevision, repository: manifest.repository, revision: manifest.revision,
            files: [.init(name: "../source/weights.bin", sha256: asset.sha256, bytes: asset.bytes)])
        XCTAssertThrowsError(try PlannerModelManager.verify(source, manifest: bad))
        let target = source.appendingPathComponent("weights.bin")
        let original = source.appendingPathComponent("original.bin"); try FileManager.default.moveItem(at: target, to: original)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: original)
        XCTAssertThrowsError(try PlannerModelManager.verify(source, manifest: manifest))
    }
    func testNetworkBlockPreventsExplicitDownloadBeforeAnyRequest() async throws {
        let (_, manifest) = try fixture(); settings.hardBlockNetworkAfterModelsDownloaded = true
        let manager = PlannerModelManager(directory: root.appendingPathComponent("install"), manifest: manifest, settings: settings)
        do { try await manager.download(); XCTFail("Ignored network setting") } catch {}
        XCTAssertFalse(manager.busy); XCTAssertNil(manager.progress)
    }
    func testProjectsRoundTripV1MigrationBoundsAndStaleWrite() throws {
        let store = AgentMemoryStore(directory: root)
        XCTAssertNil(store.memory.projects)
        var memory = store.memory
        memory.projects = [ProjectRecord(name: "LocalFlow", aliases: ["LF"], folder: root.path, workflows: [ApprovedWorkflow(name: "fixture", executable: "/bin/sleep", arguments: ["1"], workingDirectory: root.path, approvedByUser: true)])]
        try store.save(memory)
        XCTAssertEqual(AgentMemoryStore(directory: root).memory, memory)
        var other = memory; other.projects?[0].aliases = ["other"]
        try JSONEncoder().encode(other).write(to: store.fileURL, options: .atomic)
        XCTAssertThrowsError(try store.save(memory))
        store.reload(); XCTAssertEqual(store.memory, other)
        var bad = memory; bad.projects?[0].workflows[0].approvedByUser = false
        XCTAssertThrowsError(try bad.validate())
        bad = memory; bad.projects = Array(repeating: memory.projects![0], count: 101); XCTAssertThrowsError(try bad.validate())
        let text = try store.editableJSON(); XCTAssertFalse(text.contains("transcript")); XCTAssertFalse(text.contains("receipts"))
    }
}
