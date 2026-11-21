import SwiftUI
import Shared
import ModelManager
import Engines

/// Shared by first-run setup and General settings so both paths configure the same pipeline.
struct SourceConfigurationView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var settings = LocalFlowSettings.shared
    @ObservedObject private var manager = ModelManager.shared
    @State private var source = LocalFlowSettings.shared.dictationSource
    @State private var tier = LocalFlowSettings.shared.modelOverride ?? .automatic
    @State private var speechProvider = LocalFlowSettings.shared.transcriptionProvider
    @State private var polishProvider = LocalFlowSettings.shared.polishProvider
    @State private var speechModelID = LocalFlowSettings.shared.speechModel(for: LocalFlowSettings.shared.transcriptionProvider)
    @State private var polishModelID = LocalFlowSettings.shared.polishProvider.map { LocalFlowSettings.shared.polishModel(for: $0) } ?? ""
    @State private var cloudConsent = false
    @State private var working = false
    @State private var applyTask: Task<Void, Never>?
    @State private var message: String?
    @State private var failed = false
    var onboarding = false
    var onComplete: (() -> Void)?

    init(onboarding: Bool = false, initialSource: DictationSource? = nil, onComplete: (() -> Void)? = nil) {
        self.onboarding = onboarding
        self.onComplete = onComplete
        _source = State(initialValue: initialSource ?? LocalFlowSettings.shared.dictationSource)
    }

    private var usesCloud: Bool { source == .cloud || polishProvider != nil }
    private var busy: Bool { working || !coordinator.canConfigureEngine }
    private var requiredProviders: [CloudProvider] {
        CloudProvider.allCases.filter { (source == .cloud && $0 == speechProvider) || $0 == polishProvider }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 16) {
            Text(onboarding ? "Make LocalFlow yours" : "Dictation & Smart Polish")
                .font(LocalFlowDesign.instrumentSerif(size: onboarding ? 26 : 22))
            Text("Choose where your words are processed. You can change this anytime.")
                .foregroundStyle(LocalFlowDesign.graphite)

            if !onboarding {
                Text("Active dictation: \(coordinator.activeEngineName)")
                    .font(LocalFlowDesign.generalSans(size: 12))
                    .foregroundStyle(LocalFlowDesign.graphite)
            }
            Picker("Dictation", selection: $source) {
                ForEach(DictationSource.allCases) { item in Text(item.displayName).tag(item) }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Dictation processing mode")

            switch source {
            case .apple:
                Label("Built into macOS. Audio stays on this Mac.", systemImage: "apple.logo")
                Text(appleSpeechEngineIsAvailable()
                     ? "Apple Speech may download its language assets once. No API key or usage fee."
                     : "Apple Speech requires macOS 26. On this Mac, choose a local model or your API key.")
                    .foregroundStyle(LocalFlowDesign.graphite)
            case .local:
                Picker("Speech model", selection: $tier) {
                    Text("Recommended for this Mac").tag(ModelTier.automatic)
                    if manager.isAppleSilicon { Text("Parakeet TDT").tag(ModelTier.parakeetTDT) }
                    Text("Whisper Large v3 Turbo").tag(ModelTier.whisperLargeV3Turbo)
                }
                Text("Downloads a model once, then transcribes on this Mac. No API key or usage fee. Parakeet requires Apple Silicon.")
                    .foregroundStyle(LocalFlowDesign.graphite)
            case .cloud:
                Picker("Dictation provider", selection: $speechProvider) {
                    ForEach(CloudProvider.transcriptionProviders) { provider in Text(provider.displayName).tag(provider) }
                }
                Text("Recorded audio is sent directly to \(speechProvider.displayName) after you finish speaking.")
                    .foregroundStyle(LocalFlowDesign.graphite)
                TextField("Model ID", text: $speechModelID, prompt: Text(speechProvider.speechModel))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(speechProvider.displayName) dictation model ID")
            }

            Divider()
            Picker("Smart Polish · ⌥1", selection: $polishProvider) {
                Text("Apple Intelligence · on-device").tag(CloudProvider?.none)
                ForEach(CloudProvider.allCases) { provider in Text(provider.displayName).tag(Optional(provider)) }
            }
            Text(polishProvider.map { "Only the text you select for ⌥1 is sent to \($0.displayName)." }
                 ?? "Uses Apple Intelligence on supported Macs. You can use dictation even when Smart Polish is unavailable.")
                .foregroundStyle(LocalFlowDesign.graphite)
            if let polishProvider {
                TextField("Model ID", text: $polishModelID, prompt: Text(polishProvider.polishModel))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("\(polishProvider.displayName) Smart Polish model ID")
            }
            if polishProvider == .claude {
                Text("Claude polishes text. Use Apple Speech, a local model, or another provider to transcribe audio.")
                    .foregroundStyle(LocalFlowDesign.graphite)
            }

            ForEach(requiredProviders) { provider in
                ProviderKeyEditor(provider: provider).id(provider)
            }
            if usesCloud {
                Toggle("Allow the selected audio / text to be sent to these providers", isOn: $cloudConsent)
                Text("Internet required. Your provider's usage charges and data policies apply. Keys are stored only in this Mac's Keychain.")
                    .font(LocalFlowDesign.generalSans(size: 12))
                    .foregroundStyle(LocalFlowDesign.graphite)
                if settings.hardBlockNetworkAfterModelsDownloaded {
                    Text("Cloud requests are blocked. Turn off the network block in Privacy, or choose on-device options.")
                        .foregroundStyle(LocalFlowDesign.marker)
                }
            }
          }
          .disabled(working)
            if working {
                HStack {
                    if let fraction = manager.progress?.fractionCompleted {
                        ProgressView(manager.progress?.stage ?? "Preparing…", value: fraction)
                    } else {
                        ProgressView(manager.progress?.stage ?? "Preparing your selection…").controlSize(.small)
                    }
                    Button("Cancel") { applyTask?.cancel() }
                }
            }
            if let message {
                Label(message, systemImage: failed ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(failed ? LocalFlowDesign.marker : LocalFlowDesign.signal)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(onboarding ? "Finish setup" : "Apply & prepare") {
                applyTask = Task { await apply() }
            }
            .buttonStyle(.borderedProminent)
            .tint(LocalFlowDesign.signal)
            .disabled(busy || (usesCloud && (!cloudConsent || settings.hardBlockNetworkAfterModelsDownloaded)) || (source == .apple && !appleSpeechEngineIsAvailable()))
        }
        .font(LocalFlowDesign.generalSans(size: 13))
        .foregroundStyle(LocalFlowDesign.ink)
        .onChange(of: source) { _, _ in message = nil; cloudConsent = false }
        .onChange(of: speechProvider) { _, provider in
            message = nil; cloudConsent = false; speechModelID = settings.speechModel(for: provider)
        }
        .onChange(of: polishProvider) { _, provider in
            message = nil; cloudConsent = false; polishModelID = provider.map { settings.polishModel(for: $0) } ?? ""
        }
    }

    @MainActor private func apply() async {
        guard coordinator.canConfigureEngine else { return }
        working = true
        message = nil
        failed = false
        defer { working = false }
        let previous = (settings.dictationSource, settings.modelOverride, settings.transcriptionProvider, settings.polishProvider)
        do {
            for provider in requiredProviders {
                guard try ProviderKeyStore().read(provider) != nil else {
                    throw LocalFlowError.modelUnavailable("Save your \(provider.displayName) key first.")
                }
            }
            settings.dictationSource = source
            settings.modelOverride = tier
            settings.transcriptionProvider = speechProvider
            settings.polishProvider = polishProvider
            if source == .cloud { settings.setSpeechModel(speechModelID, for: speechProvider) }
            if let polishProvider { settings.setPolishModel(polishModelID, for: polishProvider) }
            try await coordinator.prepareModelsWithError()
            message = "Ready — \(coordinator.activeEngineName)"
            onComplete?()
        } catch {
            // Saved settings must keep describing the engine that is still running.
            (settings.dictationSource, settings.modelOverride, settings.transcriptionProvider, settings.polishProvider) = previous
            failed = true
            message = (error is CancellationError || (error as? URLError)?.code == .cancelled)
                ? "Cancelled. Your previous setup is unchanged; finished files are kept for next time."
                : error.localizedDescription
        }
    }
}

struct ProviderKeyEditor: View {
    let provider: CloudProvider
    @State private var key = ""
    @State private var saved = false
    @State private var testing = false
    @State private var message: String?
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(provider.displayName) API key").fontWeight(.medium)
                Spacer()
                Link("Get an API key ↗", destination: provider.keyURL)
            }
            SecureField(saved ? "Key saved · enter a new key to replace it" : "Paste your API key", text: $key)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(provider.displayName) API key")
            HStack {
                Button("Save key") {
                    perform {
                        try ProviderKeyStore().save(key, for: provider)
                        key = ""
                        saved = true
                        message = "Saved in Keychain."
                    }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(testing ? "Checking…" : "Check connection") {
                    testing = true
                    failed = false
                    message = nil
                    Task { @MainActor in
                        defer { testing = false }
                        do {
                            try await CloudAPIClient().validateKey(provider)
                            message = "Key accepted. Model availability and billing are checked when used."
                        } catch { failed = true; message = error.localizedDescription }
                    }
                }.disabled(!saved || !key.isEmpty)
                Button("Remove key", role: .destructive) {
                    perform {
                        try ProviderKeyStore().delete(provider)
                        saved = false
                        key = ""
                        message = "Key removed."
                    }
                }.disabled(!saved)
            }
            if let message {
                Text(message).font(.caption)
                    .foregroundStyle(failed ? LocalFlowDesign.marker : LocalFlowDesign.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(LocalFlowDesign.cardBackground(cornerRadius: 14))
        .disabled(testing)
        .task { perform { saved = try ProviderKeyStore().read(provider) != nil } }
    }
    private func perform(_ operation: () throws -> Void) {
        failed = false
        do { try operation() } catch { failed = true; message = error.localizedDescription }
    }
}
