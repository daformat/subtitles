// The About window.
//
// A window of our own rather than `orderFrontStandardAboutPanel`. The panel is a
// closed view hierarchy that takes an attributed string and nothing else: no way
// to inset it, and no way to put anything below its copyright line — which is
// where the author links belong. What it gave for free — the icon, the name, the
// version, the copyright — is a dozen lines to reproduce and is reproduced here.
//
// The demo lives in the welcome window, not here. This one is opened by somebody
// checking a version number.

import AppKit

final class AboutWindow: NSObject, NSWindowDelegate {
    static let shared = AboutWindow()

    /// Content width. Wide enough for the longest credit line to sit on one row,
    /// with the window's padding doing the rest.
    private static let width: CGFloat = 340
    /// Wider at the sides than at the top and bottom: the content is a stack of
    /// centred things, and side margins are what stop it reading as filling the
    /// window edge to edge.
    private static let inset: CGFloat = 28
    private static let insetH: CGFloat = 44

    private var window: NSWindow?

    func show() {
        // An agent app is never the active application, so the window would
        // otherwise open behind whatever the user is working in — and, having no
        // Dock icon to click, be unreachable except by moving windows aside.
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = build()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    /// Torn down rather than hidden, so the next open rebuilds against whatever
    /// the bundle says now — the version line included.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    // MARK: building

    private func build() -> NSWindow {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.insetH,
                                        bottom: Self.inset, right: Self.insetH)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 72),
            icon.heightAnchor.constraint(equalToConstant: 72),
        ])
        stack.addArrangedSubview(icon)

        let name = NSTextField(labelWithString: Self.bundleName)
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        stack.addArrangedSubview(name)
        stack.setCustomSpacing(2, after: icon)

        let version = NSTextField(labelWithString: Self.versionLine)
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        stack.addArrangedSubview(version)
        stack.setCustomSpacing(2, after: name)

        let credits = buildCredits()
        stack.addArrangedSubview(credits)
        stack.setCustomSpacing(18, after: version)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width + Self.insetH * 2, height: 200),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "About \(Self.bundleName)"
        // The title is in the window's own bar and saying it twice is a waste of
        // 22 points; the icon below says which app this is anyway.
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
        // The stack knows its own height; the window follows it rather than the
        // other way round.
        window.setContentSize(stack.fittingSize)
        return window
    }

    // MARK: credits

    private func buildCredits() -> NSView {
        let text = NSTextView()
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.size = NSSize(width: Self.width, height: .greatestFiniteMagnitude)
        // Ordinary text rather than blue and underlined. A text view paints every
        // .link range with these, as temporary attributes applied over whatever
        // the string says — so this, and not the string, is where it is decided.
        text.linkTextAttributes = [
            .foregroundColor: NSColor.labelColor,
            .underlineStyle: 0,
            // The only thing left saying these are clickable.
            .cursor: NSCursor.pointingHand,
        ]
        text.textStorage?.setAttributedString(Self.credits)

        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let height = ceil(text.layoutManager?.usedRect(for: text.textContainer!).height ?? 0)
        NSLayoutConstraint.activate([
            text.widthAnchor.constraint(equalToConstant: Self.width),
            text.heightAnchor.constraint(equalToConstant: height),
        ])
        return text
    }

    /// What the app is, its licence, and who made it.
    private static var credits: NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.paragraphSpacing = 5

        // The last two lines each sit away from what precedes them rather than
        // reading as more of it. `paragraphSpacingBefore` rather than the
        // `paragraphSpacing` above, because that one belongs to the paragraph on
        // the near side of the gap and these gaps are owned by the far side.
        let footer = NSMutableParagraphStyle()
        footer.setParagraphStyle(paragraph)
        footer.paragraphSpacingBefore = 12

        let text = NSMutableAttributedString()
        func add(_ string: String, colour: NSColor? = nil, link: String? = nil,
                 style: NSParagraphStyle? = nil, size: CGFloat = 11) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size),
                .paragraphStyle: style ?? paragraph,
            ]
            if let link { attributes[.link] = URL(string: link)! }
            if let colour { attributes[.foregroundColor] = colour }
            text.append(NSAttributedString(string: string, attributes: attributes))
        }

        /// A mark set on the text baseline, in the same colour as the text.
        ///
        /// Attachments are not template images — a text view draws them exactly
        /// as they come, and `linkTextAttributes` does not reach inside them — so
        /// the tint is baked in here rather than left to `isTemplate`, which only
        /// means something to a button or a menu item.
        func addMark(_ name: String, height: CGFloat, link: String, style: NSParagraphStyle) {
            guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
                  let image = NSImage(contentsOf: url) else { return }
            let width = (height * image.size.width / image.size.height).rounded()
            let tinted = NSImage(size: NSSize(width: width, height: height),
                                 flipped: false) { rect in
                NSColor.labelColor.set()
                rect.fill()
                image.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1)
                return true
            }

            let attachment = NSTextAttachment()
            attachment.image = tinted
            // Dropped below the baseline by the font's descender, so the mark is
            // centred on the x-height rather than perched on top of the line.
            attachment.bounds = NSRect(x: 0, y: NSFont.systemFont(ofSize: 11).descender,
                                       width: width, height: height)
            let run = NSMutableAttributedString(attachment: attachment)
            run.addAttributes([.link: URL(string: link)!, .paragraphStyle: style],
                              range: NSRange(location: 0, length: run.length))
            text.append(run)
        }

        add("subtitles-live.com\n", link: "https://subtitles-live.com")
        add("Live captions for whatever your Mac is playing.\u{2028}"
            + "Nothing is recorded; no audio ever leaves the machine.\n",
            colour: .labelColor)
        add("FSL-1.1-ALv2", colour: .secondaryLabelColor)

        add("\nCopyright © 2026 Mathieu Jouhet (CSS labs)",
            colour: .secondaryLabelColor, style: footer, size: 10)

        // Who made it, at the very foot of the window: the same two marks these
        // links wear on hello-mat.com, so the pair reads as a signature rather
        // than as more of the app's own business.
        add("\n", style: footer)
        addMark("LogoMat", height: 13, link: "https://hello-mat.com", style: footer)
        add(" hello-mat.com", link: "https://hello-mat.com", style: footer)
        add("   ", style: footer)
        addMark("LogoTwitter", height: 11, link: "https://x.com/daformat", style: footer)
        add(" @daformat", link: "https://x.com/daformat", style: footer)
        return text
    }

    // MARK: bundle

    private static var bundleName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Subtitles"
    }

    private static var versionLine: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(short) (\(build))"
    }

}
