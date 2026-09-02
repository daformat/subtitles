// How a stream becomes boxes, and what the ⌥ stack keeps of them.
//
// The pager is where this session's regressions clustered, because three rules
// interact and each was added after the previous one shipped: pages overlap by a
// clause so a fast turnover stays readable, the stack must not repeat what the
// box below it already shows, and a clause is worth carrying exactly once.

import XCTest
@testable import CaptionCore

final class StreamPagerTests: XCTestCase {
    /// A box that holds `capacity` words, standing in for the real text layout.
    private func fits(_ capacity: Int) -> ([String]) -> Int {
        { texts in min(capacity, texts.count) }
    }

    /// `clauses` of equal length, one chunk boundary each, a second apart.
    private func stream(_ clauses: [[String]]) -> (words: [TimedWord], starts: [TimeInterval]) {
        var words: [TimedWord] = []
        var starts: [TimeInterval] = []
        for (index, clause) in clauses.enumerated() {
            let base = Double(index) * 10
            starts.append(base)
            for (offset, text) in clause.enumerated() {
                words.append(TimedWord(text: text, start: base + Double(offset),
                                       end: base + Double(offset) + 0.5))
            }
        }
        return (words, starts)
    }

    private let sample = [["the", "cat", "sat", "down"], ["and", "then", "it", "slept"],
                          ["until", "the", "sun", "rose"], ["over", "the", "quiet", "hills"]]

    // MARK: carrying a clause

    func testWithoutCarryPagesDoNotOverlap() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: false, fits: fits(6))
        XCTAssertEqual(pager.closed, ["the cat sat down and then", "it slept until the sun rose"])
    }

    /// Boxes overlap on screen so a turnover has something to re-anchor on, but
    /// the stack keeps only what each page added: the box below already ends with
    /// the carried clause, and repeating it reads as a stutter.
    func testHistoryNeverRepeatsTheCarriedClause() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(6))
        XCTAssertEqual(pager.closed,
                       ["the cat sat down", "and then it slept", "until the sun rose"])
        let joined = (pager.closed + [pager.currentText]).joined(separator: " ")
        XCTAssertEqual(joined, sample.flatMap { $0 }.joined(separator: " "),
                       "stack and live box should read as the transcript, once")
    }

    /// The clause reaches the next box and no further. Without this a boundary
    /// stays the newest one in reach while nothing settles behind it, and opens
    /// box after box.
    func testAClauseIsCarriedAtMostOnce() {
        // One boundary, then a long unpunctuated run that keeps forcing turnovers.
        var words: [TimedWord] = []
        for index in 0..<24 {
            words.append(TimedWord(text: "w\(index)", start: Double(index),
                                   end: Double(index) + 0.5))
        }
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: [0, 4], depth: 20, allowCarry: true, fits: fits(6))
        let openings = pager.closed.compactMap { $0.split(separator: " ").first.map(String.init) }
        XCTAssertEqual(Set(openings).count, openings.count,
                       "a clause opened more than one box: \(pager.closed)")
    }

    // MARK: continuity

    func testEveryWordAppearsExactlyOnceAcrossTheStack() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        let seen = (pager.closed + [pager.currentText])
            .flatMap { $0.split(separator: " ").map(String.init) }
        XCTAssertEqual(seen, words.map(\.text))
    }

    func testDepthCapsTheStack() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 2, allowCarry: true, fits: fits(5))
        XCTAssertLessThanOrEqual(pager.closed.count, 2)
    }

    func testClearEmptiesEverything() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        XCTAssertFalse(pager.closed.isEmpty)
        pager.clear()
        XCTAssertTrue(pager.closed.isEmpty)
        XCTAssertTrue(pager.currentText.isEmpty)
    }

    // MARK: termination

    /// A boundary at or before the leading word filters nothing out, so the next
    /// pass computes the same spill and the same carry. This hung the main thread
    /// before the carry was bounded by the first visible word.
    func testPagingTerminatesWhenBoundariesSitOnPageStarts() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        // Capacity 3 against 4-word clauses puts a boundary on almost every page.
        pager.ingest(words, chunkStarts: starts, depth: 50, allowCarry: true, fits: fits(3))
        XCTAssertFalse(pager.closed.contains("!! did not terminate"))
        XCTAssertFalse(pager.closed.isEmpty)
    }

    func testAClauseWiderThanTheBoxFallsBackToPlainPaging() {
        let words = (0..<10).map {
            TimedWord(text: "w\($0)", start: Double($0), end: Double($0) + 0.5)
        }
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: [0], depth: 20, allowCarry: true, fits: fits(4))
        XCTAssertEqual(pager.closed, ["w0 w1 w2 w3", "w4 w5 w6 w7"])
    }

    // MARK: restarts

    func testATranscriptThatGoesBackwardsIsARestart() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        let before = pager.closed.count

        // The recogniser reset: times begin again near zero.
        let fresh = [TimedWord(text: "again", start: 0, end: 0.5)]
        pager.ingest(fresh, chunkStarts: [0], depth: 20, allowCarry: true, fits: fits(5))
        XCTAssertEqual(pager.currentText, "again")
        XCTAssertGreaterThanOrEqual(pager.closed.count, before,
                                    "a restart should not drop the stack")
    }

    /// Repeating an update must not repeat its pages: the transcript is delivered
    /// whole on every tick, so an idle recogniser resends the same words forever.
    func testReDeliveringTheSameTranscriptIsIdempotent() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        let once = pager.closed
        for _ in 0..<5 {
            pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        }
        XCTAssertEqual(pager.closed, once)
    }

    // MARK: a depth that came from stored settings

    /// The depth reaches here from `UserDefaults` as a bare `as? Int`, so nothing
    /// between a hand-edited plist and this call checks it.
    func testANegativeDepthDoesNotTrap() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        XCTAssertFalse(pager.closed.isEmpty)
        pager.trim(to: -5)
        XCTAssertTrue(pager.closed.isEmpty)
    }

    func testDepthZeroKeepsNoHistory() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 0, allowCarry: true, fits: fits(5))
        XCTAssertTrue(pager.closed.isEmpty, "history off should still page the live box")
        XCTAssertFalse(pager.currentText.isEmpty)
    }

    func testANegativeDepthKeepsNoHistory() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: -3, allowCarry: true, fits: fits(5))
        XCTAssertTrue(pager.closed.isEmpty)
    }

    /// Lowering the depth while boxes are on screen has to drop the oldest, not
    /// the newest: the stack reads from the live box backwards.
    func testTrimmingKeepsTheNewestBoxes() {
        let (words, starts) = stream(sample)
        var pager = StreamPager()
        pager.ingest(words, chunkStarts: starts, depth: 20, allowCarry: true, fits: fits(5))
        let all = pager.closed
        pager.trim(to: 1)
        XCTAssertEqual(pager.closed, [all.last!])
    }
}
