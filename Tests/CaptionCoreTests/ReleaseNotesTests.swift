// The appcast's release notes, read back into runs a native window can set.

import XCTest
@testable import CaptionCore

final class ReleaseNotesTests: XCTestCase {
    /// What tools/changelog-notes.py emits, wrapped as the changelog wraps.
    private let fragment = """
        <h2>1.5.0 · 2026-09-07</h2>
        <ul>
          <li>The app can update itself. <strong>Check for Updates…</strong> in the menu bar asks
        subtitles-live.com for a newer version.</li>
          <li><code>--feed URL</code> points the check at another appcast &amp; nothing else.</li>
        </ul>
        """

    func testReadsHeadingAndItems() {
        let notes = ReleaseNotes(html: fragment)
        XCTAssertEqual(notes.heading, "1.5.0 · 2026-09-07")
        XCTAssertEqual(notes.items.count, 2)
        XCTAssertTrue(notes.items.allSatisfy(\.bulleted))
    }

    func testKeepsEmphasisAsRuns() {
        let notes = ReleaseNotes(html: fragment)
        XCTAssertEqual(notes.items[0].runs, [
            .init("The app can update itself. "),
            .init("Check for Updates…", bold: true),
            .init(" in the menu bar asks subtitles-live.com for a newer version."),
        ])
        XCTAssertEqual(notes.items[1].runs, [
            .init("--feed URL", code: true),
            .init(" points the check at another appcast & nothing else."),
        ])
    }

    func testCollapsesTheChangelogsLineWrapping() {
        let notes = ReleaseNotes(html: "<li>one\n  two\n\n three</li>")
        XCTAssertEqual(notes.items.first?.text, "one two three")
    }

    func testUnknownTagsLoseTheirMarkupNotTheirWords() {
        let notes = ReleaseNotes(html: "<li>See <a href=\"https://x\">the site</a> <em>now</em>.</li>")
        XCTAssertEqual(notes.items.first?.text, "See the site now.")
        XCTAssertEqual(notes.items.first?.runs.count, 1)
    }

    func testParagraphsOutsideAListAreNotBulleted() {
        let notes = ReleaseNotes(html: "<p>A note.</p><ul><li>An item.</li></ul>")
        XCTAssertEqual(notes.items.map(\.bulleted), [false, true])
    }

    func testBareTextIsAParagraph() {
        let notes = ReleaseNotes(html: "Just words, no tags.")
        XCTAssertNil(notes.heading)
        XCTAssertEqual(notes.items, [.init([.init("Just words, no tags.")], bulleted: false)])
    }

    func testEntities() {
        let notes = ReleaseNotes(html: "<li>a &lt; b &gt; c &quot;d&quot; &#39;e&#39; &#x2014; &nbsp;f</li>")
        XCTAssertEqual(notes.items.first?.text, "a < b > c \"d\" 'e' — \u{00A0}f")
    }

    func testEmpty() {
        XCTAssertTrue(ReleaseNotes(html: "").isEmpty)
        XCTAssertTrue(ReleaseNotes(html: "<ul></ul>").isEmpty)
    }
}
