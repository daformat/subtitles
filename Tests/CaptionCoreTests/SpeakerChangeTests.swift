// A change of speaker, named late.
//
// The diarizer reports a change a second or two after the new speaker began,
// by which time their first words are drawn at the end of the outgoing box, or
// have closed with it into the stack. The change carries the time it began, and
// those words are moved to the box that follows.

import XCTest
@testable import CaptionCore

final class SpeakerChangeTests: XCTestCase {
    private func fits(_ capacity: Int) -> ([TimedWord]) -> Int {
        { words in min(capacity, words.count) }
    }

    /// One word a second, each half a second long, from `from`.
    private func words(_ texts: [String], from: TimeInterval = 0) -> [TimedWord] {
        texts.enumerated().map { index, text in
            TimedWord(text: text, start: from + Double(index), end: from + Double(index) + 0.5)
        }
    }

    private func ingest(_ pager: inout StreamPager, _ words: [TimedWord], capacity: Int = 10,
                        speculativeFrom: TimeInterval = .greatestFiniteMagnitude,
                        chunkStarts: [TimeInterval] = []) {
        pager.ingest(words, chunkStarts: chunkStarts, depth: 20, allowCarry: false,
                     speculativeFrom: speculativeFrom, fits: fits(capacity))
    }

    /// The new speaker's first words are on the outgoing page: they leave it,
    /// and open the next.
    func testChangeInsideThePageMovesTheNewSpeakersWordsToTheNextBox() {
        let spoken = words(["so", "that", "is", "it", "well", "actually"])
        var pager = StreamPager()
        ingest(&pager, spoken)
        XCTAssertEqual(pager.currentText, "so that is it well actually")

        pager.markSpeakerChange(at: 3.9)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, ["so that is it"])
        XCTAssertEqual(pager.currentText, "well actually")
        XCTAssertNil(pager.revisedFrom, "nothing that had closed was changed")
    }

    /// The outgoing page overflowed with the new speaker's first word on it
    /// before the change was known: the stack's box gives it back, and the
    /// page on screen begins with it.
    func testChangeBeforeThePageTakesTheWordsBackFromTheClosedBox() {
        let spoken = words(["so", "that", "is", "well", "I", "think"])
        var pager = StreamPager()
        ingest(&pager, spoken, capacity: 4)
        XCTAssertEqual(pager.closed, ["so that is well"])
        XCTAssertEqual(pager.currentText, "I think")

        pager.markSpeakerChange(at: 2.9)
        ingest(&pager, spoken, capacity: 4)
        XCTAssertEqual(pager.closed, ["so that is"])
        XCTAssertEqual(pager.currentText, "well I think")
        XCTAssertEqual(pager.revisedFrom, 0)
        XCTAssertEqual(pager.closedCount, 1)
        XCTAssertEqual(pager.boxes.last?.end, 2.5)
    }

    /// The box faded before the change was known and nothing is on screen to
    /// take the new speaker's words: they become a box of their own.
    func testChangeAfterAFadeSplitsTheBox() {
        let spoken = words(["so", "that", "is", "yes"])
        var pager = StreamPager()
        ingest(&pager, spoken)
        pager.close(depth: 20)
        XCTAssertEqual(pager.closed, ["so that is yes"])

        pager.markSpeakerChange(at: 2.9)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, ["so that is", "yes"])
        XCTAssertEqual(pager.currentText, "", "a faded page does not come back")
        XCTAssertEqual(pager.revisedFrom, 0)
        XCTAssertEqual(pager.closedCount, 2)
    }

    /// A box wholly after the change goes back whole, and the one it follows
    /// keeps what came before.
    func testChangeReachesBackAcrossMoreThanOneBox() {
        let spoken = words(["a", "b", "c", "d", "e", "f", "g"])
        var pager = StreamPager()
        ingest(&pager, spoken, capacity: 2)
        XCTAssertEqual(pager.closed, ["a b", "c d", "e f"])
        XCTAssertEqual(pager.currentText, "g")

        pager.markSpeakerChange(at: 2.9)
        ingest(&pager, spoken, capacity: 2)
        XCTAssertEqual(pager.closed, ["a b", "c", "d e"])
        XCTAssertEqual(pager.currentText, "f g")
        XCTAssertEqual(pager.revisedFrom, 1)
    }

    /// A change the recognizer has no words for yet waits for them rather than
    /// breaking at the newest word.
    func testChangeWaitsForTheNewSpeakersWords() {
        var pager = StreamPager()
        let first = words(["so", "that", "is", "it"])
        ingest(&pager, first)
        pager.markSpeakerChange(at: 4.9)
        ingest(&pager, first)
        XCTAssertEqual(pager.closed, [])

        let more = first + words(["and", "yes"], from: 4)
        ingest(&pager, more)
        XCTAssertEqual(pager.closed, ["so that is it and"])
        XCTAssertEqual(pager.currentText, "yes")
    }

    /// Only settled words are broken on: a change inside the unsettled tail
    /// waits for it to settle.
    func testChangeWaitsForTheTailToSettle() {
        var pager = StreamPager()
        let spoken = words(["so", "that", "is", "well", "I"])
        pager.markSpeakerChange(at: 2.9)
        ingest(&pager, spoken, speculativeFrom: 2)
        XCTAssertEqual(pager.closed, [])
        ingest(&pager, spoken, speculativeFrom: 4)
        XCTAssertEqual(pager.closed, ["so that is"])
        XCTAssertEqual(pager.currentText, "well I")
    }

    /// With settled clauses to break on, a change close to one breaks there
    /// rather than inside the sentence.
    func testChangeSnapsToANearbyClause() {
        var pager = StreamPager()
        let spoken = words(["so", "that", "is", "well", "I"])
        pager.markSpeakerChange(at: 3.4)
        ingest(&pager, spoken, chunkStarts: [0, 3])
        XCTAssertEqual(pager.closed, ["so that is"])
    }

    /// The recognizer's clock restarts at an endpoint. A change on the new
    /// clock never reaches a box from the run before it, whatever its times.
    func testChangeLeavesBoxesFromAnEarlierClockAlone() {
        var pager = StreamPager()
        let before = words((0..<9).map { "old\($0)" })
        ingest(&pager, before)
        pager.markFresh()
        let after = words(["a", "b", "c", "d"])
        ingest(&pager, after, capacity: 3)
        XCTAssertEqual(pager.closed.first?.hasPrefix("old0"), true)
        let boxesBefore = pager.boxes.count

        // The whole of the new clock's box goes back, and the walk reaches the
        // box before it, which ends long after the change on its own clock.
        pager.markSpeakerChange(at: 0.1)
        ingest(&pager, after, capacity: 3)
        XCTAssertEqual(pager.boxes.first?.text, "old0 old1 old2 old3 old4 old5 old6 old7 old8")
        XCTAssertEqual(pager.boxes.count, boxesBefore)
        XCTAssertEqual(pager.closed.last, "a b c")
        XCTAssertEqual(pager.currentText, "d")
    }

    /// A change timed on the clock before a restart is dropped with it.
    func testRestartForgetsPendingChanges() {
        var pager = StreamPager()
        ingest(&pager, words(["so", "that", "is", "it"], from: 20))
        pager.markSpeakerChange(at: 10)
        let restarted = words(Array(0..<20).map { "w\($0)" })
        ingest(&pager, restarted, capacity: 100)
        XCTAssertEqual(pager.currentText.split(separator: " ").count, 20)
    }

    private func timed(_ spans: [(String, TimeInterval, TimeInterval)]) -> [TimedWord] {
        spans.map { TimedWord(text: $0.0, start: $0.1, end: $0.2) }
    }

    /// Measured on a call: the diarizer put the change at 38.56 s, half a
    /// second after the new speaker's "I" began. The pause before it is where
    /// the turn is, and "I had" leaves the outgoing box.
    func testChangeNamedLateBreaksAtThePauseBeforeIt() {
        let spoken = timed([("else's", 35.9, 36.3), ("one", 36.3, 36.4), ("depending", 36.4, 36.72),
                            ("on", 36.8, 37.0), ("I", 38.08, 38.14), ("had", 38.16, 38.4),
                            ("a", 38.45, 38.5), ("look", 38.6, 38.9), ("at", 38.95, 39.1)])
        var pager = StreamPager()
        ingest(&pager, spoken)
        pager.markSpeakerChange(at: 38.56)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, ["else's one depending on"])
        XCTAssertEqual(pager.currentText, "I had a look at")
    }

    /// And the other way: named at 93.36 s, inside the outgoing speaker's last
    /// word. The pause after it is where the turn is, and "degree" stays.
    func testChangeNamedEarlyBreaksAtThePauseAfterIt() {
        let spoken = timed([("to", 92.7, 92.85), ("some", 92.9, 93.2), ("degree", 93.28, 93.6),
                            ("what", 94.0, 94.2), ("about", 94.25, 94.5), ("like", 94.55, 94.7)])
        var pager = StreamPager()
        ingest(&pager, spoken)
        pager.markSpeakerChange(at: 93.36)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, ["to some degree"])
        XCTAssertEqual(pager.currentText, "what about like")
    }

    /// The box closed on its own before the change could be placed: the words
    /// before the pause are still taken back out of it.
    func testChangeFoundAfterTheBoxClosedStillReachesIt() {
        let first = timed([("depending", 36.4, 36.72), ("on", 36.8, 37.0),
                           ("I", 38.08, 38.14), ("had", 38.16, 38.4)])
        var pager = StreamPager()
        ingest(&pager, first)
        pager.markSpeakerChange(at: 38.56)
        ingest(&pager, first)
        XCTAssertEqual(pager.closed, [], "nothing past the change to choose with yet")
        pager.close(depth: 20)
        XCTAssertEqual(pager.closed, ["depending on I had"])

        let more = first + timed([("a", 38.45, 38.5), ("look", 38.6, 38.9), ("at", 38.95, 39.1)])
        ingest(&pager, more)
        XCTAssertEqual(pager.closed, ["depending on"])
        XCTAssertEqual(pager.currentText, "I had a look at")
    }

    /// A sentence's end near the change wins over a wider gap: the
    /// recognizer's word ends run short, and "Friday." looked closer to the
    /// word after it than it was.
    func testChangeBreaksAtASentenceEndOverAWiderGap() {
        let spoken = timed([("somehow", 12.08, 12.4), ("before", 12.56, 12.7),
                            ("Friday.", 12.96, 13.5), ("What", 13.68, 13.8),
                            ("about", 13.84, 13.95), ("the", 14.0, 14.1), ("keynote", 14.16, 14.5)])
        var pager = StreamPager()
        pager.markSpeakerChange(at: 13.76)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, ["somehow before Friday."])
        XCTAssertEqual(pager.currentText, "What about the keynote")
    }

    /// An endpoint straight after a turn restarts the clock before any word
    /// past the change arrives. The change is placed on the words there were,
    /// and the new speaker's first words close as a box of their own.
    func testChangeWaitingAtAnEndpointIsPlacedBeforeTheClockRestarts() {
        let spoken = timed([("move", 20.56, 20.7), ("on.", 20.72, 20.9),
                            ("Sure,", 21.44, 21.8), ("I", 22.0, 22.05), ("can", 22.08, 22.1)])
        var pager = StreamPager()
        ingest(&pager, spoken)
        pager.markSpeakerChange(at: 21.76)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, [], "waiting for words past the change")

        pager.markFresh()
        ingest(&pager, timed([("draft", 0.2, 0.5), ("that", 0.6, 0.8)]))
        XCTAssertEqual(pager.closed, ["move on.", "Sure, I can"])
        XCTAssertEqual(pager.currentText, "draft that")
    }

    /// The same words paged twice after a change break once.
    func testChangeIsAppliedOnce() {
        let spoken = words(["so", "that", "is", "it", "well"])
        var pager = StreamPager()
        pager.markSpeakerChange(at: 3.9)
        ingest(&pager, spoken)
        ingest(&pager, spoken)
        ingest(&pager, spoken)
        XCTAssertEqual(pager.closed, ["so that is it"])
        XCTAssertEqual(pager.currentText, "well")
    }
}
