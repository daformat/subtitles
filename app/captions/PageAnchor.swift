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
        /// Pages that closed during this call, oldest first, each already trimmed
        /// to what it added: a carried clause belongs to the box that carries it.
        public let closed: [[TimedWord]]

        public var brokePage: Bool { !closed.isEmpty }
    }

    /// The next words start a page of their own: a pause, an endpoint, or a box
    /// that faded out from under them. Whatever is on screen closes.
    public mutating func markFresh() { freshNext = true }

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
                              fits: ([String]) -> Int) -> Page {
        guard let newest = words.last else { return Page(visible: currentWords, closed: []) }

        // Time running backwards means the recogniser restarted its transcript,
        // so the old anchor points into audio that no longer exists. `lastCarried`
        // goes with it: measured against the old timeline it sits far in the
        // future of the new one, and would refuse every carry from here on.
        if newest.end < latest {
            start = 0
            latest = 0
            previousEnd = -.greatestFiniteMagnitude
            barrier = -.greatestFiniteMagnitude
            lastCarried = -.greatestFiniteMagnitude
        }

        var closed: [[TimedWord]] = []
        if freshNext {
            freshNext = false
            let banked = currentWords.filter { $0.start >= previousEnd }
            if !banked.isEmpty { closed.append(banked) }
            start = latest
            previousEnd = latest
            barrier = latest
            lastCarried = -.greatestFiniteMagnitude
        }
        latest = max(latest, newest.end)

        var visible = words.filter { $0.start >= start }
        // A tail that began before the barrier belongs to a box that has gone.
        // Its words move as it is retranslated, so leaving them to the time filter
        // lets them creep back across it one update later.
        if speculativeFrom < barrier {
            visible = visible.filter { $0.start < speculativeFrom }
        }
        guard !visible.isEmpty else {
            currentWords = []
            return Page(visible: [], closed: closed)
        }

        while true {
            let fitted = fits(visible.map(\.text))
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
            if !leaving.isEmpty { closed.append(leaving) }

            if let carried { lastCarried = carried }
            previousEnd = nextAnchor
            start = nextAnchor
            visible = visible.filter { $0.start >= start }
        }
        currentWords = visible
        return Page(visible: visible, closed: closed)
    }
}
