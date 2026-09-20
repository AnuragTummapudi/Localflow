import Foundation
import Combine
import ModelManager
import Shared

/// View model for the privacy dashboard settings pane.
public final class PrivacyDashboardModel: ObservableObject, @unchecked Sendable {
    /// The current session network request count.
    @Published public private(set) var networkRequestCount: Int = 0

    /// Whether network access is hard-blocked after models are present.
    @Published public var hardBlockNetwork: Bool {
        didSet {
            settings.hardBlockNetworkAfterModelsDownloaded = hardBlockNetwork
        }
    }

    private let settings: LocalFlowSettings
    private let counter: NetworkActivityCounter
    private var cancellables = Set<AnyCancellable>()

    /// Creates a privacy dashboard model.
    public init(settings: LocalFlowSettings = .shared, counter: NetworkActivityCounter = .shared) {
        self.settings = settings
        self.counter = counter
        self.hardBlockNetwork = settings.hardBlockNetworkAfterModelsDownloaded
        self.networkRequestCount = counter.requestCount
        counter.$requestCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in
                self?.networkRequestCount = count
            }
            .store(in: &cancellables)
    }

    /// Refreshes the visible privacy counters.
    public func refresh() {
        networkRequestCount = counter.requestCount
        hardBlockNetwork = settings.hardBlockNetworkAfterModelsDownloaded
    }

    /// Credits displayed in the About screen.
    public var credits: [String] {
        [
            "Apple SpeechAnalyzer / SpeechTranscriber (on-device, macOS).",
            "FluidAudio / Parakeet: optional local fallback, CC-BY-4.0.",
            "WhisperKit: optional local fallback, MIT.",
            "SpeechAnalyzer live-input patterns informed by open macOS dictation work (ambient-voice, MacinTalk)."
        ]
    }

    /// A compact build identifier shown in About for version tracing.
    /// Format: "v<version> (<build>) · <date> · <tree>" so dual DerivedData apps are obvious.
    public var buildIdentifier: String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let dateString = formatter.string(from: buildDate)
        let path = bundle.bundlePath
        let tree: String
        if path.contains("/.build/DerivedData/") {
            tree = "LocalFlow.build"
        } else if path.contains("/Xcode/DerivedData/") {
            tree = "Xcode.DerivedData (STALE — use LocalFlow.build)"
        } else {
            tree = "other"
        }
        return "v\(version) (\(build)) · \(dateString) · \(tree)"
    }

    /// The compile-time date embedded at build time.
    private var buildDate: Date {
        // __DATE__ is not available in Swift; use the binary's modification date as a proxy.
        let url = Bundle.main.executableURL ?? URL(fileURLWithPath: "")
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? Date()
    }
}
