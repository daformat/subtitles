import XCTest
@testable import CaptionCore

final class TranscriptExportTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func entry(_ text: String, at shown: TimeInterval, last: TimeInterval,
                       under: String = "", app: String? = "Zoom", speaker: Int? = nil) -> TranscriptEntry {
        TranscriptEntry(text: text, under: under, app: app, speaker: speaker,
                        shown: t0.addingTimeInterval(shown), lastWord: t0.addingTimeInterval(last))
    }

    private func render(_ entries: [TranscriptEntry], _ format: TranscriptFormat) -> String {
        TranscriptExport.render(entries, as: format, title: "Transcript") { "Speaker \($0)" }
    }

    func testTimestampIsSubRipsClock() {
        XCTAssertEqual(TranscriptExport.timestamp(0), "00:00:00,000")
        XCTAssertEqual(TranscriptExport.timestamp(3_723.456), "01:02:03,456")
        XCTAssertEqual(TranscriptExport.timestamp(-1), "00:00:00,000")
    }

    func testSRTCuesEndAtTheNextOrAMomentAfterTheLastWord() {
        let srt = render([entry("One", at: 5, last: 6), entry("Two", at: 7, last: 20),
                          entry("Three", at: 60, last: 60)], .srt)
        XCTAssertEqual(srt, """
            1
            00:00:00,000 --> 00:00:02,000
            One

            2
            00:00:02,000 --> 00:00:17,000
            Two

            3
            00:00:55,000 --> 00:00:57,000
            Three

            """)
    }

    func testSRTNamesNoSpeaker() {
        let srt = render([entry("Hi", at: 0, last: 1, speaker: 1),
                          entry("Hello", at: 4, last: 5, speaker: 2)], .srt)
        XCTAssertFalse(srt.contains("Speaker"))
        XCTAssertTrue(srt.contains("\nHi\n"))
        XCTAssertTrue(srt.contains("\nHello\n"))
    }

    func testTextKeepsItsShape() {
        let text = render([entry("Hi", at: 0, last: 1, under: "Salut", speaker: 1),
                           entry("Hello", at: 2, last: 3, speaker: 2)], .text)
        XCTAssertEqual(text, "[Zoom]\n\nSpeaker 1\nHi\nSalut\n\nSpeaker 2\nHello\n")
    }

    func testMarkdownHeadsAppsAndEscapes() {
        let md = render([entry("a *b* [c]", at: 0, last: 1, under: "x_y", speaker: 1)], .markdown)
        XCTAssertEqual(md, "# Transcript\n\n## Zoom\n\n**Speaker 1:** a \\*b\\* \\[c\\]  \n*x\\_y*\n")
    }

    func testANewAppNamesTheSpeakerAgain() {
        let text = render([entry("A", at: 0, last: 1, speaker: 1),
                           entry("B", at: 2, last: 3, app: "Safari", speaker: 1)], .text)
        XCTAssertEqual(text, "[Zoom]\n\nSpeaker 1\nA\n\n[Safari]\n\nSpeaker 1\nB\n")
    }
}
