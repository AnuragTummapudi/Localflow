import Foundation
import Shared

/// Shared long-lived app services used by SwiftUI scenes and AppKit delegates.
@MainActor
public final class AppServices {
    /// The shared service container.
    public static let shared = AppServices()

    /// Single history store shared by dictation and Settings panes.
    public let historyStore: DictationHistoryStore

    /// Single vocabulary store shared by dictation and Settings panes.
    public let vocabularyStore: VocabularyStore

    /// The dictation coordinator for the running app.
    public let coordinator: DictationCoordinator

    /// The settings view model for the running app.
    public let settingsViewModel: SettingsViewModel

    private init() {
        let historyStore = DictationHistoryStore()
        let vocabularyStore = VocabularyStore()
        self.historyStore = historyStore
        self.vocabularyStore = vocabularyStore
        self.coordinator = DictationCoordinator(
            historyStore: historyStore,
            vocabularyStore: vocabularyStore
        )
        self.settingsViewModel = SettingsViewModel(
            historyStore: historyStore,
            vocabularyStore: vocabularyStore
        )
    }
}
