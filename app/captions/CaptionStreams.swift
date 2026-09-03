// The two renderings of one transcript: as spoken, and as translated.
//
// They are paged together and must break at the same moments, or ⌃ swaps
// between two stacks that disagree about where the boxes were. Holding both here
// is what makes that structural rather than a rule the caller has to keep.
//
// It also removes an `inout` seam that had already cost a crash. The overlay
// used to hand one pager at a time to a helper that then reached back for the
// other, which is an overlapping access to a property the call already holds
// exclusively: Swift traps on that, and it traps at runtime, so it survived both
// the compiler and a green test suite. There is nothing to pass by reference any
// more, so the mistake has nowhere to live.

import Foundation

public struct CaptionStreams {
    public enum Stream {
        /// The transcript as spoken.
        case source
        /// The transcript translated. Carries a dimmed tail the source has no
        /// equivalent of, which is measured with it.
        case translated
    }

    private var sourcePager = StreamPager()
    private var translatedPager = StreamPager()

    public init() {}

    /// One call's worth of paging.
    public struct Page {
        public let visible: [TimedWord]
        public let brokePage: Bool
    }

    // MARK: reading

    public func closed(_ stream: Stream) -> [String] {
        pager(stream).closed
    }

    public func currentWords(_ stream: Stream) -> [TimedWord] {
        pager(stream).currentWords
    }

    public func start(_ stream: Stream) -> TimeInterval {
        pager(stream).start
    }

    public var isEmpty: Bool { sourcePager.closed.isEmpty && translatedPager.closed.isEmpty }

    private func pager(_ stream: Stream) -> StreamPager {
        stream == .source ? sourcePager : translatedPager
    }

    // MARK: both at once

    /// The next words start a page of their own, in both languages. Applied to
    /// both so a pause breaks them at the same word and the stacks stay aligned
    /// box for box.
    public mutating func markFresh() {
        sourcePager.markFresh()
        translatedPager.markFresh()
    }

    public mutating func clear() {
        sourcePager.clear()
        translatedPager.clear()
    }

    public mutating func trim(to depth: Int) {
        sourcePager.trim(to: depth)
        translatedPager.trim(to: depth)
    }

    /// Forget how far each transcript had run, keeping the pages where they are.
    /// For a swap between renderings, which otherwise reads as time running
    /// backwards: the translated stream ends at the last settled clause while the
    /// spoken one runs ahead of it.
    public mutating func forgetProgress() {
        sourcePager.forgetProgress()
        translatedPager.forgetProgress()
    }

    // MARK: paging

    /// Advance one stream and return the page to draw.
    ///
    /// `fits` must measure the words as the box will draw them, dimmed tail
    /// included: a page overflows sooner with one than without, and measuring
    /// without it is what made the stack lag a clause behind the screen.
    public mutating func ingest(_ stream: Stream, words: [TimedWord],
                                chunkStarts: [TimeInterval], depth: Int,
                                allowCarry: Bool,
                                speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                                fits: ([String]) -> Int) -> Page {
        let before = closed(stream).count
        let visible: [TimedWord]
        switch stream {
        case .source:
            visible = sourcePager.ingest(words, chunkStarts: chunkStarts, depth: depth,
                                         allowCarry: allowCarry,
                                         speculativeFrom: speculativeFrom, fits: fits)
        case .translated:
            visible = translatedPager.ingest(words, chunkStarts: chunkStarts, depth: depth,
                                             allowCarry: allowCarry,
                                             speculativeFrom: speculativeFrom, fits: fits)
        }
        return Page(visible: visible, brokePage: closed(stream).count != before)
    }
}
