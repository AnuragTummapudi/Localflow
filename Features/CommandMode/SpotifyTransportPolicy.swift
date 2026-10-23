import Foundation

/// Pure verification/Undo policy over the existing native Spotify readback.
enum SpotifyTransportPolicy {
    static func verified(_ action: SpotifyPlaybackAction, before: SpotifyPlaybackSnapshot?, after: SpotifyPlaybackSnapshot?) -> Bool {
        guard let after else { return false }
        switch action {
        case .pause: return after.state.caseInsensitiveCompare("paused") == .orderedSame
        case .resume: return after.isPlaying
        case .next, .previous:
            guard let priorID = before?.trackIdentifier, !priorID.isEmpty, let newID = after.trackIdentifier, !newID.isEmpty else { return false }
            return priorID != newID
        }
    }
    static func undoAction(_ action: SpotifyPlaybackAction, before: SpotifyPlaybackSnapshot, after: SpotifyPlaybackSnapshot) -> SpotifyPlaybackAction? {
        guard let id = before.trackIdentifier, !id.isEmpty, after.trackIdentifier == id else { return nil }
        switch action {
        case .pause where before.isPlaying && after.state.caseInsensitiveCompare("paused") == .orderedSame: return .resume
        case .resume where before.state.caseInsensitiveCompare("paused") == .orderedSame && after.isPlaying: return .pause
        default: return nil
        }
    }
}
