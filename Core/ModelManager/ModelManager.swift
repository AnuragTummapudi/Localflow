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

/// Apple owns speech assets. LocalFlow stores readiness and locale selection only.
@MainActor public final class ModelManager: ObservableObject {
    public static let shared = ModelManager()
    @Published public private(set) var progress: ModelDownloadProgress?
    @Published public private(set) var speechReadiness = AppleSpeechReadiness(status: .actionRequired,
        localeIdentifier: Locale.current.identifier, detail: "Check Apple Speech assets")
    @Published public private(set) var supportedLocales: [Locale] = []
    public var modelsAvailable: Bool { speechReadiness.status == .ready }
    private let settings: LocalFlowSettings
    private var preparationGeneration = UUID()
    public init(settings: LocalFlowSettings = .shared) { self.settings = settings }
    public func refreshReadiness() async {
        supportedLocales = await AppleSpeechAssets.shared.supportedLocales().sorted { $0.identifier < $1.identifier }
        speechReadiness = await AppleSpeechAssets.shared.readiness(localeIdentifier: settings.speechLocaleIdentifier)
    }
    public func prepareEngine(allowInstallation: Bool = true) async throws -> AppleSpeechEngine {
        let generation = UUID()
        preparationGeneration = generation
        do {
            let locale = try await AppleSpeechAssets.shared.prepare(localeIdentifier: settings.speechLocaleIdentifier,
                allowInstallation: allowInstallation) { [weak self] fraction, stage in
                Task { @MainActor in
                    guard let self, self.preparationGeneration == generation else { return }
                    self.progress = ModelDownloadProgress(completedBytes: Int64((fraction ?? 0) * 10000),
                        totalBytes: fraction == nil ? nil : 10000, stage: stage)
                }
            }
            let engine = AppleSpeechEngine(localeIdentifier: locale.identifier)
            try await engine.prepare()
            await refreshReadiness()
            if preparationGeneration == generation { preparationGeneration = UUID(); progress = nil }
            return engine
        } catch {
            await refreshReadiness()
            if preparationGeneration == generation { preparationGeneration = UUID(); progress = nil }
            throw error
        }
    }
    public func checkForUpdates() { }
}
