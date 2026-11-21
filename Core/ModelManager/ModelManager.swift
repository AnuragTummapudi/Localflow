import CryptoKit
import Foundation
import Combine
import Shared
import Engines

/// A policy object that decides whether LocalFlow may make a network request.
public struct NetworkPolicy: Sendable {
    private let settings: LocalFlowSettings
    private let modelsAvailable: @Sendable () -> Bool

    /// Creates a network policy.
    public init(settings: LocalFlowSettings = .shared, modelsAvailable: @escaping @Sendable () -> Bool) {
        self.settings = settings
        self.modelsAvailable = modelsAvailable
    }

    /// Returns true when model or update network access is currently allowed.
    public func allowsNetworkAccess() -> Bool {
        !(settings.hardBlockNetworkAfterModelsDownloaded && modelsAvailable())
    }
}

/// Progress for a model download or verification step.
public struct ModelDownloadProgress: Codable, Equatable, Sendable {
    /// Bytes downloaded so far.
    public var completedBytes: Int64

    /// Total expected bytes, if known.
    public var totalBytes: Int64?

    /// A human-readable stage label.
    public var stage: String

    /// Creates progress metadata.
    public init(completedBytes: Int64 = 0, totalBytes: Int64? = nil, stage: String) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.stage = stage
    }

    /// Fraction complete, when the total byte count is known.
    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

/// Detects hardware, downloads and verifies models, and creates STT engines.
public final class ModelManager: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    /// The shared production model manager.
    public static let shared = ModelManager()

    /// The current download progress, if a download is active.
    @Published public private(set) var progress: ModelDownloadProgress?

    /// The currently selected engine descriptor.
    @Published public private(set) var selectedEngine = STTEngineDescriptor(kind: .automatic, modelTier: .automatic, detail: "Not loaded")

    private let settings: LocalFlowSettings
    private let networkCounter: NetworkActivityCounter
    private let supportDirectory: URL
    private var activeContinuation: CheckedContinuation<URL, Error>?
    /// Bytes from files finished earlier in a multi-file download, so per-file progress reads as overall progress.
    private var downloadBaseBytes: Int64 = 0
    private var downloadTotalBytes: Int64?
    /// Written last; a model folder without it is an interrupted download.
    static let completeMarker = ".localflow-complete"
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    /// Creates a model manager.
    public init(
        settings: LocalFlowSettings = .shared,
        networkCounter: NetworkActivityCounter = .shared,
        supportDirectory: URL? = nil
    ) {
        self.settings = settings
        self.networkCounter = networkCounter
        self.supportDirectory = supportDirectory ?? Self.defaultSupportDirectory()
        super.init()
    }

    /// Returns true when this Mac is Apple Silicon.
    public var isAppleSilicon: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// Returns true when a downloaded local Parakeet/Whisper model is present.
    public func modelsAvailable() -> Bool {
        localModelExists(for: resolvedModelTier())
    }

    /// Returns true when a specific local model folder exists on disk with usable assets.
    public func localModelExists(for tier: ModelTier) -> Bool {
        let effective: ModelTier
        switch tier {
        case .automatic:
            effective = isAppleSilicon ? .parakeetTDT : .whisperLargeV3Turbo
        default:
            effective = tier
        }
        let directory = modelDirectory(for: effective)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        switch effective {
        case .parakeetTDT:
            // FluidAudio owns the on-disk layout; empty folders from failed scrapes don't count.
            return ParakeetModelDownloader.modelsExist(at: directory)
        case .whisperLargeV3Turbo:
            // Partial downloads leave files behind, so only a verified, completed download counts.
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.completeMarker).path)
        case .automatic:
            return false
        }
    }

    /// Prepares the selected model and returns an engine hidden behind `STTEngine`.
    ///
    /// Honors the selected processing mode. Apple Speech may use an on-disk local fallback;
    /// cloud requests never switch providers or fall back automatically.
    public func prepareEngine() async throws -> any STTEngine {
        if settings.dictationSource == .cloud {
            let provider = settings.transcriptionProvider
            guard CloudProvider.transcriptionProviders.contains(provider) else {
                throw LocalFlowError.modelUnavailable("Choose Groq, OpenAI, or Gemini for cloud dictation.")
            }
            guard !settings.hardBlockNetworkAfterModelsDownloaded else { throw LocalFlowError.networkBlocked }
            guard try ProviderKeyStore().read(provider) != nil else {
                throw LocalFlowError.modelUnavailable("Add your \(provider.displayName) API key in Settings → General.")
            }
            selectedEngine = STTEngineDescriptor(kind: .cloud, modelTier: .automatic, detail: provider.displayName)
            return CloudSTTEngine(provider: provider, settings: settings)
        }
        if settings.dictationSource == .local {
            return try await prepareLocalEngine(tier: resolvedModelTier(), allowDownload: true)
        }

        if appleSpeechEngineIsAvailable() {
            try await ensureAppleSpeechModelInstalled()
            selectedEngine = STTEngineDescriptor(
                kind: .appleSpeech,
                modelTier: .automatic,
                detail: "Apple on-device SpeechAnalyzer (macOS)"
            )

            let fallbackTier: [ModelTier] = isAppleSilicon
                ? [.parakeetTDT, .whisperLargeV3Turbo]
                : [.whisperLargeV3Turbo]
            for tier in fallbackTier where localModelExists(for: tier) {
                let local = try await prepareLocalEngine(tier: tier, allowDownload: false)
                selectedEngine = STTEngineDescriptor(
                    kind: .appleSpeech,
                    modelTier: .automatic,
                    detail: "Apple Speech + local fallback"
                )
                return CascadingSTTEngine(primary: AppleSpeechEngine(), fallback: local)
            }

            return AppleSpeechEngine()
        }

        return try await prepareLocalEngine(tier: resolvedModelTier(), allowDownload: true)
    }

    /// Loads (and optionally downloads) a Parakeet or Whisper engine.
    public func prepareLocalEngine(tier: ModelTier, allowDownload: Bool) async throws -> any STTEngine {
        let effective: ModelTier
        switch tier {
        case .automatic:
            effective = isAppleSilicon ? .parakeetTDT : .whisperLargeV3Turbo
        default:
            effective = tier
        }

        let directory = modelDirectory(for: effective)
        if !localModelExists(for: effective) {
            guard allowDownload else {
                throw LocalFlowError.modelUnavailable("\(effective.displayName) is not downloaded yet.")
            }
            try await downloadModel(effective)
        }

        switch effective {
        case .parakeetTDT:
            selectedEngine = STTEngineDescriptor(kind: .parakeet, modelTier: effective, detail: "Parakeet TDT on Apple Silicon")
            return ParakeetEngine(modelDirectory: directory)
        case .whisperLargeV3Turbo:
            selectedEngine = STTEngineDescriptor(kind: .whisper, modelTier: effective, detail: "Whisper Large v3 Turbo fallback")
            return WhisperEngine(modelDirectory: directory, modelName: "openai_whisper-large-v3_turbo")
        case .automatic:
            throw LocalFlowError.modelUnavailable("Automatic model selection did not resolve.")
        }
    }

    /// Downloads a local model tier.
    ///
    /// Parakeet uses FluidAudio's official downloader — Hugging Face lists `.mlmodelc`
    /// bundles as directories, so a flat `type==file` scrape finds zero files.
    public func downloadModel(_ tier: ModelTier) async throws {
        let policy = NetworkPolicy(settings: settings, modelsAvailable: { [weak self] in
            self?.modelsAvailable() ?? false
        })
        guard policy.allowsNetworkAccess() else {
            throw LocalFlowError.networkBlocked
        }

        let effective: ModelTier = (tier == .automatic)
            ? (isAppleSilicon ? .parakeetTDT : .whisperLargeV3Turbo)
            : tier

        switch effective {
        case .parakeetTDT:
            try await downloadParakeetViaFluidAudio()
        case .whisperLargeV3Turbo:
            try await downloadWhisperViaTreeAPI()
        case .automatic:
            throw LocalFlowError.modelUnavailable("Automatic model selection did not resolve.")
        }
    }

    private func downloadParakeetViaFluidAudio() async throws {
        progress = ModelDownloadProgress(stage: "Downloading Parakeet via FluidAudio")
        networkCounter.recordRequest()
        let directory = modelDirectory(for: .parakeetTDT)
        try FileManager.default.createDirectory(
            at: directory.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try await ParakeetModelDownloader.download(to: directory) { fraction in
            DispatchQueue.main.async {
                self.progress = ModelDownloadProgress(
                    completedBytes: Int64((fraction * 1000).rounded()),
                    totalBytes: 1000,
                    stage: "Downloading Parakeet"
                )
            }
        }
        progress = ModelDownloadProgress(completedBytes: 1, totalBytes: 1, stage: "Ready")
    }

    private func downloadWhisperViaTreeAPI() async throws {
        let spec = whisperRepositorySpec()
        progress = ModelDownloadProgress(stage: "Reading Whisper model manifest")
        let files = try await fetchRepositoryFiles(spec)
        guard !files.isEmpty else {
            throw LocalFlowError.modelUnavailable("No model files were found for \(spec.repoID).")
        }

        let totalBytes = files.reduce(Int64(0)) { partial, file in
            partial + (file.byteCount ?? 0)
        }
        var completedBytes: Int64 = 0

        let marker = modelDirectory(for: .whisperLargeV3Turbo).appendingPathComponent(Self.completeMarker)
        try? FileManager.default.removeItem(at: marker)
        try FileManager.default.createDirectory(at: spec.destinationRoot, withIntermediateDirectories: true)
        try ensureFreeSpace(for: files, under: spec.destinationRoot)
        downloadTotalBytes = totalBytes > 0 ? totalBytes : nil
        defer { downloadBaseBytes = 0; downloadTotalBytes = nil }
        for file in files {
            let destination = try safeDestination(for: file.path, under: spec.destinationRoot)
            if try existingVerifiedFile(at: destination, expectedSHA256: file.sha256) {
                completedBytes += file.byteCount ?? 0
                progress = ModelDownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes > 0 ? totalBytes : nil, stage: "Verifying model")
                continue
            }

            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Task.checkCancellation()
            downloadBaseBytes = completedBytes
            networkCounter.recordRequest()
            let temporaryURL = try await download(from: resolveURL(repoID: spec.repoID, revision: spec.revision, path: file.path))
            try verifySHA256(fileURL: temporaryURL, expected: file.sha256)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: destination)
            completedBytes += file.byteCount ?? 0
            progress = ModelDownloadProgress(completedBytes: completedBytes, totalBytes: totalBytes > 0 ? totalBytes : nil, stage: "Downloading model")
        }
        try Data().write(to: marker)

        progress = ModelDownloadProgress(completedBytes: max(completedBytes, 1), totalBytes: max(totalBytes, 1), stage: "Ready")
    }

    /// Returns the model tier after applying hardware and user override rules.
    public func resolvedModelTier() -> ModelTier {
        if let override = settings.modelOverride, override != .automatic {
            if override == .parakeetTDT && !isAppleSilicon {
                return .whisperLargeV3Turbo
            }
            return override
        }
        return isAppleSilicon ? .parakeetTDT : .whisperLargeV3Turbo
    }

    /// Returns the local model directory for a tier.
    public func modelDirectory(for tier: ModelTier) -> URL {
        let root = supportDirectory.appendingPathComponent("Models", isDirectory: true)
        switch tier {
        case .automatic:
            return modelDirectory(for: resolvedModelTier())
        case .parakeetTDT:
            // Must match FluidAudio `Repo.parakeetV3.folderName` (`parakeet-tdt-0.6b-v3`).
            return root.appendingPathComponent("parakeet-tdt-0.6b-v3", isDirectory: true)
        case .whisperLargeV3Turbo:
            return root.appendingPathComponent("openai_whisper-large-v3_turbo", isDirectory: true)
        }
    }

    /// Receives download progress from URLSession.
    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        DispatchQueue.main.async {
            self.progress = ModelDownloadProgress(
                completedBytes: self.downloadBaseBytes + totalBytesWritten,
                totalBytes: self.downloadTotalBytes ?? (totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil),
                stage: "Downloading model"
            )
        }
    }

    /// Receives the finished temporary download file.
    ///
    /// Copies out of URLSession's ephemeral download location before returning —
    /// that file is deleted as soon as this delegate method returns.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("LocalFlow-download-\(UUID().uuidString)", isDirectory: false)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: location, to: destination)
            activeContinuation?.resume(returning: destination)
        } catch {
            activeContinuation?.resume(throwing: error)
        }
        activeContinuation = nil
    }

    /// Receives terminal URLSession completion state.
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let continuation = activeContinuation {
            continuation.resume(throwing: error)
            activeContinuation = nil
        }
    }

    private func download(from url: URL) async throws -> URL {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                activeContinuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Rejects manifest paths that would write outside the model folder.
    private func safeDestination(for path: String, under root: URL) throws -> URL {
        let destination = root.appendingPathComponent(path, isDirectory: false).standardizedFileURL
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              destination.path.hasPrefix(root.standardizedFileURL.path + "/") else {
            throw LocalFlowError.modelUnavailable("The model manifest contained an unsafe file path.")
        }
        return destination
    }

    private func ensureFreeSpace(for files: [ModelFileSpec], under root: URL) throws {
        let needed = files.reduce(Int64(0)) { total, file in
            let path = root.appendingPathComponent(file.path).path
            let existing = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
            return total + max(0, (file.byteCount ?? 0) - existing)
        }
        let available = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? .max
        // Headroom for the temporary copy URLSession makes before each move.
        guard available > needed + 512 * 1_048_576 else {
            let gb = Double(needed) / 1_000_000_000
            throw LocalFlowError.modelUnavailable(String(format: "Free up at least %.1f GB of disk space, then try again.", gb + 0.5))
        }
    }

    /// Streams the file through SHA-256 so multi-GB weights never load into memory at once.
    private func verifySHA256(fileURL: URL, expected: String?) throws {
        guard let expected, !expected.isEmpty else { return }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty { hasher.update(data: chunk) }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.lowercased() == expected.lowercased() else {
            throw LocalFlowError.modelUnavailable("Checksum mismatch for downloaded model.")
        }
    }

    private func existingVerifiedFile(at url: URL, expectedSHA256: String?) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try verifySHA256(fileURL: url, expected: expectedSHA256)
        return true
    }

    private func fetchRepositoryFiles(_ spec: ModelRepositorySpec) async throws -> [ModelFileSpec] {
        let url = treeURL(repoID: spec.repoID, revision: spec.revision, subdirectory: spec.subdirectory)
        networkCounter.recordRequest()
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw LocalFlowError.modelUnavailable("Could not read Hugging Face model manifest for \(spec.repoID).")
        }
        let items = try JSONDecoder().decode([HuggingFaceTreeItem].self, from: data)
        return items.compactMap { item in
            guard item.type == "file" else { return nil }
            return ModelFileSpec(
                path: item.path,
                byteCount: item.lfs?.size ?? item.size,
                sha256: item.lfs?.sha256
            )
        }
    }

    private func treeURL(repoID: String, revision: String, subdirectory: String?) -> URL {
        var path = "https://huggingface.co/api/models/\(repoID)/tree/\(revision)"
        if let subdirectory, !subdirectory.isEmpty {
            path += "/\(subdirectory)"
        }
        path += "?recursive=1&expand=1"
        return URL(string: path)!
    }

    private func resolveURL(repoID: String, revision: String, path: String) -> URL {
        let escapedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return URL(string: "https://huggingface.co/\(repoID)/resolve/\(revision)/\(escapedPath)")!
    }

    /// Whisper is downloaded here, pinned to a commit with per-file SHA-256 checks.
    /// Parakeet is downloaded by FluidAudio (`AsrModels.download`), which always fetches the repo's `main`;
    /// pinning it needs an upstream FluidAudio change (see BACKEND_REVIEW.md, N7).
    private func whisperRepositorySpec() -> ModelRepositorySpec {
        // Pinned so the manifest and its checksums are reproducible; bump deliberately.
        ModelRepositorySpec(
            repoID: "argmaxinc/whisperkit-coreml",
            revision: "0f63a7800b00dd0226abd051b906c246e1907482",
            subdirectory: "openai_whisper-large-v3_turbo",
            destinationRoot: supportDirectory.appendingPathComponent("Models", isDirectory: true)
        )
    }

    private static func defaultSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("LocalFlow", isDirectory: true)
    }
}

private struct ModelRepositorySpec: Sendable {
    var repoID: String
    var revision: String
    var subdirectory: String?
    var destinationRoot: URL
}

private struct ModelFileSpec: Sendable {
    var path: String
    var byteCount: Int64?
    var sha256: String?
}

private struct HuggingFaceTreeItem: Decodable {
    var type: String
    var path: String
    var size: Int64?
    var lfs: HuggingFaceLFSMetadata?
}

private struct HuggingFaceLFSMetadata: Decodable {
    var sha256: String?
    var size: Int64?
}
