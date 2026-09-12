// The bundle's third-party notices, reflowed for a window.

import XCTest
@testable import CaptionCore

final class NoticesTests: XCTestCase {
    /// The shapes build.sh's file has: prose, a table, a ruled heading, a
    /// numbered section with a hanging indent, and starred lines.
    private let text = """
        Subtitles — third-party notices

        The speech models are NOT included in this application. They are
        downloaded from HuggingFace on first use and carry their own terms:
          Parakeet EOU, Nemotron Streaming EN  NVIDIA Open Model License
          Silero VAD                           MIT

        ==============================================================================
        FluidAudio — https://github.com/FluidInference/FluidAudio
        ==============================================================================

           2. Grant of Copyright License. Subject to the terms and conditions of
              this License, each Contributor hereby grants to You a perpetual,
              worldwide licence.

        Copyright:
          * Until package version 1.1.23: © 2011 Daniel Müllner
          * All changes from version 1.1.24 on: © Google Inc.
        All rights reserved.
        """

    func testReflowsProseAndKeepsTheRest() {
        XCTAssertEqual(Notices.parse(text), [
            .paragraph("Subtitles — third-party notices"),
            .paragraph("The speech models are NOT included in this application. They are "
                       + "downloaded from HuggingFace on first use and carry their own terms:"),
            .row("Parakeet EOU, Nemotron Streaming EN", "NVIDIA Open Model License"),
            .row("Silero VAD", "MIT"),
            .heading("FluidAudio — https://github.com/FluidInference/FluidAudio"),
            .paragraph("2. Grant of Copyright License. Subject to the terms and conditions of "
                       + "this License, each Contributor hereby grants to You a perpetual, "
                       + "worldwide licence."),
            .paragraph("Copyright:"),
            .bullet("Until package version 1.1.23: © 2011 Daniel Müllner"),
            .bullet("All changes from version 1.1.24 on: © Google Inc."),
            .paragraph("All rights reserved."),
        ])
    }

    func testALoneDoubleSpaceIsNotAColumn() {
        let text = """
            replaced with your own identifying information. (Don't include
            the brackets!)  The text should be enclosed in the appropriate
            comment syntax for the file format.
            """
        XCTAssertEqual(Notices.parse(text), [.paragraph(
            "replaced with your own identifying information. (Don't include the brackets!)  "
            + "The text should be enclosed in the appropriate comment syntax for the file format.")])
    }

    func testCentredTitleLinesStayApart() {
        let text = """
                                             Apache License
                                       Version 2.0, January 2004
                                    http://www.apache.org/licenses/
            """
        XCTAssertEqual(Notices.parse(text), [
            .paragraph("Apache License"),
            .paragraph("Version 2.0, January 2004"),
            .paragraph("http://www.apache.org/licenses/"),
        ])
    }

    func testNothingIsLost() {
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
            .filter { !$0.allSatisfy { $0 == "=" } }
        var kept: [String] = []
        for block in Notices.parse(text) {
            switch block {
            case .heading(let s), .paragraph(let s), .bullet(let s):
                kept += s.split(separator: " ").map(String.init)
            case .row(let a, let b):
                kept += (a + " " + b).split(separator: " ").map(String.init)
            }
        }
        XCTAssertEqual(kept, words.filter { $0 != "*" })
    }
}
