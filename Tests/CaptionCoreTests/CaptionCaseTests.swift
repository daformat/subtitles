// Case repair on translated fragments.
//
// Each settled chunk is translated as its own request, and the framework
// capitalises anything it is handed: it has no way to know the chunk began
// mid-sentence. Every settle boundary therefore read as a new sentence.

import XCTest
@testable import CaptionCore

final class CaptionCaseTests: XCTestCase {
    func testLowerCasesAFragmentThatBeganMidSentence() {
        XCTAssertEqual(
            CaptionCase.matchingLeading("At the store yesterday", to: "au magasin hier"),
            "at the store yesterday")
    }

    func testLeavesARealSentenceStartAlone() {
        XCTAssertEqual(
            CaptionCase.matchingLeading("I went to the store.", to: "Je suis allé au magasin."),
            "I went to the store.")
    }

    func testLeavesAnAcronymAlone() {
        XCTAssertEqual(CaptionCase.matchingLeading("OK", to: "ok"), "OK")
        XCTAssertEqual(CaptionCase.matchingLeading("NASA said so", to: "nasa l'a dit"),
                       "NASA said so")
    }

    func testOnlyTheFirstCharacterIsTouched() {
        XCTAssertEqual(CaptionCase.matchingLeading("The API is broken", to: "l'API est cassée"),
                       "the API is broken")
        XCTAssertEqual(CaptionCase.matchingLeading("We saw Paris", to: "nous avons vu Paris"),
                       "we saw Paris")
    }

    func testEmptyInputsAreSafe() {
        XCTAssertEqual(CaptionCase.matchingLeading("", to: "abc"), "")
        XCTAssertEqual(CaptionCase.matchingLeading("Abc", to: ""), "Abc")
    }
}
