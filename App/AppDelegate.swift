import AppKit
import SwiftUI
import Shared

/// AppKit delegate used for menu bar integration and app activation policy.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: MenuBarController?
    private var onboardingController: NSWindowController?

    /// Finishes app launch by installing the menu bar item and dock presence.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        statusController = MenuBarController()
        if !LocalFlowSettings.shared.didCompleteOnboarding {
            showOnboardingWindow()
        } else {
            // Cold start after onboarding: load a local engine only when weights already exist.
            Task {
                await AppServices.shared.coordinator.prepareModelsIfAvailable()
                let name = AppServices.shared.coordinator.activeEngineName
                AppServices.shared.settingsViewModel.activeEngineName = name
            }
        }

        NotificationCenter.default.addObserver(
            forName: .localFlowEngineDidChange,
            object: nil,
            queue: .main
        ) { note in
            if let name = note.object as? String {
                Task { @MainActor in
                    AppServices.shared.settingsViewModel.activeEngineName = name
                }
            }
        }
    }

    /// Observes whether macOS is quitting because the last window closed.
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Background dictation apps must stay alive when Settings is closed.
        return false
    }

    /// Re-activates the app and shows Settings / Onboarding when clicked in the Dock or Finder.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !LocalFlowSettings.shared.didCompleteOnboarding {
            showOnboardingWindow()
        } else {
            statusController?.openSettingsWindow()
        }
        return true
    }

    /// Shows the first-run onboarding window.
    public func showOnboardingWindow() {
        if let onboardingController {
            onboardingController.showWindow(nil)
            return
        }
        let view = OnboardingView()
            .environmentObject(AppServices.shared.coordinator)
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = NSRect(origin: .zero, size: LocalFlowDesign.onboardingSize)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: LocalFlowDesign.onboardingSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "LocalFlow"
        window.contentMinSize = LocalFlowDesign.onboardingSize
        window.contentMaxSize = LocalFlowDesign.onboardingSize
        window.center()
        window.contentViewController = hosting
        let controller = NSWindowController(window: window)
        onboardingController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
