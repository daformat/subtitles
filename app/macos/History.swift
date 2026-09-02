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

import AppKit

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
        // has to land somewhere. It is only on screen while ⌥ is held, so the
        // clicks it swallows are ones the user is deliberately aiming at it.
        ignoresMouseEvents = false
        hidesOnDeactivate = false

        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
    }

    // Same as the live panel: never steal focus from what the user is working in.
    // Scroll events do not require key status, so this costs nothing.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
struct HistoryStyle {
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

    private let text: String
    private let style: HistoryStyle

    init(text: String, style: HistoryStyle) {
        self.text = text
        self.style = style
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private var attributed: NSAttributedString {
        Pill.attributed(committed: text, tentative: "", size: style.fontSize,
                        opacity: style.textOpacity)
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        Pill.fittingSize(
            Pill.attributed(committed: text, tentative: "", size: style.fontSize, centered: false),
            size: style.fontSize, maxWidth: maxWidth, maxLines: style.maxLines, pad: 0)
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

    private let panel = HistoryPanel()

    /// Whether the stack is captured by screen recording and sharing. Follows the
    /// live box: the two are one overlay as far as anyone watching is concerned,
    /// and hiding one while the other stays visible would be worse than hiding
    /// neither.
    var isVisibleInScreenShare = true {
        didSet { panel.sharingType = isVisibleInScreenShare ? .readOnly : .none }
    }

    private let scroll = HistoryScrollView()
    private let document = NSView()

    /// What is on screen right now, oldest first — the same array `present` was
    /// last called with. Compared against on every poll so a page closing while
    /// ⌥ is still down animates itself in rather than waiting for the next press.
    private(set) var shown: [String] = []

    private var isVisible = false
    private var placedAbove = true

    /// Full height of the stack, and its width — the size it *wants*, before the
    /// room next to the live box is taken into account. Kept so `place` can
    /// re-derive the panel's height on every word without rebuilding the pills.
    private var contentHeight: CGFloat = 0
    private var stackWidth: CGFloat = 0

    /// Height the panel was last given, so `place` can tell a resize — which the
    /// scroll offset has to be re-anchored against — from the far more common
    /// case of the live box merely moving.
    private var placedHeight: CGFloat = 0

    /// Softens the edge that has content beyond it. A mask on the clip view
    /// rather than a view drawn over the top: the panel is transparent, so an
    /// overlaid gradient would have to fade to a colour that is not there, and
    /// would darken the desktop showing through instead of the boxes.
    private let fadeMask = CAGradientLayer()
    private var scrollObserver: NSObjectProtocol?

    init() {
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
        panel.contentView = scroll

        scroll.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: nil
        ) { [weak self] _ in
            self?.updateFade()
        }

        panel.alphaValue = 0
    }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
    }

    // MARK: build

    /// Put `entries` (oldest first) on screen against the live box at `anchor`.
    ///
    /// Boxes already on screen keep their position and stay put; anything new
    /// animates in. That is what makes this safe to call from the poll whenever
    /// the transcript pages while ⌥ is still held.
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

        let alreadyShowing = isVisible ? shown : []
        let wasVisible = isVisible
        // Where the reader is, measured from the end of the stack that touches the
        // live box, before any of this changes underneath them.
        let previousContent = isVisible ? contentHeight : 0
        let previousNear = isVisible ? nearDistance() : 0
        let wasParked = !isVisible || previousNear <= 1

        // Above by default — history reads upwards, and the box usually sits low.
        // Flip only when there is genuinely more room the other way, and reverse
        // the stack with it so the newest box stays the one touching the live box.
        //
        // Decided once, on the press that raised the stack. Re-deciding it as the
        // live box resizes would let one sentence wrapping to a second line throw
        // the whole stack to the other side of it mid-read.
        let above = isVisible
            ? placedAbove
            : Self.room(above: true, anchor: anchor, screen: screen)
                >= Self.room(above: false, anchor: anchor, screen: screen)

        // Newest first: index 0 is the box nearest the live one, which is where
        // the eye goes and so where the animation starts.
        let ordered = Array(entries.reversed())
        // Ceiling matched to the live box: it spends `pad` of its own width on
        // the ⇧ ring margin, and these have no ring, so the same sentence must be
        // measured against a correspondingly narrower box or the stack would sit
        // a few points wider than the box it belongs to.
        let ceiling = maxWidth - SubtitleView.pad * 2

        document.subviews.forEach { $0.removeFromSuperview() }

        var pills: [HistoryPillView] = []
        var sizes: [NSSize] = []
        var width: CGFloat = 0
        for text in ordered {
            let pill = HistoryPillView(text: text, style: style)
            let size = pill.fittingSize(maxWidth: ceiling)
            pills.append(pill)
            sizes.append(size)
            width = max(width, size.width)
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
            let y = above ? offset : contentHeight - offset - size.height
            pill.frame = NSRect(x: ((width - size.width) / 2).rounded(), y: y.rounded(),
                                width: size.width, height: size.height)
            document.addSubview(pill)
            offset += size.height + Self.gap
        }

        placedAbove = above
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
        if !wasVisible || !scroll.isScrolling {
            setNearDistance(wasParked ? 0 : previousNear + (contentHeight - previousContent))
        }
        updateFade()

        if animated {
            animateIn(pills, ordered: ordered, alreadyShowing: alreadyShowing, above: above)
        }

        shown = entries
        if !isVisible {
            isVisible = true
            guard fits else { return }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    /// Follow the live box as it resizes under a new word, without rebuilding.
    func reposition(anchor: NSRect, centreX: CGFloat) {
        guard isVisible else { return }
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
    /// Returns false when there is no longer anywhere to put it.
    @discardableResult
    private func place(anchor: NSRect, centreX: CGFloat) -> Bool {
        guard contentHeight > 0, let screen = Self.screen(for: anchor) else { return false }

        let room = Self.room(above: placedAbove, anchor: anchor, screen: screen)
        guard room >= Self.minRoom else {
            // Nowhere left. Hide rather than tear down: the live box shrinks again
            // on the next page, and the stack should still be there when it does.
            panel.orderOut(nil)
            return false
        }

        let size = NSSize(width: stackWidth, height: min(contentHeight, room).rounded())

        // Elastic only while there is somewhere to go. A stack that fits its
        // panel must sit dead still under the wheel: rubber-banding a list with
        // no more content to reach reads as something broken rather than as
        // feedback. Set from the height that is about to be applied, so it is
        // already right for the first event after a resize.
        scroll.verticalScrollElasticity = contentHeight > size.height + 1 ? .allowed : .none
        let origin = NSPoint(
            x: (centreX - size.width / 2).rounded(),
            y: (placedAbove
                ? anchor.maxY - SubtitleView.pad + Self.gap
                : anchor.minY + SubtitleView.pad - Self.gap - size.height).rounded())
        let frame = NSRect(origin: clamp(origin, size: size, to: screen.visibleFrame), size: size)

        // Only a change of *height* disturbs the scroller; the live box merely
        // moving does not. Read the reader's position before the resize lands.
        let resized = abs(size.height - placedHeight) > 0.5
        let near = resized ? nearDistance() : 0

        // `display: false` matters: a synchronous repaint here would paint the
        // panel before the scroll offset below has been restored, and that stray
        // frame is exactly the shift-then-settle you see when a new box lands.
        // Left to the normal display cycle, the first frame drawn is the right
        // one.
        if frame != panel.frame { panel.setFrame(frame, display: false) }
        placedHeight = size.height

        // Back from a starved layout.
        if isVisible, !panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
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
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.document.subviews.forEach { $0.removeFromSuperview() }
        })
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

    /// Fade the edge that has boxes beyond it — and only that one.
    ///
    /// The far edge, never the near one: the box against the live one is the
    /// newest, the one being read, and dimming it would be backwards. So the
    /// fade is at the top when the stack is drawn above the live box and at the
    /// bottom when it is drawn below, which are the only directions older boxes
    /// can be in.
    ///
    /// Driven by the clip view's bounds notification, so it tracks the wheel
    /// rather than only the moment the stack is built.
    private func updateFade() {
        let clip = scroll.contentView
        guard let document = scroll.documentView else { return }

        let visible = clip.bounds
        let content = document.frame.height
        let hidden = placedAbove ? content - visible.maxY : visible.minY

        // Nothing behind that edge — including the case where the whole stack
        // fits, when there is no edge to speak of. A fade with nothing behind it
        // promises more to see and then does not deliver it.
        guard visible.height > 0, content > visible.height + 1, hidden > 0.5 else {
            if clip.layer?.mask != nil { clip.layer?.mask = nil }
            return
        }

        let fade = min(min(Self.fadeHeight, hidden), visible.height / 2)
        let stop = fade / visible.height

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
        if placedAbove {
            fadeMask.colors = [solid, solid, clear]
            fadeMask.locations = [0, NSNumber(value: Double(1 - stop)), 1]
        } else {
            fadeMask.colors = [clear, solid, solid]
            fadeMask.locations = [0, NSNumber(value: Double(stop)), 1]
        }
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
    private func animateIn(_ pills: [HistoryPillView], ordered: [String],
                           alreadyShowing: [String], above: Bool) {
        let carried = Set(alreadyShowing)
        let now = CACurrentMediaTime()
        var step = 0
        for (i, pill) in pills.enumerated() {
            // A box that was already on screen does not animate again; only the
            // ones that just closed do.
            if !alreadyShowing.isEmpty, carried.contains(ordered[i]) { continue }
            guard let layer = pill.layer else { continue }

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
