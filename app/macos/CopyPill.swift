// The Copy button on a caption box.
//
// Drawn as the ⌥ stack's search pill is: a blur under the box's own fill and
// corner, its hairline, a symbol and a word in the boxes' rounded type at half
// the text's size. The blur looks within the window, not behind it: the pill
// sits on a box, and what it has to soften is the box's own text, which a
// behind-window blur never sees.
//
// It shows on the live box while the pointer is over one that takes clicks,
// with ⇧ or ⌥ held or click-through off, and on whichever box of the ⌥ stack
// the pointer is over. The owner decides when, and whether the pointer is on
// it; this view only draws, takes the click, and copies.

import AppKit
import CaptionCore

final class CopyPill: NSView {
    /// What the pill takes from the box it sits on.
    struct Look: Equatable {
        /// The box's text size; the pill's is half of it, as the search's is.
        var fontSize: CGFloat
        var fill: CGFloat
        var textOpacity: CGFloat
        /// The box's blur setting. Never under the default: the pill sits on
        /// text, and at the setting's low end that text reads straight through.
        var blur: CGFloat
        /// The name tab's height, when the box wears one: the pill then floats
        /// beside it, as tall as it and in its type, over the picture rather
        /// than over the box.
        var tabHeight: CGFloat? = nil
    }

    private static let inset = NSSize(width: 14, height: 7)
    private static let iconGap: CGFloat = 7
    /// Between a pill floating beside the tab and the box under it.
    static let tabGap: CGFloat = 2
    /// How long "Copied" stays before the pill says Copy again.
    private static let copiedFor: TimeInterval = 1.5

    var look: Look {
        didSet { if look != oldValue { apply() } }
    }

    /// The box's text, asked for at the click rather than kept, so a live box
    /// copies the words it shows at that moment.
    var text: () -> String = { "" }

    /// The pointer is on it: the word and symbol at full strength. Polled by
    /// the owner, as the panels it sits on take the mouse only some of the
    /// time.
    var isHovered = false {
        didSet { if isHovered != oldValue { apply() } }
    }

    /// Under everything, the blur; over it, the fill; over that, the symbol
    /// and the word. The boxes' own arrangement. Within the window over a box,
    /// to soften its text; behind it beside the tab, over the picture, as the
    /// tab's own is. Replaced rather than switched when that changes.
    private var blur = BackdropBlurView(blending: .withinWindow)
    private let face = PillFace()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var isPressed = false {
        didSet { if isPressed != oldValue { face.needsDisplay = true } }
    }
    private var isCopied = false
    private var copiedTimer: Timer?

    init(look: Look) {
        self.look = look
        super.init(frame: .zero)
        face.drawing = { [unowned self] bounds in self.drawFace(in: bounds) }
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.isSelectable = false
        addSubview(blur)
        addSubview(face)
        addSubview(icon)
        addSubview(label)
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { copiedTimer?.invalidate() }

    /// Half the box's text, as the search's; the tab's type beside a tab.
    private var fontSize: CGFloat {
        look.tabHeight == nil ? max(13, (look.fontSize * 0.5).rounded()) : (look.fontSize * 0.42).rounded()
    }

    private var inset: NSSize {
        look.tabHeight == nil ? Self.inset : NSSize(width: 10, height: 0)
    }

    /// A capsule, at every size.
    private var corner: CGFloat { bounds.height / 2 }

    private static var copyTitle: String {
        L("Copy", "Button over a caption box: copies the box's text to the clipboard")
    }
    private static var copiedTitle: String {
        L("Copied", "The Copy button over a caption box, for a moment after it was pressed")
    }

    private func apply() {
        let font = Pill.font(ofSize: fontSize)
        let ink = Pill.ink.withAlphaComponent(look.textOpacity * (isHovered ? 1 : 0.75))
        label.font = font
        label.textColor = ink
        label.stringValue = isCopied ? Self.copiedTitle : Self.copyTitle
        icon.image = NSImage(systemSymbolName: isCopied ? "checkmark" : "doc.on.doc",
                             accessibilityDescription: nil)
        icon.contentTintColor = ink
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: fontSize * 0.85,
                                                                weight: .semibold)
        let blending: NSVisualEffectView.BlendingMode = look.tabHeight == nil ? .withinWindow : .behindWindow
        if blur.blendingMode != blending {
            let replacement = BackdropBlurView(blending: blending)
            replacement.frame = blur.frame
            addSubview(replacement, positioned: .below, relativeTo: face)
            blur.removeFromSuperview()
            blur = replacement
        }
        blur.radius = max(look.blur, Pill.backdropBlur)
        needsLayout = true
        face.needsDisplay = true
    }

    /// As wide as the longer of its two words, so it does not change size
    /// under the pointer when it says Copied.
    var pillSize: NSSize {
        let font = Pill.font(ofSize: fontSize)
        let word = [Self.copyTitle, Self.copiedTitle]
            .map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) }
            .max() ?? 0
        return NSSize(width: inset.width * 2 + fontSize.rounded() + Self.iconGap + word + 4,
                      height: look.tabHeight.map { $0 - Self.tabGap }
                        ?? ceil(Pill.lineHeight(ofSize: fontSize)) + inset.height * 2)
    }

    /// Faded in and out by its owner; out, it takes no clicks.
    func show(_ shown: Bool) {
        let target: CGFloat = shown ? 1 : 0
        guard abs(alphaValue - target) > 0.01 || isHidden == shown else { return }
        isHidden = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            animator().alphaValue = target
        }, completionHandler: { [weak self] in
            guard let self, self.alphaValue < 0.01 else { return }
            self.isHidden = true
            self.isPressed = false
            self.isHovered = false
        })
    }

    var isShown: Bool { !isHidden && alphaValue > 0.5 }

    private func drawFace(in bounds: NSRect) {
        // Over the box's own fill, so a pressed pill is simply a deeper one.
        let fill = min(1, look.fill + (isPressed ? 0.2 : 0))
        Pill.box.withAlphaComponent(fill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: corner, yRadius: corner).fill()
        // A device pixel inside the edge, as the boxes' hairline is. On a box,
        // at twice its strength, whatever the fill: a control on it, not one
        // more box, and a pill on a bare caption still has an edge. Beside the
        // tab, over the picture, the box's own line, as the tab wears it.
        let besideTab = look.tabHeight != nil
        guard !besideTab || look.fill > 0 else { return }
        let line = 1 / max(window?.backingScaleFactor ?? 2, 1)
        (besideTab ? Pill.outlineInk : Self.outlineInk).setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2),
                                   xRadius: max(corner - line / 2, 0), yRadius: max(corner - line / 2, 0))
        outline.lineWidth = line
        outline.stroke()
    }

    /// `Pill.outlineInk` doubled.
    private static let outlineInk = NSColor(name: nil) { appearance in
        Pill.isDark(appearance)
            ? NSColor(srgbRed: 210 / 255, green: 210 / 255, blue: 211 / 255, alpha: 0.32)
            : NSColor.black.withAlphaComponent(0.16)
    }

    override func layout() {
        super.layout()
        blur.frame = bounds
        face.frame = bounds
        blur.shape = .init(rect: bounds, corner: corner)
        // The symbol and the word as one group, centered: the pill is as wide
        // as the longer word, and the shorter one would otherwise leave its
        // spare room all at the end.
        let side = fontSize.rounded()
        let word = ceil(label.intrinsicContentSize.width)
        let start = ((bounds.width - (side + Self.iconGap + word)) / 2).rounded()
        icon.frame = NSRect(x: start, y: ((bounds.height - side) / 2).rounded(),
                            width: side, height: side)
        let height = label.intrinsicContentSize.height
        label.frame = NSRect(x: icon.frame.maxX + Self.iconGap, y: ((bounds.height - height) / 2).rounded(),
                             width: word, height: height)
    }

    /// The box's colors follow the appearance, which is the theme's.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    // MARK: the click

    /// The first click counts: neither panel it sits on ever becomes key for it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isShown ? super.hitTest(point).map { _ in self } : nil
    }

    override func mouseDown(with event: NSEvent) { isPressed = true }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        copyToPasteboard()
    }

    private func copyToPasteboard() {
        let text = text()
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        isCopied = true
        apply()
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: Self.copiedFor, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.isCopied = false
            self.apply()
        }
    }

    // MARK: VoiceOver

    override func isAccessibilityElement() -> Bool { isShown }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label.stringValue }
    override func accessibilityPerformPress() -> Bool {
        copyToPasteboard()
        return true
    }
}

extension Pill {
    /// Where a box's Copy button goes: `margin` in from the top end of `pill`,
    /// or, on a box with no header row or name tab, centered on its first line
    /// of text at the same distance from the end. Never nearer the top edge
    /// than the band a press resizes the box by. With a name tab, above the
    /// box at its end, flush with that edge as the tab is with the other, and
    /// level with the tab, raised by `lift`: the live box's, so it clears the
    /// dashed outline that runs that far off the box and tops out with it.
    static func copyFrame(size: NSSize, in pill: NSRect, room: IconRoom, fontSize: CGFloat,
                          firstLine: Bool, rtl: Bool, lift: CGFloat = 0) -> NSRect {
        let margin: CGFloat = 7
        let width = ceil(size.width), height = ceil(size.height)
        if room.top > 0 {
            return NSRect(x: rtl ? pill.minX : pill.maxX - width,
                          y: (pill.maxY + CopyPill.tabGap + lift).rounded(),
                          width: width, height: height)
        }
        let x = rtl ? pill.minX + margin : pill.maxX - margin - width
        // A line's own height less the spacing after it, which `lineHeight`
        // counts and the first line does not have above it.
        let lineMiddle = textRect(in: pill, room: room).maxY - (lineHeight(ofSize: fontSize) - 2) / 2
        let top = firstLine ? min(lineMiddle + height / 2, pill.maxY - 6) : pill.maxY - margin
        return NSRect(x: x.rounded(), y: (top - height).rounded(), width: width, height: height)
    }
}

extension Pill {
    /// How far the text around a Copy button fades out, in points.
    static let copyGlow: CGFloat = 32

    /// Take away what was drawn around a Copy button at `button`, a capsule:
    /// all of it on the button, and less of it farther out, along a
    /// smoothstep, until it is whole `copyGlow` points beyond. Rings drawn
    /// `.destinationOut`, each taking the share that leaves the band inside it
    /// at the curve, so their product telescopes to it at every ring.
    static func eraseGlow(around button: NSRect, in ctx: CGContext) {
        let steps = 24
        func kept(_ ring: Int) -> CGFloat {
            let t = CGFloat(ring) / CGFloat(steps)
            return t * t * (3 - 2 * t)
        }
        ctx.saveGState()
        ctx.setBlendMode(.destinationOut)
        for ring in 0...steps {
            let rect = button.insetBy(dx: -copyGlow * CGFloat(ring) / CGFloat(steps),
                                      dy: -copyGlow * CGFloat(ring) / CGFloat(steps))
            let radius = min(rect.width, rect.height) / 2
            ctx.setFillColor(gray: 0, alpha: ring == 0 ? 1 : 1 - kept(ring - 1) / kept(ring))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        ctx.restoreGState()
    }
}
