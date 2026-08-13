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

import AppKit
import Carbon.HIToolbox

final class Hotkey {
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate let action: () -> Void

    /// `keyCode` is a virtual key code (`kVK_ANSI_S` etc.); `modifiers` uses the
    /// Carbon constants (`cmdKey`, `optionKey`, …).
    init?(keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            Unmanaged<Hotkey>.fromOpaque(userData).takeUnretainedValue().action()
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType,
                                  selfPtr, &handlerRef) == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x5355_4253 /* "SUBS" */), id: 1)
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id,
                                  GetApplicationEventTarget(), 0, &ref) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
