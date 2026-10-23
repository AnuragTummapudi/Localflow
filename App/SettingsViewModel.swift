import Foundation
import Shared
import ModelManager
import PrivacyDashboard

/// View model for LocalFlow settings.
@MainActor public final class SettingsViewModel: ObservableObject {
    /// The shared settings store.
    public let settings: LocalFlowSettings

    public let agentMemory: AgentMemoryStore

    /// The local history store.
    public let historyStore: DictationHistoryStore

    /// The local vocabulary store.
    public let vocabularyStore: VocabularyStore

    /// The privacy dashboard model.
    public let privacyModel = PrivacyDashboardModel()

    /// The currently active engine display name ("Apple Speech").
    @Published public var activeEngineName: String = "Not loaded"

    /// Creates the settings view model.
    public init(
        settings: LocalFlowSettings = .shared,
        historyStore: DictationHistoryStore = DictationHistoryStore(),
        vocabularyStore: VocabularyStore = VocabularyStore(),
        agentMemory: AgentMemoryStore? = nil
    ) {
        self.agentMemory = agentMemory ?? AgentMemoryStore()
        self.settings = settings
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
    }
}
