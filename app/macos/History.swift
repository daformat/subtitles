// Hold ⌥ to bring back the last few boxes.
//
// The live overlay pages like broadcast subtitles: it fills, clears, and starts
// again, so a sentence you glanced away from is simply gone. This is the way
// back — the last `historyDepth` closed pages, stacked above the live box for as
// long as ⌥ is held, and scrollable when the stack is taller than the room above
// it.
//
// A second panel rather than growing the live one. The live pill carries the
// cursor reveal, the ⇧ drag ring, the anchor and the hugging resize, all written
// against there being exactly one box; making it a scroll view of N boxes would
// mean rewriting every one of them. A panel of its own also keeps the live box
// pinned exactly where it was dragged — the history grows away from it instead
// of pushing it around — and lets this one panel take the mouse for scrolling
// while the live one stays click-through.
//
// ⌥ is polled on the same 60 Hz timer as the cursor reveal, for the reason in
// Overlay.swift's header: a keyboard event monitor would demand Accessibility
// permission. 60 Hz rather than the 0.15 s modifier poll because this is an
// animation trigger — a sixth of a second of nothing after the keypress reads as
// a dropped input.
//
// The stack carries a search field at the edge touching the live box. Clicking
// it, or pressing ⌥F while the stack is up, gives this panel the keyboard — ⌥
// is stripped from what is typed, so the first letters can go in with it still
// held — and for as long as the field has the keyboard the stack is *pinned*: it
// stays up with ⌥ released, so both hands are free to type. Typing narrows the
// stack to the boxes containing the text, with the matches lit; clearing the
// field shows every box again and keeps the pin. Escape or a click anywhere
// else unpins it, and the stack goes back to living under ⌥.

import AppKit
import Carbon.HIToolbox
import CaptionCore

// MARK: - Panel

final class HistoryPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // Unlike the live panel this one *does* take the mouse: the scroll wheel
        // has to land somewhere. It is only on screen while ⌥ is held or the
        // search has pinned it, so the clicks it swallows are ones the user is
        // deliberately aiming at it.
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        // Key only for the search field. This asks, on every click, whether the
        // view under the pointer needs the keyboard — a text field does, a stack
        // of boxes does not — so the wheel and a click on a box land here without
        // pulling the caret out of the user's editor, and clicking the field is
        // the one thing that takes it. `.nonactivatingPanel` above keeps that
        // from activating the app as well.
        becomesKeyOnlyIfNeeded = true

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    // Key when a click asks for it — see `becomesKeyOnlyIfNeeded` above — and
    // never main: a borderless panel is not something the app is "in".
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The search field edits through the window's shared field editor, whose
    /// caret is the system's, which is invisible on a black pill. Set here, on
    /// the editor itself, rather than after each click: the editor is handed
    /// out fresh whenever editing begins, and a colour set on the last one
    /// does not carry.
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        let editor = super.fieldEditor(createFlag, for: object)
        (editor as? NSTextView)?.insertionPointColor = .white
        return editor
    }

    /// ⌥ is what raised the stack, so it is still down as the first letters of
    /// a search are typed — and ⌥ with a letter is the layout's alternate
    /// character: "an" arrives as "åñ". Stripped from any keystroke that would
    /// type a character, and left on everything else, so ⌥⌫ and ⌥← still edit
    /// the way they do in any field.
    override func sendEvent(_ event: NSEvent) {
        super.sendEvent(Self.withoutOption(event))
    }

    private static func withoutOption(_ event: NSEvent) -> NSEvent {
        guard event.type == .keyDown,
              event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let plain = event.charactersIgnoringModifiers,
              !plain.isEmpty,
              plain.unicodeScalars.allSatisfy({ scalar in
                  // Printable, and not one of the function-key code points
                  // AppKit uses for arrows, deletes and the rest.
                  scalar.value >= 0x20 && scalar.value != 0x7F
                      && !(0xF700...0xF8FF).contains(scalar.value)
              })
        else { return event }
        return NSEvent.keyEvent(
            with: .keyDown, location: event.locationInWindow,
            modifierFlags: event.modifierFlags.subtracting(.option),
            timestamp: event.timestamp, windowNumber: event.windowNumber, context: nil,
            characters: plain, charactersIgnoringModifiers: plain,
            isARepeat: event.isARepeat, keyCode: event.keyCode) ?? event
    }
}

// MARK: - Scroll view

/// The stack's scroll view, which reports whether a gesture is still in flight.
///
/// Any correction to the offset mid-flick — re-clamping it after the live box
/// resizes, say — fights the elastic bounce and reads as a stutter, so the
/// layout leaves the offset alone until the gesture has settled.
///
/// A timeout rather than a phase check: the elastic snap-back at the end of an
/// overscroll is animated by AppKit *after* the last event arrives, so there is
/// no event to mark the point where the content actually stops moving.
final class HistoryScrollView: NSScrollView {
    private var settlesAt: TimeInterval = 0

    var isScrolling: Bool { ProcessInfo.processInfo.systemUptime < settlesAt }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        settlesAt = ProcessInfo.processInfo.systemUptime + 0.5
    }
}

// MARK: - Style

/// Everything about how the stack is drawn, in one value.
///
/// Four numbers that all arrive together from the overlay and all belong to the
/// same decision — how far behind the live box this sits — so they travel as one
/// rather than as a growing parameter list on every call.
struct HistoryStyle: Equatable {
    var fontSize: CGFloat
    var maxLines: Int
    /// Pill background, already stepped back from the live box's.
    var fill: CGFloat
    var textOpacity: CGFloat
}

// MARK: - One past box

final class HistoryPillView: NSView {
    /// How far the stack's text sits behind the live box's. Uniform across every
    /// box — this is the stack receding as a whole, not each box ageing.
    static let defaultTextOpacity: CGFloat = 0.65

    /// Below this the text stops being dim and starts being unreadable, which is
    /// not a setting so much as a way to lose the feature.
    static let minTextOpacity: CGFloat = 0.25

    /// Applied to the live box's background opacity, so the two stay in step as
    /// that setting moves rather than the stack being pinned to one number and
    /// crossing over it.
    static let recession: CGFloat = 0.92

    /// Behind a search match. A warm wash rather than an inversion: the text
    /// over it stays white, at full strength, and the wash is what the eye
    /// lands on when scanning down the stack for it.
    private static let highlight = NSColor(calibratedRed: 1, green: 0.8, blue: 0.2, alpha: 0.45)

    private let text: String
    private let style: HistoryStyle
    /// Where the search query occurs, in UTF-16 units of `text`.
    private let highlights: [NSRange]

    init(text: String, style: HistoryStyle, highlights: [NSRange] = []) {
        self.text = text
        self.style = style
        self.highlights = highlights
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var attributed: NSAttributedString {
        let base = Pill.attributed(committed: text, tentative: "", size: style.fontSize,
                                   opacity: style.textOpacity)
        guard !highlights.isEmpty else { return base }
        let lit = NSMutableAttributedString(attributedString: base)
        for range in highlights {
            lit.addAttributes([.backgroundColor: Self.highlight, .foregroundColor: NSColor.white],
                              range: range)
        }
        return lit
    }

    /// Independent of any highlight: a background colour changes no glyph's
    /// advance, so a box measures the same lit or not, and the stack does not
    /// reflow as the query changes.
    static func fittingSize(_ text: String, style: HistoryStyle, maxWidth: CGFloat) -> NSSize {
        Pill.fittingSize(
            Pill.attributed(committed: text, tentative: "", size: style.fontSize, centered: false),
            size: style.fontSize, maxWidth: maxWidth, maxLines: style.maxLines, pad: 0)
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        Self.fittingSize(text, style: style, maxWidth: maxWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Every box in the stack at the same strength. Ageing them individually
        // was tried and is wrong: a per-box ramp reads as each box fading on its
        // own, and it fights the one gradient that is meant to be doing that job
        // — the mask across the whole scroll view.
        NSColor.black.withAlphaComponent(style.fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Pill.corner, yRadius: Pill.corner).fill()
        attributed.draw(with: bounds.insetBy(dx: Pill.inset.width, dy: Pill.inset.height),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

// MARK: - Search field

/// The text field inside the search pill.
///
/// Three overrides. The first lets a click through at all: a view in a non-key
/// window is only handed the mouse if it says it wants the first click. The
/// second keeps the caret honest: a window ordered front hands its initial
/// first responder to its first key view, which is this field, key window or
/// not — and a caret in a panel that cannot hear the keyboard is a lie. So the
/// field takes focus only in a key panel, and the controller makes the panel
/// key first. The third reports the field taking the keyboard. Not
/// `mouseDown`, which was tried: the panel becomes key before a click is
/// dispatched, and becoming key installs the field editor over the field, so
/// the click lands on the editor and the field's own `mouseDown` never runs.
/// Becoming first responder is the one step every route to focus goes through.
private final class SearchField: NSTextField {
    var onFocus: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { window?.isKeyWindow == true }

    override func becomeFirstResponder() -> Bool {
        let took = super.becomeFirstResponder()
        if took { onFocus?() }
        return took
    }
}

/// The ✕ in the search pill. It only ever shows while the field has text, and
/// the field only holds text while the panel is key, but a click on it must
/// not depend on that ordering being remembered.
private final class ClearButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The field pinned at the stack's near edge, drawn as one more box.
///
/// Not in the scroll view: it belongs to the stack rather than to any position
/// in it, and it has to stay under the pointer while the boxes move beneath the
/// wheel. Drawn with the boxes' own fill and corner so it reads as part of the
/// stack rather than as a control laid over it.
final class HistorySearchView: NSView, NSTextFieldDelegate {
    private static let inset = NSSize(width: 14, height: 7)
    private static let iconGap: CGFloat = 7

    /// Narrowest the open field is drawn. A stack narrower still lends it its
    /// width.
    static let minWidth: CGFloat = 220

    /// Open — the field has the keyboard, or holds text — or closed down to a
    /// pill of the icon and the word "Search". The controller decides; the
    /// width follows in `place`, animated between the two.
    var isExpanded = false {
        didSet { if isExpanded != oldValue { needsLayout = true } }
    }

    /// The pill's width when closed: the icon, the placeholder and the hint.
    var compactWidth: CGFloat {
        let word = field.placeholderAttributedString?.size().width ?? 0
        return Self.inset.width + fontSize.rounded() + Self.iconGap + ceil(word) + 4
            + Self.iconGap + hintWidth + Self.inset.width
    }

    private var hintWidth: CGFloat { ceil(hint.attributedStringValue.size().width) }

    private let field = SearchField()
    private let icon = NSImageView()
    /// The circled ✕ at the far end, there while the field holds text. One
    /// click empties the field, which is the same act as backspacing it out —
    /// it reaches the controller by the same route, and the field keeps the
    /// keyboard for the next word.
    private let clearButton = ClearButton()
    /// "⌥F", at the far end of the closed pill: the one place the shortcut can
    /// be found without reading about it. Gone once the field is open, where
    /// the ✕ takes that spot.
    private let hint = NSTextField(labelWithString: "⌥F")
    private var style: HistoryStyle

    /// The field took the keyboard.
    var onFocus: (() -> Void)?
    /// The text changed, to this.
    var onChange: ((String) -> Void)?
    /// Escape.
    var onCancel: (() -> Void)?

    var text: String { field.stringValue }

    init(style: HistoryStyle) {
        self.style = style
        super.init(frame: .zero)

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        icon.imageScaling = .scaleProportionallyUpOrDown

        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.isEditable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        // Long queries scroll within the field rather than growing it.
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = self
        field.onFocus = { [weak self] in self?.onFocus?() }

        clearButton.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                    accessibilityDescription: "Clear")
        clearButton.isBordered = false
        clearButton.imagePosition = .imageOnly
        clearButton.imageScaling = .scaleProportionallyUpOrDown
        clearButton.isHidden = true
        clearButton.target = self
        clearButton.action = #selector(clearClicked)

        hint.alignment = .right
        hint.isSelectable = false

        addSubview(icon)
        addSubview(field)
        addSubview(clearButton)
        addSubview(hint)
        // For the entrance: it rises out of the live box with the boxes, and
        // that is a layer animation.
        wantsLayer = true
        apply(style: style)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Half the boxes' text, floored where it would stop being legible: this is
    /// a field, not a caption, and the boxes' size is set for reading across a
    /// room.
    private var fontSize: CGFloat { max(13, (style.fontSize * 0.5).rounded()) }

    func apply(style: HistoryStyle) {
        self.style = style
        let font = Pill.font(ofSize: fontSize)
        field.font = font
        field.textColor = NSColor.white.withAlphaComponent(style.textOpacity)
        field.placeholderAttributedString = NSAttributedString(
            string: "Search", attributes: [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(style.textOpacity * 0.5),
            ])
        icon.contentTintColor = NSColor.white.withAlphaComponent(style.textOpacity * 0.75)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: fontSize * 0.85,
                                                                weight: .semibold)
        clearButton.contentTintColor = NSColor.white.withAlphaComponent(style.textOpacity * 0.75)
        hint.font = Pill.font(ofSize: (fontSize * 0.85).rounded())
        hint.textColor = NSColor.white.withAlphaComponent(style.textOpacity * 0.5)
        clearButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: fontSize * 0.85,
                                                                       weight: .semibold)
        needsLayout = true
        needsDisplay = true
    }

    var fittingHeight: CGFloat {
        ceil(Pill.lineHeight(ofSize: fontSize)) + Self.inset.height * 2
    }

    func clear() {
        field.stringValue = ""
        syncClearButton()
    }

    /// Put the caret in the field. The window must already be key, or the
    /// keystrokes go to whatever was key before.
    func focus() {
        window?.makeFirstResponder(field)
    }

    /// Setting the text from code posts no change notification, so this is
    /// called from both routes rather than from the delegate alone.
    private func syncClearButton() {
        clearButton.isHidden = field.stringValue.isEmpty
    }

    @objc private func clearClicked() {
        field.stringValue = ""
        syncClearButton()
        onChange?("")
    }

    override func layout() {
        super.layout()
        let side = fontSize.rounded()
        icon.frame = NSRect(x: Self.inset.width, y: ((bounds.height - side) / 2).rounded(),
                            width: side, height: side)
        // Room for the ✕ is held whether or not it is showing, so the text does
        // not shift when it appears under the first character typed — but only
        // in the open field. The closed pill is exactly the icon and the word.
        clearButton.frame = NSRect(x: bounds.width - Self.inset.width - side,
                                   y: ((bounds.height - side) / 2).rounded(),
                                   width: side, height: side)
        hint.isHidden = isExpanded
        let hintHeight = hint.intrinsicContentSize.height
        hint.frame = NSRect(x: bounds.width - Self.inset.width - hintWidth,
                            y: ((bounds.height - hintHeight) / 2).rounded(),
                            width: hintWidth, height: hintHeight)
        let x = icon.frame.maxX + Self.iconGap
        let right = isExpanded ? clearButton.frame.minX - Self.iconGap : hint.frame.minX - Self.iconGap
        let height = field.intrinsicContentSize.height
        field.frame = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(),
                             width: max(right - x, 0), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(style.fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Pill.corner, yRadius: Pill.corner).fill()
    }

    // MARK: NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        syncClearButton()
        onChange?(field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return true
        }
        return false
    }
}

// MARK: - Spring

/// One number on a spring, ticked once per frame of the display it is on.
///
/// The search pill opens and closes on this rather than on an AppKit animation
/// group: a plain view's frame animates only along a timing curve, and a spring
/// needs a layer-backed view and a `CASpringAnimation` that leaves the frame
/// and its subviews sitting at the far end while the layer catches up. Driving
/// the frame directly keeps the field, the icon and the ✕ laid out at the
/// width actually on screen — and a retarget mid-flight keeps its velocity, so
/// an Escape halfway through opening turns round rather than jumping.
///
/// A display link rather than a timer: it fires at the display's own rate —
/// 120 Hz on a ProMotion screen, 60 elsewhere — and the integration uses the
/// interval it actually got, so the motion is the same on both and a dropped
/// frame is a longer step, not a slower spring.
final class SpringValue {
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    private var velocity: CGFloat = 0
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    /// The view whose display paces the ticks. Set before the first `animate`.
    weak var view: NSView?

    /// Called with each new value, and once more with the target on settling.
    var onTick: ((CGFloat) -> Void)?

    private let stiffness: CGFloat
    private let damping: CGFloat

    /// The integrator's step. Fixed, and finer than any frame, so the spring
    /// is the same spring whatever the display's rate.
    private static let substep: CGFloat = 1.0 / 480.0

    /// The defaults are the search pill's: a response of about a quarter of a
    /// second with a small overshoot, quick enough to feel attached to the
    /// click, soft enough to read as a spring.
    init(_ value: CGFloat, stiffness: CGFloat = 700, dampingRatio: CGFloat = 0.74) {
        self.value = value
        self.target = value
        self.stiffness = stiffness
        self.damping = 2 * dampingRatio * stiffness.squareRoot()
    }

    deinit { link?.invalidate() }

    var isAnimating: Bool { link != nil }

    /// Go straight to `value`, dropping any motion.
    func snap(to value: CGFloat) {
        link?.invalidate()
        link = nil
        velocity = 0
        self.value = value
        target = value
    }

    func animate(to newTarget: CGFloat) {
        guard abs(newTarget - target) > 0.5 || (!isAnimating && abs(newTarget - value) > 0.5) else {
            return
        }
        target = newTarget
        guard link == nil, let view else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        lastTimestamp = 0
        self.link = link
    }

    @objc private func tick(_ link: CADisplayLink) {
        // The interval this frame actually took. Clamped: the first tick has no
        // predecessor, and a stall — a menu opening, say — must not be
        // integrated as one enormous step.
        let now = link.timestamp
        let dt = lastTimestamp == 0 ? 1.0 / 120.0 : min(max(now - lastTimestamp, 1.0 / 240.0), 1.0 / 30.0)
        lastTimestamp = now

        // Semi-implicit Euler over fixed substeps: stable at this stiffness,
        // and cheap enough that a closed form would not buy anything.
        var remaining = CGFloat(dt)
        while remaining > 0 {
            let step = min(Self.substep, remaining)
            let acceleration = -stiffness * (value - target) - damping * velocity
            velocity += acceleration * step
            value += velocity * step
            remaining -= step
        }
        if abs(value - target) < 0.3, abs(velocity) < 8 {
            snap(to: target)
        }
        onTick?(value)
    }
}

// MARK: - Controller

final class HistoryController {
    /// Between stacked boxes, and between the stack and the live box.
    private static let gap: CGFloat = 6

    /// Kept clear of the screen edge so the top box never looks cut off.
    private static let screenMargin: CGFloat = 12

    /// Below this there is not enough room for the stack to be worth drawing.
    private static let minRoom: CGFloat = 40

    /// Ceiling on the fade at the clipped edge. It grows with the amount actually
    /// hidden, so a stack overflowing by ten points gets a ten-point fade rather
    /// than swallowing a whole box to announce it.
    private static let fadeHeight: CGFloat = 150

    /// Ceiling on the fade at the near edge, there only once the reader has
    /// scrolled away from the live box. Much shorter than the far one: that edge
    /// is where the newest boxes are, and the band is a hint that they are just
    /// out of sight, not an invitation to keep going.
    private static let nearFadeHeight: CGFloat = 60

    private let panel = HistoryPanel()

    /// Whether the stack is captured by screen recording and sharing. Follows the
    /// live box: the two are one overlay as far as anyone watching is concerned,
    /// and hiding one while the other stays visible would be worse than hiding
    /// neither.
    var isVisibleInScreenShare = true {
        didSet { panel.sharingType = isVisibleInScreenShare ? .readOnly : .none }
    }

    /// Holds the scroll view and the search pill at its near edge.
    private let root = NSView()
    private let scroll = HistoryScrollView()
    private let document = NSView()
    private let search: HistorySearchView

    /// What is on screen right now, oldest first — the same array `present` was
    /// last called with, before the search narrows it. Compared against on
    /// every poll so a page closing while ⌥ is still down animates itself in
    /// rather than waiting for the next press.
    private(set) var shown: [String] = []

    /// The boxes actually in the document, oldest first: `shown` after the
    /// search has had its say. What the entrance animation compares against, so
    /// a box that was already up does not rise a second time.
    private var laidOut: [String] = []

    private var isVisible = false
    private var placedAbove = true

    /// How the boxes are drawn, and the widest they may be. Kept from `present`
    /// so a keystroke in the search can rebuild the stack without the overlay.
    private var style = HistoryStyle(fontSize: 30, maxLines: 2, fill: 0.7,
                                     textOpacity: HistoryPillView.defaultTextOpacity)
    private var ceiling: CGFloat = 400
    private var lastAnchor = NSRect.zero
    private var lastCentreX: CGFloat = 0

    /// Measured widths and heights by text. A box measures through the real
    /// layout engine, which is a few tenths of a millisecond each, and the
    /// stack can be two thousand of them at the unlimited depth: rebuilt on
    /// every page close while ⌥ is down, and on every keystroke in the search,
    /// that is a hitch. Nothing about a box's size changes between rebuilds
    /// unless the style or the ceiling does, so the answers are kept.
    private var measured: [String: NSSize] = [:]
    private var measuredFor: (style: HistoryStyle, ceiling: CGFloat)?

    // ── search ──

    /// What the field holds. The stack is narrowed to boxes containing it.
    private var query = ""

    /// Whether the field has the keyboard. Set when it takes it — as the stack
    /// opens, or on a click — and cleared by everything that takes it away.
    private var searchFocused = false

    /// Set around the panel leaving the screen for a reason of its own — a
    /// layout with no room for it — so the resign-key that follows is not
    /// taken for the user clicking elsewhere and clearing the search.
    private var isStarving = false

    /// The document no longer matches the query: the search was cleared by an
    /// unpin, and the filtered boxes were left in place for the fade that
    /// usually follows. Rebuilt on the next poll if the stack stays instead.
    private var isStale = false

    /// The stack is held up without ⌥: the field has the keyboard, by a click
    /// or by ⌥F. The overlay reads this on its poll and keeps the stack up for
    /// as long as it is true, whatever the modifier keys are doing.
    var isPinned: Bool { searchFocused }

    /// Whether the field is drawn open: in use, or holding a word.
    private var searchExpanded: Bool { searchFocused || !query.isEmpty }

    /// The search pill's width, on its way between closed and open.
    private let searchWidthSpring = SpringValue(0)

    /// The panel's origin, on its way to where the live box now wants it. The
    /// box hugs its text and grows a line at a time, and a stack that jumped a
    /// line with it read as a jolt; the box itself stays put — it changes
    /// several times a second and is what is being read — and the stack
    /// follows it on a stiff spring, a tenth of a second behind, no overshoot.
    private let originXSpring = SpringValue(0, stiffness: 900, dampingRatio: 0.9)
    private let originYSpring = SpringValue(0, stiffness: 900, dampingRatio: 0.9)
    /// Where the pill sits vertically as last placed, so the spring's ticks
    /// can lay the frame without re-deriving the panel.
    private var searchY: CGFloat = 0
    private var searchHeight: CGFloat = 0

    /// ⌥F, registered only while the stack is up. A Carbon hotkey rather than
    /// a key monitor, for the reason in Hotkey.swift; and not registered for
    /// good, because ⌥F belongs to whatever app is in front the rest of the
    /// time. The stack goes up within a poll of ⌥ going down, which is sooner
    /// than the F can follow it.
    private var searchHotkey: Hotkey?

    /// For the outside-click poll: the buttons as they were last tick.
    private var mouseWasDown = false

    private var resignObserver: NSObjectProtocol?

    /// Full height of the stack, and its width — the size it *wants*, before the
    /// room next to the live box is taken into account. Kept so `place` can
    /// re-derive the panel's height on every word without rebuilding the pills.
    private var contentHeight: CGFloat = 0
    private var stackWidth: CGFloat = 0

    /// Height the scroll view was last given, so `place` can tell a resize —
    /// which the scroll offset has to be re-anchored against — from the far
    /// more common case of the live box merely moving.
    private var placedHeight: CGFloat = 0

    /// Softens the edge that has content beyond it. A mask on the clip view
    /// rather than a view drawn over the top: the panel is transparent, so an
    /// overlaid gradient would have to fade to a colour that is not there, and
    /// would darken the desktop showing through instead of the boxes.
    private let fadeMask = CAGradientLayer()
    private var scrollObserver: NSObjectProtocol?

    init() {
        search = HistorySearchView(style: style)

        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        // No scroller. It would be the only hard edge in an overlay made of soft
        // ones, and on a transparent panel over arbitrary video it reads as
        // chrome belonging to whatever is underneath. The fade at the clipped
        // edge says there is more, which is all the scroller was there to say.
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        // Nothing is ever wider than the panel, so sideways is never a direction.
        scroll.horizontalScrollElasticity = .none
        scroll.borderType = .noBorder
        // Off, or the clip view is handed insets of its own and its bounds stop
        // matching the panel — which shows up as a fade over content that is not
        // actually clipped.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        scroll.contentView.wantsLayer = true

        // `place` sets every frame in here by hand; autoresizing would move them
        // a second time.
        root.autoresizesSubviews = false
        root.addSubview(scroll)
        root.addSubview(search)
        panel.contentView = root

        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: nil
        ) { [weak self] _ in
            self?.updateFade()
        }

        search.onFocus = { [weak self] in self?.searchTookFocus() }
        searchWidthSpring.view = search
        searchWidthSpring.onTick = { [weak self] width in self?.laySearch(width: width) }
        for spring in [originXSpring, originYSpring] {
            spring.view = root
            spring.onTick = { [weak self] _ in self?.followOrigin() }
        }
        search.onChange = { [weak self] text in self?.queryChanged(text) }
        search.onCancel = { [weak self] in self?.unpin() }

        // The keyboard went elsewhere: the user clicked into another window, or
        // another app took the front. Either is an outside click as far as the
        // pin is concerned.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: nil
        ) { [weak self] _ in
            guard let self, self.searchFocused, !self.isStarving else { return }
            self.unpin()
        }

        panel.alphaValue = 0
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    // MARK: build

    /// Put `entries` (oldest first) on screen against the live box at `anchor`.
    ///
    /// Boxes already on screen keep their position and stay put; anything new
    /// animates in. That is what makes this safe to call from the poll whenever
    /// the transcript pages while ⌥ is still held — or while the search has the
    /// stack pinned, when a page that closes joins the stack the same way and
    /// is filtered like the rest.
    /// `animated` is false when the boxes are not new, only re-worded: swapping
    /// the stack between languages with ⌃ replaces every string at once, so the
    /// usual "animate what was not here before" rule would stage the entire stack
    /// in again on a keypress. Opening and closing still animate.
    /// `centreX` is where the live box is *anchored*, not where its frame
    /// happens to sit. The two differ by up to a point: the box rounds its origin
    /// and hugs its text, so its midpoint flips back and forth as the width
    /// changes parity on every word. Following the frame passed that on to the
    /// stack, which twitched sideways under the reader for the whole of an
    /// utterance.
    func present(entries: [String], style: HistoryStyle, anchor: NSRect,
                 centreX: CGFloat, maxWidth: CGFloat, animated: Bool = true) {
        guard !entries.isEmpty else { dismiss(); return }
        guard let screen = Self.screen(for: anchor) else { return }

        // Above by default — history reads upwards, and the box usually sits low.
        // Flip only when there is genuinely more room the other way, and reverse
        // the stack with it so the newest box stays the one touching the live box.
        //
        // Decided once, on the press that raised the stack. Re-deciding it as the
        // live box resizes would let one sentence wrapping to a second line throw
        // the whole stack to the other side of it mid-read.
        placedAbove = isVisible
            ? placedAbove
            : Self.room(above: true, anchor: anchor, screen: screen)
                >= Self.room(above: false, anchor: anchor, screen: screen)

        self.style = style
        // Ceiling matched to the live box: it spends `pad` of its own width on
        // the ⇧ ring margin, and these have no ring, so the same sentence must be
        // measured against a correspondingly narrower box or the stack would sit
        // a few points wider than the box it belongs to.
        ceiling = maxWidth - SubtitleView.pad * 2
        search.apply(style: style)
        shown = entries

        let fits = rebuild(anchor: anchor, centreX: centreX, animated: animated, park: false)

        if !isVisible {
            isVisible = true
            guard fits else { return }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
            searchHotkey = Hotkey(keyCode: kVK_ANSI_F, modifiers: optionKey, id: 2) { [weak self] in
                self?.focusSearch()
            }
        }
    }

    /// Lay out the boxes the search lets through and put the panel against the
    /// live box. Returns whether there was room for it.
    ///
    /// `park` forces the scroll to the newest box. The search asks for that on
    /// every keystroke — the newest match is the one wanted — where a page
    /// closing leaves the reader where they were.
    @discardableResult
    private func rebuild(anchor: NSRect, centreX: CGFloat, animated: Bool, park: Bool) -> Bool {
        lastAnchor = anchor
        lastCentreX = centreX
        isStale = false

        let alreadyShowing = isVisible ? laidOut : []
        let wasVisible = isVisible
        // Where the reader is, measured from the end of the stack that touches the
        // live box, before any of this changes underneath them.
        let previousContent = isVisible ? contentHeight : 0
        let previousNear = isVisible ? nearDistance() : 0
        let wasParked = !isVisible || previousNear <= 1

        if measuredFor?.style != style || measuredFor?.ceiling != ceiling {
            measured = [:]
            measuredFor = (style, ceiling)
        }
        // Forget boxes that have left the stack, or a long session keeps every
        // page it ever showed.
        let current = Set(shown)
        measured = measured.filter { current.contains($0.key) }

        // Every box counts towards the width, filtered out or not: a stack that
        // narrowed as the query did would jitter under each keystroke, and the
        // search pill takes its width from the stack's.
        var width: CGFloat = 0
        for text in shown { width = max(width, size(of: text).width) }

        let matching = query.isEmpty
            ? shown
            : shown.filter { HistorySearch.matches($0, query: query) }
        // Newest first: index 0 is the box nearest the live one, which is where
        // the eye goes and so where the animation starts.
        let ordered = Array(matching.reversed())

        document.subviews.forEach { $0.removeFromSuperview() }

        var pills: [HistoryPillView] = []
        var sizes: [NSSize] = []
        for text in ordered {
            let pill = HistoryPillView(text: text, style: style,
                                       highlights: HistorySearch.ranges(of: query, in: text))
            pills.append(pill)
            sizes.append(size(of: text))
        }

        stackWidth = width
        contentHeight = sizes.reduce(0) { $0 + $1.height }
            + Self.gap * CGFloat(max(pills.count - 1, 0))
        document.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)

        // Document coordinates are y-up. Nearest-first is laid from the edge that
        // faces the live box: the bottom when the stack is above it, the top when
        // it is below.
        var offset: CGFloat = 0
        for (i, pill) in pills.enumerated() {
            let size = sizes[i]
            let y = placedAbove ? offset : contentHeight - offset - size.height
            pill.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: y.rounded(),
                                width: size.width, height: size.height)
            document.addSubview(pill)
            offset += size.height + Self.gap
        }

        let fits = place(anchor: anchor, centreX: centreX)

        // Stick to the newest box if that is where the reader already was, so a
        // page closing brings the new box into view. If they had scrolled back to
        // an older one, hold *that* box still instead: new text arriving must not
        // drag the page out from under someone mid-sentence.
        //
        // Never mid-gesture, for the same reason `place` does not: someone
        // flicking through the stack when a page happens to close is navigating,
        // and moving the content under them is the one thing that must not
        // happen. Opening the stack always parks, since there is no gesture to
        // interrupt — only a stale one from the last time it was up.
        if park {
            setNearDistance(0)
        } else if !wasVisible || !scroll.isScrolling {
            setNearDistance(wasParked ? 0 : previousNear + (contentHeight - previousContent))
        }
        updateFade()

        if animated {
            animateIn(pills, ordered: ordered, alreadyShowing: alreadyShowing, above: placedAbove,
                      withSearch: !wasVisible)
        }

        laidOut = matching
        return fits
    }

    private func size(of text: String) -> NSSize {
        if let known = measured[text] { return known }
        let size = HistoryPillView.fittingSize(text, style: style, maxWidth: ceiling)
        measured[text] = size
        return size
    }

    /// Follow the live box as it resizes under a new word, without rebuilding —
    /// unless an unpin left the boxes filtered and the stack turned out to stay,
    /// in which case this is the poll that puts every box back.
    func reposition(anchor: NSRect, centreX: CGFloat) {
        guard isVisible else { return }
        if isStale {
            rebuild(anchor: anchor, centreX: centreX, animated: false, park: true)
            return
        }
        lastAnchor = anchor
        lastCentreX = centreX
        place(anchor: anchor, centreX: centreX)
    }

    /// Size and position the panel against the live box as it stands now.
    ///
    /// Height is recomputed here, not only the origin. The live box grows upwards
    /// as a sentence wraps to a second and third line, so the room above it
    /// shrinks while the stack is up; keeping the old height and merely moving
    /// the panel pushes its top off screen, and the clamp that brings it back
    /// slides its bottom under the live box. Re-deriving the height from the room
    /// that is actually left is what keeps the two from ever meeting.
    ///
    /// The search pill sits outside the scroll view, at the panel's near edge,
    /// so it comes off the room before the boxes are measured against it.
    ///
    /// Returns false when there is no longer anywhere to put it.
    @discardableResult
    private func place(anchor: NSRect, centreX: CGFloat) -> Bool {
        guard let screen = Self.screen(for: anchor) else { return false }

        let room = Self.room(above: placedAbove, anchor: anchor, screen: screen)
        let searchHeight = search.fittingHeight
        let searchBlock = searchHeight + Self.gap
        // A stack with nothing in it — every box filtered out — still shows the
        // field, and needs only the field's own height.
        let needed = contentHeight > 0 ? Self.minRoom + searchBlock : searchHeight
        guard room >= needed else {
            // Nowhere left. Hide rather than tear down: the live box shrinks again
            // on the next page, and the stack should still be there when it does.
            // The search goes with it, keyboard included, and comes back with it.
            isStarving = true
            panel.orderOut(nil)
            isStarving = false
            return false
        }

        // The gap to the live box is *inside* the panel, as padding at its near
        // edge, so the panel itself starts flush with the box. The entrance
        // slides the pills out of the live box, and a panel that began a gap
        // short of it clipped that slide six points before the edge it was
        // meant to be coming from.
        let scrollHeight = contentHeight > 0 ? min(contentHeight, room - searchBlock).rounded() : 0
        let height = Self.gap + searchHeight + (scrollHeight > 0 ? Self.gap + scrollHeight : 0)
        let size = NSSize(width: stackWidth, height: height)

        // Elastic only while there is somewhere to go. A stack that fits its
        // panel must sit dead still under the wheel: rubber-banding a list with
        // no more content to reach reads as something broken rather than as
        // feedback. Set from the height that is about to be applied, so it is
        // already right for the first event after a resize.
        scroll.verticalScrollElasticity = contentHeight > scrollHeight + 1 ? .allowed : .none
        let origin = NSPoint(
            x: (centreX - size.width / 2).rounded(),
            y: (placedAbove
                ? anchor.maxY - SubtitleView.pad
                : anchor.minY + SubtitleView.pad - size.height).rounded())
        let target = clamp(origin, size: size, to: screen.visibleFrame)
        // Sprung towards the target while the stack is up; straight there when
        // it is arriving, since there is nowhere for it to be coming from.
        let placedOrigin: NSPoint
        if isVisible, panel.isVisible {
            originXSpring.animate(to: target.x)
            originYSpring.animate(to: target.y)
            placedOrigin = NSPoint(x: originXSpring.value.rounded(),
                                   y: originYSpring.value.rounded())
        } else {
            originXSpring.snap(to: target.x)
            originYSpring.snap(to: target.y)
            placedOrigin = target
        }
        let frame = NSRect(origin: placedOrigin, size: size)

        // Only a change of *height* disturbs the scroller; the live box merely
        // moving does not. Read the reader's position before the resize lands.
        let resized = abs(scrollHeight - placedHeight) > 0.5
        let near = resized ? nearDistance() : 0

        // `display: false` matters: a synchronous repaint here would paint the
        // panel before the scroll offset below has been restored, and that stray
        // frame is exactly the shift-then-settle you see when a new box lands.
        // Left to the normal display cycle, the first frame drawn is the right
        // one.
        if frame != panel.frame { panel.setFrame(frame, display: false) }

        // The field at the near edge, past the padding — the bottom when the
        // stack is above the live box, the top when it is below — and the
        // boxes beyond it.
        let scrollFrame = NSRect(x: 0, y: placedAbove ? height - scrollHeight : 0,
                                 width: stackWidth, height: scrollHeight)
        if scroll.frame != scrollFrame { scroll.frame = scrollFrame }
        scroll.isHidden = scrollHeight == 0
        // A pill while idle, the full field while in use — and the change
        // between them sprung, so the field is seen to open out of the pill
        // rather than replace it. Only while the stack is up: a stack arriving
        // on screen builds the field at the width it should already have.
        search.isExpanded = searchExpanded
        let searchWidth = searchExpanded
            ? min(stackWidth, max(HistorySearchView.minWidth, (stackWidth * 0.55).rounded()))
            : min(stackWidth, search.compactWidth.rounded())
        searchY = placedAbove ? Self.gap : height - Self.gap - searchHeight
        self.searchHeight = searchHeight
        if isVisible, panel.isVisible,
           searchWidthSpring.isAnimating || abs(searchWidth - search.frame.width) > 0.5 {
            searchWidthSpring.animate(to: searchWidth)
            laySearch(width: searchWidthSpring.value)
        } else {
            searchWidthSpring.snap(to: searchWidth)
            laySearch(width: searchWidth)
        }
        placedHeight = scrollHeight

        // Back from a starved layout. Leaving the screen cost the panel its key
        // status; a field that still counts as focused gets it back.
        if isVisible, !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            if searchFocused { panel.makeKey() }
        }

        // Put them back the same distance from the live box, so a growing box
        // eats the stack from the far end rather than sliding it about — but
        // never mid-gesture. During an elastic overscroll the offset is *meant*
        // to be out of range, and correcting it every frame is what turns a
        // bounce into a stutter.
        if resized, !scroll.isScrolling { setNearDistance(near) }

        updateFade()
        return true
    }

    /// One frame of the panel following the live box.
    private func followOrigin() {
        let origin = NSPoint(x: originXSpring.value.rounded(), y: originYSpring.value.rounded())
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    /// The pill at `width`, centred on the stack.
    private func laySearch(width: CGFloat) {
        let frame = NSRect(x: ((stackWidth - width) / 2).rounded(), y: searchY,
                           width: width.rounded(), height: searchHeight)
        if frame != search.frame { search.frame = frame }
    }

    /// Furthest the content can be scrolled, in clip-view coordinates.
    private var maxScrollOffset: CGFloat {
        max(contentHeight - scroll.contentView.bounds.height, 0)
    }

    /// Points between the visible edge nearest the live box and the end of the
    /// content on that side. Zero means the newest box is flush against the live
    /// one, which is where the stack parks itself.
    ///
    /// Everything about the stack is measured from that edge, because that is the
    /// end the reader is anchored to and the end new boxes arrive at.
    private func nearDistance() -> CGFloat {
        let offset = scroll.contentView.bounds.origin.y
        return placedAbove ? offset : maxScrollOffset - offset
    }

    private func setNearDistance(_ distance: CGFloat) {
        let clamped = min(max(distance, 0), maxScrollOffset)
        let offset = placedAbove ? clamped : maxScrollOffset - clamped
        guard abs(offset - scroll.contentView.bounds.origin.y) > 0.5 else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func dismiss() {
        guard isVisible else { return }
        isVisible = false
        shown = []
        laidOut = []
        searchHotkey = nil
        // Whatever held it open is over: the transcript was cleared, or the
        // feature switched off. The keyboard goes back with the panel.
        unpin()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.document.subviews.forEach { $0.removeFromSuperview() }
        })
    }

    // MARK: search

    /// ⌥F: hand the field the keyboard, as a click on it would.
    func focusSearch() {
        guard !searchFocused, panel.isVisible else { return }
        // Not `makeKey()`: from an app that is not active — and this one never
        // is; it lives in the menu bar — that does nothing. This is the route
        // by which a non-activating panel takes the keyboard without bringing
        // its app forward.
        panel.makeKeyAndOrderFront(nil)
        search.focus()
    }

    /// The field has the keyboard, by whichever route.
    private func searchTookFocus() {
        searchFocused = true
        // A click has already done this through `becomesKeyOnlyIfNeeded`, and
        // ⌥F through `focusSearch`; asking again costs nothing and does not
        // depend on either.
        if !panel.isKeyWindow { panel.makeKeyAndOrderFront(nil) }
        // Open the field out of the pill.
        if isVisible { place(anchor: lastAnchor, centreX: lastCentreX) }
    }

    private func queryChanged(_ text: String) {
        query = text
        guard isVisible else { return }
        // An emptied field shows every box again, and keeps the keyboard and
        // the pin: the next word is about to be typed.
        rebuild(anchor: lastAnchor, centreX: lastCentreX, animated: false, park: true)
    }

    /// Give the keyboard back and let the stack answer to ⌥ again. Escape and
    /// an outside click both land here; the field is emptied whichever it
    /// was. With ⌥ still down the stack stays, unfocused, and the field is a
    /// click away; with ⌥ up the overlay's next poll closes it.
    ///
    /// The boxes are left as the search had them. The usual next step is the
    /// stack fading out, and what fades should be what was on screen — a
    /// stack that swapped its two matches for the full stack on the way out
    /// read as something else appearing. If the stack stays instead, the next
    /// poll puts every box back through `reposition`.
    private func unpin() {
        guard searchFocused || !query.isEmpty else { return }
        let hadQuery = !query.isEmpty
        let hadFocus = searchFocused
        searchFocused = false
        query = ""
        search.clear()

        if hadFocus {
            panel.makeFirstResponder(nil)
            // Nothing hands key status back short of leaving the screen. Out and
            // straight back in, within one turn of the run loop, does it without
            // a frame drawn in between — and a stack on its way down still fades
            // from where it was, just no longer listening.
            if panel.isKeyWindow {
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
        if hadQuery, isVisible { isStale = true }
        // Close the field back down to its pill. Not through a rebuild: the
        // boxes stay as they are, for the fade that usually follows.
        if isVisible { place(anchor: lastAnchor, centreX: lastCentreX) }
    }

    /// Notice a click that landed outside the panel. Called from the overlay's
    /// poll, alongside the modifier keys and for the same reason: watching the
    /// mouse with an event monitor is a permission prompt away from watching
    /// the keyboard with one, and the poll is already running.
    ///
    /// A click into another window also reaches `unpin` through the panel
    /// resigning key; this catches the ones that take the keyboard nowhere —
    /// the desktop, the menu bar, the click-through live box.
    func noticeClicks() {
        let down = NSEvent.pressedMouseButtons != 0
        defer { mouseWasDown = down }
        guard down, !mouseWasDown, searchFocused || isPinned else { return }
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        unpin()
    }

    private static func screen(for anchor: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
    }

    /// Vertical space for the stack on one side of the live box, measured from
    /// the pill's own edge rather than the panel's — the panel carries a
    /// transparent margin for the ⇧ ring, and counting it would leave the stack
    /// sitting four points further away than it looks.
    private static func room(above: Bool, anchor: NSRect, screen: NSScreen) -> CGFloat {
        above
            ? screen.visibleFrame.maxY - (anchor.maxY - SubtitleView.pad) - gap - screenMargin
            : (anchor.minY + SubtitleView.pad) - screen.visibleFrame.minY - gap - screenMargin
    }

    // MARK: fade

    /// Fade each edge that has boxes beyond it — and only those.
    ///
    /// The far edge carries the tall fade: it is at the top when the stack is
    /// drawn above the live box and at the bottom when it is drawn below, which
    /// are the only directions older boxes can be in. The near edge gets a much
    /// shorter one, and only once the reader has scrolled away from the live
    /// box, because until then the box against it is the newest, the one being
    /// read, and dimming it would be backwards. Scrolled, that edge hides newer
    /// boxes, and the short band says so without swallowing what is being read.
    ///
    /// Driven by the clip view's bounds notification, so it tracks the wheel
    /// rather than only the moment the stack is built.
    private func updateFade() {
        let clip = scroll.contentView
        guard let document = scroll.documentView else { return }

        let visible = clip.bounds
        let content = document.frame.height
        let farHidden = placedAbove ? content - visible.maxY : visible.minY
        let nearHidden = placedAbove ? visible.minY : content - visible.maxY

        // Nothing behind either edge — including the case where the whole stack
        // fits, when there is no edge to speak of. A fade with nothing behind it
        // promises more to see and then does not deliver it.
        guard visible.height > 0, content > visible.height + 1,
              farHidden > 0.5 || nearHidden > 0.5 else {
            if clip.layer?.mask != nil { clip.layer?.mask = nil }
            return
        }

        // Each band is capped at half the height, so the two can meet but never
        // cross.
        let far = farHidden > 0.5 ? min(min(Self.fadeHeight, farHidden), visible.height / 2) : 0
        let near = nearHidden > 0.5 ? min(min(Self.nearFadeHeight, nearHidden), visible.height / 2) : 0
        let farStop = far / visible.height
        let nearStop = near / visible.height

        // No implicit animation: the mask is recomputed on every scroll event,
        // and CoreAnimation's default quarter-second interpolation would leave
        // the fade lagging visibly behind the content.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The mask lives in the clip view's own coordinates, whose origin *is*
        // the scroll offset — so tracking `bounds` is what keeps it still while
        // the content moves under it.
        fadeMask.frame = visible
        // A plain vertical ramp. Layer unit space is y-up here, so location 0 is
        // the bottom edge.
        fadeMask.startPoint = CGPoint(x: 0.5, y: 0)
        fadeMask.endPoint = CGPoint(x: 0.5, y: 1)
        let clear = NSColor.clear.cgColor
        let solid = NSColor.black.cgColor
        // Bottom to top. Above the live box the far edge is the top and the near
        // edge the bottom; below, the other way round. A band of zero is left
        // out rather than written as a zero-width ramp, which would put a clear
        // stop on the very edge row.
        let bottom = placedAbove ? nearStop : farStop
        let top = placedAbove ? farStop : nearStop
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        if bottom > 0 {
            colors += [clear, solid]
            locations += [0, NSNumber(value: Double(bottom))]
        } else {
            colors.append(solid)
            locations.append(0)
        }
        if top > 0 {
            colors += [solid, clear]
            locations += [NSNumber(value: Double(1 - top)), 1]
        } else {
            colors.append(solid)
            locations.append(1)
        }
        fadeMask.colors = colors
        fadeMask.locations = locations
        if clip.layer?.mask !== fadeMask { clip.layer?.mask = fadeMask }
        CATransaction.commit()
    }

    // MARK: animation

    /// Boxes rise out of the live one, nearest first.
    ///
    /// The stagger is what makes the stack read as a stack rather than a single
    /// slab appearing: 35 ms apart is enough to see the order, short enough that
    /// ten boxes are all there in a third of a second.
    ///
    /// `.backwards` fill is what holds a box invisible until its turn — without
    /// it every layer sits at its final opacity until its `beginTime` arrives and
    /// the whole stack flashes in before animating.
    ///
    /// `withSearch` is the stack opening: the search pill is the nearest thing
    /// to the live box, so it goes first and the boxes follow it. A page joining
    /// a stack already up leaves it where it is.
    private func animateIn(_ pills: [HistoryPillView], ordered: [String],
                           alreadyShowing: [String], above: Bool, withSearch: Bool) {
        let carried = Set(alreadyShowing)
        let now = CACurrentMediaTime()
        var step = 0
        var rising: [CALayer] = []
        if withSearch, let layer = search.layer { rising.append(layer) }
        for (i, pill) in pills.enumerated() {
            // A box that was already on screen does not animate again; only the
            // ones that just closed do.
            if !alreadyShowing.isEmpty, carried.contains(ordered[i]) { continue }
            if let layer = pill.layer { rising.append(layer) }
        }
        for layer in rising {
            let begin = now + Double(step) * 0.035
            step += 1

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1

            // Displaced towards the live box to start with, so it looks pushed
            // out of it rather than materialising in place.
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = above ? -12 : 12
            slide.toValue = 0

            for animation in [fade, slide] {
                animation.duration = 0.22
                animation.beginTime = begin
                animation.fillMode = .backwards
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                layer.add(animation, forKey: animation.keyPath)
            }
        }
    }

    private func clamp(_ origin: NSPoint, size: NSSize, to frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX + Self.screenMargin),
                   frame.maxX - size.width - Self.screenMargin),
            y: min(max(origin.y, frame.minY + Self.screenMargin),
                   frame.maxY - size.height - Self.screenMargin))
    }
}
