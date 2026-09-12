// The parts the app's dialogs are built from.
//
// The update window, the licence window and the acknowledgements window are
// the same kind of thing — one window in the About window's style whose
// states swap inside it — and these are the pieces they share: the icon at
// the top, the two label styles, a button that carries its action as a
// closure, a box of text, a progress bar. Kept here so the windows cannot
// drift apart by a point, and so each harness under tools/ compiles one file
// for them rather than another window.

import AppKit

enum Dialog {
    /// Content width, and the padding round it, for every dialog. Between
    /// About's 340 and the Welcome window's 584: wide enough for a paragraph
    /// to read as prose, narrow enough to be a dialog.
    static let width: CGFloat = 400
    static let inset: CGFloat = 26
    static let insetH: CGFloat = 40

    static func window(title: String, delegate: NSWindowDelegate) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width + insetH * 2, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        return window
    }

    /// The vertical stack every state is laid out in.
    static func stack() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: inset, left: insetH, bottom: inset, right: insetH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Puts `content` in `window` at the stack's own size, keeping the top
    /// edge where it was if the window is already up: a dialog whose title
    /// bar jumps as it changes state reads as a different window.
    static func place(_ content: NSView, in window: NSWindow) {
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Width stated outright, rather than left to `fittingSize` — see
            // About.swift for why a stack pinned to its window loses its insets.
            content.widthAnchor.constraint(equalToConstant: width + insetH * 2),
        ])
        let wasVisible = window.isVisible
        let top = window.frame.maxY
        let left = window.frame.minX
        window.contentView = root
        window.layoutIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if wasVisible {
            frame.origin = NSPoint(x: left, y: top - frame.height)
            window.setFrame(frame, display: true, animate: true)
        } else {
            window.setFrame(frame, display: false)
            window.center()
        }
    }

    static func icon() -> NSImageView {
        let view = NSImageView(image: NSApp.applicationIconImage)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 64),
            view.heightAnchor.constraint(equalToConstant: 64),
        ])
        return view
    }

    static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                      colour: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = colour
        label.alignment = .center
        label.preferredMaxLayoutWidth = width
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return label
    }

    /// A headline and, under it, the paragraph that explains it.
    static func add(_ stack: NSStackView, headline: String, blurb: String?) {
        let head = label(headline, size: 17, weight: .semibold)
        stack.addArrangedSubview(head)
        guard let blurb else { return }
        let sub = label(blurb, size: 11, colour: .secondaryLabelColor)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(2, after: head)
    }

    /// Buttons carry their action as a closure: the states are values, and a
    /// target/action pair would need an object per button to point at.
    static func button(_ title: String, _ action: @escaping () -> Void,
                       default isDefault: Bool = false) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        if isDefault { button.keyEquivalent = "\r" }
        return button
    }

    /// A row of buttons at the foot of a state, a little apart from what is
    /// above it.
    static func addButtons(_ stack: NSStackView, _ buttons: [NSButton]) {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    /// Text in the window's own type inside a soft box, scrolling once it
    /// runs past `maxHeight`.
    static func textBox(_ content: NSAttributedString, maxHeight: CGFloat = 220) -> NSView {
        let padH: CGFloat = 14, padV: CGFloat = 12
        let textWidth = width - padH * 2
        let text = NSTextField(wrappingLabelWithString: "")
        text.attributedStringValue = content
        text.isSelectable = true
        text.preferredMaxLayoutWidth = textWidth
        // The cell's answer, not `fittingSize`: a wrapping label outside any
        // constraint system reports its one-line width and a height to match.
        let textHeight = text.cell!.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height
        let full = ceil(textHeight + padV * 2)
        let height = min(full, maxHeight)

        let box = BoxView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 10

        // The document is laid out by frame — a document view sized by
        // constraints against its clip view is the one layout AppKit gets
        // wrong most reliably — and flipped, so its top is the top. The scroll
        // view itself is pinned to the box by constraints, because the box has
        // no size until its own constraints run, and an autoresizing mask
        // scaling from a zero frame stays zero.
        let document = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: full))
        text.frame = NSRect(x: padH, y: padV, width: textWidth, height: ceil(textHeight))
        document.addSubview(text)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = full > maxHeight
        scroll.autohidesScrollers = true
        scroll.documentView = document
        box.addSubview(scroll)
        NSLayoutConstraint.activate([
            box.widthAnchor.constraint(equalToConstant: width),
            box.heightAnchor.constraint(equalToConstant: height),
            scroll.topAnchor.constraint(equalTo: box.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
        ])
        return box
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// The box, filled in `updateLayer` rather than once when built. A
    /// dynamic colour's `cgColor` is resolved against whatever appearance is
    /// current at the call, and at build time that is the app's, not the
    /// window's: the harness sets a window dark after building it, and a
    /// system that switches while a dialog is up does the same. AppKit calls
    /// this under the view's own appearance, and again when it changes.
    private final class BoxView: NSView {
        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            layer?.backgroundColor = Dialog.boxFill.cgColor
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    static func progressBar(indeterminate: Bool) -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.isIndeterminate = indeterminate
        bar.minValue = 0
        bar.maxValue = 1
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 320).isActive = true
        if indeterminate { bar.startAnimation(nil) }
        return bar
    }

    /// The fill for a box inside a dialog. The system's quaternary fill is a
    /// shade too close to a dark window to read as a box; these are set by
    /// eye against both, and the light one twice, since a first try at five
    /// percent barely showed.
    static let boxFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.08)
    }

    final class ClosureButton: NSButton {
        private let closure: () -> Void

        init(title: String, action: @escaping () -> Void) {
            closure = action
            super.init(frame: .zero)
            self.title = title
            target = self
            self.action = #selector(fire)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func fire() { closure() }
    }
}
