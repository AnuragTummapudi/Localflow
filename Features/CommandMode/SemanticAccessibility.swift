import AppKit
import ApplicationServices
import Foundation

public struct SemanticUIElement: Codable, Equatable, Sendable {
    public var id: String
    public var role: String
    public var subrole: String
    public var label: String
    public var value: String
    public var enabled: Bool
    public var focused: Bool
    public var selected: Bool
    public var actions: [String]
    public var container: String
    public init(id: String, role: String, subrole: String = "", label: String = "", value: String = "", enabled: Bool = true, focused: Bool = false, selected: Bool = false, actions: [String] = [], container: String = "") {
        self.id = id; self.role = role; self.subrole = subrole; self.label = label; self.value = value; self.enabled = enabled; self.focused = focused; self.selected = selected; self.actions = actions; self.container = container
    }
}
public struct SemanticUIObservation: Codable, Equatable, Sendable {
    public var id: String
    public var application: String
    public var processID: Int32
    public var windows: [String]
    public var elements: [SemanticUIElement]
    public var truncated: Bool
    public init(id: String, application: String, processID: Int32, windows: [String], elements: [SemanticUIElement], truncated: Bool = false) {
        self.id = id; self.application = application; self.processID = processID; self.windows = windows; self.elements = elements; self.truncated = truncated
    }
    public var plannerValue: PlannerValue { (try? JSONDecoder().decode(PlannerValue.self, from: JSONEncoder().encode(self))) ?? .object([:]) }
    public static func decode(_ value: PlannerValue?) -> Self? {
        guard let value else { return nil }; return try? JSONDecoder().decode(Self.self, from: JSONEncoder().encode(value))
    }
}
/// Host-only references live in the backend. These handles never cross the tool boundary.
public struct AccessibilityCapture: Equatable {
    public var application: String
    public var processID: Int32
    public var identity: String
    public var windows: [String]
    public var nodes: [SemanticUIElement]
    public var truncated: Bool
    public var topology: [String] = []
}
@MainActor public protocol AccessibilityBackend {
    var trusted: Bool { get }
    func capture(application: String) throws -> AccessibilityCapture
    func perform(handle: String, action: String, value: String?) throws
}

/// One current observation, bounded lifetime, no UI persistence, no coordinate or keyboard fallback.
@MainActor public final class SemanticAccessibilityService {
    public static var readiness: String { AXIsProcessTrusted() ? "READY" : "ACTION REQUIRED" }
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    private let backend: any AccessibilityBackend
    private let now: () -> Date
    private var current: AccessibilityCapture?
    private var observation: SemanticUIObservation?
    private var expires = Date.distantPast
    private var handles: [String: String] = [:]
    private var grants: [UUID: (NativeToolID, SemanticToolArguments, ToolRisk)] = [:]
    public init(backend: (any AccessibilityBackend)? = nil, now: @escaping () -> Date = Date.init) { self.backend = backend ?? MacAccessibilityBackend(); self.now = now }
    public func invalidate() { current = nil; observation = nil; handles = [:]; grants = [:] }
    public func runningApplications() -> [(name: String, bundleID: String, processID: Int32)] { (backend as? MacAccessibilityBackend)?.runningApplications() ?? [] }
    public var frontmostApplication: String? { (backend as? MacAccessibilityBackend)?.frontmostApplication }
    private func boundedCapture(application: String) throws -> AccessibilityCapture {
        var capture = try backend.capture(application: application)
        capture.truncated = capture.truncated || capture.nodes.count > 80 || capture.windows.count > 8
        capture.windows = Array(capture.windows.prefix(8)).map { String($0.prefix(128)) }
        capture.nodes = Array(capture.nodes.filter { $0.subrole != "AXSecureTextField" && !$0.subrole.lowercased().contains("password") }.prefix(80)).map { node in
            var result = node
            result.label = String(node.label.prefix(128)); result.value = String(node.value.prefix(128))
            result.role = String(node.role.prefix(64)); result.subrole = String(node.subrole.prefix(64)); result.container = String(node.container.prefix(192))
            result.actions = node.actions.filter { ["press", "focus", "select", "setValue", "scroll", "raiseWindow"].contains($0) }
            return result
        }
        return capture
    }
    public func observe(application: String) throws -> SemanticUIObservation {
        try checkPermission()
        let capture = try boundedCapture(application: application)
        return install(capture)
    }
    private func install(_ capture: AccessibilityCapture) -> SemanticUIObservation {
        invalidate(); current = capture; expires = now().addingTimeInterval(30)
        let generation = UUID().uuidString.lowercased()
        var nodes = capture.nodes
        for i in nodes.indices { let id = "ax:\(generation):\(i)"; handles[id] = nodes[i].id; nodes[i].id = id }
        let result = SemanticUIObservation(id: generation, application: capture.application, processID: capture.processID, windows: capture.windows, elements: nodes, truncated: capture.truncated)
        observation = result; return result
    }
    private func checkPermission() throws {
        guard backend.trusted else { invalidate(); throw ToolError.permission("Accessibility") }
    }
    private func target(_ args: SemanticToolArguments) throws -> (SemanticUIElement, String, AccessibilityCapture) {
        try checkPermission()
        guard let old = current, let observation, expires > now(), args.string("app") == old.application,
              let node = observation.elements.first(where: { $0.id == args.string("elementID") }), let handle = handles[node.id] else { throw ToolError.changedTarget }
        let fresh = try boundedCapture(application: old.application)
        guard fresh == old else { invalidate(); throw ToolError.changedTarget }
        guard node.enabled else { throw ToolError.unavailable("This UI element is disabled.") }
        return (node, handle, old)
    }
    public static func risk(for id: NativeToolID, element: SemanticUIElement) -> ToolRisk {
        if [.uiObserve, .uiFocus, .uiScroll, .uiRaiseWindow].contains(id) { return .safe }
        // Labels cannot grant authority. Only structural navigation roles are safe.
        let text = (element.label + " " + element.container).lowercased()
        if ["delete", "purchase", "buy", "send", "submit", "logout", "log out", "sign out", "erase", "security", "privacy", "password", "permission"].contains(where: { text.contains($0) }) { return .consequential }
        if id == .uiSelect || id == .uiPress {
            if element.role == "AXTab" || element.role == "AXRadioButton" && element.container.contains("AXTabGroup") || element.role == "AXRow" && ["AXOutline", "AXList"].contains(where: { element.container.contains($0) }) { return .safe }
            if element.role == "AXMenu" || element.role == "AXMenuBarItem" { return .safe }
        }
        // Arbitrary UI mutations retain confirmation, including ordinary text. No fabricated Undo.
        return .consequential
    }
    public func prepare(_ action: AgentAction) throws -> AgentAction {
        guard action.toolID.isAccessibility, case .semantic(var args) = action.arguments else { throw ToolError.invalidArguments }
        try args.validateShape(for: action.toolID); try checkPermission()
        let risk: ToolRisk
        if action.toolID == .uiObserve { risk = .safe }
        else {
            let (node, _, _) = try target(args)
            guard node.actions.contains(action.toolID.uiAction) else { throw ToolError.unavailable("This semantic action is not supported by the element.") }
            args.preparedUILabel = String(node.label.prefix(64))
            risk = Self.risk(for: action.toolID, element: node)
        }
        grants[action.id] = (action.toolID, args, risk)
        return action.prepared(arguments: .semantic(args))
    }
    public func risk(for action: AgentAction) -> ToolRisk {
        guard let grant = grants[action.id], grant.0 == action.toolID, case .semantic(let args) = action.arguments, args == grant.1 else { return .consequential }
        return grant.2
    }
    public func perform(_ id: NativeToolID, arguments: ToolArguments) async throws -> ToolExecution {
        guard case .semantic(let args) = arguments else { throw ToolError.invalidArguments }
        try args.validateShape(for: id); try Task.checkCancellation()
        if id == .uiObserve {
            let result = try observe(application: args.string("app"))
            return ToolExecution(message: "Looking at \(result.application)", output: .semantic(["observation": result.plannerValue]), verification: .verified)
        }
        let (node, handle, before) = try target(args)
        guard node.actions.contains(id.uiAction) else { throw ToolError.invalidArguments }
        // Recheck a frozen host grant even after the confirmation delay.
        guard grants.values.contains(where: { $0.0 == id && $0.1 == args }) else { throw ToolError.changedTarget }
        let alreadySatisfied = id == .uiFocus && node.focused || id == .uiSelect && node.selected || id == .uiSetValue && node.value == args.string("value") || id == .uiRaiseWindow && node.focused
        if !alreadySatisfied { try backend.perform(handle: handle, action: id.uiAction, value: args.values["value"]?.string ?? args.values["direction"]?.string) }
        invalidate() // Acceptance is a real effect; cancellation cannot undo it or reuse old references.
        try? await Task.sleep(for: .milliseconds(150))
        let fresh: AccessibilityCapture
        do { fresh = try boundedCapture(application: before.application) }
        catch { return ToolExecution(message: "UI action sent; readback unavailable", verification: .unverified("UI readback unavailable")) }
        let after = fresh.nodes.first { $0.id == handle }
        let verified: Bool
        switch id {
        case .uiFocus: verified = after?.focused == true
        case .uiSetValue: verified = after?.value == args.string("value")
        case .uiSelect: verified = after?.selected == true
        case .uiRaiseWindow: verified = after?.focused == true
        case .uiPress:
            verified = (after?.selected == true && !node.selected) || (!node.label.isEmpty && fresh.windows != before.windows && fresh.windows.contains(where: { $0.caseInsensitiveCompare(node.label) == .orderedSame }))
        default: verified = false // Scrolling without readable scroll state is not claimed complete.
        }
        let result = Task.isCancelled ? nil : install(fresh)
        var data: [String: PlannerValue] = ["label": .string(node.label), "role": .string(node.role)]
        if let result { data["observation"] = result.plannerValue }
        if verified { data["verifiedAction"] = .string(id.rawValue) }
        return ToolExecution(message: verified ? "UI action verified" : "UI action sent; completion unverified", output: .semantic(data), verification: verified ? .verified : .unverified("No conclusive semantic readback"))
    }
}

extension NativeToolID {
    public var isAccessibility: Bool { rawValue.hasPrefix("ui.") }
    public var uiAction: String {
        switch self { case .uiFocus: return "focus"; case .uiPress: return "press"; case .uiSetValue: return "setValue"; case .uiSelect: return "select"; case .uiScroll: return "scroll"; case .uiRaiseWindow: return "raiseWindow"; default: return "observe" }
    }
}

@MainActor public final class MacAccessibilityBackend: AccessibilityBackend {
    public var trusted: Bool { AXIsProcessTrusted() }
    private var references: [String: AXUIElement] = [:]
    public init() {}
    public func runningApplications() -> [(name: String, bundleID: String, processID: Int32)] {
        NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map { ($0.localizedName ?? "", $0.bundleIdentifier ?? "", $0.processIdentifier) }
    }
    public var frontmostApplication: String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    private func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    private func string(_ element: AXUIElement, _ name: String) -> String { String(((read(element, name) as? String) ?? "").prefix(128)) }
    private func flag(_ element: AXUIElement, _ name: String) -> Bool { (read(element, name) as? Bool) ?? false }
    private func settable(_ element: AXUIElement, _ name: String) -> Bool { var yes = DarwinBoolean(false); return AXUIElementIsAttributeSettable(element, name as CFString, &yes) == .success && yes.boolValue }
    private func children(_ element: AXUIElement, maximum: Int = 80) -> [AXUIElement] {
        var count = 0
        guard AXUIElementGetAttributeValueCount(element, kAXChildrenAttribute as CFString, &count) == .success, count > 0 else { return [] }
        var array: CFArray?
        guard AXUIElementCopyAttributeValues(element, kAXChildrenAttribute as CFString, 0, min(count, maximum), &array) == .success else { return [] }
        return (array as? [AXUIElement]) ?? []
    }
    private func descendantLabel(_ root: AXUIElement, deadline: Date) -> String {
        var queue: [(AXUIElement, Int)] = [(root, 0)], i = 0
        while i < queue.count, i < 24, Date() < deadline {
            let (element, depth) = queue[i]; i += 1
            if string(element, kAXSubroleAttribute) == "AXSecureTextField" { continue }
            if string(element, kAXRoleAttribute) == "AXStaticText" {
                let value = string(element, kAXValueAttribute); if !value.isEmpty { return value }
            }
            if depth < 4 { queue.append(contentsOf: children(element, maximum: 6).map { ($0, depth + 1) }) }
        }
        return ""
    }
    public func capture(application: String) throws -> AccessibilityCapture {
        guard trusted else { throw ToolError.permission("Accessibility") }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == application || $0.localizedName == application }), !app.isTerminated else { references = [:]; throw ToolError.unavailable("Application is not running.") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.15)
        var windowValue: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowValue)
        guard error == .success, let windows = windowValue as? [AXUIElement] else { references = [:]; throw ToolError.unavailable("Application exposes no accessible windows (\(error.rawValue)).") }
        let old = references; var refs: [String: AXUIElement] = [:], nodes: [SemanticUIElement] = [], topology: [String] = []
        let end = Date().addingTimeInterval(2), focusedWindow = read(root, kAXFocusedWindowAttribute)
        var queue = windows.prefix(8).sorted { a, b in
            let af = focusedWindow.map { CFEqual($0, a) } == true
            let bf = focusedWindow.map { CFEqual($0, b) } == true
            return af && !bf
        }.map { ($0, 0, "", false) }
        if let menu = read(root, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() { queue.append((unsafeBitCast(menu, to: AXUIElement.self), 0, "", false)) }
        var index = 0, visited: [AXUIElement] = [], truncated = windows.count > 8
        while index < queue.count, index < 400, Date() < end {
            let (element, depth, container, inheritedSecure) = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, element) }) { continue }; visited.append(element)
            let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
            let secure = inheritedSecure || subrole == "AXSecureTextField" || subrole.lowercased().contains("password")
            var children = self.children(element)
            let nativeHandle = old.first(where: { CFEqual($0.value, element) })?.key ?? UUID().uuidString
            refs[nativeHandle] = element
            topology.append(String(index) + ":" + role + ":" + subrole + ":" + String(children.count))
            // Closed menu contents are not current actionable UI.
            if role == "AXMenuBarItem" && !flag(element, kAXSelectedAttribute) && !flag(element, "AXExpanded") { children = [] }
            var label = string(element, kAXTitleAttribute)
            if label.isEmpty { label = string(element, kAXDescriptionAttribute) }
            if label.isEmpty, ["AXRow", "AXButton", "AXRadioButton", "AXTab"].contains(role) { label = descendantLabel(element, deadline: end) }
            var actionNames: CFArray?; AXUIElementCopyActionNames(element, &actionNames)
            let nativeActions = (actionNames as? [String]) ?? []
            var actions: [String] = []
            if nativeActions.contains(kAXPressAction) { actions.append("press") }
            if nativeActions.contains(kAXRaiseAction) { actions.append("raiseWindow") }
            if settable(element, kAXFocusedAttribute) { actions.append("focus") }
            if settable(element, kAXSelectedAttribute) { actions.append("select") }
            if !secure && ["AXTextField", "AXTextArea", "AXComboBox"].contains(role) && settable(element, kAXValueAttribute) { actions.append("setValue") }
            if nativeActions.contains("AXScrollDown") || nativeActions.contains("AXScrollUp") { actions.append("scroll") }
            if !secure && (!actions.isEmpty || role == "AXWindow" || ["AXTab", "AXRow", "AXMenu"].contains(role)), nodes.count < 80 {
                let handle = nativeHandle
                refs[handle] = element
                let focus = role == "AXWindow" ? app.isActive && focusedWindow.map { CFEqual($0, element) } == true : flag(element, kAXFocusedAttribute)
                let value = ["AXTextField", "AXTextArea", "AXComboBox", "AXCheckBox", "AXRadioButton"].contains(role) ? string(element, kAXValueAttribute) : ""
                nodes.append(.init(id: handle, role: role, subrole: subrole, label: String(label.prefix(128)), value: value, enabled: (read(element, kAXEnabledAttribute) as? Bool) ?? true, focused: focus, selected: flag(element, kAXSelectedAttribute), actions: actions, container: String((container + " " + role).suffix(192))))
            }
            if depth < 12 { queue.insert(contentsOf: children.prefix(80).map { ($0, depth + 1, String((container + " " + role).suffix(192)), secure) }, at: index) }
            else if !children.isEmpty { truncated = true }
        }
        truncated = truncated || index < queue.count || nodes.count >= 80
        references = refs
        return AccessibilityCapture(application: application, processID: app.processIdentifier, identity: "\(app.processIdentifier):\(app.launchDate?.timeIntervalSince1970 ?? 0)", windows: windows.prefix(8).map { string($0, kAXTitleAttribute) }, nodes: nodes, truncated: truncated, topology: topology)
    }
    public func perform(handle: String, action: String, value: String?) throws {
        guard trusted, let element = references[handle] else { throw ToolError.changedTarget }
        let error: AXError
        switch action {
        case "press": error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case "raiseWindow":
            error = AXUIElementPerformAction(element, kAXRaiseAction as CFString)
            if error == .success { var pid: pid_t = 0; if AXUIElementGetPid(element, &pid) == .success { _ = NSRunningApplication(processIdentifier: pid)?.activate(options: []) } }
        case "focus": error = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        case "select": error = AXUIElementSetAttributeValue(element, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        case "setValue": error = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, (value ?? "") as CFString)
        case "scroll":
            guard ["up", "down"].contains(value ?? "") else { throw ToolError.invalidArguments }
            error = AXUIElementPerformAction(element, (value == "up" ? "AXScrollUp" : "AXScrollDown") as CFString)
        default: throw ToolError.invalidArguments
        }
        guard error == .success else { throw ToolError.unavailable("Accessibility action failed (\(error.rawValue)).") }
    }
}
