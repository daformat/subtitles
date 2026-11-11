// Global hotkey registration.
//
// Uses Carbon's RegisterEventHotKey rather than
// NSEvent.addGlobalMonitorForEvents. The AppKit monitor sees every keystroke
// system-wide and therefore requires Accessibility/Input Monitoring permission;
// Carbon hotkeys are registered with the window server and fire only for the
// exact combination requested, needing no permission at all.
//
// For an app whose whole value proposition is "grant me audio access", not asking
// for keyboard access too is worth the older API.

import CSubs
import AppKit
import Carbon.HIToolbox

final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let action: () -> Void

    private let id: UInt32
    private let keyCode: Int
    private let modifiers: Int

    /// Every hotkey alive, for `isSuspended`.
    private static let live = NSHashTable<Hotkey>.weakObjects()

    /// While a shortcut is being recorded in Settings: the keys pressed go to
    /// the field rather than to what they are bound to, and a probe for
    /// another app's use of them is not answered by one of ours. The handlers
    /// stay installed; only the registrations come and go.
    static var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            for hotkey in live.allObjects {
                if isSuspended { hotkey.unregister() } else { _ = hotkey.register() }
            }
        }
    }

    /// Whether the combination can be registered: false when another app
    /// has it, or macOS will not hand it out.
    static func isFree(keyCode: Int, modifiers: Int) -> Bool {
        var probe: EventHotKeyRef?
        let probeID = EventHotKeyID(signature: OSType(0x5355_4253 /* "SUBS" */), id: 0xFFFF)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), probeID,
                                  GetApplicationEventTarget(), 0, &probe) == noErr else { return false }
        if let probe { UnregisterEventHotKey(probe) }
        return true
    }

    convenience init?(_ combo: KeyCombo, id: UInt32, action: @escaping () -> Void) {
        self.init(keyCode: combo.keyCode, modifiers: combo.carbonModifiers, id: id, action: action)
    }

    /// `keyCode` is a virtual key code (`kVK_ANSI_S` etc.); `modifiers` uses the
    /// Carbon constants (`cmdKey`, `optionKey`, …). `id` tells this hotkey's
    /// events from another's: every handler installed here hears every hotkey
    /// the app registers, and only the one whose id matches acts.
    init?(keyCode: Int, modifiers: Int, id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        // `eventNotHandledErr`, not `noErr`, for a hotkey that is not this one.
        // Carbon hands a hotkey event to the most recently installed handler
        // first and stops there if it says it handled it — so the handler for
        // the second hotkey registered, returning `noErr` for everything it
        // saw, swallowed the first hotkey's presses for as long as it existed.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue()
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard status == noErr, pressed.id == hotkey.id else {
                return OSStatus(eventNotHandledErr)
            }
            hotkey.action()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                  selfPtr, &handlerRef) == noErr else { return nil }

        // Made while recording, it waits for the recording to end.
        guard Self.isSuspended || register() else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
        Self.live.add(self)
    }

    private func register() -> Bool {
        guard ref == nil else { return true }
        let hotkeyID = EventHotKeyID(signature: OSType(0x5355_4253 /* "SUBS" */), id: id)
        return RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotkeyID,
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }

    private func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
