import Foundation

/// Goal atoms and app authority come exclusively from the initiating request and frozen foreground app.
public struct SemanticUIGoal: Codable, Equatable, Sendable {
    public let application: String
    public let applicationName: String
    public let openRequested: Bool
    public let action: String
    public let label: String
    public let value: String?
    public let direction: String?
    public init?(goal: String, frontmostApplication: String?) {
        let lower = goal.lowercased()
        let named: (String, String)? = lower.contains("system settings") ? ("com.apple.systempreferences", "System Settings") : lower.contains("finder") ? ("com.apple.finder", "Finder") : nil
        let uiIntent = named != nil || lower.contains("search field") || lower.contains(" tab") || lower.hasPrefix("scroll ") || lower.hasPrefix("raise ") || lower.hasPrefix("focus the window")
        guard uiIntent else { return nil }
        guard ["open ", "observe ", "inspect ", "show ", "select ", "focus ", "raise ", "set search", "scroll ", "go to "].contains(where: { lower.hasPrefix($0) }), !["enable ", "disable ", "security change", "grant permission"].contains(where: { lower.contains($0) }) else { return nil }
        let supportedForeground = ["com.apple.systempreferences": "System Settings", "com.apple.finder": "Finder"]
        let foreground = frontmostApplication.flatMap { bundle in supportedForeground[bundle].map { (bundle, $0) } }
        guard let app = named ?? foreground else { return nil }
        application = app.0; applicationName = app.1; openRequested = lower.hasPrefix("open ")
        let text = lower.contains("set ") && lower.contains(" to ") ? goal.components(separatedBy: " to ").last : nil
        guard text.map({ !$0.isEmpty && $0.utf8.count <= 128 && !$0.contains("\0") }) ?? true else { return nil }
        value = text
        direction = lower.hasPrefix("scroll ") ? (lower.contains("up") ? "up" : "down") : nil
        if value != nil { action = "setValue"; label = "search" }
        else if lower.contains("focus") && lower.contains("search field") { action = "focus"; label = "search" }
        else if lower.contains("accessibility") { action = "navigate"; label = "Accessibility" }
        else if lower.contains("downloads") { action = "navigate"; label = "Downloads" }
        else if lower.contains("general") && lower.contains("tab") { action = "navigate"; label = "General" }
        else if direction != nil { action = "scroll"; label = "" }
        else if lower.contains("raise") || lower.contains("focus the window") { action = "raiseWindow"; label = "" }
        else {
            guard lower.hasPrefix("observe ") || lower.hasPrefix("inspect ") || lower == "open " + app.1.lowercased() else { return nil }
            action = "observe"; label = ""
        }
    }
    private func matches(_ element: SemanticUIElement) -> Bool {
        label.isEmpty || (action == "navigate" ? element.label.caseInsensitiveCompare(label) == .orderedSame : element.label.localizedCaseInsensitiveContains(label)) || label == "search" && element.subrole == "AXSearchField"
    }
    public func allows(_ id: NativeToolID, element: SemanticUIElement) -> Bool {
        guard element.enabled, element.actions.contains(id.uiAction) else { return false }
        let target = matches(element)
        switch action {
        case "navigate": return target && [.uiPress, .uiSelect].contains(id) && ["AXRow", "AXTab", "AXRadioButton", "AXButton", "AXMenuItem"].contains(element.role)
        case "focus": return target && id == .uiFocus && ["AXTextField", "AXComboBox"].contains(element.role)
        case "setValue": return target && id == .uiSetValue && ["AXTextField", "AXComboBox"].contains(element.role)
        case "raiseWindow": return id == .uiRaiseWindow && element.role == "AXWindow"
        case "scroll": return id == .uiScroll
        default: return false
        }
    }
    public func satisfied(by receipts: [PlannerResult]) -> Bool {
        if openRequested && !receipts.contains(where: { $0.tool == "application.open" && ["verified", "unverified"].contains($0.status) && $0.arguments["application"]?.string == applicationName }) { return false }
        let relevant = receipts.filter { $0.status == "verified" && $0.arguments["app"]?.string == application }
        if action == "observe" { return relevant.contains { $0.tool == "ui.observe" } }
        if let latest = relevant.last, let observation = SemanticUIObservation.decode(latest.data["observation"]), observation.application == application {
            if observation.elements.contains(where: { element in
                switch action {
                case "navigate": return matches(element) && ["AXRow", "AXTab", "AXRadioButton"].contains(element.role) && element.selected
                case "focus": return matches(element) && ["AXTextField", "AXComboBox"].contains(element.role) && element.focused
                case "setValue": return matches(element) && ["AXTextField", "AXComboBox"].contains(element.role) && element.value == value
                case "raiseWindow": return element.role == "AXWindow" && element.focused
                default: return false
                }
            }) { return true }
        }
        // Only native readback of the requested action and target can satisfy an atom.
        return relevant.contains { r in
            guard let id = NativeToolID(rawValue: r.tool), r.data["verifiedAction"]?.string == r.tool else { return false }
            if action == "navigate" { return [.uiPress, .uiSelect].contains(id) && r.data["label"]?.string?.localizedCaseInsensitiveContains(label) == true }
            if action == "setValue" { return id == .uiSetValue && r.arguments["value"]?.string == value }
            return id.uiAction == action
        }
    }
}
