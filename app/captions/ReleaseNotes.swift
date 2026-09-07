// Release notes, from the HTML the appcast carries to something a native
// window can set in its own type.
//
// The appcast's notes are the CHANGELOG entry as tools/changelog-notes.py
// renders it: one <h2>, one <ul>, and inside the items only <strong>, <code>
// and <a>. That is the whole grammar this reads. Anything else is tolerated —
// unknown tags vanish, their text stays — because an appcast is a file on a
// server, and a window that showed nothing when the file changed shape would
// be worse than one that showed the words without their emphasis.
//
// Here rather than in the app target so it can be tested without AppKit: it
// is a parser, and parsers are where the odd inputs live.

import Foundation

public struct ReleaseNotes: Equatable {
    /// A stretch of text with one style. Bold and code do not nest in the
    /// changelog; if they did, the later one wins.
    public struct Run: Equatable {
        public var text: String
        public var bold: Bool
        public var code: Bool

        public init(_ text: String, bold: Bool = false, code: Bool = false) {
            self.text = text
            self.bold = bold
            self.code = code
        }
    }

    /// A list item, or a paragraph that stood outside any list.
    public struct Item: Equatable {
        public var runs: [Run]
        public var bulleted: Bool

        public init(_ runs: [Run], bulleted: Bool = true) {
            self.runs = runs
            self.bulleted = bulleted
        }

        public var text: String { runs.map(\.text).joined() }
    }

    /// The <h2>, if there was one: "1.5.0 · 2026-09-07".
    public var heading: String?
    public var items: [Item]

    public init(heading: String? = nil, items: [Item] = []) {
        self.heading = heading
        self.items = items
    }

    public var isEmpty: Bool { heading == nil && items.isEmpty }

    // MARK: parsing

    public init(html: String) {
        var heading: String?
        var items: [Item] = []

        // What is being collected right now, and where it goes when it ends.
        enum Target { case none, heading, item(bulleted: Bool) }
        var target = Target.none
        var runs: [Run] = []
        var pending = ""
        var bold = false, code = false

        // Whitespace is collapsed the way a browser collapses it: the
        // changelog wraps its lines at 80 columns, and those newlines are not
        // paragraph breaks.
        func flushText() {
            let collapsed = Self.collapseWhitespace(pending)
            pending = ""
            guard !collapsed.isEmpty else { return }
            if let last = runs.indices.last, runs[last].bold == bold, runs[last].code == code {
                runs[last].text += collapsed
            } else {
                runs.append(Run(collapsed, bold: bold, code: code))
            }
        }

        func finish() {
            flushText()
            // Leading and trailing space belong to the markup, not the words.
            if let first = runs.indices.first {
                runs[first].text = String(runs[first].text.drop(while: \.isWhitespace))
            }
            if let last = runs.indices.last {
                while runs[last].text.last?.isWhitespace == true { runs[last].text.removeLast() }
            }
            runs.removeAll { $0.text.isEmpty }
            switch target {
            case .heading:
                let text = runs.map(\.text).joined()
                if !text.isEmpty { heading = text }
            case .item(let bulleted):
                if !runs.isEmpty { items.append(Item(runs, bulleted: bulleted)) }
            case .none:
                // Text outside any element: a paragraph without the tag.
                if !runs.isEmpty { items.append(Item(runs, bulleted: false)) }
            }
            runs = []
            target = .none
            bold = false
            code = false
        }

        var index = html.startIndex
        while index < html.endIndex {
            let ch = html[index]
            if ch == "<", let close = html[index...].firstIndex(of: ">") {
                let raw = html[html.index(after: index)..<close]
                index = html.index(after: close)
                let closing = raw.hasPrefix("/")
                let name = raw.drop(while: { $0 == "/" })
                    .prefix(while: { !$0.isWhitespace && $0 != "/" }).lowercased()
                switch name {
                case "h1", "h2", "h3", "h4":
                    finish()
                    if !closing { target = .heading }
                case "li":
                    finish()
                    if !closing { target = .item(bulleted: true) }
                case "p":
                    finish()
                    if !closing { target = .item(bulleted: false) }
                case "ul", "ol", "br", "div":
                    finish()
                case "strong", "b":
                    flushText(); bold = !closing
                case "code":
                    flushText(); code = !closing
                default:
                    // <a>, <em>, and whatever else: the words stay.
                    break
                }
            } else if ch == "&", let semi = html[index...].firstIndex(of: ";"),
                      html.distance(from: index, to: semi) <= 8,
                      let decoded = Self.entity(html[html.index(after: index)..<semi]) {
                pending.append(decoded)
                index = html.index(after: semi)
            } else {
                pending.append(ch)
                index = html.index(after: index)
            }
        }
        finish()

        self.heading = heading
        self.items = items
    }

    private static func collapseWhitespace(_ s: String) -> String {
        var out = ""
        var space = false
        for ch in s {
            // A non-breaking space is not the changelog's line wrapping; it is
            // a space someone put there on purpose, and it stays.
            if ch != "\u{00A0}", ch.isWhitespace || ch.isNewline {
                if !space { out.append(" ") }
                space = true
            } else {
                out.append(ch)
                space = false
            }
        }
        return out
    }

    private static func entity(_ name: Substring) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return "\u{00A0}"
        default:
            if name.hasPrefix("#x") || name.hasPrefix("#X"),
               let code = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(code) {
                return String(scalar)
            }
            if name.hasPrefix("#"), let code = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(code) {
                return String(scalar)
            }
            return nil
        }
    }
}
