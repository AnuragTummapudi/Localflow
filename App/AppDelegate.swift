import AppKit
import SwiftUI
import Shared
#if DEBUG
import AVFoundation
import CommandMode
import Engines
import ModelManager
#endif

/// AppKit delegate used for menu bar integration and app activation policy.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: MenuBarController?
    private var onboardingController: NSWindowController?

    public func applicationWillTerminate(_ notification: Notification) {
        AppServices.shared.coordinator.terminateOwnedPlannerProcesses()
    }

    /// Finishes app launch by installing the menu bar item and dock presence.
    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        #if DEBUG
        if let output = ProcessInfo.processInfo.environment["LOCALFLOW_NATIVE_ACCEPTANCE_OUTPUT"] {
            Task { await CoreLockNativeAcceptance.run(output: URL(fileURLWithPath: output)); NSApp.terminate(nil) }
            return
        }
        #endif
        statusController = MenuBarController()
        #if DEBUG
        if let source = ProcessInfo.processInfo.environment["LOCALFLOW_INSTALL_LAYA_V2"],
           let output = ProcessInfo.processInfo.environment["LOCALFLOW_INSTALL_LAYA_REPORT"] {
            Task { @MainActor in
                let manager = DecisionModelManager.shared
                var result: [String: Any] = ["source": source, "destination": manager.directory.path, "policiesEnabled": false]
                do {
                    for _ in 0..<150 where manager.isBusy { try await Task.sleep(for: .milliseconds(200)) }
                    try await manager.install(from: URL(fileURLWithPath: source))
                    for _ in 0..<150 where manager.isBusy { try await Task.sleep(for: .milliseconds(200)) }
                    result["status"] = manager.status.description
                    result["residentBytes"] = manager.metrics?.residentBytes as Any? ?? NSNull()
                    result["coldLoadMilliseconds"] = manager.metrics?.coldLoadMilliseconds as Any? ?? NSNull()
                } catch { result["status"] = "FAILED"; result["reason"] = error.localizedDescription }
                if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: URL(fileURLWithPath: output), options: .atomic)
                }
            }
        }
        #endif
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


#if DEBUG
/// Explicit developer launch only. Fixed test requests, real native effects and receipts.
/// This does not pretend that canned requests came from a microphone.
@MainActor private enum CoreLockNativeAcceptance {
    static func run(output: URL) async {
        let executor = ActionExecutor(registry: ToolRegistry(system: MacNativeToolSystem()))
        let commands = CommandMode()
        var rows: [[String: Any]] = []
        let stamp = ISO8601DateFormatter().string(from: Date())
        let notesAutomation = await NativePermissionReadiness.automationStatus(bundleIdentifier: "com.apple.Notes")
        let spotifyAutomation = await NativePermissionReadiness.automationStatus(bundleIdentifier: "com.spotify.client")
        func save() {
            let value: [String: Any] = ["inputSource": "fixed developer requests, no microphone", "run": stamp,
                "microphone": AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "READY" : "ACTION REQUIRED",
                "accessibility": AXIsProcessTrusted() ? "READY" : "ACTION REQUIRED",
                "automationNotesOSStatus": notesAutomation as Any? ?? NSNull(),
                "automationSpotifyOSStatus": spotifyAutomation as Any? ?? NSNull(),
                "results": rows]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output, options: .atomic) }
        }
        func record(_ label: String, _ action: AgentAction, _ result: ToolResult, milliseconds: Double) -> ToolUndoToken? {
            var row: [String: Any] = ["scenario": label, "tool": action.toolID.rawValue, "arguments": String(describing: action.arguments), "milliseconds": milliseconds]
            var undo: ToolUndoToken?
            switch result {
            case .completed(let message, let out, let verification, let token):
                row["receipt"] = message; row["output"] = String(describing: out); undo = token
                switch verification {
                case .verified: row["status"] = "VERIFIED"
                case .unverified(let reason): row["status"] = "UNVERIFIED"; row["reason"] = reason
                case .failed(let reason): row["status"] = "FAILED"; row["reason"] = reason
                }
            case .requiresConfirmation: row["status"] = "ACTION REQUIRED"; row["reason"] = "Frozen confirmation prepared; native effect not performed."
            case .failed(let reason): row["status"] = "FAILED"; row["reason"] = reason
            case .cancelled: row["status"] = "CANCELLED"
            }
            rows.append(row); save(); return undo
        }
        for text in ["Open Notes", "Open Safari", "Open Chrome", "Open github.com", "Search for Norbert Wiener", "Open nonexistent application", "Open Safari", "Open Chrome, actually Safari"] {
            // Explicit agent segmentation performs correction, using the production parser.
            let source = SpeechCommandSegmenter.segments(text, continuous: true).first?.text ?? text
            let resolution = commands.resolve(source)
            guard case .execute(let intent) = resolution else {
                rows.append(["scenario": text, "status": "UNAVAILABLE", "reason": "No exact executable parser result"]); save(); continue
            }
            let action = intent.agentAction, began = ProcessInfo.processInfo.systemUptime
            let result = await executor.execute(action)
            _ = record(text, action, result, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
        }
        let note = AgentAction(toolID: .createNote, arguments: .note(title: "LocalFlow Ideas", body: "hello from LocalFlow"))
        let noteStart = ProcessInfo.processInfo.systemUptime
        let noteResult = await executor.execute(note)
        let noteUndo = record("Create exact test note", note, noteResult, milliseconds: (ProcessInfo.processInfo.systemUptime - noteStart) * 1000)
        if case .completed(_, _, .verified, _) = noteResult {
            if case .execute(let intent) = commands.resolve("Open Notes") { _ = await executor.execute(intent.agentAction) }
            for action in [AgentAction(toolID: .appendNote, arguments: .currentNote("Exact sentence from LocalFlow.")),
                           AgentAction(toolID: .renameNote, arguments: .currentNote("LocalFlow Ideas"))] {
                let began = ProcessInfo.processInfo.systemUptime
                let result = await executor.execute(action)
                _ = record("Prepare exact note mutation", action, result, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                if case .requiresConfirmation(let challenge) = result {
                    executor.cancelConfirmation()
                    _ = record("Cancel pending note mutation", action, await executor.confirm(challenge), milliseconds: 0)
                }
            }
            if let noteUndo { _ = record("Guarded test-note Undo", note, await executor.undo(noteUndo), milliseconds: 0) }
        }
        // User-requested exact write acceptance, restricted to this new test note.
        // The production registry still prepares and consumes its normal confirmation.
        // This test note is retained after mutation; an original-body Undo cannot delete a changed note.
        let writeStart = ProcessInfo.processInfo.systemUptime
        let writeNoteResult = await executor.execute(note)
        _ = record("Create owned note for exact write acceptance", note, writeNoteResult, milliseconds: (ProcessInfo.processInfo.systemUptime - writeStart) * 1000)
        if case .completed(_, .note(let createdID), .verified, _) = writeNoteResult {
            if case .execute(let intent) = commands.resolve("Open Notes") { _ = await executor.execute(intent.agentAction) }
            for action in [AgentAction(toolID: .renameNote, arguments: .currentNote("LocalFlow Ideas")),
                           AgentAction(toolID: .appendNote, arguments: .currentNote("hello from LocalFlow"))] {
                let began = ProcessInfo.processInfo.systemUptime
                let preview = await executor.execute(action)
                _ = record("Owned-note exact write preview", action, preview, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
                if case .requiresConfirmation(let grant) = preview,
                   case .currentNote(_, let snapshot?) = grant.action.arguments, snapshot.id == createdID {
                    let confirmStart = ProcessInfo.processInfo.systemUptime
                    _ = record("Explicit developer confirmation on owned test note", grant.action, await executor.confirm(grant), milliseconds: (ProcessInfo.processInfo.systemUptime - confirmStart) * 1000)
                } else { executor.cancelConfirmation() }
            }
        }
        let reminder = AgentAction(toolID: .createReminder, arguments: .reminder(title: "Review LocalFlow Ideas"))
        let reminderStart = ProcessInfo.processInfo.systemUptime
        let reminderResult = await executor.execute(reminder)
        let reminderUndo = record("Create exact test reminder", reminder, reminderResult, milliseconds: (ProcessInfo.processInfo.systemUptime - reminderStart) * 1000)
        if let reminderUndo { _ = record("Guarded test-reminder Undo", reminder, await executor.undo(reminderUndo), milliseconds: 0) }
        for action in [AgentAction(toolID: .setVolume, arguments: .volume(40)), AgentAction(toolID: .mute, arguments: .none),
                       AgentAction(toolID: .spotifyTransport, arguments: .spotify(.pause))] {
            let began = ProcessInfo.processInfo.systemUptime
            let result = await executor.execute(action)
            let undo = record("Native reversible command", action, result, milliseconds: (ProcessInfo.processInfo.systemUptime - began) * 1000)
            if let undo { _ = record("Guarded native Undo", action, await executor.undo(undo), milliseconds: 0) }
        }
        let consequential = AgentAction(toolID: .lockMac, arguments: .none)
        let preview = await executor.execute(consequential)
        _ = record("Consequential preview", consequential, preview, milliseconds: 0)
        executor.cancelConfirmation()
        if case .requiresConfirmation(let challenge) = preview {
            _ = record("Cancelled preview cannot execute", consequential, await executor.confirm(challenge), milliseconds: 0)
        }
        save()
    }
}
#endif
