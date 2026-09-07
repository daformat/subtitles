// The window a key is entered in (PLAN.md §24).
//
// One window in the update window's style, built from Dialog.swift's pieces,
// and two states swap inside it: the form — headline for where the trial
// stands, a field, Activate, the way to a key and the way to find one — and
// the page for a key that is on file. Everything that can happen to an entered
// key is shown in place under the field, so the window never has to be
// replaced by an alert to say "refunded" or "no network".
//
// Nothing here knows the licence record or the network: License.swift turns
// the controller's answers into these states, which is what lets
// tools/license-window-harness show every one of them without Gumroad.

import AppKit
#if canImport(LicenseCore)
import LicenseCore
#endif

final class LicenseWindow: NSObject, NSWindowDelegate {
    /// What the form says under the field.
    enum Outcome: Equatable {
        case none
        case checking
        case notAKey
        case invalid(String?)
        case revoked(Revocation)
        /// No answer, and a verified key already on file, which stays.
        case unreachable(String)
    }

    enum State {
        /// The form. `entitlement` sets the headline; `key` is what is in
        /// the field, carried across outcomes so a typo can be fixed.
        case enter(entitlement: Entitlement, key: String, outcome: Outcome,
                   activate: (String) -> Void, buy: () -> Void, findKey: () -> Void,
                   close: () -> Void)
        /// A key is on file — verified, provisional, or the copy predates
        /// keys. `justActivated` is the moment after Activate worked.
        case licensed(entitlement: Entitlement, justActivated: Bool,
                      enterAnother: () -> Void, checkNow: (() -> Void)?, done: () -> Void)

        var closeAction: () -> Void {
            switch self {
            case .enter(_, _, _, _, _, _, let close): return close
            case .licensed(_, _, _, _, let done): return done
            }
        }
    }

    private var window: NSWindow?
    private var state: State?
    private var field: NSTextField?
    private var closingProgrammatically = false

    var isVisible: Bool { window?.isVisible ?? false }
    var nativeWindow: NSWindow? { window }
    /// What is in the field right now, for the controller to carry over.
    var typedKey: String { field?.stringValue ?? "" }

    func show(_ state: State) {
        self.state = state
        let window = self.window ?? Dialog.window(title: "Subtitles License", delegate: self)
        self.window = window
        Dialog.place(contentView(for: state), in: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if let field, field.isEnabled { window.makeFirstResponder(field) }
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
        action()
        return false
    }

    // MARK: building

    private func contentView(for state: State) -> NSView {
        let stack = Dialog.stack()
        field = nil
        let icon = Dialog.icon()
        stack.addArrangedSubview(icon)
        stack.setCustomSpacing(10, after: icon)

        switch state {
        case .enter(let entitlement, let key, let outcome, let activate, let buy, let findKey, _):
            let (headline, blurb) = Self.formCopy(for: entitlement)
            Dialog.add(stack, headline: headline, blurb: blurb)

            let field = Self.keyField(key)
            field.isEnabled = outcome != .checking
            let fire: () -> Void = { [weak field] in
                guard let field, field.isEnabled else { return }
                activate(field.stringValue)
            }
            (field as? ActionField)?.onReturn = fire
            stack.addArrangedSubview(field)
            stack.setCustomSpacing(16, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])
            self.field = field

            if let line = Self.outcomeView(outcome) {
                stack.addArrangedSubview(line)
                stack.setCustomSpacing(8, after: field)
            }

            // The way to a key on the left, the key on the right: the same
            // row the update window's Skip / Later / Install uses.
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 8
            row.addArrangedSubview(Dialog.button("Buy a Key · $9", buy))
            row.addArrangedSubview(Dialog.button("Where Is My Key?", findKey))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            let go = Dialog.button("Activate", fire, default: true)
            go.isEnabled = outcome != .checking
            row.addArrangedSubview(go)
            row.widthAnchor.constraint(equalToConstant: Dialog.width).isActive = true
            stack.addArrangedSubview(row)
            stack.setCustomSpacing(18, after: stack.arrangedSubviews[stack.arrangedSubviews.count - 2])

            let privacy = Dialog.label(
                "Activating sends the key to Gumroad once, and checks it again about once a month. "
                    + "Nothing else ever leaves this Mac.",
                size: 10, colour: .tertiaryLabelColor)
            stack.addArrangedSubview(privacy)
            stack.setCustomSpacing(12, after: row)

        case .licensed(let entitlement, let justActivated, let enterAnother, let checkNow, let done):
            let (headline, blurb) = Self.licensedCopy(for: entitlement, justActivated: justActivated)
            Dialog.add(stack, headline: headline, blurb: blurb)
            var buttons = [Dialog.button(entitlement == .grandfathered ? "Enter a Key" : "Enter a Different Key",
                                         enterAnother)]
            if let checkNow { buttons.append(Dialog.button("Check Now", checkNow)) }
            buttons.append(Dialog.button("Done", done, default: true))
            Dialog.addButtons(stack, buttons)
        }
        return stack
    }

    // MARK: copy

    private static let price = "Keys are $9 on Gumroad, arrive by email, and cover every Mac you use."

    static func formCopy(for entitlement: Entitlement) -> (String, String) {
        switch entitlement {
        case .trial(let days, true):
            return ("Enter your license key",
                    "Your trial has \(days) \(days == 1 ? "day" : "days") left. \(price)")
        case .trial(_, false):
            return ("Enter your license key",
                    "Your \(LicenseRecord.trialDays)-day trial starts when captions do. \(price)")
        case .expired:
            return ("Your trial has ended",
                    "Subtitles keeps running but has stopped transcribing until a key is entered. \(price)")
        case .revoked(let why):
            return ("This key was \(why.phrase)",
                    "Gumroad reports the purchase as \(why.phrase), so the key no longer works here. "
                        + "Enter another to carry on. \(price)")
        case .licensed, .provisional, .grandfathered:
            return ("Enter a license key",
                    "The key on file stays until the new one is confirmed. \(price)")
        }
    }

    static func licensedCopy(for entitlement: Entitlement, justActivated: Bool) -> (String, String) {
        switch entitlement {
        case .licensed(let email):
            let to = email.map { "Subtitles is licensed to \($0)." } ?? "Subtitles is licensed on this Mac."
            return justActivated
                ? ("You're all set", "\(to) Thank you — captions are back.")
                : ("Licensed", "\(to) If you ever reinstall, your key is in your Gumroad library and on your receipt.")
        case .provisional(let until):
            return ("Key accepted, to be confirmed",
                    "Gumroad could not be reached. Your key works until \(Self.when(until)) "
                        + "and is checked as soon as you are online; nothing more to do.")
        case .grandfathered:
            return ("Licensed",
                    "This copy is from before there were license keys, and is licensed as it is. "
                        + "If you ever reinstall, your key is in your Gumroad library.")
        case .trial, .expired, .revoked:
            return ("Licensed", "")
        }
    }

    private static func when(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: date)
    }

    private static func outcomeView(_ outcome: Outcome) -> NSView? {
        let text: String
        var colour = NSColor.systemRed
        switch outcome {
        case .none:
            return nil
        case .checking:
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 6
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            row.addArrangedSubview(spinner)
            row.addArrangedSubview(Dialog.label("Checking with Gumroad…", size: 11, colour: .secondaryLabelColor))
            return row
        case .notAKey:
            text = "That doesn't look like a key. Keys are four groups of eight letters and digits, "
                + "like 4B1C2D3E-5F607182-93A4B5C6-D7E8F9A0."
        case .invalid:
            text = "Gumroad doesn't know this key. Check it against your receipt, or your Gumroad library."
        case .revoked(let why):
            text = "This key was \(why.phrase) and no longer works. Nothing has changed."
        case .unreachable(let message):
            text = "Couldn't reach Gumroad — \(message) Your current key stays; try again when you are online."
            colour = .secondaryLabelColor
        }
        return Dialog.label(text, size: 11, colour: colour)
    }

    // MARK: the field

    private static func keyField(_ text: String) -> NSTextField {
        let field = ActionField(string: text)
        field.placeholderString = "XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX"
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.alignment = .center
        field.bezelStyle = .roundedBezel
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 340).isActive = true
        return field
    }

    /// A text field whose Return goes to the closure, and only there. The
    /// default button's key equivalent would also fire on Return while the
    /// field is editing, and the two together would activate twice.
    private final class ActionField: NSTextField {
        var onReturn: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if event.keyCode == 36, isEnabled, currentEditor() != nil {   // Return
                window?.makeFirstResponder(nil)
                onReturn?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }
    }
}
