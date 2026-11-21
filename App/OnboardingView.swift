import AppKit
import SwiftUI
import Combine
import Shared
import ModelManager
import Engines

/// First-run permissions, processing choice, and provider/model setup.
public struct OnboardingView: View {
    @EnvironmentObject private var coordinator: DictationCoordinator
    @State private var step: Step = LocalFlowSettings.shared.didPlayLaunchAnimation ? .microphone : .logo

    @State private var chosenSource = LocalFlowSettings.shared.dictationSource

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
                    message: "LocalFlow captures audio while you hold the hotkey or use hands-free mode. Next, choose on-device or cloud processing.",
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
                    step = .source
                }
            case .source:
                VStack(alignment: .leading, spacing: 14) {
                    Text("Your voice. Your choice.")
                        .font(LocalFlowDesign.instrumentSerif(size: 28))
                    Text("Choose how LocalFlow transcribes. Smart Polish comes next.")
                        .font(LocalFlowDesign.generalSans(size: 13))
                        .foregroundStyle(LocalFlowDesign.graphite)
                    sourceOption(.apple, icon: "apple.logo", detail: "Built into macOS 26+. No API key. Audio stays on this Mac.")
                    sourceOption(.local, icon: "desktopcomputer", detail: "Download Parakeet or Whisper once, then dictate on-device.")
                    sourceOption(.cloud, icon: "key", detail: "Use your Groq, OpenAI, or Gemini key. Internet and provider usage apply.")
                }
                .padding(32)
            case .model:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Button("← Back to processing options") { step = .source }
                            .buttonStyle(.plain)
                            .foregroundStyle(LocalFlowDesign.signal)
                        SourceConfigurationView(onboarding: true, initialSource: chosenSource) {
                            LocalFlowSettings.shared.didCompleteOnboarding = true
                            NSApp.keyWindow?.close()
                        }
                    }
                    .padding(32)
                }
            }
        }
        .frame(width: LocalFlowDesign.onboardingSize.width, height: LocalFlowDesign.onboardingSize.height)
        .background(LocalFlowDesign.canvas)
        .foregroundStyle(LocalFlowDesign.ink)
    }

    private func sourceOption(_ source: DictationSource, icon: String, detail: String) -> some View {
        Button {
            chosenSource = source
            step = .model
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).frame(width: 24)
                    .foregroundStyle(LocalFlowDesign.signal)
                VStack(alignment: .leading, spacing: 4) {
                    Text(source.displayName).font(LocalFlowDesign.generalSans(size: 14, weight: .medium))
                    Text(detail).font(LocalFlowDesign.generalSans(size: 12))
                        .foregroundStyle(LocalFlowDesign.graphite)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LocalFlowDesign.cardBackground(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source == .apple && !appleSpeechEngineIsAvailable())
    }

    private enum Step {
        case logo
        case microphone
        case accessibility
        case source
        case model
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
