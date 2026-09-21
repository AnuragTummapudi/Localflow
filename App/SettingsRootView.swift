import SwiftUI
import AppKit
import Shared
import PrivacyDashboard
import ModelManager
import Engines
import TextInjection
import SmartFormatting

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
    case smartFormatting
    case privacyDashboard
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dictation: "Dictation"
        case .insights: "Insights"
        case .dictionary: "Dictionary"
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
                ("open [URL]", "Opens the URL in the default browser"),
                ("open [query] in [site]", "Searches query directly on YouTube, Google, GitHub, etc."),
                ("search [query] on [site]", "Searches query on named platform or domain"),
                ("play [song] on Spotify", "Searches Spotify and starts the first relevant result"),
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

                // Engine status
                VStack(alignment: .leading, spacing: 10) {
                    Text("Speech Engine")
                        .font(LocalFlowDesign.instrumentSerif(size: 18))
                        .foregroundStyle(LocalFlowDesign.ink)

                    HStack(spacing: 10) {
                        Image(systemName: coordinator.isEngineReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(coordinator.isEngineReady ? LocalFlowDesign.signal : LocalFlowDesign.marker)
                        Text(coordinator.isEngineReady
                             ? (viewModel.activeEngineName == "Not loaded" ? coordinator.activeEngineName : viewModel.activeEngineName)
                             : "Not loaded — enable Apple Speech or download a local model")
                            .font(LocalFlowDesign.generalSans(size: 13))
                            .foregroundStyle(LocalFlowDesign.ink)
                        Spacer()
                    }
                    .padding(14)
                    .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                    if appleSpeechEngineIsAvailable() {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "apple.logo")
                                .foregroundStyle(LocalFlowDesign.signal)
                                .padding(.top, 1)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Apple Speech (primary)")
                                    .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                                    .foregroundStyle(LocalFlowDesign.ink)
                                Text("On-device SpeechAnalyzer on macOS 26. No Hugging Face download required.")
                                    .font(LocalFlowDesign.generalSans(size: 12))
                                    .foregroundStyle(LocalFlowDesign.graphite)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LocalFlowDesign.signal.opacity(0.07))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(LocalFlowDesign.signal.opacity(0.2), lineWidth: 1)
                                )
                        )
                    }

                    if let prepareMessage {
                        Text(prepareMessage)
                            .font(LocalFlowDesign.generalSans(size: 12))
                            .foregroundStyle(LocalFlowDesign.graphite)
                    }
                    if let err = coordinator.lastErrorMessage {
                        Text(err)
                            .font(LocalFlowDesign.generalSans(size: 12))
                            .foregroundStyle(LocalFlowDesign.marker)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 12) {
                        LFPrimaryButton(
                            isPreparingModel ? "Preparing…" : (appleSpeechEngineIsAvailable() ? "Enable / Reload Apple Speech" : "Download / Prepare Model"),
                            enabled: !isPreparingModel
                        ) {
                            Task { await prepareModel() }
                        }
                        if isPreparingModel {
                            ProgressView().controlSize(.small)
                        }
                    }

                    if appleSpeechEngineIsAvailable() {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Optional local fallbacks")
                                .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                                .foregroundStyle(LocalFlowDesign.ink)
                            Text("Download Parakeet or Whisper if you want a second engine when Apple Speech fails or returns empty text. Already-downloaded models are used automatically as fallback.")
                                .font(LocalFlowDesign.generalSans(size: 12))
                                .foregroundStyle(LocalFlowDesign.graphite)
                                .fixedSize(horizontal: false, vertical: true)

                            HStack(spacing: 10) {
                                Button {
                                    Task { await downloadFallback(.parakeetTDT) }
                                } label: {
                                    Text(ModelManager.shared.localModelExists(for: .parakeetTDT) ? "Parakeet ✓" : "Download Parakeet")
                                        .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                                        .foregroundStyle(LocalFlowDesign.ink)
                                        .padding(.horizontal, 12)
                                        .frame(height: 32)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(LocalFlowDesign.card)
                                                .overlay(Capsule(style: .continuous).strokeBorder(LocalFlowDesign.hairline, lineWidth: 1))
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(isPreparingModel)

                                Button {
                                    Task { await downloadFallback(.whisperLargeV3Turbo) }
                                } label: {
                                    Text(ModelManager.shared.localModelExists(for: .whisperLargeV3Turbo) ? "Whisper ✓" : "Download Whisper")
                                        .font(LocalFlowDesign.generalSans(size: 12, weight: .medium))
                                        .foregroundStyle(LocalFlowDesign.ink)
                                        .padding(.horizontal, 12)
                                        .frame(height: 32)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(LocalFlowDesign.card)
                                                .overlay(Capsule(style: .continuous).strokeBorder(LocalFlowDesign.hairline, lineWidth: 1))
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(isPreparingModel)
                            }
                        }
                        .padding(14)
                        .background(LocalFlowDesign.cardBackground(cornerRadius: 16))
                    }
                }

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
                    Divider().background(LocalFlowDesign.hairline)
                    SettingsToggleRow(
                        title: "Show advanced options",
                        subtitle: "Reveal model override controls below.",
                        isOn: Binding(
                            get: { viewModel.settings.showAdvancedOptions },
                            set: { viewModel.settings.showAdvancedOptions = $0 }
                        )
                    )
                }
                .background(LocalFlowDesign.cardBackground(cornerRadius: 16))

                if viewModel.settings.showAdvancedOptions {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model override")
                            .font(LocalFlowDesign.instrumentSerif(size: 18))
                            .foregroundStyle(LocalFlowDesign.ink)

                        Text("Automatic keeps Apple Speech first (on macOS 26). Choosing Parakeet or Whisper forces that local model.")
                            .font(LocalFlowDesign.generalSans(size: 12))
                            .foregroundStyle(LocalFlowDesign.graphite)

                        HStack(spacing: 10) {
                            ForEach(ModelTier.allCases) { tier in
                                let selected = (viewModel.settings.modelOverride ?? .automatic) == tier
                                Button {
                                    viewModel.settings.modelOverride = tier
                                    Task { await prepareModel() }
                                } label: {
                                    Text(tier.displayName)
                                        .font(LocalFlowDesign.generalSans(size: 13, weight: .medium))
                                        .foregroundStyle(selected ? Color.white : LocalFlowDesign.ink)
                                        .padding(.horizontal, 14)
                                        .frame(height: 36)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(selected ? LocalFlowDesign.signal : LocalFlowDesign.card)
                                                .overlay(
                                                    Capsule(style: .continuous)
                                                        .strokeBorder(selected ? Color.clear : LocalFlowDesign.hairline, lineWidth: 1)
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                                .disabled(isPreparingModel)
                            }
                        }
                    }
                }

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
        prepareMessage = appleSpeechEngineIsAvailable()
            ? "Enabling Apple Speech…"
            : "Downloading / loading model — this can take a few minutes the first time…"
        do {
            try await coordinator.prepareModelsWithError()
            prepareMessage = "Ready: \(coordinator.activeEngineName)"
            viewModel.activeEngineName = coordinator.activeEngineName
        } catch {
            prepareMessage = nil
        }
        isPreparingModel = false
    }

    private func downloadFallback(_ tier: ModelTier) async {
        isPreparingModel = true
        prepareMessage = "Downloading \(tier.displayName)…"
        do {
            try await ModelManager.shared.downloadModel(tier)
            try await coordinator.prepareModelsWithError()
            prepareMessage = "Ready: \(coordinator.activeEngineName)"
            viewModel.activeEngineName = coordinator.activeEngineName
        } catch {
            prepareMessage = error.localizedDescription
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
