// One stream of captions, as boxes.
//
// Thin on purpose: PageAnchor decides where a page begins and what has just
// left the screen, and this keeps the last few of those for the ⌥ stack. The box
// on screen and the boxes behind it therefore come from one pass over one piece
// of state, so a box leaves the screen and joins the stack in the same instant
// and cannot repeat what the box below it already shows.
//
// Both languages get one of these. A stack that filled only while its rendering
// happened to be the one on screen would be empty exactly when ⌃ asked for it, so
// the hidden stream is paged too, with the same rules.

import Foundation

public struct StreamPager {
    private var anchor = PageAnchor()

    /// Boxes that have left the screen, oldest first.
    public private(set) var closed: [String] = []

    public init() {}

    /// The page on screen.
    public var currentWords: [TimedWord] { anchor.currentWords }
    public var currentText: String { currentWords.map(\.text).joined(separator: " ") }

    /// Where the page begins, in audio time.
    public var start: TimeInterval { anchor.start }

    /// The next words start a page of their own.
    public mutating func markFresh() { anchor.markFresh() }

    public mutating func rewind() { anchor.rewind() }
    public mutating func forgetProgress() { anchor.forgetProgress() }

    public mutating func clear() {
        anchor.reset()
        closed.removeAll()
    }

    /// Keep at most `depth` boxes. A depth of zero or less keeps none.
    ///
    /// Clamped rather than trusted. The setting arrives from `UserDefaults` as a
    /// bare `as? Int`, so a hand-edited or corrupt value reaches here unchecked,
    /// and `removeFirst(count - depth)` with a negative depth asks to remove more
    /// than there is and traps.
    public mutating func trim(to depth: Int) {
        let keep = max(depth, 0)
        guard closed.count > keep else { return }
        closed.removeFirst(closed.count - keep)
    }

    /// Advance this stream and return the page to draw.
    @discardableResult
    public mutating func ingest(_ words: [TimedWord], chunkStarts: [TimeInterval],
                                depth: Int, allowCarry: Bool,
                                speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                                fits: ([String]) -> Int) -> [TimedWord] {
        let page = anchor.page(words, chunkStarts: chunkStarts, allowCarry: allowCarry,
                               speculativeFrom: speculativeFrom, fits: fits)
        for box in page.closed { append(box, depth: depth) }
        return page.visible
    }

    private mutating func append(_ words: [TimedWord], depth: Int) {
        guard depth > 0 else { return }
        let text = words.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A page can close by more than one route in the same beat, an overflow
        // straight after a pause say, and two identical boxes in the stack read
        // as a stutter rather than as history.
        guard !text.isEmpty, text != closed.last else { return }
        closed.append(text)
        trim(to: depth)
    }
}
