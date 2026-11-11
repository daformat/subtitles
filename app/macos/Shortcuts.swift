// The keys the app answers to, and what each one is set to.
//
// Two kinds, because they are caught two ways. Pause, Stop or Repeat Speech
// and Search are Carbon hotkeys (Hotkey.swift): a key with its modifiers,
// taken from every app while it is registered. The holds are one modifier on
// its own, polled rather than monitored (see the header of Overlay.swift), so
// a hold can only be one of the four.
//
// All of them are changed in Settings ▸ Shortcuts. A setting that is absent
// means the default: Search's default follows the key that raises the stack,
// so ⌃ for the recent boxes makes it ⌃F, until Search is given keys of its own.

import AppKit
import Carbon.HIToolbox
import CaptionCore

// MARK: - Holds

/// One of the four modifiers, as a key to hold down.
enum HoldKey: String, CaseIterable {
    case shift, control, option, command

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }

    var glyph: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    /// The glyph and the key's name, as the popups list them.
    var title: String {
        switch self {
        case .shift: return "⇧ " + L("modifier key|Shift", "The ⇧ key, named as macOS names it in this language")
        case .control: return "⌃ " + L("modifier key|Control", "The ⌃ key, named as macOS names it in this language")
        case .option: return "⌥ " + L("modifier key|Option", "The ⌥ key, named as macOS names it in this language")
        case .command: return "⌘ " + L("modifier key|Command", "The ⌘ key, named as macOS names it in this language")
        }
    }

    var isDown: Bool { NSEvent.modifierFlags.contains(flag) }
}

/// What a key held over the captions does.
enum Hold: String, CaseIterable {
    /// Stack the recent boxes back up.
    case stack
    /// Make the box solid and grabbable.
    case drag
    /// Show the original language in place of the translation.
    case peek

    var defaultKey: HoldKey {
        switch self {
        case .stack: return .option
        case .drag: return .shift
        case .peek: return .control
        }
    }

    /// ⌥ is never the drag's: held while a window is dragged, it puts macOS
    /// into its tiling preview, which fights the drag. ⇧ and ⌘ are never the
    /// stack's: one is down for every capital letter and the other for every
    /// shortcut, and the stack would come up with each, taking Search's keys,
    /// ⇧F or ⌘F, from every app while it was up.
    func allows(_ key: HoldKey) -> Bool { refusal(of: key) == nil }

    /// Why `key` cannot be this one's, for the popup's disabled item.
    func refusal(of key: HoldKey) -> String? {
        switch (self, key) {
        case (.drag, .option):
            return L("macOS uses ⌥ while a window is dragged.",
                     "Settings ▸ Shortcuts: why ⌥ cannot be the key held to move the caption box")
        case (.stack, .shift):
            return L("Held for every capital letter typed: the recent boxes would come up each time.",
                     "Settings ▸ Shortcuts: why ⇧ cannot be the key held for the recent boxes")
        case (.stack, .command):
            return L("Held for nearly every shortcut: the recent boxes would come up each time.",
                     "Settings ▸ Shortcuts: why ⌘ cannot be the key held for the recent boxes")
        default:
            return nil
        }
    }

    var key: HoldKey { Shortcuts.key(for: self) }
    var isDown: Bool { key.isDown }
}

// MARK: - Key combinations

/// A key and the modifiers pressed with it.
struct KeyCombo: Equatable {
    /// A virtual key code, `kVK_ANSI_S` and the like: the key's place on the
    /// keyboard, whatever the layout prints on it.
    let keyCode: Int
    /// Only the four modifiers; caps lock and the rest are not part of it.
    let modifiers: NSEvent.ModifierFlags

    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevant)
    }

    init(event: NSEvent) {
        self.init(keyCode: Int(event.keyCode), modifiers: event.modifierFlags)
    }

    /// "keyCode:modifiers", as UserDefaults holds it.
    init?(stored: String) {
        let parts = stored.split(separator: ":")
        guard parts.count == 2, let code = Int(parts[0]), let raw = UInt(parts[1]) else { return nil }
        self.init(keyCode: code, modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }

    var stored: String { "\(keyCode):\(modifiers.rawValue)" }

    var carbonModifiers: Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        return carbon
    }

    /// The same key with one modifier traded for another.
    func replacing(_ old: NSEvent.ModifierFlags, with new: NSEvent.ModifierFlags) -> KeyCombo {
        guard modifiers.contains(old) else { return self }
        return KeyCombo(keyCode: keyCode, modifiers: modifiers.subtracting(old).union(new))
    }

    /// The way macOS writes it, modifiers in its order: ⌃⌥⇧⌘S.
    var glyphs: String { Self.glyphs(of: modifiers) + keyName }

    static func glyphs(of modifiers: NSEvent.ModifierFlags) -> String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }

    /// F1 to F20: keys that type nothing, and so can be a shortcut alone.
    var isFunctionKey: Bool { Self.functionKeys[keyCode] != nil }

    /// ⌥ or ⌃ with it, or a key that types nothing. Anything else takes a
    /// letter from every app that is typed into, or, with ⌘, a command from
    /// its menus: ⌘W, ⇧⌘T.
    var leavesAppsAlone: Bool {
        isFunctionKey || !modifiers.isDisjoint(with: [.option, .control])
    }

    /// The key, as the keyboard says it: what the layout puts on it, or the
    /// symbol macOS draws for a key that types nothing.
    var keyName: String {
        if let name = Self.functionKeys[keyCode] { return name }
        if let glyph = Self.named[keyCode] { return glyph.name }
        return Self.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    /// For an NSMenuItem, which takes the character rather than the key: the
    /// layout's own, or AppKit's code point for a key that types nothing.
    var keyEquivalent: String {
        if let name = Self.named[keyCode] { return String(Character(UnicodeScalar(name.menu)!)) }
        if let index = Self.functionKeyCodes.firstIndex(of: keyCode) {
            return String(Character(UnicodeScalar(NSF1FunctionKey + index)!))
        }
        return Self.character(for: keyCode) ?? ""
    }

    private static let functionKeyCodes = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]
    private static let functionKeys: [Int: String] = Dictionary(
        uniqueKeysWithValues: functionKeyCodes.enumerated().map { ($1, "F\($0 + 1)") })

    /// Keys that type nothing printable, with the symbol macOS draws for each
    /// and the character an NSMenuItem wants for it.
    private static let named: [Int: (name: String, menu: Int)] = [
        kVK_Return: ("↩", 0x0D), kVK_Tab: ("⇥", 0x09), kVK_Space: ("␣", 0x20),
        kVK_Delete: ("⌫", 0x08), kVK_ForwardDelete: ("⌦", NSDeleteFunctionKey),
        kVK_Escape: ("⎋", 0x1B), kVK_Home: ("↖", NSHomeFunctionKey),
        kVK_End: ("↘", NSEndFunctionKey), kVK_PageUp: ("⇞", NSPageUpFunctionKey),
        kVK_PageDown: ("⇟", NSPageDownFunctionKey), kVK_LeftArrow: ("←", NSLeftArrowFunctionKey),
        kVK_RightArrow: ("→", NSRightArrowFunctionKey), kVK_UpArrow: ("↑", NSUpArrowFunctionKey),
        kVK_DownArrow: ("↓", NSDownArrowFunctionKey), kVK_ANSI_KeypadEnter: ("⌤", 0x03),
    ]

    /// What the key types with no modifiers, on the layout shortcuts are read
    /// from: the current one if it types Latin letters, else the one the Mac
    /// falls back to for them, as the menus do on a Russian or Japanese Mac.
    private static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// What a key combination does.
enum ShortcutAction: String, CaseIterable {
    case pause, speech, search

    var title: String {
        switch self {
        case .pause: return L("Pause or Resume", "Settings ▸ Shortcuts: the keys that pause the captions, or start them again")
        case .speech: return L("Stop or Repeat Speech", "Speak Translation action: silences the voice, or reads the last line again when it is quiet")
        case .search: return L("Search Recent Boxes", "Settings ▸ Shortcuts: the keys that open the search over the recent boxes")
        }
    }

    /// Search's follows the key that raises the stack, which is down already
    /// when it is pressed.
    var defaultCombo: KeyCombo {
        switch self {
        case .pause: return KeyCombo(keyCode: kVK_ANSI_S, modifiers: [.command, .option])
        case .speech: return KeyCombo(keyCode: kVK_ANSI_Period, modifiers: [.command, .option])
        case .search: return KeyCombo(keyCode: kVK_ANSI_F, modifiers: Hold.stack.key.flag)
        }
    }

    /// Tells this action's hotkey events from the others' (Hotkey.swift).
    var hotkeyID: UInt32 {
        switch self {
        case .pause: return 1
        case .search: return 2
        case .speech: return 3
        }
    }

    /// The keys set for it, or nil for none.
    var combo: KeyCombo? { Shortcuts.combo(for: self) }
}

/// Why a combination cannot be had.
enum ShortcutProblem: Equatable {
    case needsOptionOrControl
    case usedFor(ShortcutAction)
    case usedByMacOS
    case usedByAnotherApp

    var message: String {
        switch self {
        case .needsOptionOrControl:
            return L("Add ⌥ or ⌃: without one, these keys type text or are menu commands in other apps.",
                     "Settings ▸ Shortcuts, under a shortcut that was refused: it had neither ⌥ nor ⌃")
        case .usedFor(let action):
            return LF("Already used for %@.", action.title)
        case .usedByMacOS:
            return L("macOS already uses these keys. Choose others, or turn that shortcut off in System Settings ▸ Keyboard.",
                     "Settings ▸ Shortcuts, under a shortcut that was refused. Name System Settings ▸ Keyboard as macOS does in this language")
        case .usedByAnotherApp:
            return L("Another app already uses these keys.",
                     "Settings ▸ Shortcuts, under a shortcut that was refused")
        }
    }
}

// MARK: - The store

enum Shortcuts {
    /// Posted after any shortcut or hold changes.
    static let changed = Notification.Name("Shortcuts.changed")

    private static func defaultsKey(_ action: ShortcutAction) -> String { "shortcut.\(action.rawValue)" }
    private static func defaultsKey(_ hold: Hold) -> String { "shortcut.hold.\(hold.rawValue)" }

    /// Read every poll and every frame, so held here rather than looked up.
    private static var holds: [Hold: HoldKey] = Dictionary(uniqueKeysWithValues: Hold.allCases.map { hold in
        let stored = UserDefaults.standard.string(forKey: defaultsKey(hold)).flatMap(HoldKey.init(rawValue:))
        return (hold, stored.flatMap { hold.allows($0) ? $0 : nil } ?? hold.defaultKey)
    })

    static func key(for hold: Hold) -> HoldKey { holds[hold] ?? hold.defaultKey }

    /// Absent for the default, empty for none.
    static func combo(for action: ShortcutAction) -> KeyCombo? {
        guard let stored = UserDefaults.standard.string(forKey: defaultsKey(action)) else {
            return action.defaultCombo
        }
        return KeyCombo(stored: stored)
    }

    static func isDefault(_ action: ShortcutAction) -> Bool {
        UserDefaults.standard.string(forKey: defaultsKey(action)) == nil
    }

    static var areDefaults: Bool {
        ShortcutAction.allCases.allSatisfy(isDefault) && Hold.allCases.allSatisfy { key(for: $0) == $0.defaultKey }
    }

    /// nil for none. The default is stored as the default, by its absence, so
    /// Search set back to the stack key and F follows that key again.
    static func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        if combo == action.defaultCombo {
            UserDefaults.standard.removeObject(forKey: defaultsKey(action))
        } else {
            UserDefaults.standard.set(combo?.stored ?? "", forKey: defaultsKey(action))
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// A key another hold has is traded for this one's, so each still has one
    /// of its own. Where that hold cannot take it (the drag ⌥, the stack ⇧),
    /// the other two are given whatever keys change least. Search keys of its
    /// own trade the stack's old key for its new one, since that key is down
    /// whenever Search is pressed.
    static func set(_ key: HoldKey, for hold: Hold) {
        guard hold.allows(key), key != self.key(for: hold) else { return }
        let oldStack = self.key(for: .stack)
        let given = self.key(for: hold)
        let others = Hold.allCases.filter { $0 != hold }
        // Twelve pairs at most: every one is tried, the fewest changes winning,
        // then the one that hands the displaced hold the key just given up.
        var best: (cost: Int, keys: [HoldKey])?
        for first in HoldKey.allCases {
            for second in HoldKey.allCases {
                let keys = [first, second]
                guard first != second, !keys.contains(key),
                      zip(others, keys).allSatisfy({ $0.allows($1) }) else { continue }
                let changed = zip(others, keys).filter { self.key(for: $0) != $1 }
                let cost = changed.count * 2 + (changed.allSatisfy { $1 == given } ? 0 : 1)
                if cost < best?.cost ?? .max { best = (cost, keys) }
            }
        }
        guard let best else { return }
        for (other, otherKey) in zip(others, best.keys) { store(otherKey, for: other) }
        store(key, for: hold)

        let newStack = self.key(for: .stack)
        if newStack != oldStack, !isDefault(.search), let custom = combo(for: .search) {
            UserDefaults.standard.set(custom.replacing(oldStack.flag, with: newStack.flag).stored,
                                      forKey: defaultsKey(.search))
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    private static func store(_ key: HoldKey, for hold: Hold) {
        holds[hold] = key
        if key == hold.defaultKey {
            UserDefaults.standard.removeObject(forKey: defaultsKey(hold))
        } else {
            UserDefaults.standard.set(key.rawValue, forKey: defaultsKey(hold))
        }
    }

    static func restoreDefaults() {
        for action in ShortcutAction.allCases {
            UserDefaults.standard.removeObject(forKey: defaultsKey(action))
        }
        for hold in Hold.allCases {
            holds[hold] = hold.defaultKey
            UserDefaults.standard.removeObject(forKey: defaultsKey(hold))
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    /// Why `combo` cannot be `action`'s, or nil when it can. Asked while
    /// recording, with the app's own hotkeys suspended, so a registration
    /// that fails is another app's.
    static func problem(with combo: KeyCombo, for action: ShortcutAction) -> ShortcutProblem? {
        if !combo.leavesAppsAlone { return .needsOptionOrControl }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self.combo(for: $0) == combo }) {
            return .usedFor(other)
        }
        if macOSUses(combo) { return .usedByMacOS }
        if !Hotkey.isFree(keyCode: combo.keyCode, modifiers: combo.carbonModifiers) { return .usedByAnotherApp }
        return nil
    }

    /// The shortcuts in System Settings ▸ Keyboard that are switched on:
    /// Spotlight, the input sources, Mission Control, screenshots and the rest.
    private static func macOSUses(_ combo: KeyCombo) -> Bool {
        var array: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&array) == noErr,
              let list = array?.takeRetainedValue() as? [[String: Any]] else { return false }
        let mask = cmdKey | optionKey | controlKey | shiftKey
        return list.contains { entry in
            (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                && (entry[kHISymbolicHotKeyCode as String] as? Int) == combo.keyCode
                && ((entry[kHISymbolicHotKeyModifiers as String] as? Int) ?? -1) & mask == combo.carbonModifiers
        }
    }

    /// `text` with the held keys it names as they are set: the English, and
    /// every translation, says ⌥ for the stack, ⇧ for the drag and ⌃ for the
    /// original, and tools/strings.py makes sure each one keeps them. One
    /// pass, so keys traded between two holds do not trade back.
    static func say(_ text: String) -> String {
        let swaps: [Character: String] = [
            "⌥": key(for: .stack).glyph, "⇧": key(for: .drag).glyph, "⌃": key(for: .peek).glyph,
        ]
        guard Hold.allCases.contains(where: { key(for: $0) != $0.defaultKey }) else { return text }
        return String(text.flatMap { swaps[$0] ?? String($0) })
    }
}
