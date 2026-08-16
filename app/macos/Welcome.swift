// The welcome screen.
//
// Shown once, on the launch where there is nothing to show yet: the first run
// downloads ~600 MB of models before a single caption can appear, and without
// this the app's entire first impression is a menu bar icon with a dot on it.
// The demo — the website's, vendored into the bundle by tools/vendor-demo.sh —
// is what the wait is spent looking at, and it is a fair picture of what the app
// does, because it is a recording of the app doing it.
//
// The download is reported here rather than left to the menu: somebody watching
// a progress bar is not hunting through a menu for it, and "how long is this
// going to take" is the only question anybody has on first launch.

import AppKit
import FluidAudio
import WebKit

final class WelcomeWindow: NSObject, NSWindowDelegate {
    static let shared = WelcomeWindow()

    /// Matches the About window, and is what the demo is drawn to fill.
    private static let width: CGFloat = 584
    /// Wider at the sides than at the top and bottom: the content is a stack of
    /// centred things, and side margins are what stop it reading as filling the
    /// window edge to edge.
    private static let inset: CGFloat = 28
    private static let insetH: CGFloat = 44

    /// Set once the window has been shown of its own accord, so it is not shown
    /// again on every launch. Reopening it from the menu deliberately does not
    /// clear this: asking to see it again is not the same as wanting it back on
    /// every launch forever.
    private static let shownKey = "welcome.shown"

    // Wired up by main.swift, exactly as the menu's are.
    var engineBusy: () -> String? = { nil }
    var engineProgress: () -> Double = { 0 }

    private var window: NSWindow?
    private var webView: WKWebView?
    private var demoHeight: NSLayoutConstraint?
    /// The row that is either the download or the way out of the window.
    private var statusRow: NSStackView?
    private var headline: NSTextField?
    private var bar: NSProgressIndicator?
    private var poll: Timer?
    /// True once the bar has been swapped for the button, so the swap happens
    /// once rather than on every tick.
    private var finished = false
    /// True once the window has been put on screen; `present()` is reached from
    /// both the demo loading and the timeout, and only the first one counts.
    private var presented = false
    private var readyTimer: Timer?

    /// Whether to open unprompted on this launch.
    ///
    /// Two ways in. The first launch is the obvious one. The second is having no
    /// models on disk — the flag says this window has been seen, but a user who
    /// has cleared the cache is about to sit through the download again, and that
    /// is the situation this window exists for.
    static var shouldShowAtLaunch: Bool {
        if !UserDefaults.standard.bool(forKey: shownKey) { return true }
        return !modelsPresent
    }

    /// Whether FluidAudio has anything cached.
    ///
    /// Its own published location rather than a path spelled out here, so it
    /// follows the library. A directory that exists but is empty counts as
    /// nothing: that is what a part-deleted cache looks like.
    private static var modelsPresent: Bool {
        let dir = MLModelConfigurationUtils.defaultModelsDirectory()
        let contents = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        return !(contents ?? []).isEmpty
    }

    func show(markAsSeen: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        if markAsSeen { UserDefaults.standard.set(true, forKey: Self.shownKey) }

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = build()
        self.window = window
        startPolling()

        // Deliberately not ordered front yet — see `present()`. The fallback is
        // what guarantees the window appears at all: no bundled demo, a page that
        // fails to load, a web process that dies, and `didFinish` never comes.
        readyTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
            self?.present()
        }
    }

    /// Put the window on screen, once.
    ///
    /// Held back until the demo has loaded and been measured. Ordering the window
    /// front first meant it opened at its guessed height around an empty web view,
    /// then the demo appeared and the window resized under it — two visible jumps
    /// in the first half second the app is ever seen.
    fileprivate func present() {
        guard let window, !presented else { return }
        presented = true
        readyTimer?.invalidate()
        readyTimer = nil
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Torn down rather than hidden — see AboutWindow, which does the same and
    /// for the same reason: the demo is an animation in a web process, and a
    /// closed window is not a reason to keep painting it.
    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
        readyTimer?.invalidate()
        readyTimer = nil
        presented = false
        webView?.stopLoading()
        webView = nil
        demoHeight = nil
        statusRow = nil
        headline = nil
        bar = nil
        finished = false
        window = nil
    }

    @objc private func close() { window?.performClose(nil) }

    // MARK: the download

    /// Polled rather than driven by the engine's callbacks, because the engine
    /// reports into globals the menu already polls — one more reader costs
    /// nothing and needs no plumbing through five layers of closures.
    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
        refresh()
    }

    private func refresh() {
        guard !finished else { return }
        guard let busy = engineBusy() else {
            // Nothing loading: either the download finished while this was open,
            // or there was never one to do because the models were already here.
            showDoneButton()
            return
        }
        headline?.stringValue = busy
        // Below zero means "working, length unknown" — see FluidAudioEngine's
        // `indeterminate`. The download finishing is not the end of the wait:
        // CoreML then loads the bundles onto the Neural Engine, silently, for
        // long enough that a bar parked at 100% looks like a hang.
        guard let bar else { return }
        let fraction = engineProgress()
        let unknown = fraction < 0
        if unknown != bar.isIndeterminate {
            bar.isIndeterminate = unknown
            if unknown { bar.startAnimation(nil) } else { bar.stopAnimation(nil) }
        }
        if !unknown { bar.doubleValue = fraction }
    }

    private func showDoneButton() {
        finished = true
        poll?.invalidate()
        poll = nil

        guard let row = statusRow else { return }
        for view in row.arrangedSubviews { view.removeFromSuperview() }

        let button = NSButton(title: "All set, close", target: self, action: #selector(close))
        button.bezelStyle = .rounded
        button.controlSize = .large
        // Return closes it, which is what anybody who has been waiting will press.
        button.keyEquivalent = "\r"
        row.addArrangedSubview(button)
        window?.setContentSize(contentStack?.fittingSize ?? .zero)
    }

    private weak var contentStack: NSStackView?

    // MARK: building

    private func build() -> NSWindow {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.insetH,
                                        bottom: Self.inset, right: Self.insetH)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Welcome to Subtitles")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        stack.addArrangedSubview(title)

        // Deliberately short. The demo below says what this is far better than a
        // paragraph would, and the one thing it cannot show — that ⇧ is being
        // held — is the line underneath it.
        let blurb = NSTextField(labelWithString:
            "Live captions for whatever your Mac plays.")
        blurb.font = .systemFont(ofSize: 11)
        blurb.textColor = .secondaryLabelColor
        stack.addArrangedSubview(blurb)

        let demo = buildDemo()
        stack.addArrangedSubview(demo)
        stack.setCustomSpacing(18, after: blurb)

        let hint = buildShiftHint()
        stack.addArrangedSubview(hint)
        stack.setCustomSpacing(16, after: demo)

        let row = NSStackView()
        row.orientation = .vertical
        row.alignment = .centerX
        row.spacing = 8
        stack.addArrangedSubview(row)
        stack.setCustomSpacing(20, after: hint)
        statusRow = row
        buildProgress(into: row)
        contentStack = stack

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.insetH * 2, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Welcome to Subtitles"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self

        let root = NSView()
        root.addSubview(stack)
        window.contentView = root
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            // Width stated outright, rather than left to `fittingSize`. The
            // widest child has a fixed width of its own, and a stack pinned to a
            // window exactly that wide has nowhere to put its edge insets — so
            // AppKit breaks them, and the content runs to both window edges.
            stack.widthAnchor.constraint(
                equalToConstant: Self.width + Self.insetH * 2),
        ])
        window.setContentSize(stack.fittingSize)
        return window
    }

    /// "Hold ⇧ and drag the captions to move them."
    ///
    /// Native rather than the caption the site puts under the demo: web text in a
    /// native window never quite matches the labels around it, and this way the
    /// key can light up when the key is actually held.
    private func buildShiftHint() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5

        func label(_ string: String) -> NSTextField {
            let field = NSTextField(labelWithString: string)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            return field
        }
        row.addArrangedSubview(label("Hold"))
        row.addArrangedSubview(KeycapView(key: "⇧"))
        row.addArrangedSubview(label("and drag the captions to move them."))
        return row
    }

    private func buildProgress(into row: NSStackView) {
        let label = NSTextField(labelWithString: "Preparing…")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        row.addArrangedSubview(label)
        headline = label

        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.widthAnchor.constraint(equalToConstant: 320).isActive = true
        row.addArrangedSubview(indicator)
        bar = indicator
    }

    private func buildDemo() -> NSView {
        let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        web.translatesAutoresizingMaskIntoConstraints = false
        // Transparent, so the window's own material shows through the page. The
        // page paints nothing behind the demo either — see demo.shell.html.
        //
        // `underPageBackgroundColor` is the public half and is not sufficient on
        // its own: the web view still paints an opaque backdrop behind the page.
        // The rest is KVC onto `_setDrawsBackground:`, which is SPI — hence the
        // check. An unknown key raises an exception Swift cannot catch, and a
        // white rectangle in a welcome window is not worth crashing the app over.
        web.underPageBackgroundColor = .clear
        if WKWebView.instancesRespond(to: NSSelectorFromString("_setDrawsBackground:")) {
            web.setValue(false, forKey: "drawsBackground")
        }
        web.navigationDelegate = navigationDelegate

        // A starting height in the demo's own proportions, so the window is the
        // right shape before the page has measured itself. It is corrected from
        // the page below, which is what makes this survive the demo changing.
        let height = web.heightAnchor.constraint(equalToConstant: 432)
        NSLayoutConstraint.activate([
            web.widthAnchor.constraint(equalToConstant: Self.width),
            height,
        ])
        demoHeight = height
        webView = web

        if let url = Self.demoURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }

    /// Asks the page how tall the demo actually is, and gives it exactly that.
    ///
    /// The demo's height follows its width through the aspect ratio of the screen
    /// it draws, so it cannot be a constant here without being wrong the first
    /// time the site's demo changes shape.
    fileprivate func fitDemo() {
        guard let web = webView else { return }
        web.evaluateJavaScript("document.querySelector('.demo').getBoundingClientRect().height")
        { [weak self] value, _ in
            guard let self, let height = value as? Double, height > 0 else { return }
            self.demoHeight?.constant = ceil(height)
            guard let window = self.window, let stack = self.contentStack else { return }
            window.setContentSize(stack.fittingSize)
            self.present()
        }
    }

    private lazy var navigationDelegate = DemoNavigation(welcome: self)

    /// Links inside the demo open in the browser rather than replacing it.
    ///
    /// There are none today. There is also nothing stopping the site's demo
    /// gaining one, and a webview that quietly navigates away from the demo it
    /// exists to show is a worse failure than a link that does nothing.
    private final class DemoNavigation: NSObject, WKNavigationDelegate {
        private weak var welcome: WelcomeWindow?
        init(welcome: WelcomeWindow) { self.welcome = welcome }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            welcome?.fitDemo()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!,
                     withError error: Error) {
            welcome?.present()
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            welcome?.present()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated, let url = action.request.url else {
                decisionHandler(.allow)
                return
            }
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }
    }

    /// nil for a binary run straight from `.build`, which has no bundle to read
    /// the demo out of. The window then simply has no demo in it.
    private static var demoURL: URL? {
        Bundle.main.url(forResource: "demo", withExtension: "html", subdirectory: "Demo")
    }
}

// MARK: - Keycap

/// A single key, drawn as a key: outlined, with nothing behind it.
///
/// Drawn in `draw(_:)` rather than built from a layer border, because a
/// `CGColor` on a layer is resolved once and does not follow the system between
/// light and dark. Colours asked for here are resolved every time the view is
/// painted, which is what makes the outline right in both.
///
/// It also lights up while ⇧ is actually held — the same key, doing the thing the
/// sentence beside it describes, which says it better than the sentence does.
final class KeycapView: NSView {
    private let key: String
    private var pressed = false { didSet { if pressed != oldValue { needsDisplay = true } } }
    private var poll: Timer?

    private var font: NSFont { .systemFont(ofSize: 11) }
    private let padding = NSSize(width: 7, height: 3)
    private let corner: CGFloat = 4.5

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        let size = (key as NSString).size(withAttributes: [.font: font])
        // A floor, so ⇧ and a wider key are the same width — a row of keycaps
        // that each hug their own glyph reads as a row of different-sized boxes.
        return NSSize(width: max(ceil(size.width) + padding.width * 2, 20),
                      height: ceil(size.height) + padding.height * 2)
    }

    /// ⇧ is polled, not monitored — a keyboard event monitor would demand
    /// Accessibility permission, which is a scary prompt to raise for a highlight
    /// on a welcome screen. The overlay reads the modifier the same way, and for
    /// the same reason; see Overlay.swift.
    ///
    /// Tied to being in a window, so it runs while this is on screen and stops
    /// when the window goes, with nothing to remember to tear down.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        poll?.invalidate()
        poll = nil
        pressed = false
        guard window != nil else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pressed = NSEvent.modifierFlags.contains(.shift)
        }
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }

    override func draw(_ dirtyRect: NSRect) {
        // Half a point in, so a 1pt stroke lands on the pixel rather than
        // straddling it and rendering as two grey ones.
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                               xRadius: corner, yRadius: corner)

        // The highlight is the same idea in both appearances but not the same
        // number. `labelColor` is near-black on a light window and near-white on
        // a dark one, and the alpha that reads as a faint tint over dark reads as
        // a grey slab over light — so light gets less than half of it.
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        // Transparent unless held: the window's own material is the background,
        // and a filled cap over it reads as a black box in dark mode.
        if pressed {
            NSColor.labelColor.withAlphaComponent(dark ? 0.14 : 0.055).setFill()
            box.fill()
        }
        let held = NSColor.labelColor.withAlphaComponent(dark ? 1 : 0.6)
        (pressed ? held : NSColor.tertiaryLabelColor).setStroke()
        box.lineWidth = 1
        box.stroke()

        let colour = pressed ? held : NSColor.secondaryLabelColor
        let text = NSAttributedString(string: key, attributes: [
            .font: font, .foregroundColor: colour,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                              y: (bounds.height - size.height) / 2))
    }
}
