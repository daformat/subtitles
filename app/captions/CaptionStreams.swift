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
        /// The ordinal of the first closed box this call changed — see
        /// `StreamPager.revisedFrom`.
        public let revisedFrom: Int?
    }

    // MARK: reading

    public func closed(_ stream: Stream) -> [String] {
        pager(stream).closed
    }

    /// The same boxes, with the app each one belongs to.
    public func boxes(_ stream: Stream) -> [StreamPager.Box] {
        pager(stream).boxes
    }

    /// How many boxes have ever left one stream's screen — see
    /// `StreamPager.closedCount`.
    public func closedCount(_ stream: Stream) -> Int {
        pager(stream).closedCount
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

    /// One stream's next words start a page of their own. For an utterance's
    /// end, where the source breaks now and the translation only once its last
    /// words for that utterance have landed — see `OverlayController
    /// .endUtterance`; the boxes still close one for one.
    public mutating func markFresh(_ stream: Stream) {
        switch stream {
        case .source: sourcePager.markFresh()
        case .translated: translatedPager.markFresh()
        }
    }

    /// A new speaker began at `time`, in both languages. Each stream breaks
    /// once it has the words to break — see `PageAnchor.markSpeakerChange`.
    public mutating func markSpeakerChange(at time: TimeInterval) {
        sourcePager.markSpeakerChange(at: time)
        translatedPager.markSpeakerChange(at: time)
    }

    public mutating func clear() {
        sourcePager.clear()
        translatedPager.clear()
    }

    /// Close both pages into their stacks now: for a box that has faded, or
    /// been emptied by a change, and is wanted under ⌥ from that moment.
    public mutating func close(depth: Int) {
        sourcePager.close(depth: depth)
        translatedPager.close(depth: depth)
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
    ///
    /// `app` is the app playing as the words arrive; a box that closes is
    /// tagged with the one its words came under — see `StreamPager.ingest`.
    public mutating func ingest(_ stream: Stream, words: [TimedWord],
                                chunkStarts: [TimeInterval], depth: Int,
                                allowCarry: Bool,
                                speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                                app: String? = nil,
                                fits: ([TimedWord]) -> Int) -> Page {
        let visible: [TimedWord]
        switch stream {
        case .source:
            visible = sourcePager.ingest(words, chunkStarts: chunkStarts, depth: depth,
                                         allowCarry: allowCarry,
                                         speculativeFrom: speculativeFrom, app: app, fits: fits)
        case .translated:
            visible = translatedPager.ingest(words, chunkStarts: chunkStarts, depth: depth,
                                             allowCarry: allowCarry,
                                             speculativeFrom: speculativeFrom, app: app,
                                             fits: fits)
        }
        let pager = pager(stream)
        return Page(visible: visible, brokePage: pager.turnedPage, revisedFrom: pager.revisedFrom)
    }
}
