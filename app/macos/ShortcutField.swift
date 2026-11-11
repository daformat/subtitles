// The field a shortcut is recorded in, Settings ▸ Shortcuts.
//
// Click it and it waits for keys: the next combination typed is the shortcut,
// ⎋ leaves it as it was and ⌫ removes it. The modifiers show as they go down,
// so it is plain the field is listening. While it listens, the app's own
// hotkeys stand aside (Hotkey.isSuspended): otherwise typing ⌥⌘S to keep
// ⌥⌘S would pause the captions and never reach the field.

import AppKit
import Carbon.HIToolbox
import CaptionCore

final class ShortcutField: NSView {
    /// What it shows, nil for none.
    var combo: KeyCombo? {
        didSet { refresh() }
    }

    /// Keys typed, or nil for ⌫: why they cannot be had, or nil once they
    /// are taken.
    var onRecord: ((KeyCombo?) -> ShortcutProblem?)?
    /// A problem to show under the fields, or nil to clear it.
    var onProblem: ((String?) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private var isRecording = false {
        didSet {
            guard isRecording != oldValue else { return }
            Hotkey.isSuspended = isRecording
            refresh()
        }
    }
    private var resignObserver: NSObjectProtocol?

    static let width: CGFloat = 150

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: L("Remove Shortcut", "Settings ▸ Shortcuts: the ✕ in a shortcut's field, which leaves the action with no keys"))
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.contentTintColor = .tertiaryLabelColor
        clearButton.target = self
        clearButton.action = #selector(clear)
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            heightAnchor.constraint(equalToConstant: 24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            clearButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            clearButton.widthAnchor.constraint(equalToConstant: 14),
            clearButton.heightAnchor.constraint(equalToConstant: 14),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Torn down while listening, however that came about: the app's
    /// hotkeys must not stay suspended.
    deinit {
        if isRecording { Hotkey.isSuspended = false }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    private func refresh() {
        clearButton.isHidden = isRecording || combo == nil
        if isRecording {
            let held = KeyCombo.glyphs(of: NSEvent.modifierFlags)
            label.stringValue = held.isEmpty
                ? L("Type Shortcut", "Settings ▸ Shortcuts: a field waiting for the keys of a new shortcut")
                : held
            label.textColor = held.isEmpty ? .placeholderTextColor : .labelColor
        } else if let combo {
            label.stringValue = combo.glyphs
            label.textColor = .labelColor
        } else {
            label.stringValue = L("shortcut|None", "Settings ▸ Shortcuts: an action with no keys set for it")
            label.textColor = .tertiaryLabelColor
        }
        setAccessibilityValue(isRecording ? label.stringValue : combo?.glyphs ?? label.stringValue)
        needsDisplay = true
        noteFocusRingMaskChanged()
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
        (isRecording ? NSColor.controlAccentColor.withAlphaComponent(0.1) : .controlBackgroundColor).setFill()
        box.fill()
        NSColor.separatorColor.setStroke()
        box.lineWidth = 1
        box.stroke()
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: recording

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func mouseDown(with event: NSEvent) {
        if isRecording {
            stopRecording()
        } else {
            window?.makeFirstResponder(self)
            startRecording()
        }
    }

    /// Listening until keys are taken, ⎋, a click elsewhere, or the window
    /// going to the back.
    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        onProblem?(nil)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: window, queue: .main
        ) { [weak self] _ in self?.stopRecording() }
    }

    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Closed while listening: the app's hotkeys must not stay suspended.
        if window == nil { stopRecording() }
    }

    override func flagsChanged(with event: NSEvent) {
        if isRecording { refresh() } else { super.flagsChanged(with: event) }
    }

    /// ⌘ combinations come here before `keyDown`, and the menu would take them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording, window?.firstResponder === self, event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    /// Not listening, reached by Tab: Space or Return starts it, as they
    /// would press a button.
    override func keyDown(with event: NSEvent) {
        let combo = KeyCombo(event: event)
        guard isRecording else {
            if combo.modifiers.isEmpty, [kVK_Space, kVK_Return].contains(combo.keyCode) {
                startRecording()
            } else {
                super.keyDown(with: event)
            }
            return
        }
        if combo.modifiers.isEmpty, combo.keyCode == kVK_Escape {
            onProblem?(nil)
            stopRecording()
            return
        }
        if combo.modifiers.isEmpty, [kVK_Delete, kVK_ForwardDelete].contains(combo.keyCode) {
            clear()
            return
        }
        if let problem = onRecord?(combo) {
            NSSound.beep()
            onProblem?(problem.message)
            return
        }
        onProblem?(nil)
        stopRecording()
    }

    @objc private func clear() {
        _ = onRecord?(nil)
        onProblem?(nil)
        stopRecording()
    }
}
