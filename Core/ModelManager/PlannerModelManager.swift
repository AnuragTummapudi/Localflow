import Combine
import CryptoKit
import Foundation
import CommandMode
import Shared

public struct PlannerAsset: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let bytes: Int64
}
public struct PlannerModelManifest: Codable, Equatable, Sendable {
    public let version: Int
    public let upstream: String
    public let upstreamRevision: String
    public let repository: String
    public let revision: String
    public let files: [PlannerAsset]
}
public enum PlannerModelStatus: String, Sendable { case notInstalled = "Not Installed", downloading = "Downloading", verifying = "Verifying", loading = "Loading", ready = "Ready", error = "Error" }

/// One installed candidate. Explicit download only; verified local setup and resident inference.
@MainActor public final class PlannerModelManager: ObservableObject, PlannerGenerating {
    public static let shared = PlannerModelManager()
    @Published public private(set) var status: PlannerModelStatus = .notInstalled
    @Published public private(set) var progress: ModelDownloadProgress?
    @Published public private(set) var error: String?
    @Published public private(set) var resident = false
    @Published public private(set) var runtimeMetrics: PlannerRuntimeMetrics?
    @Published public private(set) var lastGenerationMetrics: PlannerGenerationMetrics?
    @Published public private(set) var diskBytes: Int64 = 0
    @Published public private(set) var busy = false
    public let directory: URL
    public let runtimeDirectory: URL
    public let runtime: PlannerLocalRuntime
    private let settings: LocalFlowSettings
    private let pinnedManifest: PlannerModelManifest?
    private var generation = UUID()
    private var downloadSession: URLSession?
    /// Voice remains compile-time gated until the measured quality gate passes.
    public static let voiceBenchmarksQualified = false
    public var experimentalEnabled: Bool {
        get { settings.experimentalPlannerEnabled }
        set { settings.experimentalPlannerEnabled = newValue; objectWillChange.send(); if !newValue { Task { await self.unload() } } }
    }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) }
    public var revision: String { pinnedManifest?.revision ?? "Unavailable" }
    public init(directory: URL? = nil, runtimeDirectory: URL? = nil, manifest: PlannerModelManifest? = nil, settings: LocalFlowSettings = .shared) {
        self.settings = settings
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LocalFlow/Models")
        self.directory = directory ?? root.appendingPathComponent("qwen3.5-4b-4bit")
        self.runtimeDirectory = runtimeDirectory ?? root.appendingPathComponent("qwen-runtime")
        self.runtime = PlannerLocalRuntime()
        self.pinnedManifest = manifest ?? Self.bundledManifest()
        if isInstalled { status = .ready }
    }
    public static func bundledManifest() -> PlannerModelManifest? {
        guard let url = Bundle.module.url(forResource: "model-manifest", withExtension: "json", subdirectory: "PlannerRuntime"), let bytes = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlannerModelManifest.self, from: bytes)
    }
    public func download() async throws {
        guard !busy, let manifest = pinnedManifest else { throw ToolError.busy }
        guard !settings.hardBlockNetworkAfterModelsDownloaded else { throw ToolError.unavailable("Model download is blocked by the network setting.") }
        busy = true; let id = UUID(); generation = id; status = .downloading; error = nil
        defer { busy = false; progress = nil; downloadSession = nil; if generation != id { status = isInstalled ? .ready : .notInstalled } }
        let stage = directory.deletingLastPathComponent().appendingPathComponent(".planner-" + UUID().uuidString)
        let total = manifest.files.reduce(Int64(0)) { $0 + $1.bytes }
        do {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            var completed: Int64 = 0
            for asset in manifest.files {
                try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
                let base = completed
                let delegate = PlannerDownloadProgress { [weak self] bytes in
                    Task { @MainActor in
                        guard let self, self.generation == id else { return }
                        self.progress = ModelDownloadProgress(completedBytes: base + bytes, totalBytes: total, stage: "Downloading Qwen3.5-4B")
                    }
                }
                let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCache = nil
                let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil); downloadSession = session
                defer { session.invalidateAndCancel() }
                guard let url = URL(string: "https://huggingface.co/\(manifest.repository)/resolve/\(manifest.revision)/\(asset.name)") else { throw ToolError.invalidArguments }
                let (file, response) = try await session.download(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw ToolError.unavailable("Model download failed.") }
                try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
                try FileManager.default.moveItem(at: file, to: stage.appendingPathComponent(asset.name)); completed += asset.bytes
            }
            status = .verifying
            try await Self.verifyAsync(stage, manifest: manifest)
            try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
            try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
            await runtime.unload(); resident = false
            try publish(stage); status = .ready; diskBytes = total
        } catch {
            try? FileManager.default.removeItem(at: stage)
            if generation == id { status = isInstalled ? .ready : .notInstalled; self.error = error.localizedDescription }
            throw error
        }
    }
    /// Explicit local developer import uses the same trusted pinned manifest as Download.
    public func install(from source: URL) async throws {
        guard !busy, let manifest = pinnedManifest else { throw ToolError.busy }
        busy = true; let id = UUID(); generation = id; status = .verifying; defer { busy = false }
        let stage = directory.deletingLastPathComponent().appendingPathComponent(".planner-import-" + UUID().uuidString)
        do {
            try await Self.verifyAsync(source, manifest: manifest)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let worker = Task.detached {
                for asset in manifest.files { try Task.checkCancellation(); try FileManager.default.copyItem(at: source.appendingPathComponent(asset.name), to: stage.appendingPathComponent(asset.name)) }
                try Self.verify(stage, manifest: manifest)
            }
            try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
            try JSONEncoder().encode(manifest).write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
            await runtime.unload(); resident = false; try publish(stage); status = .ready
            diskBytes = manifest.files.reduce(0) { $0 + $1.bytes }
        } catch { try? FileManager.default.removeItem(at: stage); status = isInstalled ? .ready : .notInstalled; self.error = error.localizedDescription; throw error }
    }
    private func publish(_ stage: URL) throws {
        if isInstalled { _ = try FileManager.default.replaceItemAt(directory, withItemAt: stage) }
        else { try FileManager.default.moveItem(at: stage, to: directory) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    public func prepare(schemas: [PlannerToolSchema] = []) async throws {
        guard !busy, !resident, isInstalled, let manifest = pinnedManifest else { if resident { return }; throw ToolError.unavailable("Download the planner first.") }
        busy = true; let id = UUID(); generation = id; status = .verifying; error = nil
        defer { busy = false; if generation != id { status = isInstalled ? .ready : .notInstalled } }
        do {
            try await Self.verifyAsync(directory, manifest: manifest)
            try await verifyRuntime()
            try Task.checkCancellation(); guard generation == id else { throw CancellationError() }
            status = .loading
            var metrics = try await runtime.load(executable: runtimeDirectory.appendingPathComponent("localflow-qwen"), directory: directory)
            if !schemas.isEmpty {
                let warm = try await runtime.generate(.init(goal: "Prepare registry prefix"), context: .init(memory: AgentMemory()), schemas: schemas.filter { ["project.resolve", "project.search", "file.search"].contains($0.id) }, warmOnly: true)
                metrics.prefixPrepareMS = warm.metrics.planMS
            }
            guard generation == id else { throw CancellationError() }
            runtimeMetrics = metrics; resident = true; status = .ready
        } catch { if generation == id { resident = false; status = .error; self.error = error.localizedDescription }; throw error }
    }
    private func verifyRuntime() async throws {
        guard let url = Bundle.module.url(forResource: "runtime-manifest", withExtension: "json", subdirectory: "PlannerRuntime"),
              let data = try? Data(contentsOf: url), let assets = try? JSONDecoder().decode([PlannerAsset].self, from: data) else { throw ToolError.unavailable("Prepare the pinned native planner runtime with Scripts/prepare-planner.sh.") }
        let root = runtimeDirectory
        try await Task.detached { for asset in assets { try Self.verifyAsset(root: root, asset: asset) } }.value
    }
    public func generate(_ request: PlannerRequest, context: PlannerContext, schemas: [PlannerToolSchema]) async throws -> PlannerGeneration {
        guard resident, !busy else { throw ToolError.unavailable("Planner is not resident. Load it in Settings.") }
        busy = true; let id = generation; defer { busy = false; if generation != id { status = isInstalled ? .ready : .notInstalled } }
        do {
            let result = try await runtime.generate(request, context: context, schemas: schemas)
            guard generation == id else { throw CancellationError() }
            lastGenerationMetrics = result.metrics; return result
        } catch {
            // Conservative health: a failed generation requires explicit deterministic reload.
            await runtime.unload()
            if generation == id { resident = false; status = .error; self.error = error.localizedDescription }
            throw error
        }
    }
    public func cancelGeneration() async { await unload() }
    public func unload() async {
        generation = UUID(); downloadSession?.invalidateAndCancel()
        await runtime.unload(); resident = false; runtimeMetrics = nil
        if !busy { status = isInstalled ? .ready : .notInstalled }
        // Active install/load owns busy until its task drains. Cancellation cannot publish later.
    }
    public func cancel() async { await unload() }
    public func remove() async throws {
        guard !busy else { throw ToolError.busy }
        busy = true; defer { busy = false }; await unload()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        status = .notInstalled; diskBytes = 0; error = nil
    }
    public func refreshDiskUsage() async {
        let root = directory
        diskBytes = await Task.detached {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return Int64(0) }
            return e.compactMap { $0 as? URL }.reduce(Int64(0)) { sum, file in sum + Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }.value
    }
    nonisolated private static func verifyAsync(_ root: URL, manifest: PlannerModelManifest) async throws {
        let worker = Task.detached(priority: .utility) { try verify(root, manifest: manifest) }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    nonisolated public static func verify(_ root: URL, manifest: PlannerModelManifest) throws {
        guard manifest.version == 1, manifest.revision.count == 40, manifest.upstreamRevision.count == 40,
              !manifest.files.isEmpty, manifest.files.count <= 20, Set(manifest.files.map(\.name)).count == manifest.files.count else { throw ToolError.invalidArguments }
        for asset in manifest.files { try verifyAsset(root: root, asset: asset) }
    }
    nonisolated private static func verifyAsset(root: URL, asset: PlannerAsset) throws {
        guard !asset.name.isEmpty, !asset.name.contains("/"), asset.name != ".", asset.name != "..", asset.sha256.count == 64, asset.bytes > 0 else { throw ToolError.invalidArguments }
        let file = root.appendingPathComponent(asset.name)
        let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true, values.fileSize == Int(asset.bytes) else { throw ToolError.unavailable("Planner file validation failed.") }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var hash = SHA256()
        while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == asset.sha256 else { throw ToolError.unavailable("Planner checksum mismatch. Download again.") }
    }
}
private final class PlannerDownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64) -> Void
    init(update: @escaping @Sendable (Int64) -> Void) { self.update = update }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { update(totalBytesWritten) }
}
