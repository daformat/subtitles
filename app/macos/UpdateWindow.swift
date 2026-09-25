// The window updating happens in.
//
// One window, in the About and Welcome windows' style, and the states swap
// inside it: found, downloading, ready, installing, up to date, failed, and the
// one question about checking automatically. Sparkle's own windows were tried
// first and are fine, but they are Sparkle's — a different width, a web view
// for the notes, a second window for the download — and this app's other
// windows are its own. Updater.swift is what translates Sparkle into these
// states; nothing here knows Sparkle exists, which is what lets
// tools/update-window-harness show every state without a feed. The pieces
// it is built from are Dialog.swift's, shared with the licence window.
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
        /// The version is nil on the rare update Sparkle has not named, which
        /// gets sentences of its own rather than a word in the number's place.
        case downloading(version: String?, cancel: () -> Void)
        /// Unpacking, after the download; same progress path.
        case extracting(version: String?)
        case ready(version: String?, install: () -> Void, later: () -> Void)
        /// The app is quitting so the update can be swapped in. `retry` is
        /// offered when it did not quit.
        case installing(version: String?, retry: (() -> Void)?)
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

    private static var width: CGFloat { Dialog.width }

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

        Dialog.place(contentView(for: state), in: window)
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

    /// Redrawn in the language just chosen, if it is up.
    func relocalize() {
        guard let window, window.isVisible, let state else { return }
        window.title = L("Subtitles Update")
        show(state)
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
        Dialog.window(title: L("Subtitles Update", "Update window title"), delegate: self)
    }

    private func contentView(for state: State) -> NSView {
        let stack = Dialog.stack()
        bar = nil
        detail = nil

        let icon = Dialog.icon()
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)

        switch state {
        case .permission(let allow, let decline):
            Dialog.add(stack, headline: L("Check for updates automatically?"),
                blurb: L("Once a day, Subtitles would ask subtitles-live.com whether there is a "
                    + "newer version. The request carries the app's version and nothing else: "
                    + "no audio, no captions, nothing about you. It is the only request the app "
                    + "ever makes on its own, and the menu bar can turn it off later."))
            Dialog.addButtons(stack, [Dialog.button(L("Don't Check"), decline),
                               Dialog.button(L("Check Automatically"), allow, default: true)])

        case .checking(let cancel):
            Dialog.add(stack, headline: L("Checking for updates…"), blurb: nil)
            let bar = Dialog.progressBar(indeterminate: true)
            stack.addArrangedSubview(bar)
            stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            self.bar = bar
            Dialog.addButtons(stack, [Dialog.button(L("Cancel"), cancel)])

        case .found(let version, let current, let size, let notes, let critical, let install, let later, let skip):
            let blurb: String
            switch (critical, size) {
            case (true, let size?):
                blurb = LF("You have %1$@. This one fixes something that matters. The update is %2$@ "
                           + "and installs in place, so the audio permission stays.", current, size)
            case (true, nil):
                blurb = LF("You have %@. This one fixes something that matters. It installs in place, "
                           + "so the audio permission stays.", current)
            case (false, let size?):
                blurb = LF("You have %1$@. The update is %2$@ and installs in place, "
                           + "so the audio permission stays.", current, size)
            case (false, nil):
                blurb = LF("You have %@. It installs in place, so the audio permission stays.", current)
            }
            Dialog.add(stack, headline: LF("Subtitles %@ is available", version), blurb: blurb)
            if let notes, !notes.isEmpty {
                let box = Dialog.textBox(Self.attributed(notes))
                stack.addArrangedSubview(box)
                stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            if let skip { row.addArrangedSubview(Dialog.button(L("Skip This Version"), skip)) }
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(Dialog.button(L("Later"), later))
            row.addArrangedSubview(Dialog.button(L("Install Update"), install, default: true))
            row.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

        case .downloading(let version, let cancel):
            Dialog.add(stack, headline: version.map { LF("Downloading %@…", $0) } ?? L("Downloading the update…"), blurb: nil)
            addProgress(stack, indeterminate: true, detail: L("Starting…"))
            Dialog.addButtons(stack, [Dialog.button(L("Cancel"), cancel)])

        case .extracting(let version):
            Dialog.add(stack, headline: version.map { LF("Unpacking %@…", $0) } ?? L("Unpacking the update…"), blurb: nil)
            addProgress(stack, indeterminate: true, detail: L("A moment.", "Under a progress bar while the downloaded update is unpacked"))

        case .ready(let version, let install, let later):
            Dialog.add(stack, headline: L("Ready to install"),
                blurb: version.map { LF("Subtitles will quit and come back as %@. The captions come back with it.", $0) }
                    ?? L("Subtitles will quit and come back updated. The captions come back with it."))
            Dialog.addButtons(stack, [Dialog.button(L("Later"), later),
                               Dialog.button(L("Install and Relaunch"), install, default: true)])

        case .installing(let version, let retry):
            Dialog.add(stack, headline: version.map { LF("Installing %@…", $0) } ?? L("Installing the update…"),
                blurb: retry == nil
                    ? L("Subtitles is quitting and will be back in a moment.")
                    : L("Subtitles has not quit yet. Something may be asking to keep it open."))
            if let retry {
                Dialog.addButtons(stack, [Dialog.button(L("Quit and Install"), retry, default: true)])
            } else {
                addProgress(stack, indeterminate: true, detail: nil)
            }

        case .upToDate(let version, let dismiss):
            Dialog.add(stack, headline: L("You have the latest version"),
                blurb: LF("Subtitles %@ · checked just now", version))
            Dialog.addButtons(stack, [Dialog.button(L("OK"), dismiss, default: true)])

        case .failed(let title, let message, let retry, let dismiss):
            Dialog.add(stack, headline: title, blurb: message)
            var buttons = [Dialog.button(L("OK"), dismiss, default: retry == nil)]
            if let retry { buttons.append(Dialog.button(L("Try Again"), retry, default: true)) }
            Dialog.addButtons(stack, buttons)
        }
        return stack
    }

    private func addProgress(_ stack: NSStackView, indeterminate: Bool, detail text: String?) {
        let bar = Dialog.progressBar(indeterminate: indeterminate)
        stack.addArrangedSubview(bar)
        stack.setCustomSpacing(14, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
        self.bar = bar
        guard let text else { return }
        let label = Dialog.label(text, size: 11, colour: .secondaryLabelColor)
        stack.addArrangedSubview(label)
        stack.setCustomSpacing(4, after: bar)
        detail = label
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
}
