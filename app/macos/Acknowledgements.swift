// The acknowledgements window: the third-party notices, in the update
// window's shape.
//
// Apache-2.0 is satisfied by the notices file being *in* the bundle; this
// window only makes it readable without leaving the app. One state, so it is
// the update window's pieces without the states: the icon, a headline, the
// file in a soft box that scrolls, and a button to close it. Notices.swift is
// what turns the file's hard-wrapped text into paragraphs the box can wrap.

import AppKit
import CaptionCore

final class AcknowledgementsWindow: NSObject, NSWindowDelegate {
    static let shared = AcknowledgementsWindow()

    /// The notices file `build.sh` puts in the bundle. Nil for a dev build run
    /// straight from `.build`, which has no bundle around it, and then the
    /// About window offers no button.
    static var noticesURL: URL? {
        Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "txt")
    }

    private var window: NSWindow?

    func show() {
        // An agent app is never the active application, so the window would
        // otherwise open behind whatever the user is working in.
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = Dialog.window(title: "Acknowledgements", delegate: self)
        self.window = window
        Dialog.place(content(), in: window)
        window.makeKeyAndOrderFront(nil)
    }

    /// Torn down rather than hidden, so the next open starts at the top.
    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    private func content() -> NSView {
        let stack = Dialog.stack()
        let icon = Dialog.icon()
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)
        Dialog.add(stack, headline: "Acknowledgements",
                   blurb: "What Subtitles is built on, and the terms it comes with.")
        let box = Dialog.textBox(Self.attributed(Self.blocks()), maxHeight: 360)
        stack.addArrangedSubview(box)
        stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        Dialog.addButtons(stack, [Dialog.button("OK", { [weak self] in self?.window?.close() },
                                                default: true)])
        return stack
    }

    private static func blocks() -> [Notices.Block] {
        guard let url = noticesURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [.paragraph("The notices file is missing from this copy of the app.")]
        }
        return Notices.parse(text)
    }

    /// The blocks in the notes box's type: the same sizes, the same air
    /// between paragraphs.
    private static func attributed(_ blocks: [Notices.Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            style.lineSpacing = 1
            var font = NSFont.systemFont(ofSize: 12)
            var colour = NSColor.labelColor
            var text: String
            switch block {
            case .heading(let title):
                // Set apart from the section above it, the way the file's rules do.
                style.paragraphSpacingBefore = 14
                font = .systemFont(ofSize: 12, weight: .semibold)
                text = title
            case .paragraph(let body):
                // The file opens with its own title; set as the notes box sets
                // its version line.
                if i == 0 {
                    font = .systemFont(ofSize: 11, weight: .semibold)
                    colour = .secondaryLabelColor
                }
                text = body
            case .bullet(let body):
                style.headIndent = 14
                style.tabStops = [NSTextTab(textAlignment: .left, location: 14)]
                text = "\u{2022}\t" + body
            case .row(let left, let right):
                // One line each and close together, so the table still reads
                // as one; a dash rather than a tab stop, which a long first
                // column would overrun.
                style.paragraphSpacing = 2
                text = left + " \u{2014} " + right
            }
            if i < blocks.count - 1 { text += "\n" }
            out.append(NSAttributedString(string: text, attributes: [
                .font: font, .foregroundColor: colour, .paragraphStyle: style,
            ]))
        }
        return out
    }
}
