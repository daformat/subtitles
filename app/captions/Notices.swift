// Third-party notices, from the text file build.sh assembles to something a
// native window can set in its own type.
//
// The file is plain text as licences come: hard-wrapped at eighty columns,
// indented by hand, its sections divided by rules of equals signs, and with
// one small table of models and their terms. Reflowed here into paragraphs so
// a window can wrap them to its own width, with the few shapes that are not
// prose kept as they are: a rule becomes a heading, a starred line a bullet,
// and a line whose columns are set apart by runs of spaces a row. Nothing is
// dropped; a shape this misreads costs a paragraph break, never a word.
//
// Here rather than in the app target so it can be tested without AppKit: it
// is a parser, and parsers are where the odd inputs live.

import Foundation

public enum Notices {
    public enum Block: Equatable {
        /// A title set between two rules.
        case heading(String)
        case paragraph(String)
        case bullet(String)
        /// Two columns, as the table of models has them.
        case row(String, String)
    }

    public static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var group: [String] = []
        func flush() {
            guard !group.isEmpty else { return }
            blocks.append(contentsOf: read(group))
            group = []
        }
        for line in text.components(separatedBy: .newlines) {
            if trim(line).isEmpty { flush() } else { group.append(line) }
        }
        flush()
        return blocks
    }

    /// One run of lines with no blank line inside it.
    private static func read(_ lines: [String]) -> [Block] {
        if lines.count >= 3, isRule(lines[0]), isRule(lines[lines.count - 1]) {
            return [.heading(lines[1..<lines.count - 1].map(trim).joined(separator: " "))]
        }
        // A run of two or more spaces inside a line sets columns apart, but
        // only when a neighbour has one too: a lone run is a typist's double
        // space after a sentence, which the Apache text has one of.
        let columned = lines.map { hasColumns($0) }
        var out: [Block] = []
        var open: (text: String, indent: Int, bullet: Bool)?
        func close() {
            if let p = open { out.append(p.bullet ? .bullet(p.text) : .paragraph(p.text)) }
            open = nil
        }
        for (i, line) in lines.enumerated() {
            let body = trim(line)
            let indent = line.prefix(while: { $0 == " " }).count
            let besideColumns = (i > 0 && columned[i - 1]) || (i + 1 < lines.count && columned[i + 1])
            if columned[i] && besideColumns {
                close()
                out.append(row(body))
            } else if let rest = afterBullet(body) {
                close()
                open = (rest, indent, true)
            } else if let p = open, indent >= p.indent {
                // A line no shallower than the paragraph's first is more of
                // it: the same indent in plain prose, a deeper one under a
                // numbered section. A shallower line starts something new,
                // which is what keeps a centred title from becoming a sentence.
                open = (p.text + " " + body, p.indent, p.bullet)
            } else {
                close()
                open = (body, indent, false)
            }
        }
        close()
        return out
    }

    private static func trim(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    /// Three or more ruling characters and nothing else.
    private static func isRule(_ line: String) -> Bool {
        let body = trim(line)
        return body.count >= 3 && body.allSatisfy { $0 == "=" || $0 == "-" }
    }

    private static func hasColumns(_ line: String) -> Bool {
        trim(line).range(of: "\\S {2,}\\S", options: .regularExpression) != nil
    }

    private static func row(_ body: String) -> Block {
        guard let gap = body.range(of: " {2,}", options: .regularExpression) else {
            return .paragraph(body)
        }
        return .row(String(body[..<gap.lowerBound]), String(body[gap.upperBound...]))
    }

    /// The text after a bullet marker, or nil when the line is not one.
    private static func afterBullet(_ body: String) -> String? {
        for marker in ["* ", "\u{2022} "] where body.hasPrefix(marker) {
            return String(body.dropFirst(marker.count))
        }
        return nil
    }
}
