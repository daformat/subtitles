// Two renderings of one transcript, paged together.
//
// These exist because of a crash that no test could have caught. The overlay
// used to hold the two pagers as separate properties and hand one at a time to a
// helper, which then reached back for the other to mark it fresh: an overlapping
// access to a property the call already held exclusively. Swift traps on that,
// at runtime, so it passed the compiler and passed a green suite and then
// aborted on the first translated word after a pause.
//
// An exclusivity trap cannot be asserted against. A test that provokes one takes
// the whole process down rather than failing, so there is nothing to catch. What
// can be done is to remove the shape that allowed it, which is what CaptionStreams
// is for, and then test the rule the broken code was reaching across itself to
// keep: both streams break at the same moments, and paging one leaves the other
// alone.

import XCTest
@testable import CaptionCore

final class CaptionStreamsTests: XCTestCase {
    private func fits(_ capacity: Int) -> ([String]) -> Int {
        { texts in min(capacity, texts.count) }
    }

    private func words(_ texts: [String], from start: TimeInterval = 0) -> [TimedWord] {
        texts.enumerated().map { index, text in
            let begin = start + Double(index)
            return TimedWord(text: text, start: begin, end: begin + 0.5)
        }
    }

    private let spoken = ["je", "suis", "allé", "au", "magasin", "hier", "pour", "acheter"]
    private let english = ["I", "went", "to", "the", "store", "yesterday", "to", "buy"]

    // MARK: the rule the crash was reaching across itself to keep

    /// A pause breaks both languages at the same word, so ⌃ does not swap between
    /// two stacks that disagree about where the boxes were.
    func testMarkFreshAppliesToBothStreams() {
        var streams = CaptionStreams()
        _ = streams.ingest(.source, words: words(spoken), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(20))
        _ = streams.ingest(.translated, words: words(english), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(20))
        XCTAssertTrue(streams.isEmpty, "nothing has overflowed yet")

        streams.markFresh()
        _ = streams.ingest(.source, words: words(["ensuite"], from: 100),
                           chunkStarts: [], depth: 10, allowCarry: false, fits: fits(20))
        _ = streams.ingest(.translated, words: words(["afterwards"], from: 100),
                           chunkStarts: [], depth: 10, allowCarry: false, fits: fits(20))

        XCTAssertEqual(streams.closed(.source), ["je suis allé au magasin hier pour acheter"])
        XCTAssertEqual(streams.closed(.translated), ["I went to the store yesterday to buy"])
        XCTAssertEqual(streams.currentWords(.source).map(\.text), ["ensuite"])
        XCTAssertEqual(streams.currentWords(.translated).map(\.text), ["afterwards"])
    }

    /// Paging one stream must not disturb the other: the spoken transcript
    /// arrives on every update while the translated one only moves when a
    /// translation lands, so the source is paged many times per translated page.
    func testPagingOneStreamLeavesTheOtherAlone() {
        var streams = CaptionStreams()
        _ = streams.ingest(.translated, words: words(english), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(4))
        let settled = streams.closed(.translated)
        let onScreen = streams.currentWords(.translated).map(\.text)

        for count in 1...spoken.count {
            _ = streams.ingest(.source, words: Array(words(spoken).prefix(count)),
                               chunkStarts: [], depth: 10, allowCarry: false, fits: fits(4))
        }

        XCTAssertEqual(streams.closed(.translated), settled)
        XCTAssertEqual(streams.currentWords(.translated).map(\.text), onScreen)
    }

    /// The box draws what the stream holds, so a box leaves the screen and joins
    /// the stack in the same instant. Two page breaks is what made the stack lag.
    func testTheDrawnPageIsTheStreamsOwnPage() {
        var streams = CaptionStreams()
        let page = streams.ingest(.translated, words: words(english), chunkStarts: [],
                                  depth: 10, allowCarry: false, fits: fits(3))
        XCTAssertEqual(page.visible.map(\.text), streams.currentWords(.translated).map(\.text))
        XCTAssertTrue(page.brokePage)
        XCTAssertFalse(streams.closed(.translated).isEmpty)
    }

    func testBrokePageIsFalseWhenNothingLeft() {
        var streams = CaptionStreams()
        let page = streams.ingest(.source, words: words(spoken), chunkStarts: [],
                                  depth: 10, allowCarry: false, fits: fits(20))
        XCTAssertFalse(page.brokePage)
        XCTAssertTrue(streams.closed(.source).isEmpty)
    }

    // MARK: everything else applies to both

    func testClearEmptiesBoth() {
        var streams = CaptionStreams()
        _ = streams.ingest(.source, words: words(spoken), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(3))
        _ = streams.ingest(.translated, words: words(english), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(3))
        XCTAssertFalse(streams.isEmpty)

        streams.clear()
        XCTAssertTrue(streams.isEmpty)
        XCTAssertTrue(streams.currentWords(.source).isEmpty)
        XCTAssertTrue(streams.currentWords(.translated).isEmpty)
    }

    func testTrimAppliesToBoth() {
        var streams = CaptionStreams()
        for stream in [CaptionStreams.Stream.source, .translated] {
            _ = streams.ingest(stream, words: words(spoken), chunkStarts: [], depth: 10,
                               allowCarry: false, fits: fits(2))
        }
        XCTAssertGreaterThan(streams.closed(.source).count, 1)
        streams.trim(to: 1)
        XCTAssertEqual(streams.closed(.source).count, 1)
        XCTAssertEqual(streams.closed(.translated).count, 1)
    }

    /// A depth from a hand-edited plist reaches this unchecked, and a negative one
    /// used to ask for more boxes than were held, which traps.
    func testANegativeDepthDoesNotTrap() {
        var streams = CaptionStreams()
        _ = streams.ingest(.source, words: words(spoken), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(2))
        streams.trim(to: -5)
        XCTAssertTrue(streams.isEmpty)
    }

    /// `isEmpty` has to mean both, not whichever is on screen: with a target
    /// chosen the visible one can be empty while the other holds a session, and
    /// reading only the visible one left the stack never expiring.
    func testIsEmptyMeansBothStreams() {
        var streams = CaptionStreams()
        _ = streams.ingest(.translated, words: words(english), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(2))
        XCTAssertTrue(streams.closed(.source).isEmpty)
        XCTAssertFalse(streams.isEmpty, "one stream still holds boxes")
    }

    /// The spoken stream runs ahead of the translated one, so a swap looks like
    /// time going backwards unless both drop what they knew of the transcript.
    func testForgetProgressAppliesToBoth() {
        var streams = CaptionStreams()
        _ = streams.ingest(.source, words: words(spoken), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(3))
        _ = streams.ingest(.translated, words: words(english), chunkStarts: [], depth: 10,
                           allowCarry: false, fits: fits(3))
        let sourceStart = streams.start(.source)
        let translatedStart = streams.start(.translated)

        streams.forgetProgress()
        XCTAssertEqual(streams.start(.source), sourceStart, "the page should not move")
        XCTAssertEqual(streams.start(.translated), translatedStart)
    }
}
