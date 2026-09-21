// Whether the words one ear heard are the words on screen.

import XCTest
@testable import CaptionCore

final class TranscriptMatchTests: XCTestCase {
    func testTheSameSpeechMatchesWhateverItsCaseAndPunctuation() {
        let heard = ["The", "committee", "met", "on", "Tuesday", "to", "review", "the", "proposal."]
        let shown = ["the", "committee", "met", "on", "tuesday,", "to", "review", "the", "proposal"]
        let match = TranscriptMatch.compare(heard: heard, shown: shown)
        XCTAssertEqual(match, TranscriptMatch.Match(matched: 4, total: 4),
                       "committee, tuesday, review, proposal; not the, met, on, to")
        XCTAssertEqual(match?.share, 1)
    }

    /// Lyrics under a call: a voice, and not the one on screen.
    func testOtherWordsDoNotMatch() {
        let heard = ["Hey", "ya,", "shake", "it", "like", "a", "Polaroid", "picture"]
        let shown = ["The", "committee", "met", "on", "Tuesday", "to", "review", "the", "proposal"]
        XCTAssertEqual(TranscriptMatch.compare(heard: heard, shown: shown),
                       TranscriptMatch.Match(matched: 0, total: 4))
    }

    /// Two runs of the same recognizer disagree on a word here and there.
    func testAShareIsAShare() {
        let heard = ["The", "committee", "met", "on", "Thursday", "to", "reviewed", "the", "proposal"]
        let shown = ["The", "committee", "met", "on", "Tuesday", "to", "review", "the", "proposal"]
        let match = TranscriptMatch.compare(heard: heard, shown: shown)
        XCTAssertEqual(match, TranscriptMatch.Match(matched: 2, total: 4),
                       "committee and proposal; not thursday or reviewed")
        XCTAssertEqual(match!.share, 0.5, accuracy: 0.001)
    }

    /// "Hi, can you hear me?" has one content word: nothing to judge on.
    func testTooFewContentWordsIsNoJudgment() {
        XCTAssertNil(TranscriptMatch.compare(heard: ["Hi,", "can", "you", "hear", "me?"],
                                             shown: ["hear"]))
        XCTAssertNil(TranscriptMatch.compare(heard: [], shown: ["anything"]))
    }

    /// Nothing on screen is nothing to hold the words against, not a miss:
    /// the captions may be lagging, or gated, or drowned.
    func testAnEmptyScreenIsNoJudgment() {
        let heard = ["After", "a", "long", "discussion", "they", "agreed"]
        XCTAssertNil(TranscriptMatch.compare(heard: heard, shown: []))
        XCTAssertNil(TranscriptMatch.compare(heard: heard, shown: ["a", "the", "of"]))
    }

    /// A chorus is one claim, not five: the repeats count once, so a song
    /// that repeats a word the screen happens to show does not match on it.
    func testRepeatsCountOnce() {
        let heard = ["Business,", "business,", "business,", "business,", "time", "again"]
        XCTAssertEqual(TranscriptMatch.words(heard), ["business", "time", "again"])
        XCTAssertEqual(TranscriptMatch.compare(heard: heard, shown: ["business"]),
                       TranscriptMatch.Match(matched: 1, total: 3))
    }

    func testShortWordsAndPunctuationAreNotContent() {
        XCTAssertEqual(TranscriptMatch.words(["I", "am", "the", "--", "...", "sure!", "42", "it's"]),
                       ["sure"])
    }

    /// Letters are letters in any script.
    func testAccentsAndOtherScriptsKeepTheirLetters() {
        XCTAssertEqual(TranscriptMatch.words(["Réunion", "über", "привет", "日本語です"]),
                       ["réunion", "über", "привет", "日本語です"])
    }
}
