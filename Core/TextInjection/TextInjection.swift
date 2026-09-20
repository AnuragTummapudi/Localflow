import AppKit
import ApplicationServices
import Carbon
import Foundation
import Shared

/// The outcome of attempting text injection into a target application.
public enum TextInjectionOutcome: Equatable, Sendable {
    /// Text was successfully injected into a focused text field.
    case inserted
    /// No focused or editable text target was found.
    case noFocusedTarget
}

/// Inserts text into the focused field of a target application.
///
/// Strategy (proven reliable for Notes / Electron / Chromium on macOS 26):
/// 1. Activate the app that was frontmost when dictation started (not LocalFlow/Settings).
/// 2. Try Accessibility insert, but **verify** the field value actually changed
///    (many apps return AX success without inserting).
/// 3. Fall back to clipboard + ⌘V posted at the annotated session tap
///    (`.cghidEventTap` is silently dropped on newer macOS for some apps).
public final class TextInjection {
    /// Creates a text injection service.
    public init() {}

    /// Returns whether the process is trusted for Accessibility API use.
    public func isAccessibilityTrusted(prompt: Bool = false) -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Inserts text into `targetApp` (or the current frontmost app).
    ///
    /// - Parameters:
    ///   - text: The transcript to insert.
    ///   - targetApp: The app that was frontmost when the user started holding the hotkey.
    /// - Returns: Whether the text was inserted or no focused target was found.
    @discardableResult
    public func insert(_ text: String, into targetApp: NSRunningApplication? = nil) async throws -> TextInjectionOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .inserted }

        var trusted = isAccessibilityTrusted(prompt: false)
        if !trusted {
            // Show the system Accessibility prompt once, then open Settings if still denied.
            trusted = isAccessibilityTrusted(prompt: true)
        }

        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "E",
            location: "TextInjection.swift:insert",
            message: "insert begin",
            data: [
                "textLen": trimmed.count,
                "targetBundle": targetApp?.bundleIdentifier ?? "nil",
                "targetPID": Int(targetApp?.processIdentifier ?? -1),
                "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil",
                "axTrusted": trusted
            ]
        )
        // #endregion

        guard trusted else {
            openAccessibilitySettings()
            // Keep transcript on clipboard so the user can ⌘V manually.
            let pasteboard = NSPasteboard.general
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(trimmed, forType: .string)
            throw LocalFlowError.accessibilityPermissionMissing
        }

        await activateTargetIfNeeded(targetApp)
        await waitForModifiersToClear()

        // Electron and Chromium apps often expose their editor as an opaque AXGroup,
        // even when the caret is visibly active. That makes AX role detection a useful
        // hint, but not a gate for normal Cmd+V insertion. Once the app captured at
        // hotkey-down is frontmost, use the standard paste path for both native and
        // opaque editors (Cursor, Codex, ChatGPT, and browser chats).
        let hasObservableTextTarget = hasFocusedTextTarget(preferredPID: targetApp?.processIdentifier)
        AgentDebugLog.write(
            hypothesisId: "E",
            location: "TextInjection.swift:insert",
            message: hasObservableTextTarget ? "focused text target observed" : "focused target opaque; using clipboard paste",
            data: [
                "targetBundle": targetApp?.bundleIdentifier ?? "nil",
                "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            ]
        )

        do {
            try await paste(trimmed)
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "D",
                location: "TextInjection.swift:insert",
                message: "clipboard paste posted (fast path)",
                data: [
                    "frontBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
                ]
            )
            // #endregion
            return .inserted
        } catch {
            if insertViaAccessibility(trimmed, preferredPID: targetApp?.processIdentifier) {
                return .inserted
            }
            throw error
        }
    }

    /// Replaces recent text with polished text in the target application in-place.
    /// - If the user explicitly highlighted text, replaces the selection.
    /// - If no text was highlighted, matches the unpolished text in the field to replace it without duplicating.
    @discardableResult
    public func replace(recent: String, with polished: String, hadExplicitSelection: Bool, in targetApp: NSRunningApplication? = nil) async throws -> TextInjectionOutcome {
        let trimmedPolished = polished.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPolished.isEmpty else { return .inserted }

        // If user explicitly highlighted text, inserting directly replaces the selection
        if hadExplicitSelection {
            return try await insert(trimmedPolished, into: targetApp)
        }

        var trusted = isAccessibilityTrusted(prompt: false)
        if !trusted {
            trusted = isAccessibilityTrusted(prompt: true)
        }
        guard trusted else {
            return try await insert(trimmedPolished, into: targetApp)
        }

        await activateTargetIfNeeded(targetApp)
        await waitForModifiersToClear()

        guard let element = focusedElement(preferredPID: targetApp?.processIdentifier) else {
            return try await insert(trimmedPolished, into: targetApp)
        }

        let beforeValue = axString(element, attribute: kAXValueAttribute as String)
        let trimmedRecent = recent.trimmingCharacters(in: .whitespacesAndNewlines)

        // Case 1: The field's entire text equals the recent dictation (or only differs by whitespace)
        if let before = beforeValue,
           (before.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedRecent || before == recent) {
            try postSelectAll()
            try await Task.sleep(nanoseconds: 20_000_000)
            try await paste(trimmedPolished)
            return .inserted
        }

        // Case 2: Field ends with the recent text
        if let before = beforeValue, before.hasSuffix(recent) || before.hasSuffix(trimmedRecent) {
            let match = before.hasSuffix(recent) ? recent : trimmedRecent
            let loc = (before as NSString).length - (match as NSString).length
            let len = (match as NSString).length
            var rangeValue = CFRange(location: loc, length: len)
            if let axValue = AXValueCreate(.cfRange, &rangeValue) {
                _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            try await paste(trimmedPolished)
            return .inserted
        }

        // Case 3: Recent text is found anywhere in the field
        if let before = beforeValue, !before.isEmpty {
            let nsBefore = before as NSString
            let range = nsBefore.range(of: trimmedRecent, options: .backwards)
            if range.location != NSNotFound {
                var rangeValue = CFRange(location: range.location, length: range.length)
                if let axValue = AXValueCreate(.cfRange, &rangeValue) {
                    _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axValue)
                    try await Task.sleep(nanoseconds: 15_000_000)
                }
                try await paste(trimmedPolished)
                return .inserted
            }
        }

        // Default fallback: standard insert
        return try await insert(trimmedPolished, into: targetApp)
    }

    /// Returns whether the target application or system currently has a focused, editable text target.
    public func hasFocusedTextTarget(preferredPID: pid_t?) -> Bool {
        guard let element = focusedElement(preferredPID: preferredPID) else {
            return false
        }
        return isEditableTextElement(element)
    }

    /// Retrieves currently selected/highlighted text in the target application or system focus.
    public func selectedText(preferredPID: pid_t? = nil) -> String? {
        guard let element = focusedElement(preferredPID: preferredPID) else { return nil }
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedValue) == .success,
           let text = selectedValue as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return nil
    }

    /// Determines if an accessibility element is an editable text field.
    public func isEditableTextElement(_ element: AXUIElement) -> Bool {
        let role = axString(element, attribute: kAXRoleAttribute as String) ?? ""
        let subrole = axString(element, attribute: kAXSubroleAttribute as String) ?? ""

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]

        if textRoles.contains(role) {
            var enabledRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledRef) == .success,
               let enabled = enabledRef as? Bool, !enabled {
                return false
            }
            return true
        }

        if subrole == "AXStandardText" || subrole == "AXSearchField" {
            return true
        }

        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success {
            return true
        }

        var isSettable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &isSettable) == .success,
           isSettable.boolValue {
            return true
        }

        let nonTextRoles: Set<String> = [
            kAXScrollBarRole as String,
            kAXSliderRole as String,
            kAXProgressIndicatorRole as String,
            kAXButtonRole as String,
            kAXCheckBoxRole as String,
            kAXRadioButtonRole as String,
            kAXColorWellRole as String,
            kAXScrollAreaRole as String,
            kAXWindowRole as String,
            kAXApplicationRole as String,
            "AXDesktop",
            kAXListRole as String,
            kAXTableRole as String,
            kAXOutlineRole as String
        ]

        if !nonTextRoles.contains(role),
           AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &isSettable) == .success,
           isSettable.boolValue {
            return true
        }

        return false
    }

    /// Opens System Settings → Privacy → Accessibility for this Debug build.
    public func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.Settings.PrivacySecurity.extension"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    /// Pure string splice used by the Accessibility path — exposed for tests.
    public static func splicing(
        current: String,
        utf16Location: Int,
        utf16Length: Int,
        insertion: String
    ) -> (value: String, caretUTF16Location: Int)? {
        let nsCurrent = current as NSString
        let length = nsCurrent.length
        guard utf16Location >= 0,
              utf16Length >= 0,
              utf16Location <= length,
              utf16Location + utf16Length <= length
        else {
            return nil
        }

        let before = nsCurrent.substring(to: utf16Location)
        let after = nsCurrent.substring(from: utf16Location + utf16Length)
        let insertedUTF16Length = (insertion as NSString).length
        return (before + insertion + after, utf16Location + insertedUTF16Length)
    }

    // MARK: - Target activation

    private func activateTargetIfNeeded(_ targetApp: NSRunningApplication?) async {
        // Never leave LocalFlow/Settings as the paste target.
        resignLocalFlowKeyWindows()

        guard let targetApp, !targetApp.isTerminated else { return }

        let getFrontPID = { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        let frontPID: pid_t? = if Thread.isMainThread {
            getFrontPID()
        } else {
            DispatchQueue.main.sync { getFrontPID() }
        }

        if frontPID == targetApp.processIdentifier {
            // Already frontmost — do not re-activate (drops first responder in Chromium/Electron).
            return
        }

        let activateAction = {
            _ = targetApp.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        if Thread.isMainThread {
            activateAction()
        } else {
            DispatchQueue.main.sync { activateAction() }
        }

        // Brief poll — keep dictation snappy for short phrases.
        for _ in 0..<16 {
            let currentFront: pid_t? = if Thread.isMainThread {
                getFrontPID()
            } else {
                DispatchQueue.main.sync { getFrontPID() }
            }
            if currentFront == targetApp.processIdentifier {
                break
            }
            // Full-screen Electron and Chromium windows can take longer to restore
            // their editor responder after a global hotkey releases.
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func resignLocalFlowKeyWindows() {
        let block = {
            for window in NSApp.windows where window.isVisible && window.canBecomeKey {
                // Keep the window open, but stop it from eating keystrokes / paste.
                if window.isKeyWindow {
                    window.resignKey()
                }
                if window.isMainWindow {
                    window.resignMain()
                }
            }
        }
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.sync {
                block()
            }
        }
    }

    private func waitForModifiersToClear() async {
        for _ in 0..<12 {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            let blockers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskSecondaryFn]
            if flags.intersection(blockers).isEmpty {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    // MARK: - Accessibility

    private func insertViaAccessibility(_ text: String, preferredPID: pid_t?) -> Bool {
        guard let element = focusedElement(preferredPID: preferredPID) else { return false }

        let role = axString(element, attribute: kAXRoleAttribute as String)
        let textRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String]
        // Still attempt AX on unknown roles, but require a verified value change.

        let before = axString(element, attribute: kAXValueAttribute as String)

        if AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success {
            let after = axString(element, attribute: kAXValueAttribute as String)
            // Notes / VS Code / Google Docs often report success without changing value.
            if let before, let after, after != before, after.contains(text) || after.hasSuffix(text) {
                return true
            }
            if before == nil, let after, after.contains(text) {
                return true
            }
        }

        if let role, textRoles.contains(role), insertBySplicingValue(into: element, text: text) {
            let after = axString(element, attribute: kAXValueAttribute as String)
            if let after, after.contains(text) {
                return true
            }
        }

        return false
    }

    private func focusedElement(preferredPID: pid_t?) -> AXUIElement? {
        // Prefer system-wide focus — more accurate than frontmost app alone.
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused {
            return (focused as! AXUIElement)
        }

        let pid = preferredPID ?? NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let pid else { return nil }
        let axApp = AXUIElementCreateApplication(pid)
        focused = nil
        guard AXUIElementCopyAttributeValue(
            axApp,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private func insertBySplicingValue(into element: AXUIElement, text: String) -> Bool {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRef
        ) == .success,
              let current = valueRef as? String
        else {
            return false
        }

        let range = selectedUTF16Range(of: element) ?? CFRange(location: (current as NSString).length, length: 0)
        guard let spliced = Self.splicing(
            current: current,
            utf16Location: range.location,
            utf16Length: range.length,
            insertion: text
        ) else {
            return false
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            spliced.value as CFString
        ) == .success else {
            return false
        }

        var caret = CFRange(location: spliced.caretUTF16Location, length: 0)
        if let axRange = AXValueCreate(.cfRange, &caret) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                axRange
            )
        }
        return true
    }

    private func selectedUTF16Range(of element: AXUIElement) -> CFRange? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeRef
        ) == .success,
              let axValue = rangeRef
        else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue as! AXValue, .cfRange, &range) else {
            return nil
        }
        return range
    }

    private func axString(_ element: AXUIElement, attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    // MARK: - Clipboard fallback

    private func paste(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        let previous = pasteboard.string(forType: .string)

        // Avoid clearContents() — it drops other pasteboard types and races paste.
        pasteboard.declareTypes([.string], owner: nil)
        guard pasteboard.setString(text, forType: .string) else {
            throw LocalFlowError.textInjectionFailed
        }

        // Give Electron/Chromium a short turn to restore its editor responder after
        // LocalFlow's non-activating overlay is dismissed.
        try await Task.sleep(nanoseconds: 55_000_000)

        try postCommandV()

        // Restore previous clipboard after paste has had time to consume ours.
        if let previous {
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                let pasteboard = NSPasteboard.general
                pasteboard.declareTypes([.string], owner: nil)
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    private func postCommandV() throws {
        // hidSystemState + annotated session tap: cghidEventTap is silently dropped
        // for synthetic events on newer macOS builds unless the app is specially entitled.
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw LocalFlowError.textInjectionFailed
        }
        source.localEventsSuppressionInterval = 0

        let keyCode = CGKeyCode(kVK_ANSI_V)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw LocalFlowError.textInjectionFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func postSelectAll() throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw LocalFlowError.textInjectionFailed
        }
        source.localEventsSuppressionInterval = 0

        let keyCode = CGKeyCode(kVK_ANSI_A)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else {
            throw LocalFlowError.textInjectionFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
