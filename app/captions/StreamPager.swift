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
    /// A box that has left the screen.
    public struct Box: Equatable {
        public let text: String
        /// The app whose audio it transcribed, as the tap names the family, or
        /// nil when nothing was known to be playing. The stack wears its icon.
        public let app: String?
        /// The audio the box covers, from its first word's start to its last
        /// word's end: what the other language is matched to it by.
        public let start: TimeInterval
        public let end: TimeInterval

        public init(text: String, app: String? = nil, start: TimeInterval = 0,
                    end: TimeInterval = 0) {
            self.text = text
            self.app = app
            self.start = start
            self.end = end
        }
    }

    private var anchor = PageAnchor()

    /// Boxes that have left the screen, oldest first.
    public private(set) var boxes: [Box] = []
    /// How many have ever left, trimming included: what a reader of `boxes`
    /// keeps to know which of them it has not seen yet.
    public private(set) var closedCount = 0

    /// The same boxes, as text.
    public var closed: [String] { boxes.map(\.text) }

    /// The app the page on screen belongs to: the one that was playing when its
    /// words last arrived.
    private var currentApp: String?

    public init() {}

    /// The page on screen.
    public var currentWords: [TimedWord] { anchor.currentWords }
    public var currentText: String { currentWords.map(\.text).joined(separator: " ") }

    /// Where the page begins, in audio time.
    public var start: TimeInterval { anchor.start }

    /// The next words start a page of their own.
    public mutating func markFresh() { anchor.markFresh() }

    public mutating func rewind() { anchor.rewind() }

    /// Close the page on screen into the stack now — see `PageAnchor.close`.
    public mutating func close(depth: Int) {
        let banked = anchor.close()
        guard !banked.isEmpty else { return }
        append(banked, app: currentApp, depth: depth)
    }
    public mutating func forgetProgress() { anchor.forgetProgress() }

    public mutating func clear() {
        anchor.reset()
        boxes.removeAll()
        closedCount = 0
        currentApp = nil
    }

    /// Keep at most `depth` boxes. A depth of zero or less keeps none.
    ///
    /// Clamped rather than trusted. The setting arrives from `UserDefaults` as a
    /// bare `as? Int`, so a hand-edited or corrupt value reaches here unchecked,
    /// and `removeFirst(count - depth)` with a negative depth asks to remove more
    /// than there is and traps.
    public mutating func trim(to depth: Int) {
        let keep = max(depth, 0)
        guard boxes.count > keep else { return }
        boxes.removeFirst(boxes.count - keep)
    }

    /// Advance this stream and return the page to draw.
    ///
    /// `app` is the app playing as these words arrive. A box that closes here
    /// is tagged with the app its words arrived *under*, not the one arriving
    /// with the words that close it: after a fade the next words can come a
    /// minute later from somewhere else, and the box they close was not theirs.
    @discardableResult
    public mutating func ingest(_ words: [TimedWord], chunkStarts: [TimeInterval],
                                depth: Int, allowCarry: Bool,
                                speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                                app: String? = nil,
                                fits: ([TimedWord]) -> Int) -> [TimedWord] {
        let page = anchor.page(words, chunkStarts: chunkStarts, allowCarry: allowCarry,
                               speculativeFrom: speculativeFrom, fits: fits)
        // Only the first box to close was on screen before this call; any
        // after it are pages of the words arriving now.
        for (index, box) in page.closed.enumerated() {
            append(box, app: index == 0 ? currentApp ?? app : app, depth: depth)
        }
        currentApp = app
        return page.visible
    }

    private mutating func append(_ words: [TimedWord], app: String?, depth: Int) {
        guard depth > 0 else { return }
        let text = words.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A page can close by more than one route in the same beat, an overflow
        // straight after a pause say, and two identical boxes in the stack read
        // as a stutter rather than as history.
        guard !text.isEmpty, text != boxes.last?.text,
              let first = words.first, let last = words.last else { return }
        boxes.append(Box(text: text, app: app, start: first.start, end: last.end))
        closedCount += 1
        trim(to: depth)
    }
}
