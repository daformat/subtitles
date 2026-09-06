import XCTest
@testable import CaptionCore

final class HistorySearchTests: XCTestCase {
    func testCaseIsIgnored() {
        XCTAssertTrue(HistorySearch.matches("The Quick Brown Fox", query: "quick"))
        XCTAssertTrue(HistorySearch.matches("the quick brown fox", query: "QUICK"))
    }

    func testDiacriticsAreIgnoredBothWays() {
        XCTAssertTrue(HistorySearch.matches("Un été à Zürich", query: "ete"))
        XCTAssertTrue(HistorySearch.matches("Un ete a Zurich", query: "Zürich"))
    }

    func testEmptyQueryMatchesEverythingAndHighlightsNothing() {
        XCTAssertTrue(HistorySearch.matches("anything", query: ""))
        XCTAssertEqual(HistorySearch.ranges(of: "", in: "anything"), [])
    }

    func testEveryOccurrenceIsRanged() {
        let ranges = HistorySearch.ranges(of: "an", in: "An apple and a banana")
        XCTAssertEqual(ranges.map(\.location), [0, 9, 16, 18])
        XCTAssertTrue(ranges.allSatisfy { $0.length == 2 })
    }

    func testRangesAreUTF16ForAttributedStrings() {
        let text = "café au lait"
        let ranges = HistorySearch.ranges(of: "au", in: text)
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual((text as NSString).substring(with: ranges[0]), "au")
    }

    func testNoMatchIsEmpty() {
        XCTAssertFalse(HistorySearch.matches("nothing here", query: "xyz"))
        XCTAssertEqual(HistorySearch.ranges(of: "xyz", in: "nothing here"), [])
    }
}
