// The window updating happens in.
//
// One window, in the About and Welcome windows' style, and the states swap
// inside it: found, downloading, ready, installing, up to date, failed, and the
// one question about checking automatically. Sparkle's own windows were tried
// first and are fine, but they are Sparkle's — a different width, a web view
// for the notes, a second window for the download — and this app's other
// windows are its own. Updater.swift is what translates Sparkle into these
// states; nothing here knows Sparkle exists, which is what lets
// tools/update-window-harness.swift show every state without a feed.
//
// Closing the window with its red button means what the state's most cautious
// button means: Later while an update is offered, Cancel while it downloads,
// nothing at all while it installs. Each state says so by carrying the closure.

import AppKit
#if canImport(CaptionCore)
import CaptionCore
#endif

final class UpdateWindow: NSObject, NSWindowDelegate {
    enum State {
        /// May the app check on its own, once a day.
        case permission(allow: () -> Void, decline: () -> Void)
        /// A check the user asked for is in flight.
        case checking(cancel: () -> Void)
        /// An update is offered. `skip` is nil for a critical update, where
        /// skipping is not on the table.
        case found(version: String, current: String, size: String?, notes: ReleaseNotes?,
                   critical: Bool, install: () -> Void, later: () -> Void, skip: (() -> Void)?)
        /// Downloading; progress arrives through `progress(fraction:detail:)`.
        case downloading(version: String, cancel: () -> Void)
        /// Unpacking, after the download; same progress path.
        case extracting(version: String)
        case ready(version: String, install: () -> Void, later: () -> Void)
        /// The app is quitting so the update can be swapped in. `retry` is
        /// offered when it did not quit.
        case installing(version: String, retry: (() -> Void)?)
        case upToDate(version: String, dismiss: () -> Void)
        case failed(title: String, message: String, retry: (() -> Void)?, dismiss: () -> Void)

        /// What the window's close button does in this state.
        var closeAction: (() -> Void)? {
            switch self {
            case .permission(_, let decline): return decline
            case .checking(let cancel): return cancel
            case .found(_, _, _, _, _, _, let later, _): return later
            case .downloading(_, let cancel): return cancel
            case .extracting: return nil
            case .ready(_, _, let later): return later
            case .installing: return nil
            case .upToDate(_, let dismiss): return dismiss
            case .failed(_, _, _, let dismiss): return dismiss
            }
        }
    }

    /// Content width, and the padding round it. Between About's 340 and the
    /// Welcome window's 584: wide enough for release notes to read as prose,
    /// narrow enough to be a dialog.
    private static let width: CGFloat = 400
    private static let inset: CGFloat = 26
    private static let insetH: CGFloat = 40

    private var window: NSWindow?
    private var state: State?
    private var bar: NSProgressIndicator?
    private var detail: NSTextField?
    /// True while `close()` is closing the window itself, so the delegate does
    /// not mistake it for the user's red button.
    private var closingProgrammatically = false

    var isVisible: Bool { window?.isVisible ?? false }
    /// For the harness, which captures the window by number.
    var nativeWindow: NSWindow? { window }

    func show(_ state: State) {
        self.state = state
        let window = self.window ?? build()
        self.window = window

        let content = contentView(for: state)
        let root = NSView()
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Width stated outright, rather than left to `fittingSize` — see
            // About.swift for why a stack pinned to its window loses its insets.
            content.widthAnchor.constraint(equalToConstant: Self.width + Self.insetH * 2),
        ])

        let wasVisible = window.isVisible
        let top = window.frame.maxY
        let left = window.frame.minX
        window.contentView = root
        window.layoutIfNeeded()
        let size = content.fittingSize
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        if wasVisible {
            // The top edge stays where it is: a dialog whose title bar jumps as
            // it changes state reads as a different window.
            frame.origin = NSPoint(x: left, y: top - frame.height)
            window.setFrame(frame, display: true, animate: true)
        } else {
            window.setFrame(frame, display: false)
            window.center()
        }
        // The window's close button is the state's cautious choice, and there
        // is none for the states that must run to the end.
        window.standardWindowButton(.closeButton)?.isEnabled = state.closeAction != nil

        // An agent app is never the active application, so the window would
        // otherwise open behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Progress for the downloading and extracting states. `fraction` nil
    /// means working, length unknown.
    func progress(fraction: Double?, detail text: String?) {
        if let bar {
            let unknown = fraction == nil
            if unknown != bar.isIndeterminate {
                bar.isIndeterminate = unknown
                if unknown { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
            }
            if let fraction { bar.doubleValue = fraction }
        }
        if let text { detail?.stringValue = text }
    }

    func close() {
        guard let window else { return }
        closingProgrammatically = true
        window.orderOut(nil)
        closingProgrammatically = false
        state = nil
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !closingProgrammatically, let action = state?.closeAction else {
            return closingProgrammatically
        }
        // The action is what closes it — through Updater, which will call
        // `close()` when Sparkle has finished with the session.
        action()
        return false
    }

    // MARK: building

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.insetH * 2, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Subtitles Update"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }

    private func contentView(for state: State) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.insetH,
                                        bottom: Self.inset, right: Self.insetH)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar = nil
        detail = nil

        let icon = Self.icon()
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)

        switch state {
        case .permission(let allow, let decline):
            add(stack, headline: "Check for updates automatically?",
                blurb: "Once a day, Subtitles would ask subtitles-live.com whether there is a "
                    + "newer version. The request carries the app's version and nothing else — "
                    + "no audio, no captions, nothing about you. It is the only request the app "
                    + "ever makes on its own, and the menu bar can turn it off later.")
            addButtons(stack, [Self.button("Don't Check", decline),
                               Self.button("Check Automatically", allow, default: true)])

        case .checking(let cancel):
            add(stack, headline: "Checking for updates…", blurb: nil)
            let bar = Self.progressBar(indeterminate: true)
            stack.addArrangedSubview(bar)
            stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            self.bar = bar
            addButtons(stack, [Self.button("Cancel", cancel)])

        case .found(let version, let current, let size, let notes, let critical, let install, let later, let skip):
            let what = size.map { "The update is \($0) and installs in place" } ?? "It installs in place"
            add(stack, headline: "Subtitles \(version) is available",
                blurb: critical
                    ? "You have \(current). This one fixes something that matters. \(what), so the audio permission stays."
                    : "You have \(current). \(what), so the audio permission stays.")
            if let notes, !notes.isEmpty {
                let box = Self.notesBox(notes)
                stack.addArrangedSubview(box)
                stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            if let skip { row.addArrangedSubview(Self.button("Skip This Version", skip)) }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(Self.button("Later", later))
            row.addArrangedSubview(Self.button("Install Update", install, default: true))
            row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        case .downloading(let version, let cancel):
            add(stack, headline: "Downloading \(version)…", blurb: nil)
            addProgress(stack, indeterminate: true, detail: "Starting…")
            addButtons(stack, [Self.button("Cancel", cancel)])

        case .extracting(let version):
            add(stack, headline: "Unpacking \(version)…", blurb: nil)
            addProgress(stack, indeterminate: true, detail: "A moment.")

        case .ready(let version, let install, let later):
            add(stack, headline: "Ready to install",
                blurb: "Subtitles will quit and come back as \(version). The captions come back with it.")
            addButtons(stack, [Self.button("Later", later),
                               Self.button("Install and Relaunch", install, default: true)])

        case .installing(let version, let retry):
            add(stack, headline: "Installing \(version)…",
                blurb: retry == nil
                    ? "Subtitles is quitting and will be back in a moment."
                    : "Subtitles has not quit yet. Something may be asking to keep it open.")
            if let retry {
                addButtons(stack, [Self.button("Quit and Install", retry, default: true)])
            } else {
                addProgress(stack, indeterminate: true, detail: nil)
            }

        case .upToDate(let version, let dismiss):
            add(stack, headline: "You have the latest version",
                blurb: "Subtitles \(version) · checked just now")
            addButtons(stack, [Self.button("OK", dismiss, default: true)])

        case .failed(let title, let message, let retry, let dismiss):
            add(stack, headline: title, blurb: message)
            var buttons = [Self.button("OK", dismiss, default: retry == nil)]
            if let retry { buttons.append(Self.button("Try Again", retry, default: true)) }
            addButtons(stack, buttons)
        }
        return stack
    }

    private func add(_ stack: NSStackView, headline: String, blurb: String?) {
        let head = Self.label(headline, size: 17, weight: .semibold)
        stack.addArrangedSubview(head)
        guard let blurb else { return }
        let sub = Self.label(blurb, size: 11, colour: .secondaryLabelColor)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(2, after: head)
    }

    private func addButtons(_ stack: NSStackView, _ buttons: [NSButton]) {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
    }

    private func addProgress(_ stack: NSStackView, indeterminate: Bool, detail text: String?) {
        let bar = Self.progressBar(indeterminate: indeterminate)
        stack.addArrangedSubview(bar)
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        self.bar = bar
        guard let text else { return }
        let label = Self.label(text, size: 11, colour: .secondaryLabelColor)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(4, after: bar)
        detail = label
    }

    // MARK: pieces

    private static func icon() -> NSImageView {
        let view = NSImageView(image: NSApp.applicationIconImage)
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 64),
            view.heightAnchor.constraint(equalToConstant: 64),
        ])
        return view
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
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

    /// Buttons carry their action as a closure: the states are values, and a
    /// target/action pair would need an object per button to point at.
    private static func button(_ title: String, _ action: @escaping () -> Void,
                               default isDefault: Bool = false) -> NSButton {
        let button = ClosureButton(title: title, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .large
        if isDefault { button.keyEquivalent = "\r" }
        return button
    }

    private static func progressBar(indeterminate: Bool) -> NSProgressIndicator {
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

    /// The notes, set in the window's own type inside a soft box, scrolling
    /// once they run past what a dialog should hold.
    private static func notesBox(_ notes: ReleaseNotes) -> NSView {
        let padH: CGFloat = 14, padV: CGFloat = 12, maxHeight: CGFloat = 220
        let textWidth = width - padH * 2
        let text = NSTextField(wrappingLabelWithString: "")
        text.attributedStringValue = attributed(notes)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = textWidth
        // The cell's answer, not `fittingSize`: a wrapping label outside any
        // constraint system reports its one-line width and a height to match.
        let textHeight = text.cell!.cellSize(forBounds:
            NSRect(x: 0, y: 0, width: textWidth, height: .greatestFiniteMagnitude)).height
        let full = ceil(textHeight + padV * 2)
        let height = min(full, maxHeight)

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = boxFill.cgColor

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

    private static func attributed(_ notes: ReleaseNotes) -> NSAttributedString {
        let out = NSMutableAttributedString()
        if let heading = notes.heading {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            out.append(NSAttributedString(string: heading + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: style,
            ]))
        }
        for (i, item) in notes.items.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.lineSpacing = 1
            if item.bulleted {
                style.headIndent = 14
                style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
                out.append(NSAttributedString(string: "\u{2022}\t", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: style,
                ]))
            }
            for run in item.runs {
                let font: NSFont = run.code
                    ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                    : .systemFont(ofSize: 12, weight: run.bold ? .semibold : .regular)
                out.append(NSAttributedString(string: run.text, attributes: [
                    .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
                ]))
            }
            if i < notes.items.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style]))
            }
        }
        return out
    }

    /// The box's fill. The system's quaternary fill is a shade too close to a
    /// dark window to read as a box; these are set by eye against both.
    private static let boxFill = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.05)
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private final class ClosureButton: NSButton {
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
