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
        /// The words themselves, by which a change of speaker found late can
        /// take its own back out of the box.
        public let words: [TimedWord]

        public init(text: String, app: String? = nil, start: TimeInterval = 0,
                    end: TimeInterval = 0, words: [TimedWord] = []) {
            self.text = text
            self.app = app
            self.start = start
            self.end = end
            self.words = words
        }
    }

    private var anchor = PageAnchor()

    /// Boxes that have left the screen, oldest first.
    public private(set) var boxes: [Box] = []
    /// How many have ever left, trimming included: what a reader of `boxes`
    /// keeps to know which of them it has not seen yet. A box's ordinal is its
    /// place in that count. It can go down: a change of speaker found late
    /// takes words back out of the boxes it reaches — see `revisedFrom`.
    public private(set) var closedCount = 0

    /// The ordinal of the first box the last call changed after it had closed,
    /// or nil when it changed none. A reader that has taken boxes from there on
    /// drops them and takes them again.
    public private(set) var revisedFrom: Int?

    /// Whether the last call turned the page on screen.
    public private(set) var turnedPage = false

    /// How far a box may end past the start of the one after it and still be
    /// taken for its neighbour on the same clock. Word times touch, and can
    /// overlap by a token.
    private static let clockSlack: TimeInterval = 0.3

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

    /// A new speaker began at `time` — see `PageAnchor.markSpeakerChange`.
    public mutating func markSpeakerChange(at time: TimeInterval) {
        anchor.markSpeakerChange(at: time)
    }

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
        revisedFrom = nil
        turnedPage = false
        // Only the first box to close was on screen before this call; any
        // after it are pages of the words arriving now.
        var onScreen = true
        for event in page.events {
            switch event {
            case .closed(let box):
                if append(box, app: onScreen ? currentApp ?? app : app, depth: depth) {
                    turnedPage = true
                }
                onScreen = false
            case .reclaimed(let from, let before, let ownBox):
                reclaim(from: from, before: before, ownBox: ownBox, depth: depth)
            }
        }
        currentApp = app
        return page.visible
    }

    /// Take the words from `cut` on back out of the boxes that closed with
    /// them: a new speaker's, closed with the outgoing speaker's page before
    /// the change was known. A box wholly after the cut goes; the one it falls
    /// in keeps what came before it. With `ownBox` the words taken become a box
    /// of their own; otherwise the page on screen has them now.
    ///
    /// Walks back only while each box ends where the next begins, starting from
    /// `before`, where the page on screen began: the recognizer's clock restarts
    /// at an endpoint, and a box from the run before can sit anywhere on the
    /// new one.
    private mutating func reclaim(from cut: TimeInterval, before: TimeInterval, ownBox: Bool,
                                  depth: Int) {
        var taken: [TimedWord] = []
        var app: String?
        var bound = before
        while let last = boxes.last, last.end > cut, last.end <= bound + Self.clockSlack,
              last.words.contains(where: { $0.start >= cut }) {
            boxes.removeLast()
            closedCount -= 1
            revisedFrom = closedCount
            taken = last.words.filter { $0.start >= cut } + taken
            app = last.app
            bound = last.start
            let kept = last.words.filter { $0.start < cut }
            if !kept.isEmpty {
                store(kept, app: last.app, depth: depth)
                break
            }
        }
        if ownBox, !taken.isEmpty { store(taken, app: app, depth: depth) }
    }

    @discardableResult
    private mutating func append(_ words: [TimedWord], app: String?, depth: Int) -> Bool {
        let text = words.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A page can close by more than one route in the same beat, an overflow
        // straight after a pause say, and two identical boxes in the stack read
        // as a stutter rather than as history.
        guard text != boxes.last?.text else { return false }
        return store(words, app: app, depth: depth)
    }

    @discardableResult
    private mutating func store(_ words: [TimedWord], app: String?, depth: Int) -> Bool {
        guard depth > 0 else { return false }
        let text = words.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let first = words.first, let last = words.last else { return false }
        boxes.append(Box(text: text, app: app, start: first.start, end: last.end, words: words))
        closedCount += 1
        trim(to: depth)
        return true
    }
}
