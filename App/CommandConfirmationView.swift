import SwiftUI
import CommandMode

/// A small confirmation popover for low-confidence voice commands.
public struct CommandConfirmationView: View {
    /// The command awaiting confirmation.
    public let intent: CommandIntent

    /// Called when the user confirms.
    public let confirm: () -> Void

    /// Called when the user cancels.
    public let cancel: () -> Void

    /// The view body.
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Confirm Command")
                .font(.headline)
            Text(description)
                .foregroundStyle(LocalFlowDesign.graphite)
            HStack {
                Button("Cancel", action: cancel)
                Button("Run", action: confirm)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 300)
        .background(LocalFlowDesign.canvas)
        .foregroundStyle(LocalFlowDesign.ink)
    }

    private var description: String {
        switch intent {
        case .openApplication(let match): "Open \(match.name)?"
        case .quitApplication(let match): "Quit \(match.name)?"
        case .switchToApplication(let match): "Switch to \(match.name)?"
        case .mute: "Mute system audio?"
        case .unmute: "Unmute system audio?"
        case .sleepDisplay: "Sleep the display?"
        case .lockScreen: "Lock this Mac?"
        case .spotifyControl(let action):
            switch action {
            case .resume: "Resume Spotify?"
            case .pause: "Pause Spotify?"
            case .next: "Skip to Spotify's next track?"
            case .previous: "Go to Spotify's previous track?"
            }
        case .spotifySearchAndPlay(let query, _): "Search Spotify for \"\(query)\"?"
        case .openURL(let url): "Open \(url.absoluteString)?"
        case .searchWeb(let query, let provider, _): "Search \(provider) for \"\(query)\"?"
        }
    }
}
