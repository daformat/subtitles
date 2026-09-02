// What may be handed to a translator, and when.
//
// Every case here is one that shipped wrong at some point. The buffer decides
// when a run of words has stopped moving, and getting that wrong is expensive in
// both directions: too eager and the translator is asked about a sentence the
// recogniser is still revising, too patient and the live tail runs for a
// paragraph and nothing ever settles.

import XCTest
@testable import CaptionCore

final class SentenceBufferTests: XCTestCase {
    /// Words half a second apart, as the recogniser delivers them.
    private func words(_ texts: [String], from start: TimeInterval = 0) -> [TimedWord] {
        texts.enumerated().map { index, text in
            let begin = start + Double(index) * 0.5
            return TimedWord(text: text, start: begin, end: begin + 0.4)
        }
    }

    private func texts(_ sentences: [Sentence]) -> [String] { sentences.map(\.text) }

    // MARK: terminators

    func testHoldsAnUnfinishedSentence() {
        var buffer = SentenceBuffer()
        let out = buffer.ingest(words(["I", "gave", "the", "book"]), ended: false)
        XCTAssertTrue(out.isEmpty)
    }

    /// A terminator on the newest word is not yet trustworthy: the next chunk can
    /// still revise it, and a sentence translated twice reads as a rewrite.
    func testTerminatorOnTheNewestWordIsNotEnough() {
        var buffer = SentenceBuffer()
        let out = buffer.ingest(words(["I", "gave", "the", "book", "away."]), ended: false)
        XCTAssertTrue(out.isEmpty)
    }

    func testAWordAfterTheTerminatorReleasesIt() {
        var buffer = SentenceBuffer()
        _ = buffer.ingest(words(["I", "gave", "the", "book", "away."]), ended: false)
        let out = buffer.ingest(words(["I", "gave", "the", "book", "away.", "Then"]), ended: false)
        XCTAssertEqual(texts(out), ["I gave the book away."])
    }

    func testEndpointReleasesTheTrailingFragment() {
        var buffer = SentenceBuffer()
        let out = buffer.ingest(words(["hello", "there"]), ended: true)
        XCTAssertEqual(texts(out), ["hello there"])
    }

    /// The EOU variants emit no punctuation at all, so the endpoint is the only
    /// boundary they ever offer.
    func testUnpunctuatedSpeechStillSettlesAtAnEndpoint() {
        var buffer = SentenceBuffer()
        let run = words(["one", "two", "three", "four", "five", "six"])
        XCTAssertTrue(buffer.ingest(run, ended: false).isEmpty)
        XCTAssertEqual(texts(buffer.ingest(run, ended: true)), ["one two three four five six"])
    }

    /// The multilingual checkpoint punctuates CJK with its own marks.
    func testCJKTerminators() {
        var buffer = SentenceBuffer()
        let out = buffer.ingest(words(["こんにちは。", "お元気", "ですか。"]), ended: true)
        XCTAssertEqual(texts(out), ["こんにちは。", "お元気 ですか。"])
    }

    // MARK: the time-based fallback

    /// Waiting for punctuation was the original design and it did not survive
    /// contact with the model: thirteen unpunctuated words released nothing, so
    /// the live tail ran for a paragraph.
    func testWithoutSettleAfterNothingEverSettles() {
        var buffer = SentenceBuffer()
        let run = words((0..<13).map { "w\($0)" })
        XCTAssertTrue(buffer.ingest(run, ended: false, settleAfter: nil).isEmpty)
        XCTAssertEqual(buffer.released, 0)
    }

    func testAgeSettlesUnpunctuatedSpeech() {
        var buffer = SentenceBuffer()
        let run = words((0..<13).map { "w\($0)" })
        let out = buffer.ingest(run, ended: false, settleAfter: 1)
        XCTAssertFalse(out.isEmpty, "old words should settle without punctuation")
    }

    /// The first attempt at the fallback released a word at a time, which fed the
    /// translator fragments too small to place and read worse than not settling.
    func testAgeNeverReleasesASingleWord() {
        var buffer = SentenceBuffer()
        var accumulated: [TimedWord] = []
        var released: [Sentence] = []
        for index in 0..<20 {
            accumulated.append(contentsOf: words(["w\(index)"], from: Double(index) * 0.5))
            released += buffer.ingest(accumulated, ended: false, settleAfter: 1)
        }
        XCTAssertFalse(released.isEmpty)
        for sentence in released {
            XCTAssertGreaterThanOrEqual(
                sentence.text.split(separator: " ").count, 5,
                "released '\(sentence.text)' is too short to translate on its own")
        }
    }

    /// A clause break is a far better place to cut than mid-phrase, so one in
    /// reach wins over the age limit.
    func testPrefersAClauseBreakOverTheAgeLimit() {
        var buffer = SentenceBuffer()
        let run = words(["quand", "il", "est", "parti,", "nous", "avons", "commencé", "le", "travail"])
        var released: [Sentence] = []
        for count in 1...run.count {
            released += buffer.ingest(Array(run[..<count]), ended: false, settleAfter: 1)
        }
        XCTAssertTrue(released.contains { $0.text.hasSuffix("parti,") },
                      "expected a cut at the comma, got \(texts(released))")
    }

    // MARK: restarts

    /// The recogniser resets its transcript at an endpoint and word times start
    /// again near zero. A stale offset then points into audio that is gone.
    func testAShorterTranscriptIsTreatedAsARestart() {
        var buffer = SentenceBuffer()
        _ = buffer.ingest(words(["one", "two", "three", "four"]), ended: true)
        XCTAssertEqual(buffer.released, 4)
        let out = buffer.ingest(words(["fresh"]), ended: true)
        XCTAssertEqual(texts(out), ["fresh"])
    }
}
