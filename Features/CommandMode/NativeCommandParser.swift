import Foundation

public extension CommandIntent {
    var agentAction: AgentAction {
        switch self {
        case .nativeAction(let action): return action
        case .openApplication(let app): return AgentAction(toolID: .openApplication, arguments: .application(app))
        case .switchToApplication(let app): return AgentAction(toolID: .focusApplication, arguments: .application(app))
        case .quitApplication(let app): return AgentAction(toolID: .quitApplication, arguments: .application(app))
        case .mute: return AgentAction(toolID: .mute, arguments: .none)
        case .unmute: return AgentAction(toolID: .unmute, arguments: .none)
        case .sleepDisplay: return AgentAction(toolID: .sleepDisplay, arguments: .none)
        case .lockScreen: return AgentAction(toolID: .lockMac, arguments: .none)
        case .spotifyControl(let action): return AgentAction(toolID: .spotifyTransport, arguments: .spotify(action))
        // Preserve the proven resolved URL, including custom providers and Spotify's search-results route.
        case .spotifySearchAndPlay(_, let url), .openURL(let url), .searchWeb(_, _, let url): return AgentAction(toolID: .openURL, arguments: .url(url))
        }
    }
}

/// Conservative, anchored commands. Unrecognized/ambiguous speech continues through existing dictation.
public enum NativeCommandParser {
    public static func parse(_ raw: String, registry: SearchProviderRegistry = .shared) -> AgentAction? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let phrase = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        switch phrase {
        case "mute volume": return AgentAction(toolID: .mute, arguments: .none)
        case "volume up": return AgentAction(toolID: .volumeUp, arguments: .volume(10))
        case "volume down": return AgentAction(toolID: .volumeDown, arguments: .volume(10))
        case "take a screenshot", "take screenshot": return AgentAction(toolID: .screenshot, arguments: .screenshot())
        default: break
        }
        if phrase.hasPrefix("set volume to ") {
            let value = phrase.dropFirst("set volume to ".count).replacingOccurrences(of: " percent", with: "").replacingOccurrences(of: "%", with: "")
            if let percent = Int(value), (0...100).contains(percent) { return AgentAction(toolID: .setVolume, arguments: .volume(percent)) }
            return nil
        }
        // Use explicit prefixes; preserve the exact payload, including terminal punctuation.
        let prefixes: [(String, NativeToolID)] = [
            ("type at cursor ", .typeText), ("replace selected text with ", .replaceSelection),
            ("copy to clipboard ", .copyText), ("create reminder ", .createReminder),
            ("create a reminder ", .createReminder),
            ("create note ", .createNote), ("append to current note ", .appendNote),
            ("append to the current note ", .appendNote),
            ("write current note ", .writeNote), ("reveal in finder ", .revealFile)
        ]
        for (prefix, id) in prefixes {
            // ASR may place a comma/period between a complete command header and
            // its payload. Accept that boundary without altering payload contents.
            let header = NSRegularExpression.escapedPattern(for: prefix.trimmingCharacters(in: .whitespaces))
            // In create-note syntax, ':' separates title/body; consuming it here
            // would turn a missing title into a different successful command.
            let punctuation = id == .createNote ? "[,.]" : "[,.:]"
            guard let range = text.range(of: "(?i)^" + header + "(?:\\s*" + punctuation + "\\s*|\\s+)", options: .regularExpression) else { continue }
            let payload = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return nil }
            let arguments: ToolArguments
            switch id {
            case .typeText, .copyText: arguments = .text(payload)
            case .replaceSelection: arguments = .selection(payload)
            case .createReminder: arguments = .reminder(title: payload)
            case .createNote:
                // "create note Title: Body"; absent separator, the exact payload is the title.
                let parts = payload.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                arguments = .note(title: String(parts[0]).trimmingCharacters(in: .whitespaces), body: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "")
            case .appendNote, .writeNote: arguments = .currentNote(payload)
            case .revealFile:
                // No path guesses, recursive search, or terminal expansion beyond an explicit home prefix.
                let path = (payload as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { return nil }
                arguments = .file(URL(fileURLWithPath: path))
            default: return nil
            }
            guard (try? arguments.validate(for: id)) != nil else { return nil }
            return AgentAction(toolID: id, arguments: arguments)
        }
        return nil
    }
}

public extension AgentAction {
    var summary: String {
        switch arguments {
        case .application(let app, _): return "\(toolID.description): \(app.name)"
        case .url(let url): return "\(toolID.description): \(url.host ?? url.absoluteString)"
        case .search(let query, let provider): return "Search \(provider): \(query.prefix(80))"
        case .website(let domain): return "Open \(domain)"
        case .text(let text, _), .selection(let text, _), .currentNote(let text, _): return "\(toolID.description): \(text.prefix(80))"
        case .volume(let value): return "\(toolID.description): \(value)%"
        case .reminder(let title, _, _), .note(let title, _): return "\(toolID.description): \(title.prefix(80))"
        case .file(let url): return "Reveal \(url.lastPathComponent)"
        case .semantic(let args):
            if toolID.isAccessibility {
                if toolID == .uiObserve { return "Looking at application…" }
                if let label = args.preparedUILabel, !label.isEmpty { return "\(toolID.description): \(label)" }
                return "Updating application UI…"
            }
            switch toolID {
            case .projectResolve: return "Finding \(args.string("name"))…"
            case .projectOpen, .editorOpenProject: return "Opening \(args.string("project"))…"
            case .projectOpenFile, .fileOpen, .editorOpenFile: return "Opening \(URL(fileURLWithPath: args.string("path")).lastPathComponent)…"
            case .projectSearch, .fileSearch, .editorRevealSymbol: return "Searching project…"
            case .workflowRun: return "Starting \(args.string("workflowName"))…"
            case .workflowStop: return "Stopping \(args.string("workflowName"))…"
            case .workflowList: return "Checking saved workflows…"
            case .serviceWait: return "Waiting for localhost…"
            case .serviceStatus: return "Checking localhost…"
            case .projectReveal, .fileReveal: return "Revealing project…"
            default: return toolID.description
            }
        default: return toolID.description
        }
    }
}
