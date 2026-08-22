// The settings window.
//
// Numbers that can only be judged by watching them move: how much of the box the
// pointer reveal takes, how far that reveal reaches, and how far ⌥ can scroll
// back. Every control applies to the running overlay on the same edit and writes
// through to UserDefaults as it goes — there is no OK button, because the
// overlay sitting in front of you is the preview.
//
// The on/off switches for these features stay in the menu, where they were and
// where they are one click away. This window is for the dials behind them.

import AppKit

final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    // Wired up by main.swift. Getters as well as setters: the window is rebuilt
    // on every open, so it reads the live values rather than remembering any.
    var revealOpacity: () -> CGFloat = { 1 }
    var onRevealOpacity: ((CGFloat) -> Void)?
    var revealSize: () -> NSSize = { SubtitleView.defaultMaskSize }
    var onRevealSize: ((NSSize) -> Void)?
    var historyDepth: () -> Int = { OverlayController.defaultHistoryDepth }
    var onHistoryDepth: ((Int) -> Void)?
    var historyTextOpacity: () -> CGFloat = { HistoryPillView.defaultTextOpacity }
    var onHistoryTextOpacity: ((CGFloat) -> Void)?
    /// Seconds of no new text before the stack is forgotten, and whether that
    /// happens at all.
    var historyExpiry: () -> Double = { OverlayController.defaultHistoryExpiry }
    var onHistoryExpiry: ((Double) -> Void)?
    var historyExpires: () -> Bool = { true }
    var onHistoryExpires: ((Bool) -> Void)?
    var maxLines: () -> Int = { SubtitleView.defaultMaxLines }
    var onMaxLines: ((Int) -> Void)?
    var boxOpacity: () -> CGFloat = { SubtitleView.defaultBackgroundOpacity }
    var onBoxOpacity: ((CGFloat) -> Void)?
    /// Read-only here — text size is a menu setting. The preview needs it to
    /// draw the box the size it actually is.
    var fontSize: () -> CGFloat = { 30 }
    /// Cache folders that must not be removed — the models actually in use.
    var modelsInUse: () -> Set<String> = { [] }
    /// The same state as the menu's "Fade Away Under Pointer".
    var revealEnabled: () -> Bool = { true }
    var onToggleReveal: ((Bool) -> Void)?
    /// The same state as the menu's "Recent Boxes On ⌥".
    var historyEnabled: () -> Bool = { true }
    var onToggleHistory: ((Bool) -> Void)?
    /// The same state as the menu's "Skip Non-Speech (VAD)".
    var vadEnabled: () -> Bool = { true }
    var onToggleVAD: ((Bool) -> Void)?
    /// The same state as the menu's "New Box On Speaker Change".
    var speakerBreaksEnabled: () -> Bool = { false }
    var onToggleSpeakerBreaks: ((Bool) -> Void)?
    /// Put every overlay setting back to its default. The window rebuilds itself
    /// afterwards, so this only has to change the values.
    var onResetDefaults: (() -> Void)?

    private static let width: CGFloat = 430
    private static let inset: CGFloat = 22
    /// The width everything inside a pane is laid out against.
    private static var contentWidth: CGFloat { width - inset * 2 }
    /// Shared by every row's trailing cell, so the numbers line up down the
    /// window whichever kind of row they belong to.
    private static let readoutWidth: CGFloat = 88

    private var window: NSWindow?
    /// Scrolls the pane when the screen is too short for it. Always present
    /// rather than installed on demand: a window that is tall enough today is
    /// one display change away from not being, and the scrollers hide
    /// themselves when there is nothing to reach.
    private let paneScroll = WindowFit.scrollView()
    /// The body's height, which is the pane's until the screen runs out.
    private var bodyHeight: NSLayoutConstraint?
    /// Fires when a display is added, removed, rearranged or set to another
    /// resolution — any of which can leave this window taller than the screen
    /// it is on.
    private var screenObserver: NSObjectProtocol?
    /// Holds whichever pane is showing, so the header above it never moves.
    private var body: NSView?
    /// Rows hold their own action closures, so they have to outlive `build`.
    private var rows: [SliderRow] = []
    /// The screen at the top of the UI pane. Nil while that pane has never been
    /// built, and again after the window closes.
    private var preview: SettingsPreview?

    /// The panes, in toolbar order.
    ///
    /// A header built by hand rather than an `NSToolbar`.
    ///
    /// The toolbar gets the shape right and the colours wrong: it tints its own
    /// items and draws its own selection, so there is no way to say "grey until
    /// selected, then full contrast", and in `.preference` style it lays its
    /// items on a material a shade off the window beneath. Fifty lines of view
    /// buys exact control of both.
    private static let panes: [(label: String, symbol: String)] = [
        ("UI", "captions.bubble"),
        ("Models", "cpu"),
    ]

    private var stacks: [NSStackView] = []
    private var buttons: [PaneButton] = []
    private var selected = 0

    private let revealSwitch = NSSwitch()
    private let historySwitch = NSSwitch()
    /// Held so the menu changing them behind this window can be picked up.
    private var vadRow: ToggleRow?
    private var speakerRow: ToggleRow?
    /// The rows each switch governs, dimmed with it.
    private var revealRows: [SliderRow] = []
    private var historyRows: [SliderRow] = []
    /// Governed by the section switch *and* by its own, so it is held apart.
    private var expiryRow: SecondsRow?
    private var expiryToggle: ToggleRow?

    private let cacheReadout = NSTextField(labelWithString: "")
    private let clearButton = NSButton(title: "Clear Model Cache…", target: nil, action: nil)
    /// What the last scan found, and what the button will delete.
    private var removable: [ModelCache.Entry] = []

    func show() {
        // An agent app is never the active application, so the window would
        // otherwise open behind whatever the user is working in — and, having no
        // Dock icon to click, be unreachable except by moving windows aside.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(nil)
            return
        }
        let window = build()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        // After keying it, not before: becoming key is when AppKit picks a first
        // responder of its own, and it picks the seconds field — ringed, its
        // contents selected, ready to swallow anything typed at a window nobody
        // aimed at it.
        window.makeFirstResponder(nil)
    }

    /// Torn down rather than hidden, so the next open reads the settings as they
    /// stand — including any changed from the menu in the meantime.
    func windowWillClose(_ notification: Notification) {
        window = nil
        rows = []
        stacks = []
        buttons = []
        body = nil
        // The scroll view outlives the window; the pane it was showing must not.
        paneScroll.documentView = nil
        bodyHeight = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        preview = nil
        revealRows = []
        historyRows = []
        expiryRow = nil
        expiryToggle = nil
        vadRow = nil
        speakerRow = nil
        removable = []
    }

    /// The model can be switched from the menu while this window sits open, which
    /// changes both what is removable and what must be kept.
    func windowDidBecomeKey(_ notification: Notification) {
        // All of these can be changed from the menu while the window is open.
        revealSwitch.state = revealEnabled() ? .on : .off
        syncRevealEnabled()
        historySwitch.state = historyEnabled() ? .on : .off
        syncHistoryEnabled()
        vadRow?.isOn = vadEnabled()
        speakerRow?.isOn = speakerBreaksEnabled()
        preview?.apply(currentStyle())
        refreshCacheSize()
    }

    // MARK: - One labelled slider

    /// A slider, its title and its readout, kept together.
    ///
    /// A class rather than three loose views because target/action carries no
    /// context: something has to hold the closure that knows what this particular
    /// slider means, and be retained while the window is open.
    private final class SliderRow: NSObject {
        let title: NSTextField
        let slider = NSSlider()
        let readout = NSTextField(labelWithString: "")

        var cells: [NSView] { [title, slider, readout] }

        private let format: (Double) -> String
        private let apply: (Double) -> Void
        private let snaps: Bool

        /// Dimmed rather than hidden when the feature above is switched off: the
        /// settings should still say what they are, and a section that empties
        /// itself makes the window jump.
        var isEnabled = true {
            didSet {
                slider.isEnabled = isEnabled
                title.textColor = isEnabled ? .labelColor : .disabledControlTextColor
                readout.textColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
            }
        }

        init(_ title: String, range: ClosedRange<Double>, value: Double,
             snaps: Bool = false,
             format: @escaping (Double) -> String,
             apply: @escaping (Double) -> Void) {
            self.title = NSTextField(labelWithString: title)
            self.format = format
            self.apply = apply
            self.snaps = snaps
            super.init()

            slider.minValue = range.lowerBound
            slider.maxValue = range.upperBound
            // Clamped, not just assigned: NSSlider silently pins the thumb to the
            // end of its track for an out-of-range value, and the readout would
            // then be the only thing still claiming the old number.
            slider.doubleValue = min(max(value, range.lowerBound), range.upperBound)
            // Live, not on mouse-up: the whole point is to watch the overlay
            // change while the thumb is moving.
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(changed)

            readout.stringValue = format(slider.doubleValue)
            readout.alignment = .right
            // Tabular figures, or the readout changes width as the digits change
            // and drags the layout around with it.
            readout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                      weight: .regular)
            readout.textColor = .secondaryLabelColor
            readout.setContentHuggingPriority(.defaultLow, for: .horizontal)
            readout.widthAnchor.constraint(equalToConstant: readoutWidth).isActive = true
        }

        @objc private func changed(_ sender: NSSlider) {
            // Snapped by writing the rounded value back to the slider mid-drag,
            // rather than with `allowsTickMarkValuesOnly` — that needs tick marks
            // drawn, and thirty of them across a track read as a comb.
            if snaps { sender.doubleValue = sender.doubleValue.rounded() }
            readout.stringValue = format(sender.doubleValue)
            apply(sender.doubleValue)
        }
    }

    /// A labelled switch with its explanation under it.
    ///
    /// Separate from `SliderRow` rather than a mode of it: this one carries its
    /// own two lines of text and sits full-width, where a slider row is three
    /// columns in a grid shared with its neighbours.
    private final class ToggleRow: NSObject {
        let view: NSStackView
        let control = NSSwitch()
        private let label: NSTextField
        private let sub: NSTextField
        private let apply: (Bool) -> Void

        init(_ title: String, detail: String, value: Bool, width: CGFloat,
             apply: @escaping (Bool) -> Void) {
            self.apply = apply

            let label = NSTextField(labelWithString: title)
            let sub = NSTextField(labelWithString: detail)
            self.label = label
            self.sub = sub
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor

            let text = NSStackView(views: [label, sub])
            text.orientation = .vertical
            text.alignment = .leading
            text.spacing = 1

            // Eats the slack, so the switch is pushed out to the margin instead
            // of sitting against the text.
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

            view = NSStackView(views: [text, spacer, control])
            view.orientation = .horizontal
            view.alignment = .centerY
            view.spacing = 8
            view.widthAnchor.constraint(equalToConstant: width).isActive = true

            super.init()
            control.state = value ? .on : .off
            control.target = self
            control.action = #selector(changed)
        }

        @objc private func changed(_ sender: NSSwitch) { apply(sender.state == .on) }

        var isOn: Bool {
            get { control.state == .on }
            set { control.state = newValue ? .on : .off }
        }

        var isEnabled = true {
            didSet {
                control.isEnabled = isEnabled
                label.textColor = isEnabled ? .labelColor : .disabledControlTextColor
                sub.textColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
            }
        }
    }

    /// A duration in seconds: a slider for the common range, and a field for
    /// anything outside it.
    ///
    /// The field is the value, not a readout of the slider. The slider covers
    /// 5 seconds to 5 minutes, which is the range anyone actually reaches for;
    /// someone who wants an hour, or nought, types it, and the slider then sits
    /// at its nearest end rather than pretending to hold a number it cannot
    /// reach.
    private final class SecondsRow: NSObject, NSTextFieldDelegate {
        let title = NSTextField(labelWithString: "Clear after")
        let slider = NSSlider()
        private let field = NSTextField()
        private let stepper = NSStepper()
        private let unit = NSTextField(labelWithString: "sec")
        private let trailing = NSStackView()
        private let apply: (Double) -> Void

        /// The value the three controls are showing. Kept so an emptied field can
        /// be put back rather than read as nought.
        private var seconds: Double

        var cells: [NSView] { [title, slider, trailing] }

        var isEnabled = true {
            didSet {
                slider.isEnabled = isEnabled
                field.isEnabled = isEnabled
                stepper.isEnabled = isEnabled
                title.textColor = isEnabled ? .labelColor : .disabledControlTextColor
                unit.textColor = isEnabled ? .secondaryLabelColor : .disabledControlTextColor
            }
        }

        /// Refuses the keystroke rather than the commit.
        ///
        /// A formatter alone only judges the finished string, so a letter can be
        /// typed, sit there looking accepted, and be thrown away on return.
        /// `isPartialStringValid` is asked about every edit as it happens, so
        /// anything that is not a digit simply never appears.
        private final class DigitsOnly: NumberFormatter {
            override func isPartialStringValid(
                _ partialString: String,
                newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?
            ) -> Bool {
                // Empty is allowed through so the field can be cleared to retype;
                // committing it restores the old value rather than reading as 0.
                partialString.isEmpty || partialString.allSatisfy { $0.isASCII && $0.isNumber }
            }
        }

        init(seconds: Double, apply: @escaping (Double) -> Void) {
            self.apply = apply
            self.seconds = max(seconds.rounded(), 0)
            super.init()

            slider.minValue = 5
            slider.maxValue = 300
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderMoved)

            let formatter = DigitsOnly()
            formatter.minimum = 0
            formatter.allowsFloats = false
            field.formatter = formatter
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                    weight: .regular)
            field.delegate = self
            field.target = self
            field.action = #selector(fieldCommitted)
            field.widthAnchor.constraint(equalToConstant: 40).isActive = true

            stepper.minValue = 0
            stepper.maxValue = 86_400
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.target = self
            stepper.action = #selector(stepped)

            unit.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            unit.textColor = .secondaryLabelColor

            trailing.orientation = .horizontal
            trailing.spacing = 4
            trailing.alignment = .centerY
            trailing.setViews([field, stepper, unit], in: .leading)
            trailing.widthAnchor.constraint(equalToConstant: readoutWidth).isActive = true

            set(self.seconds, notify: false)
        }

        private static func text(_ seconds: Double) -> String {
            String(Int(seconds.rounded()))
        }

        /// One place where all three controls agree.
        ///
        /// The slider parks at whichever end it can reach and the field keeps the
        /// real number, so a value outside 5–300 still shows honestly.
        private func set(_ value: Double, notify: Bool = true) {
            seconds = max(value.rounded(), 0)
            field.stringValue = Self.text(seconds)
            stepper.doubleValue = seconds
            slider.doubleValue = min(max(seconds, slider.minValue), slider.maxValue)
            if notify { apply(seconds) }
        }

        @objc private func sliderMoved(_ sender: NSSlider) { set(sender.doubleValue) }

        @objc private func stepped(_ sender: NSStepper) { set(sender.doubleValue) }

        @objc private func fieldCommitted(_ sender: NSTextField) {
            let typed = sender.stringValue.trimmingCharacters(in: .whitespaces)
            // Cleared and left cleared: put back what was there, rather than
            // reading an empty field as a request for nought.
            set(typed.isEmpty ? seconds : sender.doubleValue)
        }

        /// Committed on losing focus as well as on return, or a number typed and
        /// then clicked away from is silently dropped.
        func controlTextDidEndEditing(_ notification: Notification) {
            fieldCommitted(field)
        }
    }

    // MARK: - Building

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "Settings"
        // The titlebar stops drawing its own material, so the window is one
        // colour from the traffic lights to the bottom edge.
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            // Re-measured rather than merely clamped: the screen may have grown,
            // in which case the pane that was scrolling now fits.
            self.show(pane: self.selected, in: window)
        }
        install(into: window)
        return window
    }

    /// Build the controls and hand them to the window, replacing whatever was
    /// there. Called again after a reset: the rows read their values once, at
    /// construction, so the only way to show new ones is to build new rows.
    private func install(into window: NSWindow) {
        stacks = [buildUIStack(), buildModelsStack()]
        buttons = Self.panes.enumerated().map { index, pane in
            PaneButton(label: pane.label, symbol: pane.symbol) { [weak self] in
                guard let self, let window = self.window else { return }
                self.show(pane: index, in: window)
            }
        }

        let header = NSStackView(views: buttons)
        header.orientation = .horizontal
        header.spacing = 2
        header.alignment = .centerY

        // Centred under the title, in a strip the window background shows
        // through — nothing here draws a surface of its own.
        let headerBar = NSView()
        headerBar.addSubview(header)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.centerXAnchor.constraint(equalTo: headerBar.centerXAnchor),
            header.topAnchor.constraint(equalTo: headerBar.topAnchor, constant: 6),
            header.bottomAnchor.constraint(equalTo: headerBar.bottomAnchor, constant: -10),
        ])

        let divider = NSBox()
        // `.separator` is the one box type that follows the system's own hairline
        // colour in both appearances, rather than being a line we picked.
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        // Content is swapped inside this, so the header and its rule stay put.
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false

        paneScroll.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(paneScroll)
        let height = body.heightAnchor.constraint(equalToConstant: 0)
        bodyHeight = height
        NSLayoutConstraint.activate([
            paneScroll.topAnchor.constraint(equalTo: body.topAnchor),
            paneScroll.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            paneScroll.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            paneScroll.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            height,
        ])

        let root = NSStackView(views: [headerBar, divider, body])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .centerX
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            headerBar.widthAnchor.constraint(equalTo: root.widthAnchor),
            divider.widthAnchor.constraint(equalTo: root.widthAnchor),
            body.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        window.contentView = root
        self.body = body
        show(pane: selected, in: window)
        window.makeFirstResponder(nil)
    }

    /// Swap in one pane and fit the window to it.
    ///
    /// Per pane, not to the tallest of them: Models is a good deal shorter than
    /// UI, and sizing both to the maximum leaves it in a window mostly full of
    /// nothing.
    ///
    /// And never taller than the screen. A window sized to its content alone
    /// runs off a short display with its lower half unreachable — there is no
    /// title bar down there to drag it back by, and the controls that are cut
    /// off are simply gone. What does not fit scrolls instead.
    private func show(pane index: Int, in window: NSWindow) {
        guard index < stacks.count, let bodyHeight else { return }
        selected = index
        for (i, button) in buttons.enumerated() { button.isSelected = i == index }

        let stack = stacks[index]
        // Guarded, because this is called again on every screen change: setting
        // the same document view twice would leave a second copy of these
        // constraints behind each time.
        if paneScroll.documentView !== stack {
            paneScroll.documentView = stack
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: paneScroll.contentView.topAnchor),
                stack.leadingAnchor.constraint(equalTo: paneScroll.contentView.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: paneScroll.contentView.trailingAnchor),
            ])
        }

        // What the window costs with nothing in the body at all: the header, its
        // rule, and the title bar. Measured rather than assumed, so a change to
        // the header does not quietly eat into the room left for the pane.
        bodyHeight.constant = 0
        window.layoutIfNeeded()
        let chrome = (window.contentView?.fittingSize.height ?? 0)
            + WindowFit.chrome(of: window)

        let room = max(200, WindowFit.available(for: window) - chrome)
        let wanted = stack.fittingSize.height
        bodyHeight.constant = min(wanted, room)

        // `setContentSize` does the titlebar arithmetic; restoring the top edge
        // afterwards is what stops the window walking up and down the screen as
        // panes of different heights are selected.
        window.layoutIfNeeded()
        let top = window.frame.maxY
        window.setContentSize(NSSize(width: Self.width,
                                     height: window.contentView?.fittingSize.height ?? 0))
        var frame = window.frame
        frame.origin.y = top - frame.height
        window.setFrame(frame, display: true, animate: false)
        // Holding the top edge is right until it puts the bottom off the screen,
        // which on a short display is exactly what it does.
        WindowFit.clamp(window)
        window.layoutIfNeeded()
        // A pane that fits does not scroll at all.
        WindowFit.syncScrolling(paneScroll)
        // And one that does opens at its first control, not its last.
        WindowFit.scrollToTop(paneScroll)
    }

    // MARK: - Header button

    /// One pane selector: symbol over label, grey until selected.
    ///
    /// Every colour here is semantic — `secondaryLabelColor` reads grey against
    /// either appearance, `labelColor` is white on dark and near-black on light,
    /// and the selected pill is `quaternaryLabelColor`, which is a wash over
    /// whatever is behind it rather than a chosen grey that would be invisible
    /// in one mode and heavy in the other.
    private final class PaneButton: NSView {
        private let icon = NSImageView()
        private let caption = NSTextField(labelWithString: "")
        private let onClick: () -> Void

        var isSelected = false {
            didSet {
                guard isSelected != oldValue else { return }
                restyle()
                needsDisplay = true
            }
        }

        init(label: String, symbol: String, onClick: @escaping () -> Void) {
            self.onClick = onClick
            super.init(frame: .zero)
            wantsLayer = true

            icon.image = NSImage(
                systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 17, weight: .regular))
            icon.imageScaling = .scaleNone

            caption.stringValue = label
            caption.font = .systemFont(ofSize: 11)
            caption.alignment = .center

            let stack = NSStackView(views: [icon, caption])
            stack.orientation = .vertical
            stack.spacing = 3
            stack.alignment = .centerX
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            ])
            restyle()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        private func restyle() {
            let tint: NSColor = isSelected ? .labelColor : .secondaryLabelColor
            icon.contentTintColor = tint
            caption.textColor = tint
        }

        override func draw(_ dirtyRect: NSRect) {
            guard isSelected else { return }
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        }

        override func mouseDown(with event: NSEvent) { onClick() }

        // The pointer should say these are pressable.
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    /// An empty section stack, and the `section` helper that fills it.
    ///
    /// Returned as a pair so both panes lay out identically: same insets, same
    /// spacing, same rule for the gap between sections.
    private static func makeStack()
        -> (NSStackView, (String, String, NSView, NSView?) -> Void) {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Spacing keyed off whatever is currently last, rather than an index into
        // the stack — adding a section in the middle must not silently move the
        // gap somewhere else.
        func section(_ title: String, _ detail: String, _ content: NSView,
                     _ accessory: NSView?) {
            if let last = stack.arrangedSubviews.last {
                stack.setCustomSpacing(20, after: last)
            }
            stack.addArrangedSubview(headerRow(title, accessory: accessory))
            stack.addArrangedSubview(caption(detail))
            stack.addArrangedSubview(content)
        }
        return (stack, section)
    }

    private func buildUIStack() -> NSStackView {
        let size = revealSize()

        let opacity = SliderRow(
            "Opacity", range: Double(SubtitleView.minMaskStrength)...1,
            value: Double(revealOpacity()),
            format: { "\(Int(($0 * 100).rounded()))%" },
            apply: { [weak self] in
                self?.onRevealOpacity?(CGFloat($0))
                self?.syncPreview(.reveal)
            })

        let width = SliderRow(
            "Width", range: 200...1600, value: Double(size.width),
            format: { "\(Int($0.rounded())) pt" },
            apply: { [weak self] in
                guard let self else { return }
                self.onRevealSize?(NSSize(width: $0.rounded(), height: self.revealSize().height))
                self.syncPreview(.reveal)
            })

        let height = SliderRow(
            "Height", range: 100...1000, value: Double(size.height),
            format: { "\(Int($0.rounded())) pt" },
            apply: { [weak self] in
                guard let self else { return }
                self.onRevealSize?(NSSize(width: self.revealSize().width, height: $0.rounded()))
                self.syncPreview(.reveal)
            })

        let lines = SliderRow(
            "Lines", range: 1...5, value: Double(maxLines()), snaps: true,
            format: { $0 < 1.5 ? "1 line" : "\(Int($0.rounded())) lines" },
            apply: { [weak self] in
                self?.onMaxLines?(Int($0.rounded()))
                self?.syncPreview(.lines)
            })

        let background = SliderRow(
            "Background", range: 0...1, value: Double(boxOpacity()),
            format: { "\(Int(($0 * 100).rounded()))%" },
            apply: { [weak self] in
                self?.onBoxOpacity?(CGFloat($0))
                self?.syncPreview(.background)
            })

        let depth = SliderRow(
            "Keep", range: 0...30, value: Double(historyDepth()), snaps: true,
            format: {
                switch Int($0.rounded()) {
                case 0: return "Off"
                case 1: return "1 box"
                case let n: return "\(n) boxes"
                }
            },
            apply: { [weak self] in
                self?.onHistoryDepth?(Int($0.rounded()))
                self?.syncPreview(.keep)
            })

        let dimness = SliderRow(
            "Text", range: Double(HistoryPillView.minTextOpacity)...1,
            value: Double(historyTextOpacity()),
            format: { "\(Int(($0 * 100).rounded()))%" },
            apply: { [weak self] in
                self?.onHistoryTextOpacity?(CGFloat($0))
                self?.syncPreview(.dimness)
            })

        rows = [lines, background, opacity, width, height, depth, dimness]

        let (stack, section) = Self.makeStack()

        // Above everything, because everything below it is a description of it.
        let screen = SettingsPreview()
        preview = screen
        screen.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(screen)
        NSLayoutConstraint.activate([
            screen.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            screen.heightAnchor.constraint(equalToConstant: SettingsPreview.displayHeight),
        ])
        screen.apply(currentStyle())

        section("Subtitle Box",
                "How many lines a box fills before it clears and starts a new one, "
                + "and how solid the box behind the text is. The ⌥ history follows "
                + "it, a step behind.",
                Self.grid([lines.cells, background.cells]), nil)
        revealSwitch.target = self
        revealSwitch.action = #selector(toggleReveal)
        revealSwitch.state = revealEnabled() ? .on : .off
        revealRows = [opacity, width, height]

        section("Pointer Reveal",
                "How much of the box disappears under the pointer, and how far the "
                + "hole around it reaches. Hold ⇧ to keep the box solid.",
                Self.grid(revealRows.map(\.cells)), revealSwitch)
        syncRevealEnabled()
        historySwitch.target = self
        historySwitch.action = #selector(toggleHistory)
        historySwitch.state = historyEnabled() ? .on : .off
        historyRows = [depth, dimness]

        let expiry = SecondsRow(seconds: historyExpiry()) { [weak self] in
            self?.onHistoryExpiry?($0)
            self?.syncPreview(.expiry)
        }
        let expires = ToggleRow(
            "Forget it when idle",
            detail: "Otherwise the stack is kept until you pause or quit.",
            value: historyExpires(), width: Self.contentWidth) { [weak self] on in
                self?.onHistoryExpires?(on)
                self?.syncHistoryEnabled()
                self?.syncPreview(.expiry)
            }
        expiryRow = expiry
        expiryToggle = expires

        let recent = NSStackView(views: [
            Self.grid(historyRows.map(\.cells)), expires.view, Self.grid([expiry.cells]),
        ])
        recent.orientation = .vertical
        recent.alignment = .leading
        recent.spacing = 10

        section("Recent Boxes",
                "How many finished boxes ⌥ can bring back and scroll through, and "
                + "how far their text sits behind the live one's.",
                recent, historySwitch)
        syncHistoryEnabled()

        let reset = NSButton(title: "Reset All Settings…", target: self,
                             action: #selector(resetDefaults))
        reset.bezelStyle = .rounded
        stack.setCustomSpacing(22, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(reset)

        return stack
    }

    private func buildModelsStack() -> NSStackView {
        let (stack, section) = Self.makeStack()

        let rowWidth = Self.contentWidth
        let vad = ToggleRow(
            "Skip non-speech", detail: "Stops music reaching the recogniser.",
            value: vadEnabled(), width: rowWidth) { [weak self] in self?.onToggleVAD?($0) }
        let speakers = ToggleRow(
            "New box on speaker change", detail: "Runs a second model on the Neural Engine.",
            value: speakerBreaksEnabled(), width: rowWidth) { [weak self] in
                self?.onToggleSpeakerBreaks?($0)
            }
        vadRow = vad
        speakerRow = speakers

        let toggles = NSStackView(views: [vad.view, speakers.view])
        toggles.orientation = .vertical
        toggles.alignment = .leading
        toggles.spacing = 10

        section("Recognition",
                "Both decide what reaches the recogniser, so switching either one "
                + "reloads the engine — a pause of a few seconds, and a download "
                + "the first time speaker changes are turned on.",
                toggles, nil)

        section("Downloaded Models",
                "Every model you try stays downloaded. This removes the ones "
                + "nothing is using; the one in use is never touched.",
                modelsRow(), nil)

        return stack
    }

    /// Confirmed, and specific about its reach: everything above goes back to
    /// default, and the model, language and audio source — which are settings
    /// too, and expensive ones to re-choose — do not.
    @objc private func resetDefaults() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Reset all settings to their defaults?"
        alert.informativeText =
            "Lines, the pointer reveal, how many recent boxes are kept, the text "
            + "size and the overlay's position all go back to how they started.\n\n"
            + "Your model, language and audio source are left alone, and no "
            + "downloaded models are removed."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.onResetDefaults?()
            // Rebuild rather than nudge each control: the rows read their values
            // at construction, so new values need new rows.
            self.install(into: window)
        }
    }

    /// The clear button and the size it would reclaim, on one line.
    private func modelsRow() -> NSView {
        clearButton.target = self
        clearButton.action = #selector(clearCache)
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .regular

        cacheReadout.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                       weight: .regular)
        cacheReadout.textColor = .secondaryLabelColor

        let row = NSStackView(views: [clearButton, cacheReadout])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        refreshCacheSize()
        return row
    }

    /// Sizing a cache directory means walking every file in it, which is a
    /// gigabyte of `.mlmodelc` on a good day — off the main thread, with the
    /// button disabled until the answer arrives so it cannot delete a list it has
    /// not finished building.
    private func refreshCacheSize() {
        let keeping = modelsInUse()
        removable = []
        clearButton.isEnabled = false
        cacheReadout.stringValue = "Checking…"

        DispatchQueue.global(qos: .userInitiated).async {
            let found = ModelCache.removable(keeping: keeping)
            let total = found.reduce(0) { $0 + $1.bytes }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.removable = found
                self.clearButton.isEnabled = !found.isEmpty
                self.cacheReadout.stringValue = found.isEmpty
                    ? "Nothing unused"
                    : "\(ModelCache.format(total)) to reclaim"
            }
        }
    }

    /// Confirmed first, and specifically: the list says what goes, by name and
    /// size. Removing hundreds of megabytes that have to come back over the
    /// network is not something to do on a stray click.
    @objc private func clearCache() {
        guard !removable.isEmpty, let window else { return }
        let doomed = removable
        let total = doomed.reduce(0) { $0 + $1.bytes }

        let alert = NSAlert()
        alert.messageText = doomed.count == 1
            ? "Remove 1 unused model?"
            : "Remove \(doomed.count) unused models?"
        alert.informativeText =
            doomed.map { "\($0.name) — \(ModelCache.format($0.bytes))" }.joined(separator: "\n")
            + "\n\nFrees \(ModelCache.format(total)). Any of these downloads again "
            + "the next time you select it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        // Return picks Cancel, not Remove: the destructive button should have to
        // be aimed at.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let failed = ModelCache.remove(doomed)
            self.refreshCacheSize()
            guard !failed.isEmpty else { return }
            let problem = NSAlert()
            problem.messageText = "Some models could not be removed"
            problem.informativeText = failed.joined(separator: "\n")
            problem.alertStyle = .warning
            problem.beginSheetModal(for: window, completionHandler: nil)
        }
    }

    @objc private func toggleReveal(_ sender: NSSwitch) {
        onToggleReveal?(sender.state == .on)
        syncRevealEnabled()
        syncPreview(.reveal)
    }

    @objc private func toggleHistory(_ sender: NSSwitch) {
        onToggleHistory?(sender.state == .on)
        syncHistoryEnabled()
        syncPreview(.keep)
    }

    // MARK: - The preview

    /// Everything the preview draws, read back from the same getters the rows
    /// read. Assembled fresh on every edit rather than tracked: the menu can
    /// change half of these while this window is open, and a copy kept here
    /// would be the stale one.
    private func currentStyle() -> PreviewStyle {
        PreviewStyle(
            fontSize: fontSize(),
            maxLines: maxLines(),
            boxOpacity: boxOpacity(),
            revealOpacity: revealOpacity(),
            revealSize: revealSize(),
            revealEnabled: revealEnabled(),
            historyEnabled: historyEnabled(),
            historyDepth: historyDepth(),
            historyTextOpacity: historyTextOpacity(),
            historyExpiry: historyExpiry(),
            historyExpires: historyExpires())
    }

    /// A control was touched: show what it did, and say what it does.
    private func syncPreview(_ topic: PreviewTopic) {
        guard let preview else { return }
        preview.apply(currentStyle())
        preview.explain(topic)
    }

    /// Dim each section's dials when the feature itself is switched off.
    private func syncRevealEnabled() {
        let on = revealSwitch.state == .on
        for row in revealRows { row.isEnabled = on }
    }

    private func syncHistoryEnabled() {
        let on = historySwitch.state == .on
        for row in historyRows { row.isEnabled = on }
        expiryToggle?.isEnabled = on
        // Two gates: the section's, and the expiry's own.
        expiryRow?.isEnabled = on && expiryToggle?.isOn == true
    }

    /// A section title, optionally with a control pinned to the right of it.
    ///
    /// Given an explicit width because the enclosing stack is leading-aligned and
    /// would otherwise size this row to its label, leaving the switch tucked
    /// against the text instead of out at the margin.
    private static func headerRow(_ text: String, accessory: NSView?) -> NSView {
        let label = header(text)
        guard let accessory else { return label }
        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [label, spacer, accessory])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return row
    }

    private static func header(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Pinned to the content width rather than left to the stack. A
        // leading-aligned stack fixes only the leading edge of what it holds, so
        // a wrapping label takes whatever room is going and runs straight through
        // the trailing inset — which is why the descriptions reached the window
        // edge while the sliders beside them stopped short.
        label.preferredMaxLayoutWidth = contentWidth
        label.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return label
    }

    /// Title, slider and readout in three aligned columns, so the sliders of
    /// different sections still line up with each other.
    private static func grid(_ rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        // Wide enough for the longest label ("Background"), and fixed rather than
        // sized to content so the sliders line up across sections that do not
        // share a grid.
        grid.column(at: 0).width = 84
        grid.column(at: 1).xPlacement = .fill
        grid.column(at: 2).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        // Spans the pane, so the sliders stretch and the readouts sit on the same
        // right margin as everything else rather than wherever the widest row
        // happened to end.
        grid.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        return grid
    }
}
