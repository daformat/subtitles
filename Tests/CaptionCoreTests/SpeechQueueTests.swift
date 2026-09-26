// The queue behind the voice that reads the translation: joined when taken,
// and nothing ever dropped.

import XCTest
@testable import CaptionCore

final class SpeechQueueTests: XCTestCase {
    func testTakesEverythingWaitingAsOneUtterance() {
        var queue = SpeechQueue()
        queue.add("Hello there.")
        queue.add("  How are you?  ")
        XCTAssertEqual(queue.next(), "Hello there. How are you?")
        XCTAssertNil(queue.next())
    }

    func testIgnoresBlankText() {
        var queue = SpeechQueue()
        queue.add("   ")
        queue.add("")
        XCTAssertNil(queue.next())
    }

    func testNeverDropsAnything() {
        let long = Array(repeating: "word", count: 60).joined(separator: " ")
        var queue = SpeechQueue()
        for n in 0..<10 { queue.add("\(n) " + long) }
        XCTAssertEqual(queue.pending.count, 10)
        XCTAssertTrue(queue.next()!.hasPrefix("0 word"))
    }

    func testCountsWordsAndIdeographs() {
        XCTAssertEqual(SpeechQueue.duration(of: "one two, three!"), 3 / 2.8, accuracy: 0.001)
        XCTAssertEqual(SpeechQueue.duration(of: "l'homme"), 2 / 2.8, accuracy: 0.001)
        XCTAssertEqual(SpeechQueue.duration(of: "今日はいい天気"), 7 / 5.0, accuracy: 0.001)
        XCTAssertEqual(SpeechQueue.duration(of: "iPhone 15を買った"), 2 / 2.8 + 4 / 5.0, accuracy: 0.001)
    }
}
