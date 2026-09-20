import SwiftUI
import Combine
import Shared
import AudioCapture
import HotkeyManager
import ModelManager
import TextInjection
import Engines
import CommandMode
import SmartFormatting

/// The native SwiftUI entry point for LocalFlow.
@main
public struct LocalFlowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var coordinator: DictationCoordinator
    @StateObject private var settings: SettingsViewModel
    @State private var engineNameCancellable: AnyCancellable?

    /// Creates the LocalFlow app.
    @MainActor
    public init() {
        _coordinator = StateObject(wrappedValue: AppServices.shared.coordinator)
        _settings = StateObject(wrappedValue: AppServices.shared.settingsViewModel)
    }

    /// The app scene hierarchy.
    public var body: some Scene {
        Settings {
            SettingsRootView(viewModel: settings)
                .environmentObject(coordinator)
                .onReceive(coordinator.$activeEngineName) { name in
                    settings.activeEngineName = name
                }
        }
    }
}
