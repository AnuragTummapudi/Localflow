import AppKit
import Carbon.HIToolbox
import Foundation
import Combine
import Shared

/// Hotkey events dispatched to the coordinator.
public enum HotkeyEvent: Equatable, Sendable {
    case pushToTalkDown
    case pushToTalkUp
    case doubleTap
    case escape
    case polishShortcut
}

/// Observes the global dictation hotkey, double-taps for hands-free, and Escape cancellation.
public final class HotkeyManager: ObservableObject, @unchecked Sendable {
    /// Whether the configured hotkey is currently held.
    @Published public private(set) var isHotkeyPressed = false

    /// Stream of hotkey actions (push-to-talk down/up, double-tap, escape, polish).
    public let eventPublisher = PassthroughSubject<HotkeyEvent, Never>()

    private let settings: LocalFlowSettings
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var carbonHotKeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?

    private var lastKeyUpTime: Date?
    private let doubleTapWindow: TimeInterval = 0.38

    /// Creates a hotkey manager.
    public init(settings: LocalFlowSettings = .shared) {
        self.settings = settings
    }

    deinit {
        stop()
    }

    /// Starts observing the configured global hotkey, Escape key, and Carbon Option+1 polish shortcut.
    public func start() {
        stop()

        startCarbonPolishHotkey()

        // Global: other apps (Notes, etc.). Local: when LocalFlow itself is focused.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // A local monitor is the one place AppKit lets us prevent the frontmost
            // LocalFlow window from also handling Fn as the Mac's Globe/dictation key.
            // A global monitor is observational by design, so other apps retain their
            // normal Fn behaviour until LocalFlow is brought to the foreground.
            let consumeFunctionTrigger = self?.shouldConsumeFunctionTrigger(event) ?? false
            if event.type == .keyDown && event.keyCode == 18 {
                let flags = event.modifierFlags.intersection([.option, .command, .control])
                if flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control) {
                    if self?.settings.smartPolishShortcutEnabled == true {
                        DispatchQueue.main.async {
                            self?.eventPublisher.send(.polishShortcut)
                        }
                        return nil // Swallow event so '¡' is never typed in LocalFlow
                    }
                }
            }
            self?.handle(event: event)
            return consumeFunctionTrigger ? nil : event
        }
    }

    /// Stops observing global hotkey events.
    public func stop() {
        stopCarbonPolishHotkey()

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        isHotkeyPressed = false
        lastKeyUpTime = nil
    }

    private func startCarbonPolishHotkey() {
        stopCarbonPolishHotkey()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, _, userData) -> OSStatus in
                guard let userData else { return noErr }
                let instance = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                instance.handleCarbonPolishShortcut()
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &carbonHandlerRef
        )

        guard status == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C46), id: 1) // 'LF', 1
        _ = RegisterEventHotKey(
            UInt32(kVK_ANSI_1),
            UInt32(optionKey),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &carbonHotKeyRef
        )
    }

    private func stopCarbonPolishHotkey() {
        if let carbonHotKeyRef {
            UnregisterEventHotKey(carbonHotKeyRef)
            self.carbonHotKeyRef = nil
        }
        if let carbonHandlerRef {
            RemoveEventHandler(carbonHandlerRef)
            self.carbonHandlerRef = nil
        }
    }

    private func handleCarbonPolishShortcut() {
        guard settings.smartPolishShortcutEnabled else { return }
        DispatchQueue.main.async {
            self.eventPublisher.send(.polishShortcut)
        }
    }

    /// Updates the configured hotkey.
    public func updateHotkey(_ descriptor: HotkeyDescriptor) {
        settings.hotkey = descriptor
    }

    private func handle(event: NSEvent) {
        // Escape key handling (keyCode 53 = kVK_Escape)
        if event.type == .keyDown && event.keyCode == 53 {
            DispatchQueue.main.async {
                self.eventPublisher.send(.escape)
            }
            return
        }

        // Option + 1 shortcut for Smart Polish (keyCode 18 = kVK_ANSI_1)
        if event.type == .keyDown && event.keyCode == 18 {
            let flags = event.modifierFlags.intersection([.option, .command, .control])
            if flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control) {
                if settings.smartPolishShortcutEnabled {
                    DispatchQueue.main.async {
                        self.eventPublisher.send(.polishShortcut)
                    }
                    return
                }
            }
        }

        guard event.type == .flagsChanged else { return }

        let descriptor = settings.useFnAsAlternateHotkey ? HotkeyDescriptor.functionKey : settings.hotkey
        let pressed: Bool

        if descriptor.isFunctionKey {
            // Fn state lives in modifierFlags; update on any flagsChanged that involves Fn keycode or Fn bit flip.
            pressed = event.modifierFlags.contains(.function)
        } else {
            // Right/Left Option: ONLY update when this key's own flagsChanged fires.
            // Ignoring other modifiers prevents a false "release" while Option is still held.
            guard event.keyCode == UInt16(descriptor.keyCode) else { return }
            pressed = event.modifierFlags.contains(.option)
        }

        DispatchQueue.main.async {
            guard self.isHotkeyPressed != pressed else { return }
            self.isHotkeyPressed = pressed

            let now = Date()
            if pressed {
                if let lastUp = self.lastKeyUpTime, now.timeIntervalSince(lastUp) <= self.doubleTapWindow {
                    // Double-tap detected
                    self.lastKeyUpTime = nil
                    self.eventPublisher.send(.doubleTap)
                } else {
                    self.eventPublisher.send(.pushToTalkDown)
                }
            } else {
                self.lastKeyUpTime = now
                self.eventPublisher.send(.pushToTalkUp)
            }
        }
    }

    /// Suppresses only Fn's down/up flag events while LocalFlow itself owns the active
    /// shortcut. This prevents the configured macOS Globe/Dictation action from racing
    /// LocalFlow, without taking over Fn when the user selected Right Option instead.
    private func shouldConsumeFunctionTrigger(_ event: NSEvent) -> Bool {
        guard settings.useFnAsAlternateHotkey, event.type == .flagsChanged else { return false }
        return event.keyCode == UInt16(kVK_Function) || event.modifierFlags.contains(.function)
    }
}
