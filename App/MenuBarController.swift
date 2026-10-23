import AppKit
import SwiftUI
import Combine
import Shared
import ModelManager
import PrivacyDashboard

/// Owns LocalFlow's menu bar item and menu actions.
/// Also directly manages the settings and history windows so the actions
/// never depend on the SwiftUI private `showSettingsWindow:` selector
/// (which is greyed-out when no SwiftUI Settings scene responder is installed).
@MainActor
public final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var observer: (any NSObjectProtocol)?
    private var settingsWindowController: NSWindowController?
    private var decisionStatusItem: NSMenuItem?
    private var decisionObservers = Set<AnyCancellable>()

    /// Creates and configures a menu bar item.
    public override init() {
        super.init()
        configure()
    }

    deinit {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Updates the visible activity state.
    public func update(state: LocalFlowActivityState) {
        statusItem.button?.image = Self.image(for: state)
    }

    // MARK: - NSMenuDelegate

    public func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    // MARK: - Private

    private func configure() {
        statusItem.button?.image = Self.image(for: .idle)
        statusItem.button?.toolTip = "LocalFlow"
        observer = NotificationCenter.default.addObserver(
            forName: .localFlowActivityStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let state = notification.object as? LocalFlowActivityState else { return }
            Task { @MainActor in
                self?.update(state: state)
                let tip: String
                switch state {
                case .idle: tip = "LocalFlow — Hold Right Option to dictate"
                case .listening: tip = "Listening…"
                case .processing: tip = "Transcribing…"
                case .error:
                    tip = AppServices.shared.coordinator.lastErrorMessage
                        ?? "LocalFlow hit an error — try again"
                }
                self?.statusItem.button?.toolTip = tip
                if let menu = self?.statusItem.menu {
                    self?.rebuildMenu(menu)
                }
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        rebuildMenu(menu)
        statusItem.menu = menu
        let manager = DecisionModelManager.shared
        manager.$status.combineLatest(manager.$progress).sink { [weak self] status, progress in
            self?.decisionStatusItem?.title = progress.map { update in
                let fraction = update.fractionCompleted.map { " \(Int($0 * 100))%" } ?? ""
                return update.stage + fraction
            } ?? status.description
        }.store(in: &decisionObservers)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let coordinator = AppServices.shared.coordinator
        let currentState = coordinator.state

        if currentState == .listening || currentState == .processing {
            let statusTitle = currentState == .listening ? "● Listening…" : "◌ Transcribing…"
            let statusItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
            statusItem.isEnabled = false
            menu.addItem(statusItem)

            let stopItem = NSMenuItem(title: coordinator.isVoiceAgentSession ? "Finish Voice Agent" : "Stop & Transcribe", action: #selector(stopDictationAction), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)

            let cancelItem = NSMenuItem(title: coordinator.isVoiceAgentSession ? "Cancel Voice Agent" : "Cancel Dictation", action: #selector(cancelDictationAction), keyEquivalent: "")
            cancelItem.target = self
            menu.addItem(cancelItem)

            menu.addItem(.separator())
        }

        if currentState == .idle {
            let agent = NSMenuItem(title: "Start Voice Agent", action: #selector(startVoiceAgentAction), keyEquivalent: " ")
            agent.keyEquivalentModifierMask = [.command, .shift]
            agent.target = self
            menu.addItem(agent)
            menu.addItem(.separator())
        }

        // ── Settings ──────────────────────────────────────────────────
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self   // MUST be explicit — MenuBarController is not in the responder chain
        menu.addItem(settingsItem)

        // ── History (opens Settings at Dictation pane) ────────────────
        let historyItem = NSMenuItem(title: "History…", action: #selector(showHistory), keyEquivalent: "h")
        historyItem.target = self
        menu.addItem(historyItem)

        let decisionMenu = NSMenu(title: "Local decisions")
        let decisionStatus = NSMenuItem(title: DecisionModelManager.shared.progress?.stage ?? DecisionModelManager.shared.status.description, action: nil, keyEquivalent: "")
        decisionStatus.isEnabled = false
        decisionStatusItem = decisionStatus
        decisionMenu.addItem(decisionStatus)
        let install = NSMenuItem(title: "Install LocalFlow-Laya-v2…", action: #selector(installDecisionModel), keyEquivalent: "")
        install.target = self
        decisionMenu.addItem(install)
        let remove = NSMenuItem(title: "Remove Laya Model", action: #selector(removeDecisionModel), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = FileManager.default.fileExists(atPath: DecisionModelManager.shared.directory.path)
        decisionMenu.addItem(remove)
        let decisionItem = NSMenuItem(title: "Local Decisions", action: nil, keyEquivalent: "")
        decisionItem.submenu = decisionMenu
        menu.addItem(decisionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit LocalFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func installDecisionModel() {
        let picker = NSOpenPanel()
        picker.title = "Install LocalFlow-Laya-v2"
        picker.message = "Choose a trained and parity-validated LocalFlow-Laya-v2 native package. Calibration and human-review evidence control decision authority."
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        Task { @MainActor in
            do { try await DecisionModelManager.shared.install(from: directory) }
            catch { showDecisionModelError() }
        }
    }

    @objc private func removeDecisionModel() {
        Task { @MainActor in
            do { try await DecisionModelManager.shared.remove() }
            catch { showDecisionModelError() }
        }
    }

    private func showDecisionModelError() {
        let alert = NSAlert()
        alert.messageText = "Local Laya model unavailable"
        alert.informativeText = "Check the prepared package and try again. Deterministic voice commands remain available."
        alert.runModal()
    }

    @objc private func startVoiceAgentAction() {
        Task { @MainActor in await AppServices.shared.coordinator.beginVoiceAgent() }
    }

    @objc private func stopDictationAction() {
        Task { @MainActor in
            await AppServices.shared.coordinator.endDictation()
        }
    }

    @objc private func cancelDictationAction() {
        Task { @MainActor in
            AppServices.shared.coordinator.teardownSession(errorMessage: nil, clearErrorMessage: true)
        }
    }

    @objc private func showSettings() {
        openSettingsWindow()
    }

    @objc private func showHistory() {
        openSettingsWindow()
    }

    /// Creates (or recreates) the settings NSWindow with a SwiftUI hosting controller.
    public func openSettingsWindow() {
        // Always rebuild the hosting controller so layout/content stays current
        // (a stale blank NavigationSplitView window was getting reused).
        if let existing = settingsWindowController {
            existing.close()
            settingsWindowController = nil
        }

        let coordinator = AppServices.shared.coordinator
        let viewModel   = AppServices.shared.settingsViewModel

        let rootView = SettingsRootView(viewModel: viewModel)
            .environmentObject(coordinator)

        let hosting = NSHostingController(rootView: rootView)
        hosting.view.frame = NSRect(origin: .zero, size: LocalFlowDesign.settingsSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: LocalFlowDesign.settingsSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing:   .buffered,
            defer:     false
        )
        window.title = "LocalFlow — Settings"
        window.appearance = NSAppearance(named: .aqua)
        window.contentMinSize = LocalFlowDesign.settingsSize
        window.styleMask.insert(.resizable)
        window.contentViewController = hosting
        window.center()
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Menu bar icon drawing

    private static func image(for state: LocalFlowActivityState) -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18))
        image.lockFocus()
        let color: NSColor = switch state {
        case .idle:       NSColor.labelColor
        case .listening:  LocalFlowDesign.nsMarker
        case .processing: LocalFlowDesign.nsSignal
        case .error:      NSColor.systemRed
        }
        color.setFill()
        LocalFlowDesign.resolvedWaveformPath(in: NSRect(x: 1, y: 4, width: 20, height: 10)).fill()
        image.unlockFocus()
        image.isTemplate = state == .idle
        return image
    }
}
