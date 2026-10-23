import AppKit
import SwiftUI
import Combine
import Shared
import ModelManager
import Engines

/// First-run onboarding for permissions and Apple-managed Speech assets on macOS 26+.
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
    @ObservedObject private var manager = ModelManager.shared
    @State private var isWorking = false
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple Speech · macOS 26+").font(LocalFlowDesign.instrumentSerif(size: 26))
            Text("Apple installs and manages the required speech assets. After setup, speech recognition runs entirely on this Mac.")
            SpeechLocalePicker { }
            Text(manager.speechReadiness.detail)
            if let progress = manager.progress {
                ProgressView(value: progress.fractionCompleted)
                Text(progress.stage).font(.caption)
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            Button(manager.modelsAvailable ? "Continue" : "Set up Apple Speech") {
                Task {
                    isWorking = true; errorMessage = nil
                    do {
                        try await coordinator.prepareModelsWithError()
                        LocalFlowSettings.shared.didCompleteOnboarding = true
                        NSApp.keyWindow?.close()
                    } catch { errorMessage = error.localizedDescription }
                    isWorking = false
                }
            }.buttonStyle(.borderedProminent).disabled(isWorking || manager.speechReadiness.status == .unavailable)
        }.padding(36).task { await manager.refreshReadiness() }
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
