// Which words belong in the box right now, and which have just left it.
//
// There is one page break, not two. The box and the ⌥ stack are the same
// sequence of boxes seen at different moments, and for a while each worked it
// out for itself: the box kept an anchor in the overlay controller and the stack
// kept another in its pager. They agreed while nothing disturbed them and
// drifted the moment something did, which showed up as boxes repeating words and
// as the stack taking a clause too long to admit a box had gone.
//
// So a page closes here, once, and both readers of it see the same event.

import Foundation

public struct PageAnchor {
    /// Audio time the page begins at. Words before it are on a page the reader
    /// has already lost.
    public private(set) var start: TimeInterval = 0

    /// Newest word end seen, which is where a fresh page begins.
    private var latest: TimeInterval = 0

    /// Where the last closed page ended.
    ///
    /// Pages overlap on purpose: one restarts at the last clause it showed so
    /// that clause opens the next box and stays readable across the break. What
    /// leaves the screen must not repeat that clause, though, because the box
    /// below still ends with it, so a closed page is cut here rather than at the
    /// spill.
    private var previousEnd: TimeInterval = -.greatestFiniteMagnitude

    /// The last clause boundary carried from, so a clause reaches the next box
    /// and no further. When nothing new settles behind it the box can fill and
    /// turn over on a growing tail alone, and that boundary would otherwise stay
    /// the newest one in reach and open box after box.
    private var lastCarried: TimeInterval = -.greatestFiniteMagnitude

    private var freshNext = false

    /// Where new speakers began, in audio time, oldest first, for changes not
    /// applied yet. The diarizer names a change a second or two after it
    /// happens, so the words it is about are usually on screen already, and
    /// sometimes in a box that has closed. A change waits here until this
    /// stream has a word at or after it, and until that word is settled.
    private var speakerChanges: [TimeInterval] = []

    /// The last call's words, for placing a change still waiting on them when
    /// the clock they are timed on restarts.
    private var lastInput: (words: [TimedWord], chunkStarts: [TimeInterval],
                            speculativeFrom: TimeInterval)?

    /// Nothing from before this moment is ever shown again.
    ///
    /// A fade closes the box, and the words in it are gone as far as the reader is
    /// concerned. Filtering on `start` alone was not enough to keep them gone: the
    /// unsettled tail spans the fade, and it is re-timed on every update, so words
    /// that sat before the anchor drifted after it and came back at the top of the
    /// next box. A tail that begins before the barrier is stale by definition and
    /// is dropped whole until the speaker has produced a new one.
    private var barrier: TimeInterval = -.greatestFiniteMagnitude

    /// What is on screen now, kept so a pause can close it.
    public private(set) var currentWords: [TimedWord] = []

    public init() {}

    /// One call's worth: what to draw, and what left the screen while drawing it.
    public struct Page {
        /// The page as it should now appear.
        public let visible: [TimedWord]
        /// What happened to the boxes during this call, in order.
        public let events: [Event]

        /// Pages that closed during this call, oldest first, each already trimmed
        /// to what it added: a carried clause belongs to the box that carries it.
        public var closed: [[TimedWord]] {
            events.compactMap { if case .closed(let words) = $0 { return words } else { return nil } }
        }

        public var brokePage: Bool { !closed.isEmpty }
    }

    public enum Event: Equatable {
        /// A page left the screen.
        case closed([TimedWord])
        /// A new speaker began at `from`, before the page on screen, so the
        /// closed boxes hand back their words from there on. `before` is where
        /// the page on screen began until now: the boxes that end after it are
        /// from an earlier run of the recognizer's clock and are left alone.
        /// With `ownBox`, the words become a box of their own, there being no
        /// page on screen to take them; otherwise that page now begins with them.
        case reclaimed(from: TimeInterval, before: TimeInterval, ownBox: Bool)
    }

    /// A new speaker began at `time`. Their words start a page of their own,
    /// including any already drawn on the outgoing speaker's page or already
    /// closed with it.
    public mutating func markSpeakerChange(at time: TimeInterval) {
        speakerChanges.append(time)
        speakerChanges.sort()
    }

    /// How far a change may move to reach the start of a settled clause, in a
    /// stream that has clauses: splitting a translated sentence in two leaves
    /// half a sentence in each box, when the translator put both speakers in
    /// one sentence at all.
    static let clauseReach: TimeInterval = 0.75

    /// How far either side of the diarizer's time the break may move to find
    /// the pause the speakers left between them. Its segment boundary and the
    /// recognizer's word times disagree by up to half a second either way on
    /// real speech: measured on a call, a change named at 38.56 s belonged
    /// before "I" at 38.08, and one at 93.36 s after "degree" at 93.28.
    static let turnReach: TimeInterval = 0.8

    /// The shortest gap between words that reads as the pause at a turn.
    /// Words inside a phrase touch, or nearly.
    static let turnPause: TimeInterval = 0.12

    /// How much speech past the change to wait for before choosing, so the
    /// pause after it is in reach as well as the one before.
    static let turnLookahead: TimeInterval = 0.4

    /// Where a change at `time` breaks `words`. The end of a sentence within
    /// `turnReach` of it, the nearest if there are several; else the widest
    /// pause between two words there, the nearest of those if several are
    /// about as wide; with neither, the first word mostly spoken after it. A
    /// clause close to it wins over all three. Nil while the words past the
    /// change have not arrived, unless `final`: the words will get no further.
    ///
    /// A sentence's end before the gap, because the recognizer's word ends are
    /// the weaker of its two times: "Friday." was given an end well short of
    /// the pause after it, which made the gap before it look the wider.
    static func cut(at time: TimeInterval, in words: [TimedWord],
                    chunkStarts: [TimeInterval], final: Bool = false) -> TimeInterval? {
        guard let first = words.first(where: { ($0.start + $0.end) / 2 >= time }),
              let newest = words.last, final || newest.end >= time + turnLookahead
        else { return nil }
        if let clause = chunkStarts.min(by: { abs($0 - time) < abs($1 - time) }),
           abs(clause - time) <= clauseReach {
            return clause
        }
        let inReach = words.indices.dropFirst().filter { abs(words[$0].start - time) <= turnReach }
        if let sentence = inReach
            .filter({ Self.endsSentence(words[$0 - 1].text) })
            .min(by: { abs(words[$0].start - time) < abs(words[$1].start - time) }) {
            return words[sentence].start
        }
        var best: (gap: TimeInterval, distance: TimeInterval, start: TimeInterval)?
        for index in inReach {
            let start = words[index].start
            let distance = abs(start - time)
            let gap = start - words[index - 1].end
            guard gap >= turnPause else { continue }
            if let current = best {
                let wider = gap > current.gap + 0.04
                let asWide = abs(gap - current.gap) <= 0.04
                guard wider || (asWide && distance < current.distance) else { continue }
            }
            best = (gap, distance, start)
        }
        return best?.start ?? first.start
    }

    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ".?!…。？！".contains(last)
    }

    /// The next words start a page of their own: a pause, an endpoint, or a box
    /// that faded out from under them. Whatever is on screen closes.
    public mutating func markFresh() { freshNext = true }

    /// Close the page now. What `markFresh` would have done at the next call,
    /// done here, and what left the screen handed back: a box that faded goes
    /// to the stack at once rather than when the next words happen to arrive —
    /// ⌥ is asked for it exactly then. The next words start a page of their own.
    public mutating func close() -> [TimedWord] {
        freshNext = false
        let banked = currentWords.filter { $0.start >= previousEnd }
        start = latest
        previousEnd = latest
        barrier = latest
        lastCarried = -.greatestFiniteMagnitude
        currentWords = []
        return banked
    }

    /// Begin again from the start of whatever is available. For the case where an
    /// anchor kept across a language swap turns out to sit past everything the
    /// other rendering has.
    public mutating func rewind() { start = 0 }

    /// Forget how far the transcript had run, keeping the page where it is.
    ///
    /// For a swap between two renderings of the same audio: the translated stream
    /// ends at the last settled clause while the spoken one runs a second ahead,
    /// so carrying that figure across reads as a transcript that has gone
    /// backwards and trips the restart branch for no reason.
    public mutating func forgetProgress() { latest = 0 }

    public mutating func reset() {
        start = 0
        latest = 0
        previousEnd = -.greatestFiniteMagnitude
        barrier = -.greatestFiniteMagnitude
        lastCarried = -.greatestFiniteMagnitude
        freshNext = false
        speakerChanges.removeAll()
        lastInput = nil
        currentWords = []
    }

    /// Advance the page over `words`.
    ///
    /// Calling this twice with the same words must give the same answer and close
    /// nothing the second time: the transcript is delivered whole on every update,
    /// so an idle recogniser repeats itself several times a second and a repaint
    /// has to be free.
    ///
    /// `fits` measures how many of these words fit the box *as it will be drawn*,
    /// which includes any dimmed tail beside them. Measuring without it is what
    /// made the stack lag: the box overflowed on text the stack could not see.
    /// It is handed the words with their times rather than their text alone, so
    /// a caller drawing something else under them — the original under a
    /// translation — can measure that too, by the span the words cover.
    /// `speculativeFrom` is where the unsettled tail begins, and the page will not
    /// break at or past it.
    ///
    /// The tail is retranslated whole on every update and its word times are
    /// synthesised by spreading it across the audio it covers, so they all move
    /// as it grows. Breaking inside it therefore cannot hold: the next update
    /// re-times the same words, they land after the anchor again, and the box
    /// shows them a second and third time while the speaker adds nothing. Settled
    /// text is the only thing with times stable enough to anchor on.
    public mutating func page(_ words: [TimedWord], chunkStarts: [TimeInterval],
                              allowCarry: Bool,
                              speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                              fits: ([TimedWord]) -> Int) -> Page {
        guard let newest = words.last else { return Page(visible: currentWords, events: []) }

        // Time running backwards means the recogniser restarted its transcript,
        // so the old anchor points into audio that no longer exists. `lastCarried`
        // goes with it: measured against the old timeline it sits far in the
        // future of the new one, and would refuse every carry from here on.
        var events: [Event] = []
        defer { lastInput = (words, chunkStarts, speculativeFrom) }
        if newest.end < latest {
            // Changes still waiting for words past them are placed on the
            // words there are, before the clock they are timed on goes: an
            // endpoint straight after a turn otherwise dropped the change, and
            // the new speaker's first words stayed in the outgoing box.
            if let last = lastInput, !speakerChanges.isEmpty {
                applySpeakerChanges(last.words, chunkStarts: last.chunkStarts,
                                    speculativeFrom: last.speculativeFrom, final: true,
                                    into: &events)
            }
            start = 0
            latest = 0
            previousEnd = -.greatestFiniteMagnitude
            barrier = -.greatestFiniteMagnitude
            lastCarried = -.greatestFiniteMagnitude
            // A change timed on the old clock points anywhere on the new one.
            speakerChanges.removeAll()
        }

        if freshNext {
            freshNext = false
            let banked = currentWords.filter { $0.start >= previousEnd }
            if !banked.isEmpty { events.append(.closed(banked)) }
            start = latest
            previousEnd = latest
            barrier = latest
            lastCarried = -.greatestFiniteMagnitude
        }
        latest = max(latest, newest.end)
        applySpeakerChanges(words, chunkStarts: chunkStarts, speculativeFrom: speculativeFrom,
                            into: &events)

        var visible = words.filter { $0.start >= start }
        // A tail that began before the barrier belongs to a box that has gone.
        // Its words move as it is retranslated, so leaving them to the time filter
        // lets them creep back across it one update later.
        if speculativeFrom < barrier {
            visible = visible.filter { $0.start < speculativeFrom }
        }
        guard !visible.isEmpty else {
            currentWords = []
            return Page(visible: [], events: events)
        }

        while true {
            let fitted = fits(visible)
            if fitted >= visible.count { break }   // it all fits
            if fitted <= 0 { break }               // one word wider than the box

            let spilled = visible[fitted].start
            // Bounded by the first visible word, not by `start`: a boundary at or
            // before the leading word filters nothing out, so the next pass would
            // compute the same spill and the same carry, and never terminate.
            let floor = max(visible[0].start, lastCarried)
            let carried = allowCarry ? chunkStarts.last { $0 > floor && $0 < spilled } : nil
            let nextAnchor = min(carried ?? spilled, speculativeFrom)
            // Nowhere left to move without cutting into provisional text. The box
            // holds what it holds and clips; the tail is a second of speech, and a
            // clipped word beats one that reappears in the next three boxes.
            guard nextAnchor > start else { break }

            let leaving = visible.filter { $0.start >= previousEnd && $0.start < nextAnchor }
            if !leaving.isEmpty { events.append(.closed(leaving)) }

            if let carried { lastCarried = carried }
            previousEnd = nextAnchor
            start = nextAnchor
            visible = visible.filter { $0.start >= start }
        }
        currentWords = visible
        return Page(visible: visible, events: events)
    }

    /// Break the page where each new speaker began, as far as the words allow.
    ///
    /// Inside the page on screen, the words before the change close and the
    /// page begins at it, so the new speaker's first words open the box that
    /// follows instead of ending the one before. Before it, the change reaches
    /// into boxes already closed and takes those words back.
    ///
    /// Only on settled words: a tail's times are synthesized and move on every
    /// update, and a break inside it would not hold — see `page`.
    ///
    /// `final` places every change the words reach and drops the rest, for
    /// words about to be replaced by a new clock's.
    private mutating func applySpeakerChanges(_ words: [TimedWord], chunkStarts: [TimeInterval],
                                              speculativeFrom: TimeInterval, final: Bool = false,
                                              into events: inout [Event]) {
        while let time = speakerChanges.first {
            guard let cut = Self.cut(at: time, in: words, chunkStarts: chunkStarts, final: final),
                  cut <= speculativeFrom
            else {
                if final { speakerChanges.removeFirst(); continue }
                break
            }
            speakerChanges.removeFirst()
            if cut >= start {
                let leaving = words.filter {
                    $0.start >= start && $0.start >= previousEnd && $0.start < cut
                }
                if !leaving.isEmpty { events.append(.closed(leaving)) }
                barrier = max(barrier, cut)
            } else {
                let live = words.contains { $0.start >= start }
                events.append(.reclaimed(from: cut, before: start, ownBox: !live))
                guard live else { continue }
                barrier = cut
            }
            start = cut
            previousEnd = cut
            lastCarried = -.greatestFiniteMagnitude
            // What a page closing next, before these words are paged, would
            // bank: the new speaker's, not the outgoing speaker's again.
            currentWords = words.filter { $0.start >= cut }
        }
    }
}
