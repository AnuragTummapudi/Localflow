import Foundation
import Shared
import ModelManager
import PrivacyDashboard

/// View model for LocalFlow settings.
public final class SettingsViewModel: ObservableObject {
    /// The shared settings store.
    public let settings: LocalFlowSettings

    /// The local history store.
    public let historyStore: DictationHistoryStore

    /// The local vocabulary store.
    public let vocabularyStore: VocabularyStore

    /// The privacy dashboard model.
    public let privacyModel = PrivacyDashboardModel()

    /// The currently active engine display name (e.g. "Apple Speech", "Parakeet").
    @Published public var activeEngineName: String = "Not loaded"

    /// Creates the settings view model.
    public init(
        settings: LocalFlowSettings = .shared,
        historyStore: DictationHistoryStore = DictationHistoryStore(),
        vocabularyStore: VocabularyStore = VocabularyStore()
    ) {
        self.settings = settings
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
    }
}
