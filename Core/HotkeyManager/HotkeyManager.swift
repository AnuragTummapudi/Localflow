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
    case promptEngineerShortcut
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
    private var polishHotKeyRef: EventHotKeyRef?
    private var promptHotKeyRef: EventHotKeyRef?
    private var carbonHandlerRef: EventHandlerRef?
    private var settingsCancellable: AnyCancellable?
    private var lastPolishDispatch = Date.distantPast
    private var lastPromptDispatch = Date.distantPast
    public private(set) var isPolishShortcutRegistered = false
    public private(set) var isPromptShortcutRegistered = false

    private var lastKeyUpTime: Date?
    private let doubleTapWindow: TimeInterval = 0.38

    /// Creates a hotkey manager.
    public init(settings: LocalFlowSettings = .shared) {
        self.settings = settings
        settingsCancellable = settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPolishShortcutRegistration() }
        }
    }

    deinit {
        stop()
    }

    /// Starts observing the configured global hotkey, Escape key, and Carbon Option+1 polish shortcut.
    public func start() {
        stop()

        startCarbonTransformHotkeys()

        // Carbon owns Option + 1. Monitors remain solely for dictation flags and Escape.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event: event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            // A local monitor is the one place AppKit lets us prevent the frontmost
            // LocalFlow window from also handling Fn as the Mac's Globe/dictation key.
            // A global monitor is observational by design, so other apps retain their
            // normal Fn behaviour until LocalFlow is brought to the foreground.
            let consumeFunctionTrigger = self?.shouldConsumeFunctionTrigger(event) ?? false
            self?.handle(event: event)
            return consumeFunctionTrigger ? nil : event
        }
    }

    /// Stops observing global hotkey events.
    public func stop() {
        stopCarbonTransformHotkeys()

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

    private func startCarbonTransformHotkeys() {
        stopCarbonTransformHotkeys()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { (_, event, userData) -> OSStatus in
                guard let event, let userData else { return noErr }
                let instance = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard readStatus == noErr else { return readStatus }
                instance.handleCarbonTransformShortcut(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &carbonHandlerRef
        )

        guard status == noErr else { return }

        if settings.smartPolishShortcutEnabled {
            let polishID = EventHotKeyID(signature: OSType(0x4C46), id: 1) // 'LF', 1
            let polishStatus = RegisterEventHotKey(
                UInt32(kVK_ANSI_1), UInt32(optionKey), polishID,
                GetEventDispatcherTarget(), 0, &polishHotKeyRef
            )
            isPolishShortcutRegistered = polishStatus == noErr && polishHotKeyRef != nil
        }

        let promptID = EventHotKeyID(signature: OSType(0x4C46), id: 2) // 'LF', 2
        let promptStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_2), UInt32(optionKey), promptID,
            GetEventDispatcherTarget(), 0, &promptHotKeyRef
        )
        isPromptShortcutRegistered = promptStatus == noErr && promptHotKeyRef != nil
    }

    private func stopCarbonTransformHotkeys() {
        if let polishHotKeyRef {
            UnregisterEventHotKey(polishHotKeyRef)
            self.polishHotKeyRef = nil
        }
        if let promptHotKeyRef {
            UnregisterEventHotKey(promptHotKeyRef)
            self.promptHotKeyRef = nil
        }
        if let carbonHandlerRef {
            RemoveEventHandler(carbonHandlerRef)
            self.carbonHandlerRef = nil
        }
        isPolishShortcutRegistered = false
        isPromptShortcutRegistered = false
    }

    private func handleCarbonTransformShortcut(id: UInt32) {
        let now = Date()
        switch id {
        case 1:
            guard settings.smartPolishShortcutEnabled,
                  now.timeIntervalSince(lastPolishDispatch) > 0.18 else { return }
            lastPolishDispatch = now
            DispatchQueue.main.async { self.eventPublisher.send(.polishShortcut) }
        case 2:
            guard now.timeIntervalSince(lastPromptDispatch) > 0.18 else { return }
            lastPromptDispatch = now
            DispatchQueue.main.async { self.eventPublisher.send(.promptEngineerShortcut) }
        default:
            return
        }
    }

    /// Re-registers only the Carbon shortcut when its setting changes.
    public func refreshPolishShortcutRegistration() {
        startCarbonTransformHotkeys()
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
