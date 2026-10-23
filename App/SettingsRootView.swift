import SwiftUI
import AppKit
import Shared
import PrivacyDashboard
import ModelManager
import Engines
import TextInjection
import SmartFormatting
import CommandMode
import AVFoundation

#if DEBUG
/// Uses the application's actual capture, parser, executor and readback receipts.
/// All payload evidence is transient in this pane and cleared when it is closed.
private struct AgentRealityGatePanel: View {
    @ObservedObject var agent: VoiceAgentCoordinator
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var enabled = false
    @State private var step = 0
    @State private var activeStep: Int?
    @State private var evidence: [Int: VoiceAgentSnapshot] = [:]
    @State private var expected: [Int: [AgentAction]] = [:]
    @State private var error = ""
    @State private var permissionRefresh = 0
    @State private var confirmationTask: Task<Void, Never>?
    private let instructions = [
        "Microphone permission", "Accessibility permission", "Automation permission for Notes and Reminders",
        "Say: Apple Speech transcript check", "Open Notes", "Create a note called LocalFlow Ideas",
        "Append to current note Exact sentence from LocalFlow.", "Open Safari",
        "Search for Norbert Wiener", "Open github.com",
        "Create reminder Review LocalFlow Ideas", "Open Chrome",
        "Open Notes, pause, Open Safari, pause, Open Chrome, pause, Open github.com — ONE continuous session",
        "Open Chrome, actually Safari", "Open Notes then search for cancellation test — cancel pending action",
        "Consequential confirmation preview — consume the grant without locking the Mac",
        "Set volume to 40 percent, then mute — use guarded Undo to restore", "Pause Spotify",
        "Open nonexistent application, then Open Safari", "Stop Voice Agent and restart; then Open Notes",
        "Open Notes; Create a new note; Call it LocalFlow Ideas; Write hello from LocalFlow — pause between commands"
    ]
    var body: some View {
        GroupBox("Developer reality gate · Debug only") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Show transient live evidence", isOn: $enabled)
                Text("Real microphone and native effects. Steps create one test note/reminder and append to that test note. Payloads stay in this pane's memory; closing it clears them. Browser request acceptance remains UNVERIFIED until observable readback proves completion.").font(.caption)
                if enabled {
                    Text("Step \(step + 1) of \(instructions.count): \(instructions[step])").font(.headline).textSelection(.enabled)
                    controls
                    if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let snapshot = evidence[step] { trace(snapshot) }
                    else if enabled { trace(agent.snapshot) }
                    HStack {
                        Button("Previous") { step = max(0, step - 1) }.disabled(step == 0 || coordinator.state != .idle || agent.snapshot.isBusy)
                        Button("Next") { step = min(instructions.count - 1, step + 1) }.disabled(step == instructions.count - 1 || coordinator.state != .idle || agent.snapshot.isBusy)
                        Button("Clear Evidence") { evidence.removeAll(); expected.removeAll(); agent.clearDeveloperTrace(); agent.developerTraceEnabled = enabled }
                    }
                }
            }.padding(6)
        }
        .onChange(of: enabled) { _, value in
            if value { agent.developerTraceEnabled = true }
            else { evidence.removeAll(); expected.removeAll(); activeStep = nil; agent.clearDeveloperTrace(); confirmationTask?.cancel(); coordinator.cancelRealityPreview() }
        }
        .onChange(of: agent.snapshot) { _, value in
            if enabled, let activeStep {
                evidence[activeStep] = value
                if activeStep == 6, let grant = value.confirmation,
                   case .currentNote(_, let captured?) = grant.action.arguments {
                    let created = evidence[5]?.actions.first { $0.action.toolID == .createNote && $0.verification == .verified }
                    if created?.output != .note(captured.id) {
                        error = "FAILED — selected note differs from the verified test note. Append cancelled."
                        agent.cancel()
                    }
                }
            }
        }
        .onDisappear {
            evidence.removeAll(); expected.removeAll(); activeStep = nil
            agent.clearDeveloperTrace(); confirmationTask?.cancel(); confirmationTask = nil; coordinator.cancelRealityPreview()
        }
    }
    @ViewBuilder private var controls: some View {
        switch step {
        case 0:
            Text(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "VERIFIED — microphone permission granted" : "UNVERIFIED — microphone permission not granted").id(permissionRefresh)
            Button("Request Microphone Permission") { Task { _ = await AVCaptureDevice.requestAccess(for: .audio); permissionRefresh += 1 } }
        case 1:
            Text(TextInjection().isAccessibilityTrusted() ? "VERIFIED — Accessibility trust granted" : "UNVERIFIED — Accessibility trust not granted")
            Button("Open Accessibility Settings") { TextInjection().openAccessibilitySettings() }
            Button("Refresh Permission Status") { permissionRefresh += 1 }
        case 2:
            Text("UNVERIFIED until the following real Notes/Reminders actions receive permission and read back their changes. Grant only the Automation prompts you approve.")
            Button("Open Automation Settings") { openPermissionSettings("Privacy_Automation") }
        case 15:
            Text(coordinator.realityConfirmationStatus).textSelection(.enabled)
            HStack {
                Button("Prepare Real Confirmation") { confirmationTask = Task { await coordinator.prepareRealityConfirmation() } }
                    .disabled(coordinator.state != .idle || agent.snapshot.isBusy || coordinator.realityPreviewPreparing)
                Button("Confirm Preview Without Effect") { coordinator.confirmRealityPreview() }.disabled(coordinator.realityConfirmation == nil)
                Button("Cancel Preview") { confirmationTask?.cancel(); coordinator.cancelRealityPreview() }
                    .disabled(coordinator.realityConfirmation == nil && !coordinator.realityPreviewPreparing)
            }
        default:
            if step == 14 { Text("Press Cancel while an action is executing. Cancellation after an effect was sent cannot retract it; inspect the receipt and phase below.").font(.caption) }
            HStack {
                Button("Start Real Spoken Step") {
                    if step == 6, evidence[5]?.actions.contains(where: { $0.action.toolID == .createNote && $0.verification == .verified }) != true {
                        error = "Create and verify the test note in step 6 before appending."
                        return
                    }
                    let selectedStep = step
                    error = ""; activeStep = selectedStep; evidence[selectedStep] = VoiceAgentSnapshot()
                    if step > 3 {
                        let commands = CommandMode().forAgentSession(memory: coordinator.agentMemory.memory)
                        let parts = try? commands.segments(instructions[step])
                        expected[step] = parts?.compactMap { part in
                            if let action = SpeechCommandSegmenter.noteAction(part.text) { return action }
                            switch commands.resolve(part.text) {
                            case .execute(let intent), .needsConfirmation(let intent): return intent.agentAction
                            case .notCommand: return nil
                            }
                        }
                        // Payload gold is explicit, not produced by the parser under test.
                        switch step {
                        case 5: expected[step] = [AgentAction(toolID: .createNote, arguments: .note(title: "LocalFlow Ideas", body: ""))]
                        case 6: expected[step] = [AgentAction(toolID: .appendNote, arguments: .currentNote("Exact sentence from LocalFlow."))]
                        case 9: expected[step] = [AgentAction(toolID: .openURL, arguments: .url(URL(string: "https://github.com")!))]
                        case 10: expected[step] = [AgentAction(toolID: .createReminder, arguments: .reminder(title: "Review LocalFlow Ideas"))]
                        default: break
                        }
                    }
                    Task {
                        await coordinator.beginVoiceAgent()
                        if selectedStep == 6, coordinator.state == .listening {
                            // Settings was clicked to start capture. Restore Notes for
                            // the current-note tool; the island itself remains non-key.
                            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first?.activate(options: [.activateIgnoringOtherApps])
                        }
                    }
                }.disabled(coordinator.state != .idle || agent.snapshot.isBusy || agent.snapshot.confirmation != nil)
                Button("Finish Speech") {
                    Task {
                        if activeStep == 6 { restoreNotesFocus() }
                        await coordinator.endDictation()
                    }
                }.disabled(coordinator.state != .listening)
                Button("Cancel") { coordinator.cancelHandsFreeSession() }.disabled(coordinator.state == .idle && !agent.snapshot.isBusy && agent.snapshot.confirmation == nil)
                if agent.snapshot.confirmation != nil {
                    Button("Confirm Native Action") { Task { if activeStep == 6 { restoreNotesFocus() }; await agent.confirm() } }
                }
            }
            if let message = coordinator.lastErrorMessage { Text("FAILED — " + message).foregroundStyle(.red) }
        }
    }
    private func openPermissionSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
    private func restoreNotesFocus() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Notes").first?.activate(options: [.activateIgnoringOtherApps])
    }
    @ViewBuilder private func trace(_ snapshot: VoiceAgentSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Volatile / original: " + snapshot.streamingTranscript)
            Text("Finalized / original: " + snapshot.finalizedTranscript)
            Text("Chosen interpretation: " + snapshot.transcript)
            ForEach(snapshot.speechInterpretations, id: \.phraseID) { phrase in
                Text("Phrase \(phrase.phraseID): \(phrase.original) → \(phrase.selected) · alternative used: \(phrase.rescued) · alternatives: \(phrase.alternatives.joined(separator: " | "))")
            }
            Text("Final: " + (snapshot.isFinal ? snapshot.transcript : "UNVERIFIED — awaiting final"))
            Text("Speech source: " + (snapshot.speechSource ?? "streaming partial"))
            DisclosureGroup("Live stream diagnostics (in memory only)") {
                Text("Seen \(snapshot.seenWordCount) · stable \(snapshot.stabilizedWordCount) · consumed \(snapshot.consumedWordCursor)")
                ForEach(Array(snapshot.streamTrace.enumerated()), id: \.offset) { _, item in
                    Text("\(item.event) session=\(item.sessionID) revision=\(item.revision)\nTranscript: \(item.transcript)\nPrevious stable: \(item.previousStablePrefix)\nStable: \(item.stablePrefix)\nConsumed: \(item.consumedWordCursor), next: \(item.nextUnconsumedRange)\n\(item.candidates.joined(separator: "; "))\n\(item.ledger.joined(separator: "; "))\n\(item.details)")
                }
            }
            ForEach(Array(snapshot.decisionTrace.enumerated()), id: \.offset) { _, item in
                Text("Segment \(item.segment): \(item.text)\nParsed: \(item.parsed)\nQuestions/results: \(String(describing: item.questions))\nDecision source: \(item.source) · confidence: \(item.confidence.map { String(format: "%.4f", $0) } ?? "not used") · accepted: \(item.accepted.map(String.init) ?? "not used")")
            }
            ForEach(snapshot.actions) { record in
                Text("Tool: \(record.action.toolID.rawValue)\nExact arguments: \(String(describing: record.action.arguments))\nReceipt: \(record.detail)\nOutput: \(record.output.map { String(describing: $0) } ?? "none received")\nPhase: \(record.phase.rawValue) · \(verification(record.verification))")
            }
            if snapshot.isFinal, let slots = expected[step], !slots.isEmpty {
                let result = AgentBenchmarkResult(scenario: step + 1, mode: "developer-real-microphone-native", snapshot: snapshot, expected: slots)
                Text("Exact invocation comparator: incorrect \(result.incorrectActionRate), missing \(result.missingActions), duplicate \(result.duplicateActionRate). Verification is separately reported above.")
            }
            Text("Timings: " + snapshot.timings.map { "\($0.kind.rawValue) \(String(format: "%.1f", $0.milliseconds)) ms" }.joined(separator: " · "))
            Text(snapshot.notice)
        }.font(.system(.caption, design: .monospaced)).textSelection(.enabled)
    }
    private func verification(_ value: ToolVerification?) -> String {
        switch value {
        case .verified: return "VERIFIED"
        case .unverified(let reason): return "UNVERIFIED — " + reason
        case .failed(let reason): return "FAILED — " + reason
        case nil: return "UNVERIFIED — no completion receipt"
        }
    }
}
#endif

// MARK: - Settings Root

/// The complete LocalFlow settings window — sidebar + detail NavigationSplitView layout.
public struct SettingsRootView: View {
    /// The settings view model.
    @ObservedObject public var viewModel: SettingsViewModel
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var selection: SettingsPane = .dictation

    /// Creates the settings root view.
    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    /// The view body.
    public var body: some View {
        // Avoid NavigationSplitView inside a custom NSWindow — it often renders
        // a blank white content area on macOS 26 menu-bar apps.
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection)
                .frame(width: 200)
                .frame(maxHeight: .infinity, alignment: .top)

            Divider()
                .background(LocalFlowDesign.hairline)

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LocalFlowDesign.canvas)
        }
        .frame(minWidth: LocalFlowDesign.settingsSize.width, minHeight: LocalFlowDesign.settingsSize.height)
        .background(LocalFlowDesign.canvas)
        .preferredColorScheme(.light)
        .popover(isPresented: Binding(
            get: { coordinator.pendingCommand != nil },
            set: { if !$0 { coordinator.cancelPendingCommand() } }
        )) {
            if let intent = coordinator.pendingCommand {
                CommandConfirmationView(
                    intent: intent,
                    confirm: coordinator.confirmPendingCommand,
                    cancel: coordinator.cancelPendingCommand
                )
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        switch selection {
        case .dictation:
            DictationPane(
                store: viewModel.historyStore,
                hotkeyName: viewModel.settings.useFnAsAlternateHotkey ? "Fn" : "Right Option"
            )
        case .insights:
            InsightsPane(store: viewModel.historyStore)
        case .dictionary:
            DictionaryPane(store: viewModel.vocabularyStore)
        case .agent:
            AgentSettingsView(store: viewModel.agentMemory)
        case .commandMode:
            CommandModeSettingsView()
        case .smartFormatting:
            FormattingSettingsView(settings: viewModel.settings)
        case .privacyDashboard:
            PrivacySettingsView(model: viewModel.privacyModel, activeEngineName: viewModel.activeEngineName)
        case .general:
            GeneralSettingsView(viewModel: viewModel)
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var selection: SettingsPane

    var body: some View {
        VStack(spacing: 0) {
            // App title / brand mark in sidebar header
            HStack(spacing: 9) {
                LocalFlowDesign.logomark(size: CGSize(width: 22, height: 14), color: LocalFlowDesign.signal)
                Text("LocalFlow")
                    .font(LocalFlowDesign.generalSans(size: 14, weight: .semibold))
                    .foregroundStyle(LocalFlowDesign.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()
                .background(LocalFlowDesign.graphite.opacity(0.18))

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsPane.allCases) { pane in
                        SidebarRow(
                            pane: pane,
                            isSelected: selection == pane
                        ) {
                            selection = pane
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .background(LocalFlowDesign.canvas.opacity(0.9))
    }
}

// MARK: - Sidebar row

private struct SidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SidebarSymbol(name: pane.icon, isSelected: isSelected)

                Text(pane.title)
                    .font(LocalFlowDesign.generalSans(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? LocalFlowDesign.ink : LocalFlowDesign.graphite)

                Spacer()
            }
            .frame(height: 42)
            .padding(.horizontal, 10)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LocalFlowDesign.signal.opacity(0.075))
                } else if isHovering {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LocalFlowDesign.graphite.opacity(0.045))
                }
            }
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(LocalFlowDesign.signal)
                        .frame(width: 3, height: 20)
                        .padding(.leading, 6)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A quiet, consistent symbol container keeps navigation legible without turning the sidebar
/// into a collection of unrelated glyph weights.
private struct SidebarSymbol: View {
    let name: String
    let isSelected: Bool

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? LocalFlowDesign.signal : LocalFlowDesign.graphite.opacity(0.8))
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

// MARK: - Pane enum

private enum SettingsPane: String, CaseIterable, Identifiable {
    // Ordered per spec: Dictation first, General last
    case dictation
    case insights
    case dictionary
    case commandMode
    case agent
    case smartFormatting
    case privacyDashboard
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .insights: "Insights"
        case .dictionary: "Dictionary"
        case .agent: "Agent / Mac Control"
        case .commandMode: "Command Mode"
        case .smartFormatting: "Smart Formatting"
        case .privacyDashboard: "Privacy Dashboard"
        case .general: "General"
        }
    }

    var icon: String {
        switch self {
        case .dictation: "mic.fill"
        case .insights: "chart.xyaxis.line"
        case .dictionary: "character.cursor.ibeam"
        case .agent: "desktopcomputer"
        case .commandMode: "command"
        case .smartFormatting: "text.badge.checkmark"
        case .privacyDashboard: "hand.raised.fill"
        case .general: "slider.horizontal.3"
        }
    }
}

// MARK: - Command Mode stub pane

/// Placeholder pane for Command Mode settings.
private struct CommandModeSettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            LFPaneTitle("Command Mode")
                .padding(.top, 24)

            Text("Say a command phrase while holding the hotkey to trigger system actions — no dictation is inserted.")
                .font(LocalFlowDesign.generalSans(size: 13))
                .foregroundStyle(LocalFlowDesign.graphite)
                .fixedSize(horizontal: false, vertical: true)

            Text("Available commands")
                .font(LocalFlowDesign.instrumentSerif(size: 18))
                .foregroundStyle(LocalFlowDesign.ink)

            let commands: [(phrase: String, action: String)] = [
                ("open [app name]", "Opens the named application"),
                ("quit [app name]", "Quits the named application"),
                ("switch to [app name]", "Brings named app to front"),
                ("mute / unmute", "Toggles system audio mute"),
                ("sleep display", "Puts the display to sleep"),
                ("lock it", "Locks this Mac immediately"),
                ("open [URL]", "Opens the URL in the default browser"),
                ("open [query] in [site]", "Searches query directly on YouTube, Google, GitHub, etc."),
                ("search [query] on [site]", "Searches query on named platform or domain"),
                ("play [song] on Spotify", "Opens Spotify's native results for that song"),
                ("pause / resume Spotify", "Controls the installed Spotify desktop app"),
                ("next / previous Spotify track", "Moves through Spotify's current queue")
            ]

            VStack(spacing: 0) {
                ForEach(commands, id: \.phrase) { cmd in
                    HStack(spacing: 0) {
                        Text(cmd.phrase)
                            .font(LocalFlowDesign.fragmentMono(size: 12))
                            .foregroundStyle(LocalFlowDesign.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(cmd.action)
                            .font(LocalFlowDesign.generalSans(size: 12))
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)

                    Divider()
                        .background(LocalFlowDesign.hairline)
                }
            }
            .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

            Spacer()
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LocalFlowDesign.canvas)
    }
}

// MARK: - General settings pane

/// General settings for hotkeys, models, and login behavior.
public struct GeneralSettingsView: View {
    /// The settings view model.
    @ObservedObject public var viewModel: SettingsViewModel
    /// Observed separately because the view model intentionally owns the settings service.
    /// Without this, a UserDefaults write changes the hotkey but leaves the selection card stale.
    @ObservedObject private var observedSettings: LocalFlowSettings
    @EnvironmentObject private var coordinator: DictationCoordinator

    @State private var isPreparingModel = false
    @State private var prepareMessage: String?

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        _observedSettings = ObservedObject(wrappedValue: viewModel.settings)
    }

    /// The view body.
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LFPaneTitle("General")
                    .padding(.top, 8)

                // Accessibility (required for paste into Notes / other apps)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Permissions")
                        .font(LocalFlowDesign.instrumentSerif(size: 18))
                        .foregroundStyle(LocalFlowDesign.ink)

                    let axOK = TextInjection().isAccessibilityTrusted(prompt: false)
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: axOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(axOK ? LocalFlowDesign.signal : LocalFlowDesign.marker)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(axOK ? "Accessibility enabled" : "Accessibility required for paste")
                                .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                                .foregroundStyle(LocalFlowDesign.ink)
                            Text(axOK
                                 ? "LocalFlow can insert text into Notes and other apps."
                                 : "Speech already works. Enable Accessibility for this LocalFlow Debug app, then dictate again.")
                                .font(LocalFlowDesign.generalSans(size: 12))
                                .foregroundStyle(LocalFlowDesign.graphite)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    if !axOK {
                        HStack(spacing: 12) {
                            LFPrimaryButton("Enable Accessibility…", enabled: true) {
                                _ = TextInjection().isAccessibilityTrusted(prompt: true)
                                TextInjection().openAccessibilitySettings()
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Speech · macOS 26+").font(LocalFlowDesign.instrumentSerif(size: 18))
                    Text(ModelManager.shared.speechReadiness.detail)
                    SpeechLocalePicker { Task { await prepareModel() } }
                    Text("Apple manages speech assets. Transcription stays on this Mac after setup.").font(.caption)
                    if let prepareMessage { Text(prepareMessage).font(.caption) }
                    if let error = coordinator.lastErrorMessage { Text(error).foregroundStyle(.red).font(.caption) }
                    LFPrimaryButton(isPreparingModel ? "Preparing…" : "Set up Apple Speech", enabled: !isPreparingModel) {
                        Task { await prepareModel() }
                    }
                    if let progress = ModelManager.shared.progress {
                        ProgressView(value: progress.fractionCompleted)
                        Text(progress.stage).font(.caption)
                    }
                }
                AgentReadinessView()

                // Hotkey — custom card selector (not stock Picker)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Shortcuts")
                        .font(LocalFlowDesign.instrumentSerif(size: 18))
                        .foregroundStyle(LocalFlowDesign.ink)

                    HStack(spacing: 12) {
                        HotkeyOptionCard(
                            title: "Right Option",
                            subtitle: "Hold ⌥ and speak",
                            isSelected: !viewModel.settings.useFnAsAlternateHotkey
                        ) {
                            viewModel.settings.useFnAsAlternateHotkey = false
                        }
                        HotkeyOptionCard(
                            title: "Fn",
                            subtitle: "Hold Fn and speak",
                            isSelected: viewModel.settings.useFnAsAlternateHotkey
                        ) {
                            viewModel.settings.useFnAsAlternateHotkey = true
                        }
                    }

                    Text("Double-tap either key anytime for hands-free — no holding required.")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)

                    Text("When Fn is selected, LocalFlow reserves the key while running so macOS shortcuts do not open at the same time.")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    SettingsToggleRow(
                        title: "Launch at login",
                        subtitle: "Start LocalFlow when you sign in to this Mac.",
                        isOn: Binding(
                            get: { viewModel.settings.launchAtLogin },
                            set: {
                                viewModel.settings.launchAtLogin = $0
                                LaunchAtLoginController.setEnabled($0)
                            }
                        )
                    )
                }
                .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                Spacer(minLength: 24)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LocalFlowDesign.canvas)
        .onAppear {
            viewModel.activeEngineName = coordinator.activeEngineName
        }
        .onReceive(NotificationCenter.default.publisher(for: .localFlowEngineDidChange)) { note in
            if let name = note.object as? String {
                viewModel.activeEngineName = name
            }
        }
    }

    private func prepareModel() async {
        isPreparingModel = true
        prepareMessage = "Setting up Apple Speech…"
        do {
            try await coordinator.prepareModelsWithError()
            prepareMessage = "Ready: \(coordinator.activeEngineName)"
            viewModel.activeEngineName = coordinator.activeEngineName
        } catch {
            prepareMessage = nil
        }
        isPreparingModel = false
    }


}

private struct HotkeyOptionCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title)
                        .font(LocalFlowDesign.generalSans(size: 14, weight: .medium))
                        .foregroundStyle(LocalFlowDesign.ink)
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? LocalFlowDesign.signal : LocalFlowDesign.graphite.opacity(0.4))
                }
                Text(subtitle)
                    .font(LocalFlowDesign.fragmentMono(size: 11))
                    .foregroundStyle(LocalFlowDesign.graphite)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LocalFlowDesign.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected ? LocalFlowDesign.signal : LocalFlowDesign.hairline,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(LocalFlowDesign.generalSans(size: 14, weight: .medium))
                    .foregroundStyle(LocalFlowDesign.ink)
                Text(subtitle)
                    .font(LocalFlowDesign.generalSans(size: 12))
                    .foregroundStyle(LocalFlowDesign.graphite)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LocalFlowDesign.signal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct SettingsSubToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(title)
                .font(LocalFlowDesign.generalSans(size: 13, weight: .regular))
                .foregroundStyle(isEnabled ? LocalFlowDesign.ink : LocalFlowDesign.graphite)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(LocalFlowDesign.signal)
                .disabled(!isEnabled)
        }
        .padding(.leading, 32)
        .padding(.trailing, 16)
        .padding(.vertical, 12)
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

// MARK: - Formatting settings pane

/// Formatting override settings.
public struct FormattingSettingsView: View {
    /// The shared settings store.
    @ObservedObject public var settings: LocalFlowSettings
    @State private var availabilityRevision = 0

    /// Creates a formatting settings view.
    public init(settings: LocalFlowSettings) {
        self.settings = settings
    }

    /// The view body.
    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                LFPaneTitle("Smart Formatting")
                    .padding(.top, 8)

                // Smart Formatting & Autocorrect section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Smart Formatting & Spelling")
                        .font(LocalFlowDesign.instrumentSerif(size: 18))
                        .foregroundStyle(LocalFlowDesign.ink)

                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: "Format text automatically",
                            subtitle: "Applies smart capitalization, punctuation, and app-specific structure.",
                            isOn: Binding(
                                get: { settings.smartFormattingEnabled },
                                set: { settings.smartFormattingEnabled = $0 }
                            )
                        )

                        Divider().background(LocalFlowDesign.hairline)

                        SettingsSubToggleRow(
                            title: "Fix spelling & common typos (NSSpellChecker)",
                            isOn: Binding(
                                get: { settings.smartFormattingAutocorrect },
                                set: { settings.smartFormattingAutocorrect = $0 }
                            ),
                            isEnabled: settings.smartFormattingEnabled
                        )

                        Divider().background(LocalFlowDesign.hairline)

                        SettingsSubToggleRow(
                            title: "Smart typography (curly quotes, em-dashes, clean spacing)",
                            isOn: Binding(
                                get: { settings.smartFormattingSmartPunctuation },
                                set: { settings.smartFormattingSmartPunctuation = $0 }
                            ),
                            isEnabled: settings.smartFormattingEnabled
                        )
                    }
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    Text("Local spelling and typography cleanup respects your custom vocabulary and preserves technical literals. Gmail and Slack receive light destination-aware formatting; every other app uses neutral dictation.")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Smart Polish (Option + 1) section
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Smart Polish")
                            .font(LocalFlowDesign.instrumentSerif(size: 18))
                            .foregroundStyle(LocalFlowDesign.ink)

                        Text("⌥1")
                            .font(LocalFlowDesign.fragmentMono(size: 11))
                            .fontWeight(.bold)
                            .foregroundStyle(LocalFlowDesign.signal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(LocalFlowDesign.signal.opacity(0.12))
                            )
                    }

                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: "Enable Option + 1 Polish Shortcut",
                            subtitle: "Select text in any app and press ⌥1 to rewrite it in place.",
                            isOn: Binding(
                                get: { settings.smartPolishShortcutEnabled },
                                set: { settings.smartPolishShortcutEnabled = $0 }
                            )
                        )

                        Divider().background(LocalFlowDesign.hairline)

                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Default tone")
                                    .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                                Text("Used whenever you press ⌥1.")
                                    .font(LocalFlowDesign.generalSans(size: 12))
                                    .foregroundStyle(LocalFlowDesign.graphite)
                            }
                            Spacer()
                            Picker("Default tone", selection: Binding(get: { PolishTone(rawValue: settings.smartPolishTone) ?? .natural }, set: { settings.smartPolishTone = $0.rawValue })) {
                                ForEach(PolishTone.allCases) { tone in Text(tone.displayName).tag(tone) }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Apple on-device model status")
                                .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                            Text(LocalWritingAssistant.availabilityDescription)
                                .id(availabilityRevision)
                                .font(LocalFlowDesign.generalSans(size: 12))
                                .foregroundStyle(LocalFlowDesign.graphite)
                            if LocalWritingAssistant.isAvailable {
                                Text("Runs privately on this Mac. No API key or usage fee.")
                                    .font(LocalFlowDesign.generalSans(size: 12))
                                    .foregroundStyle(LocalFlowDesign.graphite)
                            }
                        }
                        Spacer()
                        Button("Refresh") { availabilityRevision += 1 }
                            .buttonStyle(.plain)
                            .foregroundStyle(LocalFlowDesign.signal)
                    }
                    .onAppear { availabilityRevision += 1 }
                    .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)) { _ in
                        availabilityRevision += 1
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Text("Prompt Engineer")
                            .font(LocalFlowDesign.instrumentSerif(size: 18))
                            .foregroundStyle(LocalFlowDesign.ink)
                        Text("⌥2")
                            .font(LocalFlowDesign.fragmentMono(size: 11))
                            .fontWeight(.bold)
                            .foregroundStyle(LocalFlowDesign.signal)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(LocalFlowDesign.signal.opacity(0.12)))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Build a structured prompt from selected text")
                            .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                        Text("Select rough text in any app and press ⌥2. LocalFlow privately turns it into a grounded role, objective, context, requirements, constraints, and expected result, then replaces the selection in place.")
                            .font(LocalFlowDesign.generalSans(size: 12))
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))
                }

                // Speech Cleanup section
                VStack(alignment: .leading, spacing: 12) {
                    Text("Speech Cleanup")
                        .font(LocalFlowDesign.instrumentSerif(size: 18))
                        .foregroundStyle(LocalFlowDesign.ink)

                    VStack(spacing: 0) {
                        SettingsToggleRow(
                            title: "Clean speech before inserting",
                            subtitle: "Deterministic cleanup for raw transcribed speech.",
                            isOn: Binding(
                                get: { settings.cleanSpeechEnabled },
                                set: { settings.cleanSpeechEnabled = $0 }
                            )
                        )

                        Divider().background(LocalFlowDesign.hairline)

                        SettingsSubToggleRow(
                            title: "Remove filler words (um, uh, etc.)",
                            isOn: Binding(
                                get: { settings.removeFillerWords },
                                set: { settings.removeFillerWords = $0 }
                            ),
                            isEnabled: settings.cleanSpeechEnabled
                        )

                        Divider().background(LocalFlowDesign.hairline)

                        SettingsSubToggleRow(
                            title: "Collapse repeated words",
                            isOn: Binding(
                                get: { settings.collapseRepeatedWords },
                                set: { settings.collapseRepeatedWords = $0 }
                            ),
                            isEnabled: settings.cleanSpeechEnabled
                        )

                        Divider().background(LocalFlowDesign.hairline)

                        SettingsSubToggleRow(
                            title: "Handle self-corrections (\"no wait\", \"scratch that\")",
                            isOn: Binding(
                                get: { settings.handleSelfCorrections },
                                set: { settings.handleSelfCorrections = $0 }
                            ),
                            isEnabled: settings.cleanSpeechEnabled
                        )
                    }
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    Text("Runs deterministic, rule-based cleanup on transcribed text. Does not use an AI model or change the meaning of your words.")
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LocalFlowDesign.canvas)
    }
}

// MARK: - Privacy settings pane

/// Privacy dashboard and credits.
public struct PrivacySettingsView: View {
    /// The privacy dashboard model.
    @ObservedObject public var model: PrivacyDashboardModel
    /// The name of the engine currently in use.
    public var activeEngineName: String

    /// The view body.
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LFPaneTitle("Privacy Dashboard")
                .padding(.top, 24)
                .padding(.horizontal, 28)
                .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "cpu")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LocalFlowDesign.signal)
                        Text("Currently using:")
                            .font(LocalFlowDesign.generalSans(size: 13))
                            .foregroundStyle(LocalFlowDesign.graphite)
                        Text(activeEngineName)
                            .font(LocalFlowDesign.fragmentMono(size: 13))
                            .foregroundStyle(LocalFlowDesign.ink)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    if activeEngineName.contains("Apple Speech") {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(LocalFlowDesign.signal)
                                .padding(.top, 1)
                            Text("Apple's on-device speech model is downloaded and managed by macOS itself, not by LocalFlow directly. LocalFlow does not send audio anywhere either way.")
                                .font(LocalFlowDesign.generalSans(size: 12))
                                .foregroundStyle(LocalFlowDesign.graphite)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(LocalFlowDesign.signal.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(LocalFlowDesign.signal.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "network.slash")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(LocalFlowDesign.signal)
                        Text("Network requests this session:")
                            .font(LocalFlowDesign.generalSans(size: 13))
                            .foregroundStyle(LocalFlowDesign.graphite)
                        Text("\(model.networkRequestCount)")
                            .font(LocalFlowDesign.fragmentMono(size: 13))
                            .foregroundStyle(LocalFlowDesign.ink)
                    }
                    .padding(16)
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    Toggle("Hard-block network after models are downloaded", isOn: $model.hardBlockNetwork)
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .toggleStyle(.switch)
                        .tint(LocalFlowDesign.signal)

                    Divider()
                        .background(LocalFlowDesign.hairline)

                    HStack(spacing: 9) {
                        LocalFlowDesign.logomark(size: CGSize(width: 20, height: 13), color: LocalFlowDesign.signal)
                        Text("About & Credits")
                            .font(LocalFlowDesign.instrumentSerif(size: 18))
                            .foregroundStyle(LocalFlowDesign.ink)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 12))
                            .foregroundStyle(LocalFlowDesign.graphite)
                        Text(model.buildIdentifier)
                            .font(LocalFlowDesign.fragmentMono(size: 11))
                            .foregroundStyle(LocalFlowDesign.graphite)
                            .textSelection(.enabled)
                    }

                    ForEach(model.credits, id: \.self) { credit in
                        Text(credit)
                            .font(LocalFlowDesign.generalSans(size: 12))
                            .foregroundStyle(LocalFlowDesign.graphite)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LocalFlowDesign.canvas)
        .onAppear { model.refresh() }
    }
}

// Matches the existing General/Privacy panes: same canvas, pane title, native controls.
private struct AgentSettingsView: View {
    @ObservedObject var store: AgentMemoryStore
    @ObservedObject private var planner = PlannerModelManager.shared
    @State private var plannerGoal = ""
    @State private var plannerThinking = false
    @State private var plannerTask: Task<Void, Never>?
    @ObservedObject private var models = DecisionModelManager.shared
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var draft = ""
    @State private var message = ""
    @State private var bytes: Int64 = 0
    @State private var modelTask: Task<Void, Never>?
    @State private var modelBusy = false
    @State private var resetRequested = false
    @State private var removeRequested = false
    @State private var mappingName = ""
    @State private var benchmarkIndex = 1
    @State private var applications: [ApplicationMatch] = []
    @State private var aliasKind = "application"
    @State private var aliasName = ""
    @State private var aliasValue = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LFPaneTitle("Agent / Mac Control")
                Text("Operational preferences stay on this Mac. Nothing is learned from conversations. Changes apply to the next agent session.")
                    .foregroundStyle(LocalFlowDesign.graphite)
                GroupBox("System-2 Planner") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Qwen3.5-4B · " + planner.status.rawValue)
                        Text(planner.resident ? "Warm / resident" : "Unloaded").font(.caption)
                        Text(ByteCountFormatter.string(fromByteCount: planner.diskBytes, countStyle: .file) + " · " + String(planner.revision.prefix(12))).font(.caption)
                        if let progress = planner.progress { ProgressView(value: progress.fractionCompleted); Text(progress.stage).font(.caption) }
                        if let error = planner.error { Text(error).font(.caption).foregroundStyle(.red) }
                        HStack {
                            Button("Download") { plannerTask = Task { do { try await planner.download(); await planner.refreshDiskUsage() } catch { message = error.localizedDescription } } }
                                .disabled(planner.busy || planner.isInstalled)
                            Button("Prepare / Load") { plannerTask = Task { do { try await planner.prepare(schemas: coordinator.plannerToolSchemas) } catch { message = error.localizedDescription } } }
                                .disabled(planner.busy || !planner.isInstalled || planner.resident)
                            Button("Unload") { plannerTask = Task { await planner.unload() } }.disabled(!planner.resident || planner.busy)
                            Button("Cancel") { plannerTask?.cancel(); Task { await planner.cancel() } }.disabled(!planner.busy)
                            Button("Remove", role: .destructive) { plannerTask = Task { do { try await planner.remove() } catch { message = error.localizedDescription } } }
                                .disabled(planner.busy || !planner.isInstalled)
                        }
                        Toggle("Experimental Planner", isOn: Binding(get: { planner.experimentalEnabled }, set: { planner.experimentalEnabled = $0; if !$0 && coordinator.isTypedPlannerSession { coordinator.cancelTypedPlanner() } }))
                        Text("Explicit typed requests only. Automatic voice fallback awaits the planner quality gate.").font(.caption)
                        #if DEBUG
                        TextField("Typed planner goal", text: $plannerGoal)
                        Toggle("Thinking mode (benchmark)", isOn: $plannerThinking)
                        Button("Run typed request") { coordinator.runTypedPlanner(goal: plannerGoal, thinking: plannerThinking) }
                            .disabled(!coordinator.canRunTypedRequest(plannerGoal))
                        if coordinator.voiceAgent.snapshot.plannerNeedsContinuation {
                            Button("Continue (up to 16 more actions)") { coordinator.continueTypedPlannerAfterUserApproval() }
                        }
                        Text("Saved projects and approved executable workflows are edited in operational JSON below. Prepare the pinned native helper with Scripts/prepare-planner.sh before loading.").font(.caption)
                        if let metrics = planner.lastGenerationMetrics {
                            Text(String(format: "TTFT %.0f ms · first call %.0f ms · %.1f tokens/s", metrics.ttftMS, metrics.firstToolCallMS, metrics.tokensPerSecond)).font(.caption)
                        }
                        #endif
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .task { await planner.refreshDiskUsage() }
                GroupBox("Local decision model") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(models.isInstalled ? "Laya installed" : "Laya not installed")
                        Text(models.status.description)
                        Text("Model disk usage: \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        if let progress = models.progress {
                            Text(progress.stage)
                            ProgressView(value: progress.fractionCompleted)
                        }
                        HStack {
                            Button("Install LocalFlow-Laya-v2…") { installDecisionModel() }
                                .disabled(modelBusy || models.isBusy || coordinator.state != .idle)
                            Button("Cancel Installation") { modelTask?.cancel() }.disabled(!modelBusy)
                            Button("Remove Model", role: .destructive) { removeRequested = true }
                                .disabled(!models.isInstalled || modelBusy || models.isBusy || coordinator.state != .idle)
                        }
                        .disabled(models.isBusy && !modelBusy)
                        Text("Supported commands remain available when Laya is absent or abstains.").font(.caption)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Toggle("Enable real-time agent (⌘⇧Space)", isOn: Binding(
                    get: { store.memory.realTimeEnabled }, set: { enabled in update { $0.realTimeEnabled = enabled } }))
                Picker("Confirmation policy", selection: Binding(
                    get: { store.memory.confirmAllActions }, set: { all in update { $0.confirmAllActions = all } })) {
                    Text("Consequential and uncertain actions").tag(false)
                    Text("Every action").tag(true)
                }
                Text("Quitting apps, replacing text, and changing existing notes always require confirmation.").font(.caption)
                GroupBox("Preferred apps") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(["browser", "editor", "terminal"], id: \.self) { role in
                            preferredAppPicker(role)
                        }
                    }.padding(6)
                }
                GroupBox("Aliases, folders, websites & workflows") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Add", selection: $aliasKind) {
                            Text("Application alias").tag("application")
                            Text("Folder / project").tag("folder")
                            Text("Website alias").tag("website")
                            Text("Workflow").tag("workflow")
                        }
                        TextField("Name (for example, placement portal)", text: $aliasName)
                        if aliasKind == "workflow" {
                            Text("One supported command per line. Text payloads remain intact.").font(.caption)
                            TextEditor(text: $aliasValue).frame(height: 80).accessibilityLabel("Workflow commands")
                        } else {
                            TextField(aliasKind == "website" ? "Full website URL" : aliasKind == "folder" ? "Absolute folder path" : "Application name or bundle identifier", text: $aliasValue)
                        }
                        HStack {
                            Button("Add / Update") { addAlias() }.disabled(aliasName.trimmingCharacters(in: .whitespaces).isEmpty)
                            if aliasKind == "folder" {
                                Button("Choose Folder…") {
                                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                                    panel.allowsMultipleSelection = false
                                    if panel.runModal() == .OK, let url = panel.url { aliasValue = url.path }
                                }
                            }
                        }
                        Text("Review or remove entries in the editable JSON. Save applies the complete configuration; Reload discards unsaved JSON edits.").font(.caption)
                        TextEditor(text: $draft).font(.system(.body, design: .monospaced)).frame(minHeight: 260)
                            .accessibilityLabel("Operational memory JSON")
                        HStack {
                            Button("Save Memory") { saveDraft() }
                            Button("Reload from Disk") { store.reload(); refreshDraft() }
                            Button("Reveal JSON") {
                                do {
                                    if !FileManager.default.fileExists(atPath: store.fileURL.path) { try store.save(store.memory) }
                                    NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
                                } catch { message = error.localizedDescription }
                            }
                        }
                        Text(store.fileURL.path).font(.caption).textSelection(.enabled)
                    }.padding(6)
                }
                GroupBox("Approve a successful command mapping") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Save the last verified single command under a name you choose. Consequential actions are excluded.")
                        Text(coordinator.voiceAgent.snapshot.transcript.isEmpty ? "No instruction to approve yet." : coordinator.voiceAgent.snapshot.transcript)
                            .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        TextField("Mapping name", text: $mappingName)
                        Button("Approve & Save Last Command") {
                            do { try coordinator.voiceAgent.approveSuccessfulCommand(as: mappingName); refreshDraft(); message = "Approved command saved." }
                            catch { message = error.localizedDescription }
                        }.disabled(mappingName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.padding(6)
                }
                if !message.isEmpty { Text(message).textSelection(.enabled) }
                if let error = store.error { Text(error).foregroundStyle(.red) }
                GroupBox("Activity / history · last 200 actions") {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if store.activity.isEmpty { Text("No agent activity yet.") }
                        ForEach(store.activity.reversed()) { event in
                            Text("\(event.date.formatted(date: .abbreviated, time: .shortened)) · \(event.tool) · \(event.outcome) · \(Int(event.milliseconds)) ms").font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("Daily-use benchmark") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Scenario", selection: $benchmarkIndex) {
                            ForEach(AgentBenchmarkScenario.daily) { scenario in
                                Text("\(scenario.id). \(scenario.instruction)").tag(scenario.id)
                            }
                        }
                        Text("Start, say the selected instruction, then press Finish in the island. Confirm when prompted. This uses real apps and creates a benchmark note/reminder; camera capture is not triggered.").font(.caption)
                        HStack {
                            Button("Start Spoken Benchmark") {
                                Task { @MainActor in
                                    do { try await coordinator.beginBenchmark(AgentBenchmarkScenario.daily[benchmarkIndex - 1]) }
                                    catch { message = error.localizedDescription }
                                }
                            }.disabled(coordinator.state != .idle || !store.memory.realTimeEnabled)
                            Button("Export Measurements") {
                                do { NSWorkspace.shared.activateFileViewerSelecting([try coordinator.exportBenchmarks()]) }
                                catch { message = error.localizedDescription }
                            }.disabled(coordinator.benchmarkResults.isEmpty)
                        }
                        ForEach(coordinator.benchmarkResults.suffix(10).reversed()) { result in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Scenario \(result.scenario) · \(result.cancelled ? "cancelled" : "finished")")
                                Text("Partial STT \(ms(result.partialSTTMilliseconds)) · Decision \(ms(result.decisionMilliseconds)) · First action \(ms(result.firstActionMilliseconds)) · Total \(ms(result.completionMilliseconds))")
                                Text("Duplicate \(Int(result.duplicateActionRate * 100))% · Incorrect \(Int(result.incorrectActionRate * 100))% · Missing \(result.missingActions) · Unverified \(result.unverifiedActions) · Failed \(result.failedActions) · Out of order \(result.outOfOrderActions)")
                            }.font(.caption).textSelection(.enabled)
                        }
                    }.padding(6)
                }
#if DEBUG
                AgentRealityGatePanel(agent: coordinator.voiceAgent)
#endif
                Button("Reset Agent Memory", role: .destructive) { resetRequested = true }
                    .disabled(coordinator.state != .idle)
            }
            .padding(28)
        }
        .task {
            refreshDraft()
            let apps = LaunchServicesApplicationCatalog().installedApplications()
            applications = Dictionary(grouping: apps, by: \.id).compactMap { $0.value.first }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            bytes = await models.diskUsage()
        }
        .alert("Reset operational memory?", isPresented: $resetRequested) {
            Button("Reset", role: .destructive) {
                Task { @MainActor in
                    do { try await coordinator.resetOperationalMemory(); refreshDraft(); message = "Agent memory and activity reset." }
                    catch { message = error.localizedDescription }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes saved agent preferences, aliases, workflows and activity. Dictation history and vocabulary are preserved.") }
        .alert("Remove local Laya model?", isPresented: $removeRequested) {
            Button("Remove", role: .destructive) {
                modelBusy = true
                modelTask = Task { @MainActor in
                    do { try await models.remove(); bytes = await models.diskUsage() }
                    catch { message = error.localizedDescription }
                    modelBusy = false; modelTask = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    private func preferredAppPicker(_ role: String) -> some View {
        let preference = store.memory.preferredApps[role] ?? ""
        let isKnown = applications.contains { ($0.bundleIdentifier ?? $0.name) == preference }
        return Picker(role.capitalized, selection: Binding<String>(
            get: { store.memory.preferredApps[role] ?? "" },
            set: { value in update { memory in
                if value.isEmpty { memory.preferredApps.removeValue(forKey: role) }
                else { memory.preferredApps[role] = value }
            } })) {
                Text("System default / unset").tag("")
                ForEach(applications) { app in Text(app.name).tag(app.bundleIdentifier ?? app.name) }
                if !preference.isEmpty && !isKnown { Text(preference).tag(preference) }
            }
    }
    private func ms(_ value: Double?) -> String { value.map { "\(Int($0)) ms" } ?? "unavailable" }
    private func refreshDraft() { draft = (try? store.editableJSON()) ?? "" }
    private func update(_ edit: (inout AgentMemory) -> Void) {
        do {
            var value = store.memory
            edit(&value)
            try store.save(value)
            // Keep unrelated advanced JSON edits when changing a top-level control.
            if var edited = try? JSONDecoder().decode(AgentMemory.self, from: Data(draft.utf8)) {
                edit(&edited)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                draft = String(decoding: try encoder.encode(edited), as: UTF8.self)
            } else { refreshDraft() }
            message = "Preference saved."
        } catch { message = error.localizedDescription }
    }
    private func addAlias() {
        do {
            var value = try JSONDecoder().decode(AgentMemory.self, from: Data(draft.utf8))
            let key = AgentMemory.key(aliasName)
            switch aliasKind {
            case "folder": value.folders[key] = aliasValue.trimmingCharacters(in: .whitespacesAndNewlines)
            case "website": value.websites[key] = aliasValue.trimmingCharacters(in: .whitespacesAndNewlines)
            case "workflow": value.workflows[key] = aliasValue.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            default: value.applicationAliases[key] = aliasValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try CommandMode().validateOperationalMemory(value)
            try store.save(value); refreshDraft(); message = "Saved \(key)."; aliasName = ""; aliasValue = ""
        } catch { message = error.localizedDescription }
    }
    private func saveDraft() {
        do {
            let value = try JSONDecoder().decode(AgentMemory.self, from: Data(draft.utf8))
            try CommandMode().validateOperationalMemory(value)
            try store.save(value); refreshDraft(); message = "Memory saved locally."
        } catch { message = error.localizedDescription }
    }
    private func installDecisionModel() {
        guard !modelBusy, !models.isBusy, coordinator.state == .idle else { return }
        let picker = NSOpenPanel()
        picker.title = "Install LocalFlow-Laya-v2"
        picker.message = "Choose a trained native package with hashes, calibration and parity evidence."
        picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false
        guard picker.runModal() == .OK, let directory = picker.url else { return }
        modelBusy = true
        modelTask = Task { @MainActor in
            do { try await models.install(from: directory); message = "Local decision model installed." }
            catch is CancellationError { message = "Model preparation cancelled." }
            catch { message = error.localizedDescription }
            bytes = await models.diskUsage(); modelBusy = false; modelTask = nil
        }
    }
}

/// Native speech locale selection is shared by onboarding and Settings.
struct SpeechLocalePicker: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var manager = ModelManager.shared
    @ObservedObject private var settings = LocalFlowSettings.shared
    let didSelect: () -> Void
    var body: some View {
        Picker("Speech language", selection: Binding(get: { settings.speechLocaleIdentifier }, set: { value in
            settings.speechLocaleIdentifier = value
            Task { await manager.refreshReadiness(); didSelect() }
        })) {
            if !manager.supportedLocales.contains(where: { $0.identifier == settings.speechLocaleIdentifier }) {
                Text(Locale.current.localizedString(forIdentifier: settings.speechLocaleIdentifier) ?? settings.speechLocaleIdentifier)
                    .tag(settings.speechLocaleIdentifier)
            }
            ForEach(manager.supportedLocales, id: \.identifier) { locale in
                Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(locale.identifier)
            }
        }.disabled(coordinator.state != .idle || manager.progress != nil)
            .task { await manager.refreshReadiness() }
    }
}

/// Readiness is observational. Native Automation prompts occur when a tool needs access.
private struct AgentReadinessView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var speech = ModelManager.shared
    @ObservedObject private var laya = DecisionModelManager.shared
    @State private var refresh = 0
    @State private var automationReady = false
    var body: some View {
        GroupBox("Agent Readiness") {
            VStack(alignment: .leading, spacing: 10) {
                row("Microphone", state: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized ? "READY" : "ACTION REQUIRED") {
                    Task { _ = await coordinator.requestMicrophonePermission(); refresh += 1 }
                }
                row("Accessibility", state: SemanticAccessibilityService.readiness) {
                    TextInjection().openAccessibilitySettings()
                }
                row("Apple Speech Assets", state: speech.speechReadiness.status == .ready ? "READY" : speech.speechReadiness.status == .unavailable ? "UNAVAILABLE" : "ACTION REQUIRED") {
                    Task { await coordinator.prepareModels() }
                }
                Text(speech.speechReadiness.detail).font(.caption)
                row("Automation", state: automationReady ? "READY" : "ACTION REQUIRED") {
                    open("Privacy_Automation")
                }
                Text("Notes and Spotify each need Automation access. Run the requested tool to trigger its native prompt. Reminders uses its own permission.").font(.caption)
                row("Laya", state: laya.status == .ready ? "READY" : laya.status == .failed ? "UNAVAILABLE" : "ACTION REQUIRED") {
                    laya.prepareInstalled()
                }
                Text("Model readiness is separate from calibrated decision authority.").font(.caption)
                Button("Refresh Readiness") { Task { refresh += 1; await speech.refreshReadiness() } }
            }.padding(6).id(refresh)
        }.task(id: refresh) { automationReady = await NativePermissionReadiness.automationReady() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { refresh += 1; await speech.refreshReadiness() }
        }
    }
    private func row(_ title: String, state: String, action: @escaping () -> Void) -> some View {
        HStack { Text(title); Spacer(); Text(state).font(.caption.monospaced()); Button(state == "READY" ? "Settings" : "Review", action: action) }
    }
    private func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane) { NSWorkspace.shared.open(url) }
    }
}
