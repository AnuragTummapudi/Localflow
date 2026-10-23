import AppKit
import Carbon

public enum NativePermissionReadiness {
    /// Receipts retain a specific permission name so the island can offer its settings pane.
    public static func settingsURL(forFailure message: String) -> URL? {
        guard message.contains("Permission required:") else { return nil }
        let pane: String
        if message.contains("Automation") { pane = "Privacy_Automation" }
        else if message.contains("Accessibility") { pane = "Privacy_Accessibility" }
        else if message.contains("Microphone") { pane = "Privacy_Microphone" }
        else if message.contains("Reminders") { pane = "Privacy_Reminders" }
        else if message.contains("Screen Recording") { pane = "Privacy_ScreenCapture" }
        else { return nil }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?" + pane)
    }
    /// askUserIfNeeded=false never preauthorizes or shows a permission prompt.
    private static func queryAutomationStatus(bundleIdentifier: String) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false)
    }
    /// The system probe can stall even with askUserIfNeeded=false. Never call it
    /// on the main thread or await an unbounded structured child task.
    public static func automationStatus(bundleIdentifier: String) async -> OSStatus? {
        await probes.status(bundleIdentifier)
    }
    public static func automationReady() async -> Bool {
        let installed = await MainActor.run { ["com.apple.Notes", "com.spotify.client"].filter {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil
        } }
        for id in installed where await automationStatus(bundleIdentifier: id) != noErr { return false }
        return true
    }
    private static let probes = AutomationProbes()
    private actor AutomationProbes {
        private var tasks: [String: Task<OSStatus?, Never>] = [:]
        private var completedAt: [String: Date] = [:]
        func status(_ id: String) async -> OSStatus? {
            // A timed-out OS call remains cached: repeated UI refreshes must not
            // accumulate blocked system threads. Successful probes expire.
            if let time = completedAt[id], Date().timeIntervalSince(time) > 30 {
                tasks[id] = nil; completedAt[id] = nil
            }
            if tasks[id] == nil {
                tasks[id] = Task {
                    await withCheckedContinuation { continuation in
                        let gate = ProbeCompletion(continuation)
                        DispatchQueue.global(qos: .utility).async {
                            gate.finish(queryAutomationStatus(bundleIdentifier: id))
                        }
                        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) { gate.finish(nil) }
                    }
                }
            }
            let result = await tasks[id]!.value
            if result != nil, completedAt[id] == nil { completedAt[id] = Date() }
            return result
        }
    }
    private final class ProbeCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<OSStatus?, Never>?
        init(_ continuation: CheckedContinuation<OSStatus?, Never>) { self.continuation = continuation }
        func finish(_ value: OSStatus?) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}
