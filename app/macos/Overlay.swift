// Phase 2 — the subtitle overlay.
//
// A borderless, click-through, never-focused panel that floats above everything
// including fullscreen apps. All the behaviour that made native the right call in
// PLAN.md §1 lives in this file: in Electron each of these is a flag that half
// works and regresses between versions.
//
// Interaction model: click-through by default, so the overlay never intercepts a
// click meant for the app underneath. Point at the box and it fades away under
// the cursor, so anything it is covering can be read without moving it. Hold ⇧
// to make it solid again and grabbable, and drag it somewhere else; the position
// is remembered. ⇧ rather than ⌥ because holding ⌥ while dragging a window puts
// macOS into its tiling preview, which fights the drag. With Pointer Reveal and
// Click-Through off, the box is an ordinary thing on screen: solid, taking the
// clicks that land on it, and dragged without ⇧.
//
// Hold ⌥ and the last few closed pages stack up above the live box — see
// History.swift. The box pages like broadcast subtitles, so without it anything
// you glanced away from is gone for good.
//
// ⇧ is detected by polling `NSEvent.modifierFlags` rather than installing a
// global event monitor — a keyboard monitor would demand Accessibility
// permission, and asking for a second scary prompt to enable dragging is a bad
// trade.

import CSubs
import AppKit
import Carbon.HIToolbox
import CaptionCore
import CoreImage
import UniformTypeIdentifiers

// MARK: - Panel

/// Lets the box set the cursor while another app is the active one, which is
/// always: the overlay never takes focus. Without it macOS drops the cursor a
/// background app sets, and the resize arrows over the box's edge never show.
///
/// Private, and looked up by name: the window server's per-connection
/// "SetsCursorInBackground" property, which no header declares. Should it go,
/// the lookup returns nil and the edge still resizes, only without the arrows.
enum BackgroundCursor {
    private static let allowed: Void = {
        typealias Connection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let all = dlopen(nil, RTLD_LAZY)
        guard let main = dlsym(all, "_CGSDefaultConnection"),
              let set = dlsym(all, "CGSSetConnectionProperty") else { return }
        let connection = unsafeBitCast(main, to: Connection.self)()
        _ = unsafeBitCast(set, to: SetProperty.self)(connection, connection,
                                                      "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }()

    /// Once per process; later calls are free.
    static func allow() { _ = allowed }
}

final class SubtitlePanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // .nonactivatingPanel is what stops the overlay from stealing focus
            // from whatever the user is actually working in.
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        // Not the window server's drag: it holds the pointer's offset from the
        // frame's corner, so a box that resizes under the pointer mid-drag slides
        // away from it. `SubtitleView` drags the box itself instead.
        isMovableByWindowBackground = false
        hidesOnDeactivate = false

        // Follow the user across Spaces and sit above fullscreen apps rather than
        // being left behind on one desktop.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    // Never become key or main: taking focus would pull the caret out of the
    // user's editor every time a subtitle appeared.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

final class SubtitleView: NSView {
    var committed = "" { didSet { needsDisplay = true } }
    var tentative = "" { didSet { needsDisplay = true } }
    /// The original under a translation, when both languages are shown: a
    /// second paragraph beneath the caption in a smaller, dimmer run. Empty
    /// when there is nothing to pair the caption with. Not part of `lineCount`,
    /// so paging is decided on the caption alone and the box grows for it.
    var secondary = "" { didSet { if secondary != oldValue { needsDisplay = true } } }
    /// The unsettled tail of the paragraph under the caption, dimmed the way
    /// the caption's own is — the same fraction of its run's strength — when
    /// that paragraph is the translation. Follows the translation timing
    /// setting exactly as the caption does, since it is the same emission.
    var secondaryTentative = "" { didSet { if secondaryTentative != oldValue { needsDisplay = true } } }
    var fontSize: CGFloat = 30 {
        didSet {
            for button in actionButtons { button.fontSize = fontSize }
            needsLayout = true
            needsDisplay = true
        }
    }

    /// The Text Size menu's steps, smallest first.
    static var textSizes: [(label: String, size: CGFloat)] {
        [(L("text size|Small"), 22), (L("text size|Medium"), 30),
         (L("text size|Large"), 40), (L("text size|Huge"), 52)]
    }

    /// Below Small, for the history at Small: not offered in the menu, only
    /// as the step the stack comes down to.
    static let historyFloorSize: CGFloat = 17

    /// The ⌥ history's boxes, one step down from the live box's size so the
    /// stack reads as behind it; at Small, the step is `historyFloorSize`.
    /// A size between steps comes down to the largest step under it.
    static func historyFontSize(for size: CGFloat) -> CGFloat {
        let steps = [historyFloorSize] + textSizes.map(\.size)
        guard let index = steps.lastIndex(where: { $0 <= size + 0.5 }), index > 0 else {
            return min(size, historyFloorSize)
        }
        return steps[index - 1]
    }

    /// The original's type against the caption's: smaller and a little
    /// lighter, so the caption stays the line being read and the original
    /// the note under it — the way dual subtitles are set.
    static let secondaryScale: CGFloat = 0.8
    static let secondaryOpacity: CGFloat = 0.75
    var secondaryFontSize: CGFloat { fontSize * Self.secondaryScale }
    /// Between the caption's last line and the original's first.
    static func secondaryGap(for size: CGFloat) -> CGFloat { (size * 0.35).rounded() }
    private var secondaryGap: CGFloat { Self.secondaryGap(for: fontSize) }

    /// The icon of the app whose audio is on screen, or nil for text alone,
    /// and the app's name for the styles that show it. Where it goes is
    /// `iconStyle`; the box makes room for it — see Pill.
    var icon: NSImage? {
        didSet { if icon !== oldValue { needsDisplay = true } }
    }
    var appName: String? {
        didSet { if appName != oldValue { needsDisplay = true } }
    }
    var iconStyle: Pill.IconStyle = .header {
        didSet { if iconStyle != oldValue { needsDisplay = true } }
    }

    /// How the text sits in the box — see `Pill.TextAlignment`. Changes no
    /// measurement: the box hugs its widest line either way.
    var textAlignment: Pill.TextAlignment = .start {
        didSet { if textAlignment != oldValue { needsDisplay = true } }
    }

    /// What the icon takes around the pill right now.
    private var iconRoom: Pill.IconRoom {
        Pill.room(iconStyle, size: fontSize, icon: icon != nil, name: appName)
    }

    /// The text's direction, from its first strong character: what natural
    /// alignment lays it out by, and which edge the icon sits at.
    private var isRightToLeft: Bool {
        Pill.isRightToLeft(committed.isEmpty ? tentative : committed)
    }

    private var squareCorners: Set<Pill.Corner> {
        Pill.squareCorners(style: iconStyle, icon: icon != nil, rtl: isRightToLeft)
    }

    /// The tab for the blur to cover, when there is one.
    private func blurTab(on pill: NSRect, rtl: Bool) -> BackdropBlurView.Shape.Tab? {
        guard icon != nil, iconStyle == .nameTab else { return nil }
        return .init(rect: Pill.tabRect(on: pill, name: appName, size: fontSize, rtl: rtl), rtl: rtl)
    }

    /// The box's colors follow the appearance, which is the theme's: see
    /// `Pill.Theme`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Draws the dashed ring that says the box can be picked up right now. Set
    /// while ⇧ is held, alongside the panel dropping its click-through, and
    /// with the pointer over the box when click-through is off.
    var showsDragOutline = false { didSet { if showsDragOutline != oldValue { needsDisplay = true } } }

    /// A drag of the box, in screen coordinates: where it began, each point it
    /// moves through, and its end. The controller moves the panel, since it
    /// knows which edge the box is anchored by.
    var onDragBegan: ((NSPoint) -> Void)?
    var onDragged: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?

    /// The edge a drag resizes the box by, nil while it cannot be resized:
    /// the one away from the edge the box is anchored by, so the box grows
    /// and shrinks the way it does as it fills.
    enum ResizeEdge { case top, bottom }
    var resizableEdge: ResizeEdge? {
        didSet { if resizableEdge != oldValue { updateCursor(at: pointerInView) } }
    }
    /// A drag of that edge, as the drag's own three are.
    var onResizeBegan: ((NSPoint) -> Void)?
    var onResized: ((NSPoint) -> Void)?
    var onResizeEnded: (() -> Void)?

    /// While the edge is dragged, the number of lines it has reached. The
    /// box is drawn empty at that many lines' height and a line wide, the
    /// app's name still on it, with the count in a small ringed pill in the
    /// middle.
    var resizeLines: Int? {
        didSet { if resizeLines != oldValue { needsDisplay = true } }
    }

    /// How far the text has gone behind the line count, 0 to 1: blurred and
    /// dimmed at 1, untouched at 0. Eased in and out by the controller around
    /// a resize, so the words soften as the count appears and come back as it
    /// goes.
    var resizeVeil: CGFloat = 0 {
        didSet { if resizeVeil != oldValue { needsDisplay = true } }
    }

    /// How far either side of the pill's edge a press takes the edge rather
    /// than the box.
    private static let edgeReach: CGFloat = 5

    private func isOnResizableEdge(_ point: NSPoint) -> Bool {
        guard let resizableEdge else { return false }
        let y = resizableEdge == .top ? boxRect.maxY : boxRect.minY
        return abs(point.y - y) <= Self.edgeReach && point.x >= bounds.minX && point.x <= bounds.maxX
    }

    private var pointerInView: NSPoint? {
        guard let window else { return nil }
        return convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    }

    /// The up-down arrows over the edge, and while it is dragged. Set rather
    /// than left to cursor rects, which only a key window keeps, and this
    /// panel never is one; and set on every tick of the controller's cursor
    /// poll while it is wanted, since the app under the pointer's last move
    /// may have set its own since. None of it shows without
    /// `BackgroundCursor`: the app is never the active one while someone
    /// points at its box, and macOS ignores cursors from the others.
    private var showsResizeCursor = false
    private func updateCursor(at point: NSPoint?) {
        let wants = isResizing || (point.map(isOnResizableEdge) ?? false)
        if wants {
            BackgroundCursor.allow()
            NSCursor.resizeUpDown.set()
        } else if showsResizeCursor {
            NSCursor.arrow.set()
        }
        showsResizeCursor = wants
    }

    /// The cursor for wherever the pointer is now.
    func refreshCursor() { updateCursor(at: pointerInView) }

    /// A button inline after the text, and what pressing it does. The offer
    /// to save the transcript and the trial's end have one. The panel takes
    /// clicks while it shows, and the box around the button neither acts nor
    /// drags.
    var action: (title: String, press: () -> Void)? {
        didSet { rebuildActionButtons() }
    }

    /// A second button, before `action`'s: the way out, beside the way in.
    /// Only with an `action`; the offer's Don't Ask Again.
    var secondaryAction: (title: String, press: () -> Void)? {
        didSet { rebuildActionButtons() }
    }

    private func rebuildActionButtons() {
        for button in actionButtons { button.removeFromSuperview() }
        actionButtons = []
        if let action {
            if let secondaryAction {
                let button = ActionButton(title: secondaryAction.title, target: self,
                                          action: #selector(pressSecondaryAction))
                button.bezelStyle = .flexiblePush
                button.fontSize = fontSize
                addSubview(button)
                actionButtons.append(button)
            }
            let button = ActionButton(title: action.title, target: self,
                                      action: #selector(pressAction))
            button.bezelStyle = .flexiblePush
            button.fontSize = fontSize
            addSubview(button)
            actionButtons.append(button)
        }
        needsLayout = true
        needsDisplay = true
    }

    /// The system's push button, in the bezel that takes any height, with
    /// its title set a size under the caption's so it follows Text Size. The
    /// fixed-height push button stayed one size beside a caption set large.
    ///
    /// The first click in a panel that never becomes key has to count. Under
    /// ⇧ the button is not there to be hit, so the click picks the box up.
    private final class ActionButton: NSButton {
        var fontSize: CGFloat = 30 {
            didSet {
                font = .systemFont(ofSize: (fontSize * 0.6).rounded())
                invalidateIntrinsicContentSize()
            }
        }

        /// The bezel's own size for the title, with room either side, and a
        /// caption line tall at the least.
        var size: NSSize {
            let own = intrinsicContentSize
            return NSSize(width: ceil(own.width + fontSize * 0.6),
                          height: ceil(max(own.height, Pill.lineHeight(ofSize: fontSize) * 0.9)))
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            SubtitleView.isDragHeld ? nil : super.hitTest(point)
        }
    }

    /// ⇧ is down: every box drags, the ones that take clicks included.
    static var isDragHeld: Bool { NSEvent.modifierFlags.contains(.shift) }

    /// The buttons in reading order: `secondaryAction`'s, when there is
    /// one, then `action`'s.
    private var actionButtons: [ActionButton] = []

    @objc private func pressAction() { action?.press() }
    @objc private func pressSecondaryAction() { secondaryAction?.press() }

    // MARK: Copy

    /// The Copy button at the box's top end, shown while the controller says
    /// so: while the pointer is over a box that takes clicks.
    private lazy var copyPill: CopyPill = {
        let pill = CopyPill(look: copyLook)
        pill.text = { [weak self] in self?.copyText ?? "" }
        addSubview(pill)
        return pill
    }()

    private var copyLook: CopyPill.Look {
        CopyPill.Look(fontSize: fontSize, fill: backgroundOpacity, textOpacity: 1,
                      blur: backdrop?.radius ?? Pill.backdropBlur,
                      tabHeight: iconRoom.top > 0 ? iconRoom.top : nil)
    }

    var showsCopy = false {
        didSet {
            guard showsCopy != oldValue else { return }
            if showsCopy { layoutCopyPill() }
            copyPill.show(showsCopy)
            needsDisplay = true
        }
    }

    /// Where the text fades out around the Copy button: while it shows on the
    /// box, not while it floats beside a name tab, clear of the text.
    private var copyFadeHole: NSRect? {
        showsCopy && iconRoom.top == 0 ? copyPill.frame : nil
    }

    /// What Copy puts on the clipboard: the caption as it reads now, and the
    /// other language under it when both are shown.
    var copyText: String {
        let caption = [committed, tentative].filter { !$0.isEmpty }.joined(separator: " ")
        let under = [secondary, secondaryTentative].filter { !$0.isEmpty }.joined(separator: " ")
        return [caption, under].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Whether the pointer is on the Copy button while it shows: the one
    /// place a box held under ⌥ catches the click.
    var isPointerOnCopy: Bool {
        guard showsCopy, let point = pointerInView else { return false }
        return copyPill.frame.contains(point)
    }

    /// The pointer on the Copy button brings its word up to full strength.
    func syncCopyHover() {
        let on = isPointerOnCopy
        if showsCopy || !on { copyPill.isHovered = on }
    }

    private func layoutCopyPill() {
        copyPill.look = copyLook
        copyPill.frame = Pill.copyFrame(size: copyPill.pillSize, in: boxRect, room: iconRoom,
                                        fontSize: fontSize, firstLine: iconRoom == Pill.IconRoom(),
                                        rtl: isRightToLeft, lift: Self.pad - 0.5)
    }

    // MARK: VoiceOver

    /// Whether VoiceOver finds the box and reads what it says. Off for the
    /// Settings preview's box, which is a drawing of one.
    var isReadByVoiceOver = true

    /// One element: the app's name and the text, the original under a
    /// translation included, with the button, when there is one, inside it to
    /// be pressed. Read when VoiceOver comes to it, never announced as it
    /// changes: the live box would talk over whoever is speaking. What the app
    /// says itself, the offer and the trial's end, `OverlayController`
    /// announces.
    override func isAccessibilityElement() -> Bool { isReadByVoiceOver }
    override func accessibilityRole() -> NSAccessibility.Role? { isReadByVoiceOver ? .group : nil }

    override func accessibilityLabel() -> String? {
        guard isReadByVoiceOver else { return nil }
        let caption = [committed, tentative].filter { !$0.isEmpty }.joined(separator: " ")
        let under = [secondary, secondaryTentative].filter { !$0.isEmpty }.joined(separator: " ")
        let text = [caption, under].filter { !$0.isEmpty }.joined(separator: "\n")
        guard let appName, !appName.isEmpty else { return text }
        return text.isEmpty ? appName : "\(appName): \(text)"
    }

    override func accessibilityChildren() -> [Any]? {
        guard isReadByVoiceOver else { return [] }
        return actionButtons
    }

    /// Between the text and the buttons.
    static let actionGap: CGFloat = 16
    /// Between one button and the next.
    static let actionSpacing: CGFloat = 6

    /// The width the buttons take from the text's line, gap included.
    private var actionRoom: CGFloat {
        guard !actionButtons.isEmpty else { return 0 }
        let widths = actionButtons.map { ceil($0.size.width) }
        return widths.reduce(0, +) + Self.actionSpacing * CGFloat(widths.count - 1)
            + Self.actionGap
    }

    /// The tallest button's height, 0 with none.
    private var actionHeight: CGFloat {
        ceil(actionButtons.map(\.size.height).max() ?? 0)
    }

    /// Where the text goes: the pill's text rect less the button's room on
    /// the trailing side, and, when the button is taller than the text,
    /// lowered so the two share a middle.
    private func captionRect(for text: NSAttributedString) -> NSRect {
        var rect = Pill.textRect(in: boxRect, room: iconRoom)
        guard !actionButtons.isEmpty else { return rect }
        rect.size.width -= actionRoom
        if isRightToLeft { rect.origin.x += actionRoom }
        let used = Pill.metrics(text, textWidth: rect.width).used.height
        let extra = rect.height - ceil(used)
        if extra > 0, actionHeight > ceil(used) {
            rect.size.height -= extra / 2
        }
        return rect
    }

    override func layout() {
        super.layout()
        if showsCopy { layoutCopyPill() }
        guard !actionButtons.isEmpty else { return }
        let text = Pill.textRect(in: boxRect, room: iconRoom)
        // Laid from the trailing edge inwards, so `action`'s button keeps the
        // corner it has always had and the second one sits before it.
        var edge = isRightToLeft ? text.minX : text.maxX
        for button in actionButtons.reversed() {
            let size = button.size
            let width = ceil(size.width)
            let x = isRightToLeft ? edge : edge - width
            button.frame = NSRect(x: x.rounded(), y: (text.midY - size.height / 2).rounded(),
                                  width: width, height: ceil(size.height))
            edge += isRightToLeft ? width + Self.actionSpacing : -(width + Self.actionSpacing)
        }
    }

    // The first click in a panel that never becomes key has to count, the
    // one that starts a drag as much as the one on a button.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Whether a click beside the button is swallowed rather than the start
    /// of a drag. A box with a button still moves under ⇧, like any other.
    private var takesClicks: Bool { action != nil && !Self.isDragHeld }

    override var mouseDownCanMoveWindow: Bool { false }

    private var isDragging = false
    private var isResizing = false

    override func mouseDown(with event: NSEvent) {
        guard !takesClicks else { return }
        if isOnResizableEdge(convert(event.locationInWindow, from: nil)) {
            isResizing = true
            onResizeBegan?(NSEvent.mouseLocation)
            return
        }
        isDragging = true
        onDragBegan?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        if isResizing {
            onResized?(NSEvent.mouseLocation)
        } else if isDragging {
            onDragged?(NSEvent.mouseLocation)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isResizing {
            isResizing = false
            onResizeEnded?()
            updateCursor(at: convert(event.locationInWindow, from: nil))
        } else if isDragging {
            isDragging = false
            onDragEnded?()
        }
    }

    /// How far along the bar on the pill's bottom edge is filled, 0 to 1; nil
    /// draws no bar. Only the offer to save the transcript has one: it runs
    /// out with the time left before the stack is forgotten.
    var progress: CGFloat? {
        didSet { if progress != oldValue { needsDisplay = true } }
    }

    /// The bar's height. Inside the pill's bottom padding, clear of the text.
    static let progressHeight: CGFloat = 3

    /// The borealis's frame to paint along the bottom of the pill; nil
    /// paints none. See AudioBorealis.
    var borealis: AudioBorealis.Frame? {
        didSet { if borealis != oldValue { needsDisplay = true } }
    }

    /// Cursor position in view coordinates, or nil when the pointer is nowhere
    /// near (or ⇧ is held). Punches a soft hole through the box so whatever the
    /// overlay is covering can be read by pointing at it.
    var maskCenter: NSPoint? {
        didSet {
            switch (oldValue, maskCenter) {
            case (nil, nil): break
            case let (old?, new?) where old == new: break
            default: needsDisplay = true
            }
        }
    }

    /// The blur under the pill, when there is one: a sibling beneath this view,
    /// told the pill's shape on every draw — hole included — so what it
    /// softens is exactly what the pill covers, and no more once the reveal
    /// has opened the box.
    weak var backdrop: BackdropBlurView?

    /// Full extent of the reveal about the cursor. Wider than it is tall because
    /// the box is: a circle big enough to clear the pill's width overshoots its
    /// height several times over and takes far more of the screen with it than it
    /// needs to.
    /// Settable, because it is one of the numbers you can only judge by watching
    /// it move — see Settings.swift.
    var maskSize = SubtitleView.defaultMaskSize {
        didSet { if maskSize != oldValue, maskCenter != nil { needsDisplay = true } }
    }

    static let defaultMaskSize = NSSize(width: 800, height: 400)

    /// Fraction of the way out that stays fully clear before the falloff starts.
    /// Most of the radius, leaving the falloff the last third to spend.
    private static let maskPlateau: CGFloat = 0.7

    /// How much of the box the reveal takes at its strongest. 1 erases the pill
    /// outright under the cursor; lower leaves it showing through.
    var maskStrength: CGFloat = SubtitleView.defaultMaskStrength {
        didSet {
            guard maskStrength != oldValue else { return }
            // The falloff is baked into the gradient's stops, so a new strength
            // means a new gradient.
            builtGradient = nil
            if maskCenter != nil { needsDisplay = true }
        }
    }

    static let defaultMaskStrength: CGFloat = 0.95

    /// How far open the reveal is, 0 to 1, as a share of `maskStrength`: eased
    /// by the controller as ⇧ or ⌥ close it and open it again, rather than the
    /// box snapping solid and back.
    var maskLevel: CGFloat = 1 {
        didSet {
            guard maskLevel != oldValue else { return }
            builtGradient = nil
            if maskCenter != nil { needsDisplay = true }
        }
    }

    /// The strength the hole is drawn at right now.
    private var openStrength: CGFloat { maskStrength * maskLevel }

    /// Weakest the reveal may be set to. Below about half, the hole stops
    /// reading as a hole — you get a slightly paler box and no sense that
    /// anything was revealed, which is a setting with nothing on the other end
    /// of it.
    static let minMaskStrength: CGFloat = 0.5

    /// Hard ceiling on displayed lines. The controller pages the text so this is
    /// never actually exceeded; the view clips as a last resort.
    var maxLines = SubtitleView.defaultMaxLines { didSet { needsDisplay = true } }

    static let defaultMaxLines = 2

    /// How solid the pill behind the text is. Zero is a legitimate setting —
    /// bare text over the picture, the way some players draw subtitles.
    var backgroundOpacity = SubtitleView.defaultBackgroundOpacity {
        didSet {
            guard backgroundOpacity != oldValue else { return }
            needsDisplay = true
            // The Copy button wears the same fill.
            needsLayout = true
        }
    }

    static let defaultBackgroundOpacity: CGFloat = 0.72

    private let inset = Pill.inset
    private let corner = Pill.corner

    /// Transparent margin between the pill and the panel edge, where the ⇧ ring
    /// is drawn. Reserved on every layout rather than only while ⇧ is held: a
    /// window clips its own drawing, so the room for the ring has to exist
    /// before there is a ring, and growing the panel on keypress would mean
    /// re-laying it out mid-gesture.
    static let pad: CGFloat = 4

    /// The pill itself, inside that margin and the icon's room.
    private var boxRect: NSRect { Pill.pillRect(in: bounds, pad: Self.pad, room: iconRoom) }

    /// Committed text at full strength, the in-flight tail dimmed.
    ///
    /// Spike 0A measured this engine as effectively non-revising (0 ms p50 commit
    /// lag, 4 of 66 words ever revised), so in practice the dimmed tail is usually
    /// empty. It stays because it costs nothing and is what makes a revising
    /// engine survivable if the model is ever swapped.
    func attributed(committed: String, tentative: String,
                    measuring: Bool = false) -> NSAttributedString {
        Pill.attributed(committed: committed, tentative: tentative,
                        size: fontSize, measuring: measuring, alignment: textAlignment)
    }

    private func metrics(committed: String, tentative: String,
                         maxWidth: CGFloat) -> (used: NSSize, lines: Int) {
        Pill.metrics(attributed(committed: committed, tentative: tentative, measuring: true),
                     textWidth: maxWidth - (inset.width + Self.pad) * 2)
    }

    func lineCount(committed: String, tentative: String, width: CGFloat) -> Int {
        metrics(committed: committed, tentative: tentative, maxWidth: width).lines
    }

    func attributedSecondary(_ text: String, tentative: String = "",
                             measuring: Bool = false) -> NSAttributedString {
        Pill.attributed(committed: text, tentative: tentative, size: secondaryFontSize,
                        measuring: measuring, opacity: Self.secondaryOpacity,
                        alignment: textAlignment)
    }

    func secondaryLineCount(_ text: String, width: CGFloat) -> Int {
        Pill.metrics(attributedSecondary(text, measuring: true),
                     textWidth: width - (inset.width + Self.pad) * 2).lines
    }

    /// The original's block under the caption: the height it adds, gap
    /// included and capped at `maxLines` of its own size, and the width it
    /// hugs. nil with no original to draw.
    private func secondaryBlock(maxWidth: CGFloat) -> (height: CGFloat, width: CGFloat)? {
        guard !(secondary.isEmpty && secondaryTentative.isEmpty) else { return nil }
        let m = Pill.metrics(attributedSecondary(secondary, tentative: secondaryTentative,
                                                 measuring: true),
                             textWidth: maxWidth - (inset.width + Self.pad) * 2)
        guard m.lines > 0 else { return nil }
        let capped = min(m.used.height,
                         Pill.lineHeight(ofSize: secondaryFontSize) * CGFloat(maxLines) + 4)
        return (secondaryGap + ceil(capped), m.used.width + 2 + (inset.width + Self.pad) * 2)
    }

    /// What a box of `lines` full lines measures: a line wide, and as tall as
    /// that many lines are, with the inset and the icon's room around them.
    /// Measured off that many lines of type rather than reckoned from a line's
    /// height, so the box lands at the height it will have when full and does
    /// not jump when the edge is let go.
    func size(forLines lines: Int, maxWidth: CGFloat) -> NSSize {
        let room = iconRoom
        let sample = Array(repeating: "Ag", count: max(lines, 1)).joined(separator: "\n")
        let text = ceil(Pill.metrics(attributed(committed: sample, tentative: "", measuring: true),
                                     textWidth: maxWidth).used.height)
        return NSSize(width: maxWidth,
                      height: text + (inset.height + Self.pad) * 2 + room.top + room.inside)
    }

    /// Size the box needs, hugging its content.
    ///
    /// `maxWidth` is a ceiling, not the width: a short line gets a short box.
    /// While its edge is dragged, the size of the lines it has reached.
    func fittingSize(maxWidth: CGFloat) -> NSSize {
        if let resizeLines { return size(forLines: resizeLines, maxWidth: maxWidth) }
        let room = actionRoom
        var size = Pill.fittingSize(attributed(committed: committed, tentative: tentative,
                                               measuring: true),
                                    size: fontSize, maxWidth: maxWidth - room,
                                    maxLines: maxLines, pad: Self.pad, room: iconRoom)
        // The button beside the text: the box wider by it, and at least as
        // tall as it.
        if size.height > 0, !actionButtons.isEmpty {
            size.width = min(size.width + room, maxWidth)
            size.height = max(size.height, actionHeight
                + (inset.height + Self.pad) * 2 + iconRoom.top + iconRoom.inside)
        }
        // The original under the caption adds its block: the box is as tall as
        // both and as wide as the wider.
        if size.height > 0, let block = secondaryBlock(maxWidth: maxWidth) {
            size.height += block.height
            size.width = min(max(size.width, block.width), maxWidth)
        }
        return size
    }

    /// A resize must repaint the whole box, not just the newly exposed strip.
    /// The reveal is punched through a transparency layer covering the entire
    /// pill, so a partial redraw would apply it to part of the box and leave the
    /// rest carrying the hole from the previous frame.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Falloff for the reveal, built once.
    ///
    /// Two parts. A flat core out to `maskPlateau`, held at full strength so the
    /// middle of the hole is properly gone rather than merely thinner — a falloff
    /// that starts at the very centre spends its whole span dimming and never
    /// reads as clear. Then a smoothstep tail, sampled rather than left as a pair
    /// of stops because CoreGraphics interpolates linearly between them and a
    /// straight ramp shows its edge.
    ///
    /// Smoothstep is flat at both ends, which is what makes the two parts join
    /// invisibly: the tail leaves the plateau at zero slope, so there is no crease
    /// where the core ends, and it lands on the untouched box the same way.
    private var builtGradient: CGGradient?

    /// Rebuilt only when the strength changes, so the frame poll still draws
    /// against a gradient it did not have to sample, except while the reveal
    /// is easing open or shut.
    private var maskGradient: CGGradient? {
        if let builtGradient { return builtGradient }
        builtGradient = Self.buildMaskGradient(strength: openStrength)
        return builtGradient
    }

    private static func buildMaskGradient(strength: CGFloat) -> CGGradient? {
        let space = CGColorSpaceCreateDeviceRGB()
        var colors: [CGColor] = []
        var locations: [CGFloat] = []
        func stop(_ location: CGFloat, alpha: CGFloat) {
            guard let c = CGColor(colorSpace: space, components: [0, 0, 0, alpha]) else { return }
            colors.append(c)
            locations.append(location)
        }

        stop(0, alpha: strength)
        stop(maskPlateau, alpha: strength)

        let steps = 32
        for i in 1...steps {
            let u = CGFloat(i) / CGFloat(steps)          // 0…1 across the tail
            // Scaled by `strength` too, or the tail would start above the plateau
            // it is meant to leave and draw a bright ring around the hole.
            stop(maskPlateau + u * (1 - maskPlateau),
                 alpha: strength * (1 - u * u * (3 - 2 * u)))
        }
        return CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)
    }

    /// Cuts the reveal out of everything drawn so far.
    private func punchMask(_ ctx: CGContext, at center: NSPoint) {
        guard let gradient = maskGradient else { return }
        ctx.saveGState()
        // The gradient's alpha is subtracted from what is already on the layer,
        // so opaque centre = fully transparent box.
        ctx.setBlendMode(.destinationOut)
        // CoreGraphics radial gradients are circular, so the ellipse comes from
        // squashing the space it is drawn in: move the origin to the cursor,
        // scale y, then draw a circle of the half-width there.
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: 1, y: maskSize.height / maskSize.width)
        ctx.drawRadialGradient(
            gradient,
            startCenter: .zero, startRadius: 0,
            endCenter: .zero, endRadius: maskSize.width / 2,
            options: [])
        ctx.restoreGState()
    }

    /// The blur wears the pill's shape. None at all with no text, and none at
    /// zero: that setting says bare text over the picture, and a softened
    /// rectangle behind bare text is a pill by another name.
    private func syncBackdrop(drawsPill: Bool) {
        guard let backdrop else { return }
        guard drawsPill, backgroundOpacity > 0 else {
            backdrop.shape = nil
            return
        }
        let rtl = isRightToLeft
        backdrop.shape = .init(rect: boxRect, corner: corner, hole: maskCenter.map {
            .init(center: $0, size: maskSize, strength: openStrength)
        }, square: squareCorners, tab: blurTab(on: boxRect, rtl: rtl))
    }

    override func draw(_ dirtyRect: NSRect) {
        let resizing = resizeLines != nil
        let text = attributed(committed: committed, tentative: tentative)
        // Here, because everything the shape depends on ends in a redraw: this
        // is the one place the blur is certain to be told with the pill.
        syncBackdrop(drawsPill: text.length > 0 || resizing)
        guard text.length > 0 || resizing else { return }

        // Pill, ring and text have to be composited into one image before the
        // hole is cut: `.destinationOut` only erases what is already in the
        // destination, so without a transparency layer it would eat the pill and
        // leave the text — and the text is the opaque part.
        let ctx = NSGraphicsContext.current?.cgContext
        if maskCenter != nil { ctx?.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer {
            if let ctx, let center = maskCenter {
                punchMask(ctx, at: center)
                ctx.endTransparencyLayer()
            }
        }

        let box = boxRect
        let rtl = isRightToLeft
        Pill.box.withAlphaComponent(backgroundOpacity).setFill()
        Pill.pillPath(box, radius: corner, square: squareCorners).fill()
        // The tab's fill goes down with the pill's, so what is painted over
        // the box runs into the tab too; its line, icon and name come later,
        // over that.
        let wearsTab = icon != nil && iconStyle == .nameTab
        if wearsTab, backgroundOpacity > 0 {
            Pill.fillTab(on: box, name: appName, size: fontSize, fill: backgroundOpacity, rtl: rtl)
        }
        // The glow, over the box and under everything on it, inside its whole
        // silhouette, tab included. With no pill there is no edge to sit on.
        if let borealis, backgroundOpacity > 0, let ctx {
            let silhouette = Pill.silhouette(pill: box, style: iconStyle, icon: icon != nil,
                                             name: appName, size: fontSize, rtl: rtl, grow: 0)
            if resizeVeil > 0 {
                drawVeiledBorealis(borealis, in: ctx, pill: box, path: silhouette)
            } else {
                AudioBorealisPainter.draw(borealis, in: ctx, pill: box, path: silhouette,
                                          fontSize: fontSize)
            }
        }
        // No pill, no outline: at zero the setting says bare text over the picture.
        let scale = window?.backingScaleFactor ?? 2
        if backgroundOpacity > 0 {
            Pill.outline(pill: box, style: iconStyle, icon: icon != nil, name: appName,
                         size: fontSize, rtl: rtl, scale: scale)
        }

        // Full width along the bottom edge, clipped to the pill so its
        // corners round the bar's ends. Fills from where the text starts.
        if let progress, !resizing {
            NSGraphicsContext.saveGraphicsState()
            Pill.pillPath(box, radius: corner, square: squareCorners).addClip()
            let track = NSRect(x: box.minX, y: box.minY, width: box.width, height: Self.progressHeight)
            Pill.ink.withAlphaComponent(0.15).setFill()
            track.fill()
            let width = (box.width * min(max(progress, 0), 1)).rounded()
            let filled = NSRect(x: rtl ? track.maxX - width : track.minX, y: track.minY,
                                width: width, height: track.height)
            Pill.ink.withAlphaComponent(0.7).setFill()
            filled.fill()
            NSGraphicsContext.restoreGraphicsState()
        }

        if showsDragOutline {
            // Just enough to say it can be picked up now: a hairline dashed ring
            // sitting off the pill, the same hint the web demo gives. Half a
            // point in from the panel edge so the stroke lands on the pixel
            // instead of straddling it.
            //
            // Two-tone, because the ring is drawn over whatever is on the desktop
            // and a single colour loses to half of it — white vanished against a
            // white window. `.difference` is the obvious answer and is not
            // available: a blend mode composites against what is already in *this
            // window*, and the ring hangs in the transparent margin outside the
            // pill, where there is nothing to blend with. The desktop behind is
            // composited by the window server long after this draw call. So the
            // contrast has to be carried in the ink itself: white dashes, black
            // dashes phase-shifted into the gaps between them, and whichever tone
            // the background happens to be, the other one shows against it.
            // Around the pill and its tab, not the panel: the icon's room is
            // outside it, and a tab is part of the shape being picked up.
            let ring = Pill.silhouette(pill: box, style: iconStyle, icon: icon != nil, name: appName,
                                       size: fontSize, rtl: rtl, grow: Self.pad - 0.5)
            ring.lineWidth = 1

            let dash: [CGFloat] = [3, 3]
            ring.setLineDash(dash, count: dash.count, phase: 0)
            NSColor.white.withAlphaComponent(0.75).setStroke()
            ring.stroke()

            // Offset by exactly one dash, so the black lands in the gaps the
            // white left rather than on top of it.
            ring.setLineDash(dash, count: dash.count, phase: dash[0])
            NSColor.black.withAlphaComponent(0.75).setStroke()
            ring.stroke()
        }

        // What the Copy button sits on, in a layer of its own while it shows,
        // so the glow around it takes that and not the pill: the header row
        // when there is one, and only it; the text when there is not. Closed
        // before the reveal's: defers run last first.
        let fadeHole = copyFadeHole
        let fadesHeader = iconRoom.inside > 0
        if fadeHole != nil { ctx?.beginTransparencyLayer(auxiliaryInfo: nil) }
        defer {
            if let ctx, let fadeHole, !fadesHeader {
                Pill.eraseGlow(around: fadeHole, in: ctx)
                ctx.endTransparencyLayer()
            }
        }

        // Inside the transparency layer with the rest, so the reveal opens
        // through the icon as it does through the text.
        if let icon {
            Pill.draw(icon: icon, name: appName, style: iconStyle, on: box,
                      size: fontSize, fill: backgroundOpacity, rtl: rtl, scale: scale, filled: false)
        }
        if let ctx, let fadeHole, fadesHeader {
            Pill.eraseGlow(around: fadeHole, in: ctx)
            ctx.endTransparencyLayer()
        }
        let textRect = captionRect(for: text)
        if resizeVeil > 0 {
            // Clipped to the pill: a box stepped down past its text would
            // otherwise spill the words over its edge.
            NSGraphicsContext.saveGraphicsState()
            Pill.pillPath(box, radius: corner, square: squareCorners).addClip()
            drawVeiled(text, in: textRect, scale: scale)
            NSGraphicsContext.restoreGraphicsState()
        }
        if let resizeLines {
            drawLineCount(resizeLines, in: Pill.textRect(in: box, room: iconRoom), scale: scale)
            return
        }
        if resizeVeil > 0 { return }
        text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        // The original, in the room `fittingSize` added under the caption: the
        // bottom of the text rect, the gap above it left empty.
        if let block = secondaryBlock(maxWidth: bounds.width) {
            let under = NSRect(x: textRect.minX, y: textRect.minY,
                               width: textRect.width, height: block.height - secondaryGap)
            attributedSecondary(secondary, tentative: secondaryTentative)
                .draw(with: under, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    /// One renderer for every veiled frame, as Core Image wants: building a
    /// context is the expensive part.
    private static let veilContext = CIContext(options: [.useSoftwareRenderer: false])
    /// The last veiled text, kept while the words, the rect and the veil hold:
    /// a resize sits at full veil for as long as the edge is held, and the box
    /// is redrawn on every step and every glow frame meanwhile.
    private var veiled: (key: String, image: CGImage, rect: NSRect)?

    /// The caption behind the count: blurred and dimmed by `resizeVeil`,
    /// drawn into a bitmap at the screen's scale and softened there, since a
    /// layer filter would blur the pill and the count along with it.
    private func drawVeiled(_ text: NSAttributedString, in rect: NSRect, scale: CGFloat) {
        let radius = 6 * resizeVeil
        let alpha = 1 - 0.6 * resizeVeil
        let margin = ceil(radius * 3)
        let area = rect.insetBy(dx: -margin, dy: -margin)
        let key = "\(text.string)|\(rect)|\(resizeVeil)|\(effectiveAppearance.name.rawValue)"
        if veiled?.key != key {
            veiled = nil
            let width = Int(ceil(area.width * scale)), height = Int(ceil(area.height * scale))
            guard width > 0, height > 0,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0, bitsPerPixel: 0) else { return }
            // In points before the context is made from it, or the context draws
            // in pixels and the text comes out at a fraction of its size.
            bitmap.size = area.size
            guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            // The ink is a dynamic colour: resolved against this box's look,
            // not whatever the bitmap would assume.
            effectiveAppearance.performAsCurrentDrawingAppearance {
                text.draw(with: NSRect(x: margin, y: margin, width: rect.width, height: rect.height),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let source = CIImage(bitmapImageRep: bitmap) else { return }
            let blurred = radius > 0.1
                ? source.clampedToExtent().applyingGaussianBlur(sigma: Double(radius * scale)).cropped(to: source.extent)
                : source
            guard let image = Self.veilContext.createCGImage(blurred, from: source.extent) else { return }
            veiled = (key, image, area)
        }
        guard let veiled, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.setAlpha(alpha)
        ctx.draw(veiled.image, in: veiled.rect)
        ctx.restoreGState()
    }

    /// Pixels per point the glow is softened at behind a resize: blurred, the
    /// glow has no detail left for more to keep, and it is redrawn on every
    /// frame of the display.
    private static let veiledGlowResolution: CGFloat = 0.5

    /// The glow behind the count, softened with the text: painted whole, the
    /// haze and its curves, into a small bitmap, blurred there by
    /// `resizeVeil`, and laid back over the box.
    private func drawVeiledBorealis(_ frame: AudioBorealis.Frame, in ctx: CGContext,
                                    pill: NSRect, path: NSBezierPath) {
        let radius = 6 * resizeVeil
        let resolution = Self.veiledGlowResolution
        let area = path.bounds.union(pill).insetBy(dx: -ceil(radius * 3), dy: -ceil(radius * 3))
        let width = Int((area.width * resolution).rounded(.up))
        let height = Int((area.height * resolution).rounded(.up))
        guard width > 0, height > 0,
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        bitmap.scaleBy(x: resolution, y: resolution)
        bitmap.translateBy(x: -area.minX, y: -area.minY)
        AudioBorealisPainter.draw(frame, in: bitmap, pill: pill, path: path, fontSize: fontSize)
        guard let painted = bitmap.makeImage() else { return }
        let source = CIImage(cgImage: painted)
        let blurred = radius > 0.1
            ? source.clampedToExtent().applyingGaussianBlur(sigma: Double(radius * resolution))
                .cropped(to: source.extent)
            : source
        guard let image = Self.veilContext.createCGImage(blurred, from: source.extent) else { return }
        ctx.saveGState()
        // Inside the box, as it is sharp: the blur spreads it past the edge.
        ctx.addPath(path.cgPath)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: area)
        ctx.restoreGState()
    }

    /// The count a resize has reached, centred where the text goes: in the
    /// box's ink, in a pill ringed with a hairline and nothing else, so it
    /// reads as a note on the empty box rather than a caption in it.
    private func drawLineCount(_ lines: Int, in rect: NSRect, scale: CGFloat) {
        let label = NSAttributedString(
            string: LP("Max %lld Lines", one: "Max %lld Line", lines),
            attributes: [.font: Pill.font(ofSize: max(13, (fontSize * 0.55).rounded())),
                         .foregroundColor: Pill.ink])
        let size = label.size()
        let height = ceil(size.height) + 8
        let width = ceil(size.width) + height
        // Whole points, then half a pixel in, so the hairline sits on the pixel.
        let hairline = 1 / scale
        let ring = NSRect(x: (rect.midX - width / 2).rounded(), y: (rect.midY - height / 2).rounded(),
                          width: width, height: height).insetBy(dx: hairline / 2, dy: hairline / 2)
        let path = NSBezierPath(roundedRect: ring, xRadius: ring.height / 2, yRadius: ring.height / 2)
        path.lineWidth = hairline
        Pill.ink.withAlphaComponent(0.6).setStroke()
        path.stroke()
        label.draw(at: NSPoint(x: ring.midX - size.width / 2, y: ring.midY - size.height / 2))
    }
}

// MARK: - Controller

/// A call on every frame the display draws, at the display's own rate: 120
/// Hz on a ProMotion screen, 60 on most others, whatever an external one runs
/// at. For animation, which a fixed-interval timer steps at the wrong rate
/// for one screen or another. Started on a screen it runs whether or not any
/// window is showing, which the overlay's polls need while the box is faded
/// out; started in a view it pauses while the view is not on screen.
///
/// An object of its own because a display link wants an Objective-C target,
/// and holds it: whoever owns one stops it when done with it.
final class FrameClock: NSObject {
    private let tick: () -> Void
    private var link: CADisplayLink?

    init(_ tick: @escaping () -> Void) { self.tick = tick }

    func start(on screen: NSScreen) {
        replace(with: screen.displayLink(target: self, selector: #selector(step)))
    }

    func start(in view: NSView) {
        replace(with: view.displayLink(target: self, selector: #selector(step)))
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// In `.common`, so it keeps going while a menu or a drag has the run loop
    /// in a tracking mode.
    private func replace(with new: CADisplayLink) {
        link?.invalidate()
        new.add(to: .main, forMode: .common)
        link = new
    }

    @objc private func step(_ link: CADisplayLink) { tick() }
}

final class OverlayController {
    private let panel: SubtitlePanel
    private let view: SubtitleView
    /// Under the view, filling the panel with it — see BackdropBlur.swift.
    private let backdrop = BackdropBlurView(blending: .behindWindow)
    private var idleTimer: Timer?
    private var modifierTimer: Timer?
    private lazy var frameClock = FrameClock { [weak self] in self?.frameTick() }
    private var panelScreenObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// True only while `layout()` is moving the panel itself, so the move
    /// observer can tell our repositioning apart from the user's dragging.
    private var isRepositioning = false

    // Fade on *text* inactivity, not audio inactivity.
    //
    // Audio-driven fading fails on the case that matters most: music. A backing
    // track keeps the voice gate open indefinitely, so the endpoint never fires
    // and the last thing anyone said stays frozen on screen over the music. What
    // the reader cares about is whether new words are arriving, not whether the
    // room is quiet.
    private var lastTextAt = Date.distantPast
    private var lastShownText = ""
    /// How long the box stays up with no new words before it fades. Settings ▸
    /// UI's Hide after.
    var textIdleTimeout: TimeInterval = OverlayController.defaultTextIdleTimeout
    static let defaultTextIdleTimeout: TimeInterval = 4
    /// The slider's ends. Under four seconds a short line is gone before it is
    /// read; over twenty the box is still up long after the conversation moved on.
    static let textIdleTimeouts: ClosedRange<TimeInterval> = 4...20

    /// When the page currently on screen was opened.
    ///
    /// Gates the clause carried across a page break. Carrying exists for a box
    /// that turns over before it can be read; a box that has been up as long as
    /// the idle fade would have allowed has already given the reader that time,
    /// and repeating its last clause then only spends room in the new box on text
    /// they are done with.
    private var pageShownAt = Date.distantPast

    /// A page turn held back for reading — see `holdPage(after:)`: until when
    /// the page on screen stays, whatever the pager has moved on to.
    private var holdUntil: Date?
    private var holdTimer: Timer?
    /// The next draw is a new page, and dates `displayedPageSince`.
    private var pendingPageChange = false
    /// When the page on screen was first drawn: how long it has been readable.
    private var displayedPageSince = Date.distantPast
    /// Characters a second a reader gets through at the caption's size — 17,
    /// the upper end of what subtitle guidelines allow, since a reader here
    /// has been following the words as they came rather than meeting a full
    /// box cold. Characters rather than words: it is the rendered text that
    /// takes reading, and a word is a different amount of it in French, in
    /// German and in Japanese. Text drawn smaller reads slower in proportion.
    private let readingRate: Double = 17
    /// The most a page may be held for. The hold is only what the reader is
    /// still owed, so it is usually a fraction of this. A second, tried at
    /// two: every hold puts the caption that much further behind the speaker,
    /// and two read as the box lagging rather than as time to finish it.
    private let maxHold: TimeInterval = 1
    /// `SUBS_DEBUG_PAGING=1` reports each hold, mirroring SUBS_DEBUG_TRANSLATE.
    private static let debugPaging = ProcessInfo.processInfo.environment["SUBS_DEBUG_PAGING"] != nil

    /// The last clause boundary a page break carried from.
    ///
    /// A clause is carried into the *next* box and no further. When nothing new
    /// settles behind it the box can fill and turn over on the growing tail alone,
    /// and that same boundary is still the newest one in reach, so without this it
    /// is carried again and again and opens box after box. Recording it means the
    /// carry can only ever move forwards.

    /// The box has been emptied and is showing nothing: it faded out, or a switch
    /// cleared it.
    ///
    /// The stored transcripts outlive the box, which is what lets ⌃ swap language
    /// instantly, and it also meant ⌃ could redraw a box that had already faded
    /// and hand back a caption the reader had finished with. A repaint is not new
    /// speech, so it does not bring the box back; the next words do.
    private var boxIsCleared = false

    /// Set while a repaint is only swapping the stack's language, so it is
    /// replaced in place rather than staged in again.
    private var isSwappingLanguage = false

    /// Whether the page about to close is one worth carrying a clause from.
    ///
    /// Two rules, and the first is absolute: a box that has faded is never carried
    /// from. Whatever was in it is gone from the screen and from the reader, so
    /// repeating its last clause is not continuity, it is old text taking up the
    /// top of a box that should be showing what is being said now. `boxIsCleared`
    /// is still set while the first words after a fade are being paged, which is
    /// what keeps that first new box clean.
    ///
    /// Second, a box that sat there as long as the fade would have allowed has
    /// already given the reader that time, so there is nothing to hand back.
    private var allowsCarry: Bool {
        guard !boxIsCleared else { return false }
        return Date().timeIntervalSince(pageShownAt) < textIdleTimeout
    }
    private var isDraggable = false

    /// How solid the box behind the text is, 0…1. The ⌥ stack follows it, a step
    /// behind — see `HistoryPillView.recession`.
    var boxOpacity: CGFloat {
        get { view.backgroundOpacity }
        set { view.backgroundOpacity = newValue }
    }

    /// How far the picture behind the box is softened, in points; 0 is not at
    /// all. The ⌥ stack takes the same number: unlike the fill there is no
    /// stepping back to do, since a softer picture is a softer picture.
    var backdropBlur: CGFloat = Pill.backdropBlur {
        didSet { backdrop.radius = backdropBlur }
    }

    /// How much of the box the pointer reveal takes, 0…1.
    var revealOpacity: CGFloat {
        get { view.maskStrength }
        set { view.maskStrength = newValue }
    }

    /// Full extent of that reveal.
    var revealSize: NSSize {
        get { view.maskSize }
        set { view.maskSize = newValue }
    }

    /// The app whose audio is being transcribed, as the tap names its family,
    /// or nil while nothing is known to be playing. Set from the poll in
    /// PlayingApp.swift. The live box wears its icon, and every page that
    /// closes under it is tagged with it, so the ⌥ stack shows a Zoom box over
    /// a Chrome box when that is what happened.
    var playingApp: String? {
        didSet {
            guard playingApp != oldValue else { return }
            // The app's own line wears the app's own name until it goes.
            guard !holdsFinalCaption else { return }
            wearPlayingApp()
        }
    }

    private func wearPlayingApp() {
        view.icon = playingApp.map { AppCatalog.shared.icon(for: $0) }
        view.appName = playingApp.map { app in
            let name = AppCatalog.shared.name(for: app)
            guard showsSpeakerOnAppLabel, let speaker else { return name }
            return "\(name) · Speaker \(speaker + 1)"
        }
        // The box makes room for the icon, so whatever is on screen re-fits.
        layout()
    }

    /// How loud what the app listens to is, for the glow along the box's
    /// bottom edge; nil paints none.
    var voiceMeter: VoiceMeter?
    /// Whether the glow is wanted at all: the menu's Audio Borealis row.
    var isBorealisEnabled = true
    private var borealis = AudioBorealis()
    private var borealisTickedAt: CFTimeInterval = 0
    /// The glow's knobs, live: the debug window turns them.
    var borealisConfig: AudioBorealis.Config {
        get { borealis.config }
        set { borealis.config = newValue }
    }

    /// The boxes' colors, the live box's and the stack's alike — see
    /// `Pill.Theme`. Set as the panels' appearance, which every color on
    /// them follows; nil, for auto, hands them back to the system's.
    var theme: Pill.Theme = .auto {
        didSet {
            guard theme != oldValue else { return }
            panel.appearance = theme.appearance
            history.theme = theme
        }
    }

    /// Where the icon goes, on the live box and the stack alike — see
    /// `Pill.IconStyle`.
    var iconStyle: Pill.IconStyle {
        get { view.iconStyle }
        set {
            guard newValue != view.iconStyle else { return }
            view.iconStyle = newValue
            layout()
        }
    }

    /// How the text sits in the boxes — see `Pill.TextAlignment`.
    var textAlignment: Pill.TextAlignment {
        get { view.textAlignment }
        set { view.textAlignment = newValue }
    }

    /// The untranslated transcript, kept even while the translated one is on
    /// screen, so ⌃ can show the original without waiting for new speech.
    private var sourceWords: [TimedWord] = []
    /// The translated rendering, when there is one: its words, the dimmed
    /// tail, the chunk boundaries paging carries across a break, and the
    /// transcript it was made from.
    private var translatedWords: TranslatedTranscript?
    /// Show the original beneath the translation. Only while a translation is
    /// what the box shows: in the source language there is nothing to pair it
    /// with. ⌃ does nothing while this is on — both languages are already on
    /// screen, and a key that hid one of them to show the other read as a
    /// glitch rather than a peek.
    var showsBothLanguages = false {
        didSet {
            guard showsBothLanguages != oldValue else { return }
            // Not left to the next poll: ⌃ held as the setting goes on would
            // show the original alone for a tick.
            if showsBothLanguages { showsSource = false }
            redraw()
        }
    }

    /// The pair points back out of the target language: the target itself is
    /// being spoken, and is translated into the other language. The target
    /// stays on top whichever way the pair points — it is the language being
    /// read, and a reader should not have to look for it — so here the
    /// transcript as spoken is the caption and the translation goes under it.
    /// Set by main.swift with the pair; see `translationPair()` there.
    var translationBelow = false {
        didSet {
            guard translationBelow != oldValue else { return }
            redraw()
        }
    }

    /// The stream carrying the target language while translating: the caption
    /// whenever a translation is shown at all.
    private var captionStream: CaptionStreams.Stream { translationBelow ? .source : .translated }

    /// The stream the box is drawing as its caption right now: the source as
    /// spoken when there is no translation to show or ⌃ asks for the original,
    /// else whichever carries the target language.
    private var primaryStream: CaptionStreams.Stream {
        showingSourceLanguage ? .source : captionStream
    }

    /// Set while a translation target is chosen. Without it a stale translation
    /// would keep being drawn after translation was switched off.
    var prefersTranslation = false {
        didSet {
            guard prefersTranslation != oldValue else { return }
            translatedWords = nil
            // Start the clock: the box stays empty rather than flashing the
            // original, but only for as long as a translation plausibly takes.
            lastTranslatedAt = Date()
            clearForLanguageChange()
        }
    }

    /// Empty the box when translation is switched on or off.
    ///
    /// Whatever is in it is in the language just left, and it would otherwise sit
    /// there until enough new words arrived to page it out: half a box in one
    /// language and half in the other. The next words open a clean box.
    ///
    /// The stacks are kept. Each already holds one language and ⌃ picks between
    /// them, so nothing there is mixed; the page on screen is banked into its own
    /// stack on the way out, in the language it was written in.
    private func clearForLanguageChange() {
        cancelHold()
        bankPages()
        boxIsCleared = true
        page = ""
        pendingCommit = ""
        tentative = ""
        lastShownText = ""
        startFreshOnNextText = false
        view.committed = ""
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }
        updateHistory()
    }
    /// ⌃ held: show the original language for as long as it is down. Never
    /// with both languages shown — see `showsBothLanguages`.
    ///
    /// Polled with ⇧ rather than watched with an event monitor, for the reason in
    /// the file header: a keyboard monitor would demand Accessibility permission,
    /// and a second scary prompt to peek at a caption is a bad trade.
    private var showsSource = false

    /// Whether the overlay is captured by screen recording and sharing.
    ///
    /// `sharingType = .none` asks the window server to leave the window out of
    /// what any other process can read, which is how password managers keep
    /// themselves out of screenshots. It applies to the capture itself rather than
    /// to any one app, so it covers Zoom, QuickTime and Screenshot alike without
    /// naming any of them — and it is not a promise about a camera pointed at the
    /// screen.
    ///
    /// On by default. Subtitles you cannot share are the surprising choice, and a
    /// setting that hides things should be one the user reached for.
    var isVisibleInScreenShare = true {
        didSet {
            panel.sharingType = isVisibleInScreenShare ? .readOnly : .none
            history.isVisibleInScreenShare = isVisibleInScreenShare
        }
    }

    /// Whether pointing at the box fades it away and clicks pass through it. On
    /// by default; the menu turns it off for anyone who would rather the
    /// subtitles simply stayed put, and could be picked up without ⇧.
    var isRevealEnabled = true {
        didSet {
            // Close any hole that is open right now — the next poll would leave it
            // there, since a disabled reveal stops updating the centre at all.
            if !isRevealEnabled { view.maskCenter = nil }
            syncClickThrough()
        }
    }

    /// Let clicks through to what is under the box, or catch them: while ⇧
    /// holds it for dragging, while it carries a button, and always with the
    /// reveal off. Never while paused or faded out, when catching them would
    /// make an invisible rectangle that swallows clicks meant for whatever is
    /// underneath. Called on every modifier poll as well as on each change,
    /// because the box fading out and coming back does not pass through here.
    private func syncClickThrough() {
        let catches = !isSuppressed
            && (isDraggable || isHandled || view.action != nil
                || (!isRevealEnabled && panel.alphaValue > 0) || view.isPointerOnCopy)
        if panel.ignoresMouseEvents == catches { panel.ignoresMouseEvents = !catches }
    }

    /// Paused. Nothing may put the overlay back on screen until resumed — not
    /// words already in the engine's pipeline when the pause landed, not the ⇧
    /// drag nudge.
    ///
    /// A flag rather than a one-shot `clearAndHide()`: pausing gates audio at the
    /// tap, but whatever is already inside the ring and the recogniser keeps
    /// arriving for a beat afterwards, and each update called `show()` and put the
    /// box straight back up.
    private var isSuppressed = false
    /// The box holds a line of the app's own rather than the transcript's —
    /// see `showFinalCaption` — and nothing the recognizer or the translator
    /// still has in flight may replace it or fade it.
    private var holdsFinalCaption = false {
        didSet { if holdsFinalCaption != oldValue { syncEscapeHotkey() } }
    }

    // ── paging state ──
    // Broadcast subtitles never scroll a wall of text: they fill, clear, and
    // start again. `page` is what is on screen now; when the next words would
    // push past maxLines we drop the page entirely and begin a new one from
    // those words, rather than letting old text slide up out of view.
    private var page = ""
    private var pendingCommit = ""
    private var tentative = ""
    private var startFreshOnNextText = false
    /// An utterance ended and the translated pager's fresh mark is waiting for
    /// the words that are genuinely next — see `markPagersFreshAtUtteranceEnd`.
    private var translatedFreshDeferred = false

    // ── history ──
    // Pages that have scrolled off, oldest first, brought back by holding ⌥.
    // Recorded at every point a page closes rather than sampled, because by the
    // time a page is gone from `page` there is nothing left to read it from.
    private let history = HistoryController()
    /// Both renderings, paged together. Not two properties: handing one to a
    /// helper that reached for the other is what crashed on an overlapping access.
    private var streams = CaptionStreams()

    /// Whether the box is currently showing the language as spoken.
    ///
    /// `translatedWords == nil` is part of it and not an afterthought: a target
    /// can be chosen and still produce nothing to draw, which is exactly what
    /// happens when the audio turns out to be in the target language already. The
    /// box falls back to the original there, so the stack has to as well. Reading
    /// `prefersTranslation` alone left the stack pointed at an empty pager, and
    /// ⌥ showed nothing at all.
    private var showingSourceLanguage: Bool {
        guard !showsSource, prefersTranslation, translationProducesOutput else { return true }
        // Translation is on and working, but has not spoken yet. Falling back to
        // the original here is how switching translation on came to flash a line
        // of untranslated text before the first translation landed: the box was
        // cleared for the change and then immediately refilled in the language
        // just left. Nothing is the honest thing to show for the half second it
        // takes.
        //
        // Unless it has been much longer than that, in which case something has
        // gone wrong that the reader should not have to sit through blank. An
        // overlay showing nothing is indistinguishable from a broken app.
        return translatedWords == nil && waitedTooLongForTranslation
    }

    /// Whether translation is expected to produce anything at all: false while a
    /// language pack downloads, and false when the audio turns out to be in the
    /// target language already, where the untranslated captions are the answer.
    var translationProducesOutput = false {
        didSet { if translationProducesOutput != oldValue { lastTranslatedAt = Date() } }
    }

    /// When translated words last arrived, or when translation was last enabled.
    private var lastTranslatedAt = Date.distantPast
    /// Set by a fade: the first words after it restart the wait for their
    /// translation. The clock ran from the last translation before the fade
    /// and had long expired, so the original was drawn for the half second a
    /// translation takes — a flash of the other language at the start of every
    /// turn after a silence.
    private var patienceRestartsOnNextWords = false

    /// How long the box may stay empty waiting for a translation that is not
    /// coming before the original is shown instead.
    private let translationPatience: TimeInterval = 4

    private var waitedTooLongForTranslation: Bool {
        Date().timeIntervalSince(lastTranslatedAt) >= translationPatience
    }

    /// A box as the stack keeps it: what it showed as its caption and, when
    /// there was one, the other language that went with it — each in the
    /// language it was in on screen, whichever way the pair pointed then.
    /// The stack is its own record for that reason: read off one pager's
    /// boxes by the current direction, a turn in the other direction turned
    /// every earlier box into the other language.
    private struct StackBox {
        let text: String
        var under: String
        let app: String?
        /// Which way the pair pointed for this box: true when its caption was
        /// the speech itself and the translation went under. From the pager it
        /// came out of, not the direction at the time it was recorded — a box
        /// that closes at a turn's end is recorded once the next turn's words
        /// arrive, which may already be the other way round.
        let below: Bool
        /// The box's first word — its start in the audio and the word itself —
        /// by which an emission is known to be about these words at all, and
        /// its span, by which the other language is matched to it. Never by
        /// span alone: the recogniser's clock restarts, and a box from before
        /// the restart overlapped one after it in time and took its words.
        let start: TimeInterval
        let end: TimeInterval
        /// The pager box it was taken from: its stream and its place in that
        /// stream's count, by which a box revised after it closed is found
        /// again — see `reviseStack`.
        let stream: CaptionStreams.Stream
        let ordinal: Int
        /// The diarizer's index for who said it; nil with speaker breaks off.
        let speaker: Int?
        /// When its first and last words reached the screen, by the clock:
        /// what a saved SubRip file is timed by.
        let shown: Date
        let lastWord: Date

        var head: StackHead { StackHead(stream: stream, ordinal: ordinal, shown: shown) }
    }

    /// Which box a stack started with: the same box when it is the same
    /// session, and gone once it has been trimmed off or forgotten.
    private struct StackHead: Equatable {
        let stream: CaptionStreams.Stream
        let ordinal: Int
        let shown: Date
    }

    /// When each word first arrived, by stream, audio start and text: the
    /// audio times restart at every endpoint, so a box's words are looked up
    /// here for the clock times it was on screen. Emptied with the stack.
    private struct SeenWord: Hashable {
        let stream: CaptionStreams.Stream
        let start: TimeInterval
        let text: String
    }
    private var wordSeenAt: [SeenWord: Date] = [:]

    /// Who is talking, as the diarizer numbers them, and the last change:
    /// where in the utterance's audio it fell and who was talking before. A
    /// box is the one before the change when most of it is before it.
    private var speaker: Int?
    private var speakerChange: (time: TimeInterval, previous: Int?)?

    /// Someone is talking from `time`, in audio time: the first voice of an
    /// utterance, or a new one. Only the saved transcript uses it.
    func markSpeaker(_ index: Int, at time: TimeInterval) {
        speakerChange = (time, speaker)
        speaker = index
        if showsSpeakerOnAppLabel, !holdsFinalCaption, !offersTranscript { wearPlayingApp() }
    }

    /// Settings ▸ Models: a saved transcript says who spoke each turn, when
    /// more than one voice is in it.
    var namesSpeakersInTranscript = true

    /// Settings ▸ Debug, in development builds: the app label also names
    /// who the diarizer hears, by its own number counted from 1.
    var showsSpeakerOnAppLabel = false {
        didSet {
            guard showsSpeakerOnAppLabel != oldValue, !holdsFinalCaption, !offersTranscript else { return }
            wearPlayingApp()
        }
    }

    /// Who said a box, from the last change and which side of it the box's
    /// middle is. Not its first word: the diarizer's turn and the recognizer's
    /// words disagree by a few tenths of a second, and the page breaks on a
    /// word near the change, so the new speaker's first box often starts just
    /// before the time reported. Read by its start, that box went to the
    /// speaker before, and the new name appeared a box late.
    private func speaker(from start: TimeInterval, to end: TimeInterval) -> Int? {
        guard let speakerChange, (start + end) / 2 < speakerChange.time else { return speaker }
        return speakerChange.previous
    }

    private var stack: [StackBox] = []
    /// How many of each pager's boxes have been taken into the stack.
    private var recorded: [CaptionStreams.Stream: Int] = [:]
    /// The last few emissions, newest first, kept for pairing: a box that
    /// closes at a turn's end is recorded once the next turn's first words
    /// arrive, when the emission about it has already been replaced.
    private var recentEmissions: [TranslatedTranscript] = []

    /// The stream whose closed boxes are the stack's: the caption's while a
    /// translation is being shown, the source otherwise — including while
    /// translation is on but has nothing to say, the audio being in the target
    /// language already, when the source is what the box shows.
    private var historyStream: CaptionStreams.Stream {
        prefersTranslation && translationProducesOutput ? captionStream : .source
    }

    /// Take into the stack the boxes that have left the screen since last
    /// time, from the caption's stream; the other stream's are the other
    /// language of those, and are only marked as seen. Each new box is paired
    /// straight away from the words on hand.
    private func recordClosedBoxes() {
        for stream in [CaptionStreams.Stream.source, .translated] {
            let total = streams.closedCount(stream)
            let unseen = total - (recorded[stream] ?? 0)
            recorded[stream] = total
            guard stream == historyStream, unseen > 0 else { continue }
            let boxes = streams.boxes(stream)
            let fresh = boxes.suffix(min(unseen, boxes.count))
            for (offset, box) in fresh.enumerated() {
                let seen = { (word: TimedWord?) in
                    word.flatMap { self.wordSeenAt[SeenWord(stream: stream, start: $0.start, text: $0.text)] }
                        ?? Date()
                }
                stack.append(StackBox(text: box.text, under: "", app: box.app,
                                      below: stream == .source, start: box.start, end: box.end,
                                      stream: stream, ordinal: total - fresh.count + offset,
                                      speaker: speaker(from: box.start, to: box.end),
                                      shown: seen(box.words.first), lastWord: seen(box.words.last)))
                if Self.debugPaging {
                    FileHandle.standardError.write(
                        "[stack] + \(stream) \"\(box.text)\"\n".data(using: .utf8)!)
                }
            }
        }
        if stack.count > effectiveHistoryDepth {
            stack.removeFirst(stack.count - effectiveHistoryDepth)
        }
        pairHistory()
    }

    /// A change of speaker found late took words back out of boxes that had
    /// already closed, from `ordinal` on. The stack's copies of those go, and
    /// are taken again as they are now — the outgoing speaker's box without the
    /// new speaker's first words, and those words where they went.
    private func reviseStack(_ stream: CaptionStreams.Stream, from ordinal: Int) {
        stack.removeAll { $0.stream == stream && $0.ordinal >= ordinal }
        if let seen = recorded[stream], seen > ordinal { recorded[stream] = ordinal }
        if Self.debugPaging {
            FileHandle.standardError.write("[stack] revise \(stream) from #\(ordinal)\n"
                .data(using: .utf8)!)
        }
    }

    /// The other language under each box in the stack, from the words on
    /// hand. A box is paired from an emission only when that emission is about
    /// its words — its first word is one of the emission's own, at the same
    /// moment — so a translation that lands after its page has left the screen
    /// still reaches it, and an emission from another stretch of speech, on a
    /// clock that has since restarted, cannot. Same rule as the live box's for
    /// the text: the words over the box's span, and nothing when that is the
    /// caption again.
    private func pairHistory() {
        guard prefersTranslation else { return }
        let emissions = [translatedWords].compactMap { $0 } + recentEmissions
        guard !emissions.isEmpty else { return }
        for index in stack.indices {
            let box = stack[index]
            // The newest emission about this box's words, if any is.
            guard let transcript = emissions.first(where: { emission in
                let own = box.below ? emission.source : emission.words
                return own.contains { $0.start == box.start && box.text.hasPrefix($0.text) }
            }) else { continue }
            let other = box.below ? transcript.words : transcript.source
            let text = other.filter { $0.start >= box.start && $0.start < box.end }
                .map(\.text).joined(separator: " ")
            let under = TranslatedTranscript.sameWords(text, box.text) ? "" : text
            // Only ever towards something: a pairing can be bettered by a later
            // emission — the settled form of a tail — but never taken away by
            // one that has nothing over this span, or the caption's own words.
            guard !under.isEmpty, under != box.under else { continue }
            stack[index].under = under
            if Self.debugPaging {
                FileHandle.standardError.write(
                    "[stack] pair \"\(box.text.prefix(24))\" ← \"\(under.prefix(40))\"\n"
                        .data(using: .utf8)!)
            }
        }
    }

    /// Everything the stack holds goes, with the pagers' boxes.
    private func forgetStack() {
        stack.removeAll()
        recorded = [:]
        recentEmissions = []
        // A new session starts here, and its first voice is Speaker 1 again.
        speaker = nil
        speakerChange = nil
        wordSeenAt = [:]
        offeredSinceText = false
        autoSaved = nil
        onHistoryCleared?()
    }

    /// Fired whenever the whole stack goes: the idle expiry, a transcript
    /// saved, and a pause, model or source switch. The diarizer starts over
    /// with it, so the voices it numbers belong to the session the stack holds.
    var onHistoryCleared: (() -> Void)?

    /// The page that has closed but is still on screen, held there for
    /// reading by `holdPage`: its stream and place in that stream's count, as
    /// `StackBox` keeps them. It is in the stack already, for the transcript,
    /// but kept out of the ⌥ stack until the live box lets it go, or the stack
    /// animates in a box the reader is still reading in the live one.
    private var heldBox: (stream: CaptionStreams.Stream, ordinal: Int)?

    /// The stack as shown, each box wearing the icon of the app it came from.
    /// Under ⌃ each box shows its other language, the way the live box shows
    /// the original; with both languages shown the other goes under, and ⌃
    /// is not held (`showsSource` is never set then). Without the page still
    /// held on screen, if there is one.
    private var pastPages: [HistoryEntry] {
        stack.filter { box in
            guard let heldBox else { return true }
            return box.stream != heldBox.stream || box.ordinal != heldBox.ordinal
        }.map { box in
            let swapped = showsSource && !box.under.isEmpty
            return HistoryEntry(text: swapped ? box.under : box.text,
                                icon: box.app.map { AppCatalog.shared.icon(for: $0) },
                                name: box.app.map { AppCatalog.shared.name(for: $0) },
                                under: showsBothLanguages ? box.under : "")
        }
    }

    /// How many closed pages ⌥ can reach back through. Adjustable in Settings;
    /// lowering it drops the oldest immediately rather than waiting for the
    /// buffer to be pushed down to the new size. Zero keeps none at all, which
    /// is how someone turns the whole thing off without losing the ⌥ gesture
    /// having ever meant anything. `unlimitedHistoryDepth` keeps every box,
    /// within `historyDepthCap`.
    ///
    /// Only the count. How long a silence forgets the stack is `historyExpiry`,
    /// and the two are deliberately not tied: someone who asks for every box
    /// has said nothing about how long they want them for.
    var historyDepth = OverlayController.defaultHistoryDepth {
        didSet {
            guard historyDepth != oldValue else { return }
            streams.trim(to: effectiveHistoryDepth)
            if stack.count > effectiveHistoryDepth {
                stack.removeFirst(stack.count - effectiveHistoryDepth)
            }
        }
    }

    /// The slider's last stop: keep everything. A sentinel rather than the cap
    /// itself, so a plist written at today's cap does not turn into a fixed
    /// number the day the cap moves.
    static let unlimitedHistoryDepth = Int.max

    /// Everything, out of the box. The expiry is what keeps the stack about
    /// what was just said; a count on top of it only ever lost a box someone
    /// was scrolling back for.
    static let defaultHistoryDepth = unlimitedHistoryDepth

    /// What "everything" comes to in practice. A page is a sentence or two, so
    /// this is a few hundred kilobytes of text at the very most — and a stack
    /// nobody could scroll to the end of long before then.
    static let historyDepthCap = 2000

    /// The depth the pagers are actually asked to keep.
    private var effectiveHistoryDepth: Int { min(historyDepth, Self.historyDepthCap) }

    /// How bright the ⌥ stack's text is against the live box's white.
    var historyTextOpacity = HistoryPillView.defaultTextOpacity

    /// Which side the ⌥ stack's boxes line up on.
    var historyAlignment: StackLayout.Alignment = .start

    /// Forget the stack after this long with no new text, so ⌥ pressed an hour
    /// later does not answer with whatever was on screen before lunch. Off keeps
    /// it until a pause or a model switch.
    var historyExpiry: TimeInterval = OverlayController.defaultHistoryExpiry
    var isHistoryExpiryEnabled = true

    /// Half a minute. Long enough to cover a pause in the conversation, short
    /// enough that the stack is about what was *just* said.
    static let defaultHistoryExpiry: TimeInterval = 30

    /// Whether the box offers to save the transcript at all. Settings ▸
    /// Transcript, and the offer's own Don't Ask Again. Off, Save Transcript…
    /// is still in the status menu.
    var isTranscriptOfferEnabled = true {
        didSet { if !isTranscriptOfferEnabled { withdrawTranscriptOffer(fading: true) } }
    }

    /// How long the offer stays up, which its bar counts down. At the tail it
    /// comes up this long before the stack is forgotten. Settings ▸ Transcript.
    var transcriptOfferDuration: TimeInterval = OverlayController.defaultTranscriptOfferDuration

    static let defaultTranscriptOfferDuration: TimeInterval = 10
    /// The slider's ends. Under five seconds there is no reading the question
    /// and reaching the button; over half a minute it is a fixture.
    static let transcriptOfferDurations: ClosedRange<TimeInterval> = 5...30

    /// The offer's Don't Ask Again was pressed: main.swift saves it and
    /// Settings follows.
    var onDisableTranscriptOffer: (() -> Void)?

    /// Settings ▸ Transcript's Save without asking: where the box would ask,
    /// it saves the transcript itself, to `transcriptDirectory` in the format
    /// last used, and says so instead. Only with the offer on.
    var savesTranscriptAutomatically = false

    /// The shortest Clear after there is. Twice the default offer, so the
    /// captions have been quiet for ten seconds before it asks, rather than
    /// asking over the box that has only just faded.
    static let minHistoryExpiry: TimeInterval = 20

    /// The box is showing the offer to save the transcript. See
    /// `offerTranscriptIfIdle`.
    private var offersTranscript = false {
        didSet {
            if !offersTranscript { savedTranscript = nil }
            if offersTranscript != oldValue { syncEscapeHotkey() }
        }
    }
    /// The file the box is saying it saved, while it says so in the offer's
    /// place. Nil while it asks, and when it is down.
    private var savedTranscript: URL?
    /// The file the stack was last saved to without asking, under the title
    /// and in the format it was written with, and the box that headed it.
    /// While that box still heads the stack the session is the same one, so
    /// the next save brings this file up to date rather than starting
    /// another. Forgotten with the stack.
    private var autoSaved: (url: URL, title: String, format: TranscriptFormat, head: StackHead)?
    /// The save panel is up. The stack is kept while it is, whatever the
    /// timer says: it is what is being saved.
    private var savingTranscript = false
    /// How long the offer has been up, the time the pointer spent over it
    /// left out. It lasts `transcriptOfferDuration`, wherever it came up.
    private var offerElapsed: TimeInterval = 0
    /// The offer has been made since the last words: once per quiet spell,
    /// so one that came up on silence and ran out does not come back at the
    /// tail.
    private var offeredSinceText = false

    /// Whether the source has stopped making sound, as Core Audio tells it:
    /// nothing playing, or the chosen app not playing. Nil when there is no
    /// telling, for the microphone. See `PlayingAppMonitor.onSilence`.
    var isSourceSilent: Bool?
    /// When the offer's bar last ticked, for holding it while hovered.
    private var offerTickedAt: Date?

    /// Whether ⌥ brings the last few boxes back. Menu-controlled, like the
    /// pointer reveal.
    var isHistoryEnabled = true {
        didSet { if !isHistoryEnabled { history.dismiss() } }
    }
    /// Audio time the current page starts at. Words spoken before this are on a
    /// page the reader has already lost.
    ///
    /// A *time* anchor rather than a word index: a word-count anchor skips any
    /// words that arrive in the same update as the anchor point, which is why a
    /// new page could previously start part-way into a sentence.
    private var pageStartTime: TimeInterval = 0
    /// Latest word end seen, so "start fresh" means "from here on in the audio".

    /// Fired once the overlay has faded because no new text arrived.
    ///
    /// The engine uses it to drop a context that may be full of music, and the
    /// translator to drop everything it has not delivered: a box that has gone
    /// takes its pending work with it, or that work arrives into the next box as
    /// text from before the pause.
    var onFaded: (() -> Void)?

    /// Remembered across launches once the user drags the panel somewhere.
    ///
    /// Stored as (centre x, bottom y) rather than the frame origin: the box now
    /// resizes with its text, and anchoring the origin would make it grow
    /// rightwards off its position instead of expanding evenly about its centre.
    private static let anchorKey = "overlay.anchor"
    private static let anchorTopKey = "overlay.anchorTop"

    /// Where the box sits, and the *only* source of truth for it while running —
    /// `UserDefaults` is persistence, read once here and written on release.
    /// `layout()` used to re-read the defaults on every text update, so a word
    /// arriving mid-drag snapped the panel back to the last saved position.
    ///
    /// nil until the user drags: the fallback is derived from the screen on every
    /// layout, so an untouched overlay follows a resolution or display change.
    private var anchor: NSPoint?

    /// Whether `anchor.y` is the pill's top edge rather than its bottom. A box
    /// in the upper half of the screen keeps its top where it was left and
    /// grows downwards, away from the edge it is near, as one in the lower half
    /// keeps its bottom and grows upwards. Decided while it is dragged, as it
    /// crosses the middle.
    private var anchorsTop = false

    /// The pointer's offset from `anchor` while the box is being dragged, nil
    /// otherwise. Measured from the anchor rather than the frame, so a box
    /// that grows or shrinks under the pointer mid-drag stays where it is held.
    private var dragGrab: NSPoint?

    /// Where an edge resize began: the pointer's height and the line count
    /// the box had. Nil when no edge is being dragged.
    private var resizeStart: (y: CGFloat, lines: Int)?

    /// A drag or a resize is under way: the box is in the reader's hand.
    private var isHandled: Bool { dragGrab != nil || resizeStart != nil }

    /// The Lines setting changed by dragging the box's edge, for the settings
    /// to keep.
    var onMaxLinesChosen: ((Int) -> Void)?
    /// The anchor `frame` puts the pill on, by the edge it is anchored by.
    private func edgeAnchor(of frame: NSRect) -> NSPoint {
        NSPoint(x: frame.midX,
                y: anchorsTop ? frame.maxY - SubtitleView.pad : frame.minY + SubtitleView.pad)
    }
    /// The box's ceiling: a line of `Pill.maxLineCharacters` at the current
    /// text size, or less of the screen on one too narrow for it.
    private var maxWidth: CGFloat {
        let line = Pill.maxWidth(ofSize: view.fontSize, pad: SubtitleView.pad)
        guard let screen = NSScreen.main else { return min(line, 900) }
        return min(screen.frame.width * 0.75, line)
    }

    init(fontSize: CGFloat) {
        let initial = NSRect(x: 0, y: 0, width: 900, height: 80)
        panel = SubtitlePanel(contentRect: initial)
        view = SubtitleView(frame: initial)
        view.fontSize = fontSize
        // The blur beneath the view, both filling the panel, and the view telling
        // the blur its shape.
        let root = NSView(frame: initial)
        backdrop.frame = root.bounds
        backdrop.autoresizingMask = [.width, .height]
        view.autoresizingMask = [.width, .height]
        view.backdrop = backdrop
        root.addSubview(backdrop)
        root.addSubview(view)
        panel.contentView = root
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        if let saved = UserDefaults.standard.string(forKey: Self.anchorKey) {
            anchor = NSPointFromString(saved)
            anchorsTop = UserDefaults.standard.bool(forKey: Self.anchorTopKey)
        }

        view.onDragBegan = { [weak self] in self?.beginDrag(at: $0) }
        view.onDragged = { [weak self] in self?.drag(to: $0) }
        view.onDragEnded = { [weak self] in self?.endDrag() }
        view.onResizeBegan = { [weak self] in self?.beginResize(at: $0) }
        view.onResized = { [weak self] in self?.resize(to: $0) }
        view.onResizeEnded = { [weak self] in self?.endResize() }

        // While the user drags, the panel's own position is the truth — this is
        // what feeds it back into `anchor` so the next word lays out where the box
        // now is.
        //
        // `queue: nil` on purpose: the block then runs synchronously inside the
        // posting call, so `isRepositioning` is still true for the moves layout()
        // makes itself. Re-deriving the anchor from a frame we just computed would
        // creep it half a pixel sideways on every word, because the origin is
        // rounded and half a text width is not.
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: nil
        ) { [weak self] _ in
            guard let self, !self.isRepositioning else { return }
            // The anchor is the pill's edge, not the panel's: the panel carries
            // a transparent margin for the ⇧ ring, and folding that into the
            // anchor would walk the box a few points on every drag.
            self.anchor = self.edgeAnchor(of: self.panel.frame)
        }

        // Resolution changed, a display arrived or left, or the arrangement
        // moved. The remembered position is in the coordinates of a screen that
        // no longer exists at that size, so the box can be sitting off the edge
        // of the new one — and `maxWidth`, which decides where the text pages,
        // has changed with it.
        //
        // An untouched overlay derives its position from the screen on every
        // layout and so fixes itself, but only on the next word: a machine that
        // is quiet across the change stays wrong until somebody speaks.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.screenChanged()
        }

        // Polled rather than armed per update: a one-shot timer must be cancelled
        // and re-armed on every text change, and anything that forgets to re-arm
        // strands the overlay on screen — which is exactly the bug this replaces.
        // A poll cannot be forgotten.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.fadeIfTextIdle()
            self?.expireHistoryIfIdle()
            self?.offerTranscriptIfIdle()
        }

        // ⇧ toggles grabbable. Polled, not monitored — see the file header.
        modifierTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Not while paused: the panel is invisible then, and making an
            // invisible panel grabbable just means it swallows clicks meant for
            // whatever is underneath.
            // ⌃ peeks at the original language. Checked before the drag branch
            // because it changes what is drawn, not how the panel behaves, and the
            // two are independent: peeking while dragging is fine. Inert with
            // both languages shown: there is nothing to peek at.
            let wantsSource = NSEvent.modifierFlags.contains(.control) && !self.showsBothLanguages
            if wantsSource != self.showsSource {
                self.showsSource = wantsSource
                self.redraw()
            }

            let wantsDrag = NSEvent.modifierFlags.contains(.shift) && !self.isSuppressed
            if wantsDrag != self.isDraggable {
                self.isDraggable = wantsDrag
                // Nudge visible while it can be grabbed, so it is obvious the
                // overlay is now catching clicks instead of passing them through.
                if wantsDrag { self.panel.alphaValue = 1.0 }
                if !wantsDrag { self.saveAnchor() }
            }
            self.syncClickThrough()
        }

        // Cursor tracking for the reveal. Polled for the same reason ⇧ is (see
        // the file header) and because the panel is click-through: it receives no
        // mouse events of its own, so there is nothing to track from.
        //
        // On the display's frames rather than a job on the 0.15s modifier
        // poll: the hole is attached to the pointer, and at 0.15s it visibly lags
        // behind it. The screen's frames, at its own rate, so a ProMotion screen
        // gets all 120 of them; and the screen's rather than the panel's, which
        // would stop while the box is faded out and ⌥ is still to be noticed.
        // Moved to whichever screen the box is dragged onto.
        if let screen = panel.screen ?? NSScreen.main { frameClock.start(on: screen) }
        panelScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let screen = self.panel.screen else { return }
            self.frameClock.start(on: screen)
        }
    }

    /// Everything that moves with the frames: the reveal, the stack, the ring
    /// and the cursor, the glow, the offer's bar, and the box easing into a
    /// resize and out of it.
    private func frameTick() {
        updateHistory()
        tickRevealLevel()
        updateMask()
        updateDragOutline()
        updateCopyButton()
        tickAudioBorealis()
        tickTranscriptOffer()
        tickFrameEase()
        tickResizeVeil()
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        idleTimer?.invalidate()
        modifierTimer?.invalidate()
        frameClock.stop()
        if let panelScreenObserver { NotificationCenter.default.removeObserver(panelScreenObserver) }
    }

    /// Raise or drop the ⌥ stack.
    ///
    /// Rebuilt whenever the entries differ from what is on screen, so a page
    /// closing while ⌥ is still held joins the stack immediately — `present`
    /// leaves boxes that were already up alone and animates only the new one.
    private func updateHistory() {
        let flags = NSEvent.modifierFlags
        // Same poll, same reason: an outside click unpins the search, and the
        // mouse buttons are as pollable as the modifiers.
        history.noticeClicks()
        // Never alongside ⇧: that is the drag gesture, and a second panel over
        // the box while it is being picked up just gets in the way. Pinned by
        // the search, the stack stays whatever the keys are doing: that is what
        // pinning is for.
        let held = flags.contains(.option) && !flags.contains(.shift)
        let wants = isHistoryEnabled && !isSuppressed && !pastPages.isEmpty
            && (held || history.isPinned)
        guard wants else {
            history.dismiss()
            return
        }

        // The stack follows the live box: peeking at the original with ⌃ and
        // leaving the boxes above it translated would be the worst of both.
        let entries = pastPages
        let style = HistoryStyle(
            fontSize: SubtitleView.historyFontSize(for: view.fontSize),
            fill: view.backgroundOpacity * HistoryPillView.recession,
            textOpacity: historyTextOpacity,
            blur: backdropBlur,
            iconStyle: view.iconStyle,
            textAlignment: view.textAlignment,
            alignment: historyAlignment)
        if history.shown != entries {
            history.present(entries: entries, style: style, anchor: panel.frame,
                            centreX: boxCentreX, maxWidth: maxWidth,
                            animated: !isSwappingLanguage)
        } else if history.style != style {
            // A setting changed under a stack that is up, ⌥ held while
            // Settings is clicked: the same boxes, redrawn in place.
            history.present(entries: entries, style: style, anchor: panel.frame,
                            centreX: boxCentreX, maxWidth: maxWidth, animated: false)
        } else {
            // The live box resizes on every word; the stack rides along with it.
            history.reposition(anchor: panel.frame, centreX: boxCentreX)
        }
        history.updateHover()
    }

    /// One frame of the glow: read the meter, advance the driver, paint.
    /// Only while the box is up and the glow is wanted; otherwise the glow
    /// is dropped and the driver rests, so it opens from silence.
    private func tickAudioBorealis() {
        // The offer to save the transcript glows too, like the trial's last
        // line: it sits on a box emptied by the fade, but it is on screen.
        guard let voiceMeter, isBorealisEnabled, panel.alphaValue > 0,
              !boxIsCleared || offersTranscript else {
            if view.borealis != nil {
                view.borealis = nil
                borealis.reset()
            }
            borealisTickedAt = 0
            return
        }
        let now = CACurrentMediaTime()
        let dt = borealisTickedAt == 0 ? 1.0 / 60 : min(0.05, now - borealisTickedAt)
        borealisTickedAt = now
        let reading = voiceMeter.read()
        let frame = borealis.step(dt: dt, loudness: reading.loudness, bands: reading.bands)
        // Nothing to paint in silence, and nothing to redraw for: the box is
        // left alone until a voice lifts the glow.
        view.borealis = frame.glow > 0.002 ? frame : nil
    }

    /// Point the reveal at the cursor, or turn it off. The keys that close it
    /// ease it shut through `revealLevel` rather than here: see `revealHeld`.
    ///
    /// ⌥ closes it for a different reason than ⇧: the pointer has to be over the
    /// stack to scroll it, and a hole punched through the live box under the
    /// cursor while the user is reading the history above it is pure noise. A
    /// stack pinned by its search is being read the same way, with ⌥ released.
    /// `frame` is the panel frame to measure against, for the case where the
    /// panel is about to be given one and has not got it yet.
    private func updateMask(for frame: NSRect? = nil) {
        let panelFrame = frame ?? panel.frame
        guard isRevealEnabled,
              !holdsFinalCaption,
              !offersTranscript,
              panel.alphaValue > 0 else {
            view.maskCenter = nil
            // Ready at whatever the keys say, so a box coming back under the
            // pointer is not seen easing open.
            revealLevel = revealHeld ? 0 : 1
            view.maskLevel = revealLevel
            return
        }
        // Held shut, and eased all the way there: no hole to draw.
        guard revealLevel > 0 else {
            view.maskCenter = nil
            return
        }

        // Cheap reject before converting: only a cursor within the reveal's reach
        // of the panel can affect a pixel of it. The reach is wide enough that the
        // box starts opening before the pointer is over it.
        let reach = view.maskSize
        let point = NSEvent.mouseLocation
        guard panelFrame.insetBy(dx: -reach.width / 2, dy: -reach.height / 2).contains(point) else {
            view.maskCenter = nil
            return
        }
        // Subtraction rather than the panel's own coordinate conversion: this is
        // called before the panel has been given `frame`, so asking the panel
        // where a screen point lands would answer for the frame it is leaving. A
        // borderless panel's content view fills its frame exactly, so the two
        // agree in every other respect.
        view.maskCenter = NSPoint(x: point.x - panelFrame.minX, y: point.y - panelFrame.minY)
    }

    /// What closes the reveal while it is on: ⇧ to pick the box up, ⌥ and a
    /// pinned stack to read the history over it, and the box being dragged or
    /// resized. Read off the keys every frame, not `isDraggable`, so the box
    /// starts going solid the moment ⇧ is down rather than on the next
    /// modifier poll.
    private var revealHeld: Bool {
        let flags = NSEvent.modifierFlags
        return flags.contains(.shift) || flags.contains(.option) || history.isPinned || isHandled
    }

    /// How far open the reveal is before easing, 0 to 1.
    private var revealLevel: CGFloat = 1
    private var revealTickedAt: CFTimeInterval = 0
    private static let revealEase: CFTimeInterval = 0.15

    /// The reveal easing shut as ⇧ or ⌥ goes down and open as it comes up,
    /// once a frame, the hole staying under the pointer while it does.
    private func tickRevealLevel() {
        let target: CGFloat = revealHeld ? 0 : 1
        guard revealLevel != target else {
            revealTickedAt = 0
            return
        }
        let now = CACurrentMediaTime()
        let dt = revealTickedAt == 0 ? 1.0 / 120 : min(0.05, now - revealTickedAt)
        revealTickedAt = now
        let step = CGFloat(dt / Self.revealEase)
        revealLevel = target > revealLevel ? min(1, revealLevel + step) : max(0, revealLevel - step)
        let t = revealLevel
        view.maskLevel = t * t * (3 - 2 * t)
    }

    // MARK: text

    /// Committed text arrives as a delta and does *not* render on its own — the
    /// core always follows a COMMITTED with a TENTATIVE, and rendering on both
    /// would paint the new word beside a stale tail for one frame.
    func appendCommitted(_ delta: String) {
        pendingCommit += delta
    }

    func setTentative(_ text: String) {
        guard !holdsFinalCaption else { return }
        if !(pendingCommit.isEmpty && text.isEmpty) {
            offeredSinceText = false
            withdrawTranscriptOffer(fading: false)
        }
        tentative = text
        if startFreshOnNextText, !(pendingCommit.isEmpty && text.isEmpty) {
            startFreshOnNextText = false
            page = ""
        }

        let grown = page + pendingCommit
        if !page.isEmpty,
           view.lineCount(committed: grown, tentative: text, width: maxWidth) > view.maxLines {
            // Would overflow: clear and restart from the words that caused it, so
            // nothing is lost and nothing scrolls.
            page = trimLeadingSpace(pendingCommit)
        } else {
            page = grown
        }
        pendingCommit = ""

        boxIsCleared = false
        view.committed = page
        view.tentative = tentative
        layout()
        show()
    }

    /// Render the transcript, paged by audio time.
    ///
    /// Fills to `maxLines`, then clears and restarts from the first word that did
    /// not fit — the same behaviour as broadcast subtitles, which never scroll.
    /// `speculative` is an unfinished tail rendered in the dimmed style — text the
    /// app expects to replace. Live translation is the first thing to use it: the
    /// sentence being spoken is translated before it is finished, so it is shown
    /// as provisional until the settled version arrives. Empty for transcription,
    /// where the recogniser barely revises at all.
    /// The transcript as spoken. Always stored, drawn when there is no translation
    /// to show or while ⌃ is held.
    func setSourceWords(_ words: [TimedWord]) {
        sourceWords = words
        if patienceRestartsOnNextWords {
            patienceRestartsOnNextWords = false
            lastTranslatedAt = Date()
        }
        let visible = page(.source, words, chunkStarts: [])
        // Drawn when the source is the caption: with no translation to show,
        // under ⌃, or with the target language itself being spoken, where the
        // translation goes under it. Not for the original under a translation:
        // that comes from the transcript the translation was made of, with the
        // translation, never from words it has not seen — see `underCaption`.
        guard primaryStream == .source else { return }
        showWords(visible, under: underCaption)
    }

    /// The transcript translated. Stored and drawn unless ⌃ is asking for the
    /// original.
    func setTranslatedWords(_ transcript: TranslatedTranscript) {
        if let previous = translatedWords {
            recentEmissions.insert(previous, at: 0)
            if recentEmissions.count > 4 { recentEmissions.removeLast() }
        }
        translatedWords = transcript
        lastTranslatedAt = Date()
        // Translated words are proof that translation produces output, whatever
        // the last word update was told: after a pair change the pack is
        // confirmed again, and a turn that ends inside that moment sends no
        // further words to carry the news. Without this its translation arrived
        // at a box that believed there was none, and went under nothing.
        translationProducesOutput = true
        // The utterance's last translation lands after the endpoint that closed
        // it: the settled form of the page on screen, not new speech, and it
        // pages into that page. The fresh mark the endpoint left for this
        // stream is applied by the first words that are new.
        if translatedFreshDeferred, !transcript.settlesUtterance {
            translatedFreshDeferred = false
            streams.markFresh(.translated)
        }
        pageTranslated(transcript)
    }

    /// Page the translation and draw it, or the caption it goes under.
    private func pageTranslated(_ transcript: TranslatedTranscript) {
        let visible = page(.translated, transcript.words, chunkStarts: transcript.chunkStarts,
                           speculativeFrom: transcript.speculativeFrom)
        pairHistory()
        guard !showsSource else { return }
        if translationBelow {
            // The caption is the transcript as spoken, already on screen; the
            // translation goes under it. Not for a box that has faded — the
            // page it would bring back is finished with, and new speech returns
            // through the source words as it always has.
            guard !boxIsCleared else { return }
            showWords(streams.currentWords(.source), under: underCaption)
        } else {
            showWords(visible, speculativeFrom: transcript.speculativeFrom, under: underCaption)
        }
    }

    /// Whether the other language goes under the caption right now: the
    /// setting, and a translation that is expected. Not a question of ⌃, which
    /// changes what is drawn and nothing else — the streams are paged the same
    /// way whether or not they are on screen, or the stack would not match the
    /// box.
    private var pairsLanguages: Bool {
        showsBothLanguages && prefersTranslation && translationProducesOutput
    }

    /// The other language, for under the caption: the words the translation was
    /// made from, over the translated page's span — or, with the target
    /// language itself being spoken, the translation over the caption's span
    /// instead (`translationBelow`). Translated words
    /// are timed over the sentence they render, so a translated page begins
    /// where a source sentence does, and the pager has already made sure that
    /// much fits — see `longestFittingPrefix`. Only ever those words: what the
    /// recogniser has said since is not translated yet, and at an utterance's
    /// end it is the next speaker, possibly in the other language — the old
    /// translation over the new speech showed French under French. Empty
    /// whenever the box is not showing a translation.
    ///
    /// And never the same language twice. A translation that came back as its
    /// own original — the pair pointing the wrong way for the first word or two
    /// of a new speaker, before the recogniser named the language — is the
    /// original, and is shown once.
    /// The paragraph under the caption: settled text, and the unsettled tail to
    /// draw dimmed after it.
    typealias Under = (settled: String, tentative: String)

    private var underCaption: Under {
        guard pairsLanguages, !showingSourceLanguage, let transcript = translatedWords else { return ("", "") }
        let caption = streams.currentWords(captionStream)
        guard let last = caption.last else { return ("", "") }
        let from = streams.start(captionStream)
        let other = translationBelow ? transcript.words : transcript.source
        let span = other.filter { $0.start >= from && $0.start < last.end }
        // Under the caption the translation keeps its unsettled tail dimmed, as
        // it is when it is the caption: the same words, split at the same
        // moment, so the translation timing setting reads the same either way.
        // The original as spoken has no tail.
        let cut = translationBelow ? transcript.speculativeFrom : .greatestFiniteMagnitude
        let settled = span.filter { $0.start < cut }.map(\.text).joined(separator: " ")
        var tentative = span.filter { $0.start >= cut }.map(\.text).joined(separator: " ")
        // `Pill.attributed` joins the two runs with no separator.
        if !settled.isEmpty, !tentative.isEmpty { tentative = " " + tentative }
        let whole = settled + tentative
        return TranslatedTranscript.sameWords(whole, caption.map(\.text).joined(separator: " "))
            ? ("", "") : (settled, tentative)
    }

    /// Run a stream through its own pager, measuring with the live box's geometry
    /// so the hidden stack breaks where it would have if it were on screen.
    /// `tentative` must be whatever the box would be drawing alongside these
    /// words, because it is measured alongside them.
    ///
    /// The dimmed tail occupies the box, so a page overflows sooner with one than
    /// without. Paging the stack without it meant the pager thought a page still
    /// had room after the box had already moved on, and a closed box only reached
    /// the stack once enough settled words arrived to overflow it unaided: the
    /// history ran a settle or more behind the screen.
    /// Advance one stream and hand back the page to draw.
    ///
    /// `tentative` must be whatever the box would be drawing alongside these
    /// words, because it is measured alongside them: the dimmed tail occupies the
    /// box, so a page overflows sooner with one than without.
    /// Advance one stream and hand back the page to draw.
    ///
    /// A pending fresh page is applied to both streams first, so a pause breaks
    /// them at the same word. `CaptionStreams` owns both, which is why that is
    /// safe to do here: the earlier shape passed one pager `inout` and reached for
    /// the other inside the call, an overlapping access that Swift traps on at
    /// runtime. It crashed on the first translated word after a pause, and neither
    /// the compiler nor the test suite could see it.
    private func page(_ stream: CaptionStreams.Stream, _ words: [TimedWord],
                      chunkStarts: [TimeInterval],
                      speculativeFrom: TimeInterval = .greatestFiniteMagnitude) -> [TimedWord] {
        if startFreshOnNextText {
            startFreshOnNextText = false
            streams.markFresh(.source)
            if !translatedFreshDeferred { streams.markFresh(.translated) }
        }
        // Whichever stream is the caption pages on both paragraphs, with the
        // other language's words over the same span — see `longestFittingPrefix`.
        let paired: [TimedWord]? = pairsLanguages && stream == captionStream
            ? (translationBelow ? translatedWords?.words : translatedWords?.source) : nil
        let onScreen = stream == primaryStream
        // What the reader has to get through before the page may turn: the
        // caption as it stands and, with both languages shown, the paragraph
        // drawn under it — `view.secondary`, at its smaller size. The page
        // turns on whichever of the two fills first, and the hold is sized on
        // whichever takes longer to read.
        let captionBefore = streams.currentWords(stream).map(\.text).joined(separator: " ")
        let now = Date()
        for word in words {
            let key = SeenWord(stream: stream, start: word.start, text: word.text)
            if wordSeenAt[key] == nil { wordSeenAt[key] = now }
        }
        let underBefore = onScreen ? view.secondary + view.secondaryTentative : ""
        var holding = false
        let paged = streams.ingest(stream, words: words, chunkStarts: chunkStarts,
                                   depth: effectiveHistoryDepth, allowCarry: allowsCarry,
                                   speculativeFrom: speculativeFrom, app: playingApp) { candidates in
            longestFittingPrefix(candidates, pairedWith: paired)
        }
        if let revised = paged.revisedFrom { reviseStack(stream, from: revised) }
        if paged.brokePage {
            pageShownAt = Date()
            if onScreen {
                pendingPageChange = true
                holding = holdPage(caption: captionBefore, under: underBefore)
            }
        }
        if paged.brokePage || paged.revisedFrom != nil { recordClosedBoxes() }
        // The box that just closed is the one the hold keeps on screen, when it
        // is this stream's that the stack takes.
        if holding, stream == historyStream, let last = stack.last, last.stream == stream {
            heldBox = (stream, last.ordinal)
        }
        pageStartTime = streams.start(stream)
        return paged.visible
    }

    /// The page on screen is leaving. Keep it for as long as a reader who has
    /// been reading since it appeared still needs to finish it — its text as
    /// drawn, the slower-read of its two paragraphs when there are two, at
    /// `readingRate`, less the time it has had — and no longer than `maxHold`.
    /// A slow speaker's page was read as it filled and turns at once; a fast
    /// one's, or a translated sentence that landed whole, gets its moment. The
    /// words keep arriving into the pager meanwhile, and the redraw at the end
    /// shows wherever they have got to. A hold already running is left alone:
    /// a page that turned during it was never seen, and is owed nothing.
    /// Whether it began a hold: the page that closed is then the one on screen.
    @discardableResult
    private func holdPage(caption: String, under: String) -> Bool {
        if let holdUntil, holdUntil > Date() { return false }
        let shown = Date().timeIntervalSince(displayedPageSince)
        let needed = max(readingTime(caption, scale: 1),
                         readingTime(under, scale: SubtitleView.secondaryScale))
        let owed = needed - shown
        let hold = min(max(owed, 0), maxHold)
        if Self.debugPaging {
            FileHandle.standardError.write(String(
                format: "[page] turn: %d + %d chars need %.1fs, shown %.1fs → hold %.2fs\n",
                caption.count, under.count, needed, shown, hold).data(using: .utf8)!)
        }
        guard hold > 0.05 else { holdUntil = nil; return false }
        holdUntil = Date().addingTimeInterval(hold)
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.holdUntil = nil
            // The page leaves the box as it joins the stack: the redraw's
            // stack update animates it in.
            self.heldBox = nil
            self.redraw()
        }
        return true
    }

    /// Seconds to read `text` drawn at `scale` of the caption's size.
    private func readingTime(_ text: String, scale: CGFloat) -> TimeInterval {
        Double(text.count) / (readingRate * Double(scale))
    }

    /// The box is being emptied: nothing left to hold for.
    private func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdUntil = nil
        heldBox = nil
        pendingPageChange = false
    }

    /// Draw whichever rendering is currently wanted, from what the pagers hold.
    ///
    /// Nothing is re-paged. Both streams have already been broken into boxes by
    /// their own pager as words arrived, so a swap is a matter of drawing the
    /// other one's current page: idempotent by construction, and incapable of
    /// disagreeing with the stack it is shown above.
    private func redraw() {
        defer {
            isSwappingLanguage = true
            updateHistory()
            isSwappingLanguage = false
        }
        // The stack still swaps with ⌃ while the box is down; the box itself does
        // not come back until there is something new to say.
        guard !boxIsCleared else { return }
        if primaryStream == .source {
            showWords(streams.currentWords(.source), under: underCaption)
        } else if let translated = translatedWords {
            showWords(streams.currentWords(.translated),
                      speculativeFrom: translated.speculativeFrom, under: underCaption)
        }
    }

    /// `chunkStarts` are the audio times settled units begin at, when the caller
    /// has such units. Live translation does: it settles a clause at a time. Given
    /// them, a page that overflows restarts at the last chunk boundary it showed
    /// rather than at the word that spilled, so the final clause of the old box
    /// opens the new one and stays readable across the break. Empty for
    /// transcription, which pages as it always has.
    /// `speculativeFrom` is the audio time the unsettled tail begins at, so the
    /// words from there on are drawn dimmed. It is part of `words` rather than a
    /// string beside them, which is what lets the box fill with it and turn over
    /// when full rather than evicting settled clauses to make room.
    /// `secondary` is the original to set under these words, when both
    /// languages are shown — see `secondaryText`; empty draws the words alone.
    func showWords(_ words: [TimedWord],
                   speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                   under: Under = ("", "")) {
        guard !isSuppressed, !holdsFinalCaption else { return }
        // A page held for reading — see `holdPage(after:)`. Its own redraw
        // comes back here when it ends.
        if let holdUntil, holdUntil > Date() { return }
        guard !words.isEmpty else { return }

        // `words` is already the page: whichever pager owns this stream broke it,
        // and the same break put the box that left into the stack. Deciding it
        // again here is what let the two drift apart.
        let settled = words.filter { $0.start < speculativeFrom }
        let unsettled = words.filter { $0.start >= speculativeFrom }
        let text = settled.map(\.text).joined(separator: " ")
        // `Pill.attributed` concatenates the two runs with no separator, so the
        // dimmed one carries the space that divides them.
        var speculative = unsettled.map(\.text).joined(separator: " ")
        if !text.isEmpty, !speculative.isEmpty { speculative = " " + speculative }

        // An unchanged transcript is not new information: return before touching
        // visibility at all.
        //
        // Testing `alphaValue == 0` here instead was not enough. Engines resend
        // identical partials several times a second; mid-fade the alpha is
        // somewhere between 0 and 1, so the guard missed, `show()` animated it
        // back to full, and the idle poll faded it again — the overlay flashed.
        // Worse, `show()` interrupting the fade meant its completion handler kept
        // seeing a non-zero alpha and never cleared the page, so the next speaker
        // appended to text that should long since have gone.
        // The tail is part of what is on screen, so an unchanged transcript with a
        // changed tail is still new information. Comparing only `text` here left
        // the live translation frozen on its first guess. The original under
        // the caption counts the same way: it changes with every spoken word
        // while the translation above it waits for the clause to settle.
        guard text != lastShownText || speculative != tentative
                || under.settled != view.secondary || under.tentative != view.secondaryTentative
        else { return }
        lastShownText = text
        lastTextAt = Date()
        offeredSinceText = false
        withdrawTranscriptOffer(fading: false)
        // A new page: the first draw is when its reading time starts. A box
        // coming back from empty is a new page too.
        if pendingPageChange || boxIsCleared {
            displayedPageSince = Date()
            pendingPageChange = false
        }

        page = text
        pendingCommit = ""
        tentative = speculative
        boxIsCleared = false
        view.committed = page
        view.tentative = speculative
        view.secondary = under.settled
        view.secondaryTentative = under.tentative
        layout()
        show()
    }

    /// Index one past the last word that still fits within `maxLines` — and,
    /// when the original goes under these words, one past the last whose
    /// original still fits its own lines too, so the page turns when either
    /// paragraph fills. The original of a run of translated words is the
    /// speech over the same span. Translated words are spread over the
    /// sentence they render, so within a sentence the span is approximate; at
    /// a sentence's edges it is exact, and with chunk boundaries to carry from
    /// that is where a page restarts anyway.
    private func longestFittingPrefix(_ words: [TimedWord],
                                      pairedWith original: [TimedWord]?) -> Int {
        var end = 0
        while end < words.count {
            let candidate = words[0...end].map(\.text).joined(separator: " ")
            if view.lineCount(committed: candidate, tentative: "", width: maxWidth) > view.maxLines {
                return end
            }
            if let original {
                let span = original.lazy
                    .filter { $0.start >= words[0].start && $0.start < words[end].end }
                    .map(\.text).joined(separator: " ")
                if !span.isEmpty, view.secondaryLineCount(span, width: maxWidth) > view.maxLines {
                    return end
                }
            }
            end += 1
        }
        return words.count
    }

    /// Speech stopped briefly. Whatever is on screen stays there, but the next
    /// words start a new page instead of being appended to it — so pages break at
    /// natural pauses rather than wherever the text happened to overflow.
    ///
    /// Display-only: the core keeps the recognizer running across this, so there
    /// is no accuracy cost (unlike an endpoint, which resets it).
    func markPause() {
        if !pendingCommit.isEmpty { setTentative("") }
        startFreshOnNextText = true
        markPagersFreshAtUtteranceEnd()
    }

    /// Someone else started speaking at `time`, in audio time. Their words
    /// start a box of their own, from the first of them: the diarizer names a
    /// change a second or two late, when those words are already drawn at the
    /// end of the outgoing speaker's box, or have closed with it into the
    /// stack, and they are taken back from there.
    ///
    /// The spoken words are paged again at once, having everything the break
    /// needs; the translation breaks as its words before the change settle.
    func markSpeakerChange(at time: TimeInterval) {
        if Self.debugPaging {
            let near = sourceWords.filter { abs($0.start - time) < 2 }
                .map { String(format: "%@@%.2f", $0.text, $0.start) }.joined(separator: " ")
            FileHandle.standardError.write(String(
                format: "[page] speaker change at %.2fs, page from %.2fs: %@\n",
                time, streams.start(.source), near).data(using: .utf8)!)
        }
        streams.markSpeakerChange(at: time)
        guard !holdsFinalCaption else { return }
        if !sourceWords.isEmpty {
            let visible = page(.source, sourceWords, chunkStarts: [])
            if primaryStream == .source, !boxIsCleared { showWords(visible, under: underCaption) }
            if Self.debugPaging {
                FileHandle.standardError.write(String(
                    format: "[page] after change: page from %.2fs \"%@\", last box \"%@\"\n",
                    streams.start(.source), visible.map(\.text).joined(separator: " "),
                    streams.boxes(.source).last?.text ?? "").data(using: .utf8)!)
            }
        }
        if let translatedWords, !boxIsCleared {
            pageTranslated(translatedWords)
        }
    }

    /// Utterance finished: keep it on screen briefly, then fade. The next words
    /// begin a new page rather than continuing this one.
    /// Utterance finished: the next words start a new page. Fading is handled by
    /// the text-idle poll, so there is nothing to arm here.
    func endUtterance() {
        // Fold in any commit that arrived without a following tentative — an
        // endpoint flush emits COMMITTED then ENDPOINT with nothing between.
        if !pendingCommit.isEmpty {
            setTentative("")
        }
        startFreshOnNextText = true
        markPagersFreshAtUtteranceEnd()
    }

    /// A page just left the screen. Keep it for ⌥.
    ///
    /// Deduplicated against the last entry: a page can close by more than one
    /// route in the same beat — an overflow immediately after a pause, say — and
    /// two identical boxes in the stack read as a stutter, not as history.
    /// The page on screen goes to the stack now, in both languages, and the
    /// next words start a page of their own. For a fade and for a clear: ⌥ is
    /// asked for the box exactly then, and a mark for the next words left it
    /// out of the stack until someone spoke again.
    private func bankPages() {
        streams.close(depth: effectiveHistoryDepth)
        translatedFreshDeferred = false
        recordClosedBoxes()
    }

    /// The next words begin a page of their own, in both languages.
    private func markPagersFresh() {
        streams.markFresh()
        translatedFreshDeferred = false
    }

    /// The next words begin a page of their own — in the source now, and in
    /// the translation once its last words for this utterance have landed.
    /// Translation runs behind speech: the settled form of the dimmed tail
    /// arrives after the endpoint, and a translated pager marked fresh here
    /// put its anchor past every one of those words, so they were dropped and
    /// the tail stayed dimmed for good. The mark is applied by the first
    /// translated words that are new — see `setTranslatedWords`. With no
    /// translation there is nothing to wait for.
    private func markPagersFreshAtUtteranceEnd() {
        streams.markFresh(.source)
        if prefersTranslation {
            translatedFreshDeferred = true
        } else {
            streams.markFresh(.translated)
        }
    }

    private func trimLeadingSpace(_ s: String) -> String {
        var out = s
        while out.hasPrefix(" ") { out.removeFirst() }
        return out
    }

    // MARK: layout / visibility

    /// Where the box is anchored horizontally, which is steadier than where it
    /// currently is. `layout` resolves the same value; the stack hangs off this so
    /// it does not inherit the box's per-word rounding.
    private var boxCentreX: CGFloat {
        anchor?.x ?? NSScreen.main?.frame.midX ?? panel.frame.midX
    }

    /// One dimension of the box easing from one size to another: the box
    /// going into a resize and coming out of it. Run by the cursor poll rather
    /// than the window's animator, which moves the whole frame as one: a step
    /// taken while the box is still widening must land its height at once and
    /// leave the width to carry on.
    private struct Ease {
        var from: CGFloat
        var to: CGFloat
        var start: CFTimeInterval

        static let duration: CFTimeInterval = 0.18

        func value(at now: CFTimeInterval) -> CGFloat {
            let t = CGFloat(min(max((now - start) / Self.duration, 0), 1))
            return from + (to - from) * t * t * (3 - 2 * t)
        }

        func isDone(at now: CFTimeInterval) -> Bool { now - start >= Self.duration }
    }
    private var widthEase: Ease?
    private var heightEase: Ease?
    /// The size the box is headed for, which an ease is still on its way to.
    private var sizeTarget: NSSize?

    /// `animated` eases the box to its new size; `snaps` lands its height at
    /// once, and its width too unless an ease is already carrying it, which
    /// then turns towards the new width from wherever it has got to. A plain
    /// layout over a running ease retargets it the same way.
    private func layout(animated: Bool = false, snaps: Bool = false) {
        let size = view.fittingSize(maxWidth: maxWidth)
        guard size.height > 0, NSScreen.main != nil else { return }
        let now = CACurrentMediaTime()
        let shown = panel.frame.size

        func ease(_ running: Ease?, from current: CGFloat, to target: CGFloat,
                  starts: Bool) -> Ease? {
            if starts { return current == target ? nil : Ease(from: current, to: target, start: now) }
            guard let running, !running.isDone(at: now) else { return nil }
            if running.to == target { return running }
            return Ease(from: running.value(at: now), to: target, start: now)
        }
        widthEase = ease(widthEase, from: shown.width, to: size.width, starts: animated)
        heightEase = snaps ? nil : ease(heightEase, from: shown.height, to: size.height, starts: animated)
        sizeTarget = size
        placeFrame(at: now)
    }

    /// One frame of the box's ease.
    private func tickFrameEase() {
        guard widthEase != nil || heightEase != nil else { return }
        let now = CACurrentMediaTime()
        placeFrame(at: now)
        if widthEase?.isDone(at: now) == true { widthEase = nil }
        if heightEase?.isDone(at: now) == true { heightEase = nil }
    }

    /// Put the panel at the size it has eased to, about its anchor.
    private func placeFrame(at now: CFTimeInterval) {
        guard let target = sizeTarget, let screen = NSScreen.main else { return }
        let size = NSSize(width: (widthEase?.value(at: now) ?? target.width).rounded(),
                          height: (heightEase?.value(at: now) ?? target.height).rounded())
        let anchor = resolvedAnchor(on: screen)

        // Round the origin: a half-pixel x makes the text render soft as the box
        // resizes on every word. The y moves by the ring margin so the *pill*
        // still sits on the anchor — the margin is invisible, and the box would
        // otherwise appear to float a few points off where it was left.
        let y = anchorsTop ? anchor.y + SubtitleView.pad - size.height : anchor.y - SubtitleView.pad
        let origin = NSPoint(x: (anchor.x - size.width / 2).rounded(), y: y.rounded())
        // NSWindow resizes its content view itself, so assigning view.frame here
        // is redundant — and actively harmful: setFrame(display: true) paints
        // immediately, so a manual assignment afterwards means that paint happens
        // with the view still at its previous, smaller size and the text is drawn
        // clipped for a frame.
        // The reveal's centre is in view coordinates, so a layout that moves the
        // panel's origin invalidates it — and `setFrame(display:)` paints
        // immediately, so the stale centre is what gets painted. A box can go
        // from 140 to 900 points wide on one word, which moves the origin by most
        // of the box: the hole lands off the pointer for a frame or two, and
        // reads as the reveal blinking out. Recomputed here against the frame
        // about to be set, so the first paint is already right.
        let frame = NSRect(origin: origin, size: size)
        guard frame != panel.frame else { return }
        updateMask(for: frame)
        isRepositioning = true
        panel.setFrame(frame, display: true)
        isRepositioning = false
    }

    /// Bring the box back onto the screen it is now on, and lay it out there.
    ///
    /// The anchor is written back rather than only applied: it is what gets
    /// saved, and a position that is off the current display is not one to keep
    /// remembering.
    private func screenChanged() {
        guard let screen = NSScreen.main else { return }
        if let current = anchor {
            let clamped = clamp(current, to: screen)
            if clamped != current {
                anchor = clamped
                saveAnchor()
            }
        }
        // Empty box: `layout()` returns early and there is nothing to move, but
        // the anchor above is now right for the next word.
        layout()
    }

    /// Hold the pill inside the screen's visible frame.
    ///
    /// The anchor is the centre of the pill's bottom or top edge, so the clamp
    /// is against half a width either side and the box's own height above or
    /// below. A box wider or taller than the screen has no valid position, and
    /// centring it is the least surprising answer.
    private func clamp(_ point: NSPoint, to screen: NSScreen) -> NSPoint {
        let area = screen.visibleFrame
        let size = panel.frame.size
        let half = size.width / 2
        // The pill's height, which is what separates its two edges.
        let pill = size.height - SubtitleView.pad * 2

        let x = area.width >= size.width
            ? min(max(point.x, area.minX + half), area.maxX - half)
            : area.midX
        let bottom = anchorsTop ? point.y - pill : point.y
        let lowest = area.minY + SubtitleView.pad
        let highest = area.maxY - size.height + SubtitleView.pad
        let y = highest >= lowest ? min(max(bottom, lowest), highest) : lowest
        return NSPoint(x: x.rounded(), y: (anchorsTop ? y + pill : y).rounded())
    }

    /// Where the box goes: where it was left, or low and centred on the screen
    /// until it has been moved.
    private func resolvedAnchor(on screen: NSScreen) -> NSPoint {
        anchor ?? NSPoint(x: screen.frame.midX, y: screen.frame.minY + screen.frame.height * 0.12)
    }

    private func saveAnchor() {
        guard let anchor else { return }
        UserDefaults.standard.set(NSStringFromPoint(anchor), forKey: Self.anchorKey)
        UserDefaults.standard.set(anchorsTop, forKey: Self.anchorTopKey)
    }

    // MARK: drag

    private func beginDrag(at mouse: NSPoint) {
        guard let screen = NSScreen.main else { return }
        let current = anchor ?? resolvedAnchor(on: screen)
        anchor = current
        dragGrab = NSPoint(x: current.x - mouse.x, y: current.y - mouse.y)
    }

    /// The anchor follows the pointer by the offset it was grabbed at, and the
    /// box is laid out from it, so a word that resizes the box mid-drag grows
    /// it about the anchor rather than out from under the pointer. Crossing the
    /// middle of the screen hands the anchor to the other edge, measured off
    /// the frame as it stands, so nothing moves when it does.
    private func drag(to mouse: NSPoint) {
        guard let grab = dragGrab, let screen = NSScreen.main else { return }
        anchor = NSPoint(x: mouse.x + grab.x, y: mouse.y + grab.y)
        layout()
        let wantsTop = panel.frame.midY > screen.visibleFrame.midY
        guard wantsTop != anchorsTop else { return }
        anchorsTop = wantsTop
        let handed = edgeAnchor(of: panel.frame)
        anchor = handed
        dragGrab = NSPoint(x: handed.x - mouse.x, y: handed.y - mouse.y)
    }

    private func endDrag() {
        guard dragGrab != nil else { return }
        dragGrab = nil
        saveAnchor()
        syncClickThrough()
    }

    /// The dashed ring: while ⇧ makes the box grabbable, while it is being
    /// dragged or resized, and, with click-through off, whenever the pointer is
    /// over a box that a drag would move. Not over one with a button, whose
    /// clicks go to the button and nowhere else. Whenever the box can be picked
    /// up it can be resized too, by the edge away from its anchor.
    private func updateDragOutline() {
        let grabbable = !isRevealEnabled && !isSuppressed && panel.alphaValue > 0
            && view.action == nil
        let hovering = grabbable && panel.frame.contains(NSEvent.mouseLocation)
        let wanted = !isSuppressed && (isDraggable || isHandled || hovering)
        if view.showsDragOutline != wanted { view.showsDragOutline = wanted }
        let resizable = resizeStart != nil
            || (!isSuppressed && panel.alphaValue > 0 && dragGrab == nil && (isDraggable || grabbable))
        let edge: SubtitleView.ResizeEdge? = resizable ? (anchorsTop ? .bottom : .top) : nil
        if view.resizableEdge != edge { view.resizableEdge = edge }
        view.refreshCursor()
    }

    /// The Copy button, while the pointer is over a box that takes clicks:
    /// with ⇧ or ⌥ held, or click-through off. Not on a box with a button of
    /// its own, nor while it is being dragged or resized. Under ⌥ alone the
    /// box still lets clicks through, except on the button itself.
    private func updateCopyButton() {
        let flags = NSEvent.modifierFlags
        let takesClicks = flags.contains(.shift) || flags.contains(.option) || !isRevealEnabled
        let wanted = takesClicks && !isSuppressed && !isHandled && panel.alphaValue > 0
            && view.action == nil && panel.frame.contains(NSEvent.mouseLocation)
            && !view.copyText.isEmpty
        if view.showsCopy != wanted { view.showsCopy = wanted }
        view.syncCopyHover()
        syncClickThrough()
    }

    /// How far the veil over the text has got, 0 to 1, before easing.
    private var veilProgress: CGFloat = 0
    private var veilTickedAt: CFTimeInterval = 0

    /// The text softening behind the count while the edge is held, and
    /// coming back after, over the time the box takes to change size.
    private func tickResizeVeil() {
        let target: CGFloat = resizeStart != nil ? 1 : 0
        guard veilProgress != target else {
            veilTickedAt = 0
            return
        }
        let now = CACurrentMediaTime()
        let dt = veilTickedAt == 0 ? 1.0 / 60 : min(0.05, now - veilTickedAt)
        veilTickedAt = now
        let step = CGFloat(dt / 0.18)
        veilProgress = target > veilProgress ? min(1, veilProgress + step) : max(0, veilProgress - step)
        let t = veilProgress
        view.resizeVeil = t * t * (3 - 2 * t)
    }

    // MARK: resize

    /// The box empties to the line count it is set to, and the edge then
    /// steps it a line at a time, a line's height of pointer travel to each.
    /// Counted from where the press began rather than from where the edge
    /// is, so the box jumping to its full height on the press does not count
    /// as a move. Laid out from the anchor, so the anchored edge stays put.
    private func beginResize(at mouse: NSPoint) {
        guard let screen = NSScreen.main else { return }
        if anchor == nil { anchor = resolvedAnchor(on: screen) }
        resizeStart = (mouse.y, maxLines)
        view.resizeLines = maxLines
        layout(animated: true)
    }

    private func resize(to mouse: NSPoint) {
        guard let start = resizeStart else { return }
        // Away from the anchor is bigger: up for a box anchored by its bottom,
        // down for one anchored by its top.
        let travel = anchorsTop ? start.y - mouse.y : mouse.y - start.y
        let lines = max(1, start.lines + Int((travel / Pill.lineHeight(ofSize: view.fontSize)).rounded()))
        guard lines != view.resizeLines else { return }
        view.resizeLines = lines
        // Steps land their height at once, under the pointer; a width still
        // easing in carries on. Only going into the resize and out of it ease.
        layout(snaps: true)
    }

    private func endResize() {
        guard resizeStart != nil, let lines = view.resizeLines else { return }
        resizeStart = nil
        // Set while the box is still the count's size, so the re-page it may
        // bring lays out at that size and the one animation below takes the
        // box from there to its text.
        maxLines = lines
        onMaxLinesChosen?(lines)
        view.resizeLines = nil
        // The text back, at the new count; re-paged by `maxLines` if it no
        // longer fits.
        layout(animated: true)
        saveAnchor()
        syncClickThrough()
    }

    /// Drop the ⌥ stack once the transcript has been quiet long enough.
    ///
    /// Measured from the last *text*, not the last audio, for the same reason
    /// the fade is: a backing track keeps the voice gate open indefinitely, and
    /// what matters is whether new words are arriving.
    private func expireHistoryIfIdle() {
        // Both stacks, not the one on screen: with a target chosen the visible one
        // can be empty while the other still holds a session's worth of boxes, and
        // guarding on the visible one alone left that never expiring.
        // Nor while the offer is up: it asks before the stack clears, and its
        // bar is the time left to answer. Longer than the quiet left before
        // Clear after, it holds the stack until it runs out.
        guard isHistoryExpiryEnabled, !savingTranscript, !offersTranscript,
              !streams.isEmpty || !stack.isEmpty else { return }
        // Not while it is on screen. Someone holding ⌥ is reading it, and a
        // stack that empties under their eyes because nobody spoke for a minute
        // is the one moment this must not fire.
        guard history.shown.isEmpty else { return }
        guard Date().timeIntervalSince(lastTextAt) >= stackExpiry else { return }
        streams.clear()
        forgetStack()
    }

    /// Clear after, but never before the box has faded and the offer to save
    /// the transcript has had its turn: the offer only comes up over a faded
    /// box, so a long Hide after against a short Clear after would forget the
    /// stack before it could ask.
    private var stackExpiry: TimeInterval {
        isTranscriptOfferEnabled
            ? max(historyExpiry, textIdleTimeout + transcriptOfferDuration) : historyExpiry
    }

    /// Once the source has stopped making sound, or `transcriptOfferDuration`
    /// seconds before the stack is forgotten if that comes first, the box
    /// asks whether to save it, for `transcriptOfferDuration` seconds, and
    /// takes clicks while it asks. Its bar fills over those seconds. Up at the
    /// tail, it ends as the stack goes; up earlier on silence, it fades on its
    /// own and the stack stays until Clear after. New words take the box back
    /// at once. Silence is the better moment: the video or the call is over,
    /// and the person is still there to answer.
    ///
    /// Only over a box that has already faded, and never over the ⌥ stack,
    /// a line of the app's own or a box being dragged. Once up it stays, sound
    /// or no sound, until words, the timer or a click take it; withdrawn,
    /// faded, if Clear after or the offer itself is turned off in the
    /// meantime.
    ///
    /// With Save without asking, the same moment saves the transcript and
    /// the box says where, for as long and with the same bar; it asks after
    /// all if the file could not be written.
    private func offerTranscriptIfIdle() {
        let idle = Date().timeIntervalSince(lastTextAt)
        let due = isSourceSilent == true || idle >= stackExpiry - transcriptOfferDuration
        let enoughSaid = debugOffersAnyway || speechInStack >= Self.transcriptOfferMinimum
        let wanted = isTranscriptOfferEnabled && isHistoryExpiryEnabled
            && !savingTranscript && !isSuppressed
            && !holdsFinalCaption && !stack.isEmpty
            && (offersTranscript || (due && !offeredSinceText && enoughSaid))
        guard wanted else {
            withdrawTranscriptOffer(fading: true)
            return
        }
        guard !offersTranscript, boxIsCleared, panel.alphaValue == 0,
              !isDraggable, history.shown.isEmpty else { return }

        offersTranscript = true
        offeredSinceText = true
        debugOffersAnyway = false
        offerElapsed = 0
        // Said by Subtitles, like the trial's last line.
        view.icon = NSApp.applicationIconImage
        view.appName = "Subtitles"
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        if savesTranscriptAutomatically, let url = saveTranscriptAutomatically() {
            savedTranscript = url
            let folder = FileManager.default.displayName(atPath: url.deletingLastPathComponent().path)
            view.committed = LF("Transcript saved to %@.", folder)
            view.secondaryAction = nil
            view.action = (L("Show in Finder", "Button in the caption box after a transcript was saved without asking: selects the file in a Finder window"),
                           { [weak self] in self?.revealSavedTranscript(url) })
        } else {
            view.committed = transcriptOfferText
            view.secondaryAction = (L("Don't Ask Again", "Button in the caption box beside Save Transcript…: turns the offer to save the transcript off"),
                                    { [weak self] in self?.declineTranscriptOffers() })
            view.action = (L("Save Transcript…", "Button in the caption box: saves the session's recent boxes to a text file"),
                           { [weak self] in self?.saveTranscript() })
        }
        syncClickThrough()
        tickTranscriptOffer()
        layout()
        show()
        if savedTranscript != nil {
            announce(view.committed)
        } else {
            announce(L("Save a transcript of this session before it clears?")
                     + " " + L("Save Transcript… is also in the Subtitles menu.", "Read by VoiceOver after the offer to save the transcript"))
        }
    }

    /// Write the stack where the save panel would open, without asking: over
    /// the file saved before while it is still the same session, else to a
    /// new one named as the panel would name it, with " 2", " 3"… should that
    /// name be taken. Nil when it could not be written.
    private func saveTranscriptAutomatically() -> URL? {
        guard let head = stack.first?.head else { return nil }
        let url: URL
        let title: String
        let format: TranscriptFormat
        if let saved = autoSaved, saved.head == head {
            (url, title, format) = (saved.url, saved.title, saved.format)
        } else {
            guard let folder = transcriptDirectory else { return nil }
            title = Self.transcriptTitle(at: Date())
            format = defaultTranscriptFormat
            var candidate = folder.appendingPathComponent(title + "." + format.fileExtension)
            var number = 2
            while FileManager.default.fileExists(atPath: candidate.path) {
                candidate = folder.appendingPathComponent("\(title) \(number).\(format.fileExtension)")
                number += 1
            }
            url = candidate
        }
        let text = TranscriptExport.render(transcriptEntries, as: format, title: title) {
            LF("Speaker %lld", $0)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(
                "subtitles: could not save the transcript to \(url.path): \(error.localizedDescription)\n"
                    .data(using: .utf8)!)
            return nil
        }
        autoSaved = (url, title, format, head)
        return url
    }

    /// The saved notice's Show in Finder: the file selected in a Finder
    /// window, and the notice taken down.
    private func revealSavedTranscript(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
        withdrawTranscriptOffer(fading: true)
    }

    /// The offer's Don't Ask Again: no more offers, this one taken down, and
    /// the stack kept as it was. Settings ▸ Transcript turns them back on.
    private func declineTranscriptOffers() {
        isTranscriptOfferEnabled = false
        onDisableTranscriptOffer?()
        announce(L("The offer is off. Settings ▸ Transcript turns it back on.",
                   "Read by VoiceOver after Don't Ask Again; Settings ▸ Transcript is the Settings window's tab"))
    }

    /// Less speech than this and the box does not ask: a minute of captions
    /// is rarely worth a file, and a question after every short clip is one
    /// to learn to ignore. The status menu still offers it.
    static let transcriptOfferMinimum: TimeInterval = 60

    /// How long the stack's words were spoken over: each box's time from its
    /// first word to its last, by the clock, which the recognizer's restarts
    /// do not touch.
    private var speechInStack: TimeInterval {
        stack.reduce(0) { $0 + max($1.lastWord.timeIntervalSince($1.shown), 0) }
    }

    /// Settings ▸ Debug's offer comes up whatever was said: its two sample
    /// boxes are seconds long.
    private var debugOffersAnyway = false

    /// There is something to save: the status menu offers Save Transcript…
    /// whenever there is, the box's question or not.
    var hasTranscript: Bool { !stack.isEmpty && !savingTranscript }

    /// The status menu's Save Transcript…: the offer's button when the box is
    /// asking, and the same save when it is not.
    func acceptTranscriptOffer() { saveTranscript() }

    /// Have VoiceOver say `text` now, whatever has focus: the box is in a
    /// panel that never becomes key, so nothing would read it otherwise.
    /// Only for what the app says itself; captions are never announced.
    ///
    /// Said by main.swift's `Speaker` in VoiceOver's own voice and rate, not
    /// posted to VoiceOver as an announcement: VoiceOver only reads those
    /// from the app in front, and this one never is.
    private func announce(_ text: String) {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        onAnnounce?(text)
    }

    /// Says a line of the app's own aloud. See `announce`.
    var onAnnounce: ((String) -> Void)?

    // MARK: Escape

    /// Escape pressed over a line of the app's own: the trial's end asks for
    /// its hold to be cut short, which main.swift owns. The offer is simply
    /// taken down here.
    var onDismissFinalCaption: (() -> Void)?

    /// ⎋, registered only while the offer or the trial's end is up. A Carbon
    /// hotkey like ⌥⌘S, since the panel never becomes key and a keyboard
    /// monitor would need Accessibility permission. It takes Escape from
    /// every app for those seconds, which is why it is held no longer.
    private var escapeHotkey: Hotkey?

    private func syncEscapeHotkey() {
        let wanted = offersTranscript || holdsFinalCaption
        if wanted, escapeHotkey == nil {
            escapeHotkey = Hotkey(keyCode: kVK_Escape, modifiers: 0, id: 4) { [weak self] in
                self?.escapePressed()
            }
        } else if !wanted {
            escapeHotkey = nil
        }
    }

    private func escapePressed() {
        if offersTranscript {
            withdrawTranscriptOffer(fading: true)
        } else if holdsFinalCaption {
            onDismissFinalCaption?()
        }
    }

    /// The pointer is over the box on screen, the transparent margin round it
    /// left out. What a line that times out holds still for: someone reading
    /// it, or reaching for what it offers.
    var isPointerOverBox: Bool {
        guard panel.alphaValue > 0 else { return false }
        return panel.frame.insetBy(dx: SubtitleView.pad, dy: SubtitleView.pad)
            .contains(NSEvent.mouseLocation)
    }

    /// The bar under the app's own last line, 0 to 1, for a caller that
    /// counts its hold: the trial's end. Only while that line is up; taken
    /// down with it.
    func setFinalCaptionProgress(_ progress: CGFloat) {
        guard holdsFinalCaption else { return }
        view.progress = min(max(progress, 0), 1)
    }

    #if DEV_BUILD
    /// Settings ▸ Debug: bring the offer up now, as if the captions had been
    /// quiet until the offer's length before Clear after. A box on screen fades
    /// first, as it would. With nothing said yet, two sample boxes stand in
    /// for the session, so there is something to save. Needs Clear after on,
    /// and not paused, as the real one does. With Save without asking on, it
    /// saves them, as the real one would.
    func debugOfferTranscript() {
        guard isTranscriptOfferEnabled, isHistoryExpiryEnabled, !isSuppressed else { return }
        if stack.isEmpty {
            let samples = ["A sample box, so the offer has something to save.",
                           "Nothing had been said since the history last cleared."]
            // Ordinals below zero: no pager revision can reach them.
            let now = Date()
            stack = samples.enumerated().map { index, text in
                StackBox(text: text, under: "", app: playingApp, below: true,
                         start: Double(index), end: Double(index) + 1,
                         stream: .source, ordinal: -1 - index, speaker: nil,
                         shown: now.addingTimeInterval(Double(index * 3) - 6),
                         lastWord: now.addingTimeInterval(Double(index * 3) - 4))
            }
        }
        if panel.alphaValue == 0 { boxIsCleared = true }
        offeredSinceText = false
        debugOffersAnyway = true
        lastTextAt = Date().addingTimeInterval(-max(stackExpiry - transcriptOfferDuration, 0))
    }
    #endif

    /// The offer's question. No time left in it: the bar under it says
    /// that, and a line whose words change every second is no line to read.
    private var transcriptOfferText: String {
        L("Save a transcript of this session before it clears?",
          "Asked in the caption box before the recent boxes are forgotten")
    }

    /// The offer's bar, over its own `transcriptOfferDuration`, and its end
    /// when that is up. At the tail it is the last of the quiet before the
    /// stack goes, which then goes with it.
    ///
    /// Frozen while the pointer is over the box: someone reading the
    /// question, or reaching for the button, is not letting the time run
    /// out. The silence is moved on by the time spent there too, so the
    /// expiry stops with the bar and picks up where it was.
    private func tickTranscriptOffer() {
        let now = Date()
        defer { offerTickedAt = offersTranscript ? now : nil }
        guard offersTranscript else { return }
        if let last = offerTickedAt {
            let step = now.timeIntervalSince(last)
            if isPointerOverBox {
                lastTextAt += step
            } else if NSWorkspace.shared.isVoiceOverEnabled {
                // Three times as long under VoiceOver: hearing the question
                // and reaching the button or the menu takes longer than
                // reading and clicking. The expiry waits the difference.
                offerElapsed += step / 3
                lastTextAt += step * 2 / 3
            } else {
                offerElapsed += step
            }
        }
        view.progress = CGFloat(min(offerElapsed / transcriptOfferDuration, 1))
        // At the tail, the expiry that waited for it follows on its next
        // poll, at most half a second behind.
        if offerElapsed >= transcriptOfferDuration {
            withdrawTranscriptOffer(fading: true)
        }
    }

    /// Take the offer down. `fading` for the box going with it; otherwise
    /// the caller is putting words in it straight away.
    private func withdrawTranscriptOffer(fading: Bool) {
        guard offersTranscript else { return }
        offersTranscript = false
        view.secondaryAction = nil
        view.action = nil
        view.progress = nil
        syncClickThrough()
        guard fading else {
            view.committed = ""
            wearPlayingApp()
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Words may have taken the box in the meantime; they keep it.
            guard let self, !self.offersTranscript, self.boxIsCleared,
                  !self.holdsFinalCaption else { return }
            self.view.committed = ""
            self.wearPlayingApp()
        })
    }

    /// The stack as a transcript's entries: each box's app by its name, and
    /// with more than one voice in it, who spoke, numbered in the order they
    /// are first heard here: the diarizer's own numbers mean nothing to a
    /// reader.
    private var transcriptEntries: [TranscriptEntry] {
        var numbers: [Int: Int] = [:]
        for case let index? in stack.map(\.speaker) where numbers[index] == nil {
            numbers[index] = numbers.count + 1
        }
        let named = namesSpeakersInTranscript && numbers.count > 1
        return stack.map { box in
            TranscriptEntry(text: box.text, under: box.under,
                            app: box.app.map { AppCatalog.shared.name(for: $0) },
                            speaker: named ? box.speaker.flatMap { numbers[$0] } : nil,
                            shown: box.shown, lastWord: box.lastWord)
        }
    }

    /// The format last saved in, offered first next time.
    private static let transcriptFormatKey = "transcript.format"

    /// The format chosen under Settings ▸ Transcript, or nil for the one
    /// the last transcript was saved in. Set by main.swift.
    var transcriptFormat: TranscriptFormat?

    /// What the save panel offers first, and what a save without asking
    /// writes: the format chosen in Settings, else the one last saved in,
    /// else plain text.
    private var defaultTranscriptFormat: TranscriptFormat {
        transcriptFormat
            ?? UserDefaults.standard.string(forKey: Self.transcriptFormatKey)
                .flatMap(TranscriptFormat.init(rawValue:))
            ?? .text
    }

    /// A transcript's title and file name. The date and time go into it as
    /// numbers, sorting as they read.
    private static func transcriptTitle(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return LF("Transcript %@", formatter.string(from: date))
    }
    /// The folder the last transcript went to.
    private static let transcriptLastFolderKey = "transcript.lastFolder"

    /// The folder chosen under Settings ▸ Transcript, or nil for wherever the
    /// last transcript went. Set by main.swift.
    var transcriptFolder: URL?

    /// Where the save panel opens, and where a save without asking goes:
    /// the folder chosen in Settings, else `lastTranscriptFolder`. A folder
    /// since deleted, or on a disk that is not mounted, is passed over.
    /// Settings ▸ Transcript shows it beside the popup.
    var transcriptDirectory: URL? {
        transcriptFolder.flatMap(Self.existingFolder) ?? lastTranscriptFolder
    }

    /// What Last Used Folder stands for right now: the folder the last
    /// transcript went to, else Documents.
    private var lastTranscriptFolder: URL? {
        UserDefaults.standard.string(forKey: Self.transcriptLastFolderKey)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .flatMap(Self.existingFolder)
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func existingFolder(_ folder: URL) -> URL? {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder)
            && isFolder.boolValue ? folder : nil
    }

    /// A transcript was saved through the panel, so the last folder may have
    /// moved: main.swift has Settings follow.
    var onTranscriptSaved: (() -> Void)?

    /// Ask where, and write the file. Taken from the offer, the stack is then
    /// forgotten, as the timer was about to; cancelled, the timer takes it
    /// from there. From the status menu with no offer up, mid-session, the
    /// stack stays: ⌥ still brings back what was just saved.
    ///
    /// What is saved is the stack as it was clicked. Should someone speak
    /// while the panel is up, only the boxes saved are forgotten.
    private func saveTranscript() {
        guard !stack.isEmpty, !savingTranscript else { return }
        // The box saying it saved is no offer: the menu's save over it keeps
        // the stack, as it would mid-session.
        let fromOffer = offersTranscript && savedTranscript == nil
        let entries = transcriptEntries
        let saved = stack.count
        let clickedAt = Date()
        savingTranscript = true
        withdrawTranscriptOffer(fading: true)

        let title = Self.transcriptTitle(at: clickedAt)
        let save = NSSavePanel()
        let picker = TranscriptFormatPicker(panel: save, format: defaultTranscriptFormat)
        save.accessoryView = picker.view
        save.nameFieldStringValue = title + "." + picker.format.fileExtension
        save.directoryURL = transcriptDirectory
        save.isExtensionHidden = false
        // Over a full-screen video, where the click came from, rather than
        // on a desktop the click would switch to.
        save.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        NSApp.activate(ignoringOtherApps: true)
        save.begin { [weak self] response in
            guard let self else { return }
            self.savingTranscript = false
            guard response == .OK, let url = save.url else { return }
            let format = picker.format
            UserDefaults.standard.set(format.rawValue, forKey: Self.transcriptFormatKey)
            // Kept with a folder and a format chosen in Settings too, for
            // when they are set back to Last Used.
            UserDefaults.standard.set(url.deletingLastPathComponent().path,
                                      forKey: Self.transcriptLastFolderKey)
            self.onTranscriptSaved?()
            let text = TranscriptExport.render(entries, as: format, title: title) {
                LF("Speaker %lld", $0)
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                NSAlert(error: error).runModal()
                return
            }
            guard fromOffer else { return }
            if self.lastTextAt <= clickedAt {
                self.streams.clear()
                self.forgetStack()
            } else {
                self.stack.removeFirst(min(saved, self.stack.count))
            }
        }
    }

    /// The save panel's Format popup: plain text, Markdown or SubRip. A
    /// choice sets the panel's type, which puts the matching extension on the
    /// name as it stands.
    private final class TranscriptFormatPicker: NSObject {
        let view: NSView
        private let popup = NSPopUpButton()
        private weak var panel: NSSavePanel?

        init(panel: NSSavePanel, format: TranscriptFormat) {
            self.panel = panel
            let label = NSTextField(labelWithString: L("Format:", "Save panel: label before the popup choosing the transcript's file format"))
            popup.addItems(withTitles: TranscriptFormat.allCases.map(\.title))
            let stack = NSStackView(views: [label, popup])
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
            view = stack
            super.init()
            popup.selectItem(at: TranscriptFormat.allCases.firstIndex(of: format) ?? 0)
            popup.target = self
            popup.action = #selector(chosen)
            apply()
        }

        var format: TranscriptFormat { TranscriptFormat.allCases[max(popup.indexOfSelectedItem, 0)] }

        @objc private func chosen(_ sender: NSPopUpButton) { apply() }

        private func apply() {
            guard let panel else { return }
            let type = UTType(filenameExtension: format.fileExtension) ?? .plainText
            panel.allowedContentTypes = [type]
            // The name's extension follows the type only when it had one the
            // type knew; set it outright.
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            if !name.isEmpty { panel.nameFieldStringValue = name + "." + format.fileExtension }
        }
    }

    private func fadeIfTextIdle() {
        guard !isDraggable, !isHandled, !holdsFinalCaption, !offersTranscript,
              panel.alphaValue > 0 else { return }
        guard Date().timeIntervalSince(lastTextAt) >= textIdleTimeout else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            // New text may have arrived during the fade and shown the panel again;
            // discarding the page then would throw away what is on screen.
            guard self.panel.alphaValue == 0 else { return }

            // Empty the box now that it is invisible, so the next words open a
            // clean one instead of resuming a paragraph nobody can still see —
            // but keep it for ⌥ first. Fading is precisely when someone looks
            // away and wants it back.
            self.bankPages()
            self.boxIsCleared = true
            // The stored transcripts go too. They outlive the box on purpose so ⌃
            // can swap language instantly, but everything in them predates the
            // fade, so keeping them is keeping exactly what must never be shown
            // again.
            self.sourceWords = []
            self.translatedWords = nil
            self.recentEmissions = []
            self.patienceRestartsOnNextWords = true
            self.page = ""
            self.pendingCommit = ""
            self.tentative = ""
            self.view.committed = ""
            self.view.tentative = ""
            self.view.secondary = ""
            self.view.secondaryTentative = ""

            // `latestWordEnd` is deliberately *kept*: engines that never reset keep
            // growing one transcript, so "fresh" must mean "the words after this
            // moment in the audio", not "replay everything from the beginning".
            self.startFreshOnNextText = true
            self.onFaded?()
        })
    }

    private func show() {
        guard !isSuppressed else { return }
        if panel.alphaValue < 1 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func resetPosition() {
        anchor = nil
        anchorsTop = false
        UserDefaults.standard.removeObject(forKey: Self.anchorKey)
        UserDefaults.standard.removeObject(forKey: Self.anchorTopKey)
        layout()
    }

    /// How many lines a box may fill before it is closed and a new one begun.
    var maxLines: Int {
        get { view.maxLines }
        set {
            guard newValue != view.maxLines else { return }
            view.maxLines = newValue
            // Re-page at the new ceiling, for the same reason a font size change
            // does: what fitted five lines does not fit two, and without this the
            // box already on screen would simply be clipped.
            if !page.isEmpty,
               view.lineCount(committed: page, tentative: "", width: maxWidth) > view.maxLines {
                markPagersFresh()
                page = ""
                view.committed = ""
                view.secondary = ""
                view.secondaryTentative = ""
                startFreshOnNextText = true
            }
            layout()
        }
    }

    func setFontSize(_ size: CGFloat) {
        view.fontSize = size
        // Re-page at the new size: text that fit three lines at 22pt may need five
        // at 52pt, and without this the box would simply clip.
        if !page.isEmpty,
           view.lineCount(committed: page, tentative: "", width: maxWidth) > view.maxLines {
            markPagersFresh()
            page = ""
            view.committed = ""
            view.secondary = ""
            view.secondaryTentative = ""
            startFreshOnNextText = true
        }
        layout()
    }

    /// Pause and resume: drop what is on screen and stay dark until resumed.
    ///
    /// Distinct from `clearAndHide()`, which model and source switches use and
    /// which must *not* keep the overlay down — those are expected to start
    /// showing text again on their own.
    func setPaused(_ paused: Bool) {
        isSuppressed = paused
        if paused {
            clearAndHide()
            // Drop the drag state too, or a ⇧ held across the pause leaves the
            // panel catching clicks it will never show anything for.
            isDraggable = false
            syncClickThrough()
            updateDragOutline()
        }
    }

    /// Put `text` in the box as the last caption of a run: the trial's free
    /// minutes ending. Drawn whole, over the glow like any caption, and held
    /// there against the transcript and the idle fade until
    /// `setPaused` or `clearAndHide` takes it down.
    /// `action` is a button inline after the text, as the offer to save the
    /// transcript has.
    /// `hint` follows the text when VoiceOver announces it: where to act on it.
    func showFinalCaption(_ text: String, action: (title: String, press: () -> Void)? = nil,
                          hint: String? = nil) {
        guard !isSuppressed else { return }
        history.dismiss()
        cancelHold()
        offersTranscript = false
        view.secondaryAction = nil
        view.action = nil
        view.progress = nil
        holdsFinalCaption = true
        // Said by Subtitles, not by the app playing: the box wears this app's
        // name and icon for it.
        view.icon = NSApp.applicationIconImage
        view.appName = "Subtitles"
        pendingCommit = ""
        tentative = ""
        startFreshOnNextText = true
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        view.action = action
        // Clicks reach the box while the button is up, and only then, unless
        // the reveal is off and they always do.
        syncClickThrough()
        // All of it at once, not a word at a time: it is the app talking, and
        // someone reading it wants the whole line, not to watch it typed out.
        boxIsCleared = false
        lastShownText = text
        lastTextAt = Date()
        page = text
        view.committed = text
        layout()
        show()
        announce([text, hint].compactMap { $0 }.joined(separator: " "))
    }

    /// Wipe the box and fade it out, leaving it free to come back on the next
    /// word. Used when the engine underneath changes — model or source switch.
    func clearAndHide() {
        if view.action != nil {
            view.secondaryAction = nil
            view.action = nil
            syncClickThrough()
        }
        // The app's name comes back once the box is out of sight, not while
        // the line Subtitles said is still fading under it.
        let rewear = holdsFinalCaption || offersTranscript
        holdsFinalCaption = false
        offersTranscript = false
        view.progress = nil
        // The history goes with it. It survives the idle fade on purpose, but a
        // pause or a model switch is the user saying this transcript is over, and
        // ⌥ offering the last thing a since-replaced model heard is a puzzle.
        streams.clear()
        forgetStack()
        translatedFreshDeferred = false
        history.dismiss()
        cancelHold()
        boxIsCleared = true
        lastShownText = ""
        lastTextAt = .distantPast
        page = ""
        pendingCommit = ""
        tentative = ""
        pageStartTime = 0
        startFreshOnNextText = false
        view.committed = ""
        view.tentative = ""
        view.secondary = ""
        view.secondaryTentative = ""
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, rewear, !self.holdsFinalCaption else { return }
            self.wearPlayingApp()
        })
    }
}

extension TranscriptFormat {
    /// The format's name, in the save panel's Format popup and Settings ▸
    /// Transcript's.
    var title: String {
        switch self {
        case .text: return L("Plain Text", "Transcript format: a .txt file")
        case .markdown: return L("Markdown", "Transcript format: a .md file")
        case .srt: return L("SubRip (SRT)", "Transcript format: a .srt subtitle file, with each box's times; SubRip is the format's name")
        }
    }
}
