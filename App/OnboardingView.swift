import AppKit
import SwiftUI
import Combine
import Shared
import ModelManager
import Engines

/// First-run onboarding for permissions and Apple Speech (optional local fallback).
public struct OnboardingView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var step: Step = LocalFlowSettings.shared.didPlayLaunchAnimation ? .microphone : .logo

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            switch step {
            case .logo:
                LaunchLogoView {
                    step = .microphone
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .microphone:
                PermissionStepView(
                    title: "Microphone Access",
                    message: "LocalFlow listens only while you hold the hotkey. Audio stays on this Mac.",
                    supportingDetail: "Double-tap either key anytime for hands-free — no holding required.",
                    buttonTitle: "Allow Microphone"
                ) {
                    Task {
                        _ = await coordinator.requestMicrophonePermission()
                        step = .accessibility
                    }
                }
            case .accessibility:
                PermissionStepView(
                    title: "Accessibility Access",
                    message: "LocalFlow needs Accessibility permission to insert transcribed text into the app you are already using.",
                    buttonTitle: "Open Accessibility Prompt"
                ) {
                    _ = coordinator.requestAccessibilityPermission()
                    step = .model
                }
            case .model:
                SpeechReadyStepView()
            }
        }
        .frame(width: LocalFlowDesign.onboardingSize.width, height: LocalFlowDesign.onboardingSize.height)
        .background(LocalFlowDesign.canvas)
        .foregroundStyle(LocalFlowDesign.ink)
    }

    private enum Step {
        case logo
        case microphone
        case accessibility
        case model
    }
}

// MARK: - Speech ready step (Apple Speech primary)

private struct SpeechReadyStepView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @ObservedObject private var modelManager = ModelManager.shared

    @State private var isWorking = false
    @State private var statusMessage = "Ready to enable Apple Speech"
    @State private var errorMessage: String?
    @State private var appleReady = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(appleSpeechEngineIsAvailable() ? "Enable Apple Speech" : "Prepare Local Model")
                .font(LocalFlowDesign.instrumentSerif(size: 26))
                .foregroundStyle(LocalFlowDesign.ink)

            if appleSpeechEngineIsAvailable() {
                Text("You're on macOS 26 — LocalFlow uses Apple's built-in on-device SpeechAnalyzer. No Hugging Face download is required to start dictating.")
                    .font(LocalFlowDesign.generalSans(size: 14))
                    .foregroundStyle(LocalFlowDesign.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This Mac needs a local speech model (Parakeet or Whisper). This is the only network step.")
                    .font(LocalFlowDesign.generalSans(size: 14))
                    .foregroundStyle(LocalFlowDesign.graphite)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isWorking || modelManager.progress != nil {
                let fraction = modelManager.progress?.fractionCompleted ?? (isWorking ? 0.15 : 0)
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(LocalFlowDesign.signal)
                Text(modelManager.progress?.stage ?? statusMessage)
                    .font(LocalFlowDesign.generalSans(size: 12))
                    .foregroundStyle(LocalFlowDesign.graphite)
            } else {
                Text(statusMessage)
                    .font(LocalFlowDesign.generalSans(size: 12))
                    .foregroundStyle(LocalFlowDesign.graphite)
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.red.opacity(0.07))
                )
            }

            HStack(spacing: 12) {
                Button(appleSpeechEngineIsAvailable() ? (appleReady ? "Continue" : "Enable Apple Speech") : "Download Model") {
                    Task { await primaryAction() }
                }
                .buttonStyle(.borderedProminent)
                .tint(LocalFlowDesign.signal)
                .disabled(isWorking)

                if appleSpeechEngineIsAvailable() {
                    Button("Also download Parakeet (optional)") {
                        Task { await downloadParakeetOptional() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isWorking)
                }

                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if appleSpeechEngineIsAvailable() {
                Text("Parakeet is an optional local fallback. Download it later anytime in Settings → General.")
                    .font(LocalFlowDesign.generalSans(size: 11))
                    .foregroundStyle(LocalFlowDesign.graphite.opacity(0.85))
            }
        }
        .padding(36)
        .task {
            appleReady = await appleSpeechModelIsInstalled()
            if appleReady {
                statusMessage = "Apple Speech is already installed on this Mac."
            }
        }
    }

    private func primaryAction() async {
        if appleReady {
            await finishWithAppleSpeech()
            return
        }
        isWorking = true
        errorMessage = nil
        statusMessage = appleSpeechEngineIsAvailable()
            ? "Installing Apple Speech assets…"
            : "Downloading local model…"
        do {
            try await coordinator.prepareModelsWithError()
            LocalFlowSettings.shared.didCompleteOnboarding = true
            NSApp.keyWindow?.close()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    private func finishWithAppleSpeech() async {
        isWorking = true
        errorMessage = nil
        do {
            try await coordinator.prepareModelsWithError()
            LocalFlowSettings.shared.didCompleteOnboarding = true
            NSApp.keyWindow?.close()
        } catch {
            errorMessage = error.localizedDescription
            isWorking = false
        }
    }

    private func downloadParakeetOptional() async {
        isWorking = true
        errorMessage = nil
        statusMessage = "Downloading Parakeet fallback…"
        do {
            try await ModelManager.shared.downloadModel(.parakeetTDT)
            try await coordinator.prepareModelsWithError()
            statusMessage = "Parakeet downloaded. You can continue."
            appleReady = true
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

// MARK: - Permission step

public struct PermissionStepView: View {
    public var title: String
    public var message: String
    public var supportingDetail: String? = nil
    public var buttonTitle: String
    public var action: () -> Void

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(LocalFlowDesign.instrumentSerif(size: 26))
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(LocalFlowDesign.generalSans(size: 14))
                    .foregroundStyle(LocalFlowDesign.graphite)
                    .fixedSize(horizontal: false, vertical: true)
                if let supportingDetail {
                    Text(supportingDetail)
                        .font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .tint(LocalFlowDesign.signal)
        }
        .padding(36)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
