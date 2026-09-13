// Which app a box belongs to, under all system audio.
//
// The rules the picker keeps: sticky while the pick plays, slow to hand over so
// a notification sound cannot take the icon, and falling to the most recently
// started app when the pick stops.

import XCTest
@testable import CaptionCore

final class PlayingAppTests: XCTestCase {
    func testTheFirstPollPicksStraightAway() {
        var picker = PlayingAppPicker()
        XCTAssertEqual(picker.update(playing: ["chrome"]), "chrome")
    }

    func testNothingPlayingKeepsTheLastPick() {
        var picker = PlayingAppPicker()
        picker.update(playing: ["chrome"])
        XCTAssertEqual(picker.update(playing: []), "chrome",
                       "the words on screen came from somewhere")
    }

    /// A ding is playing for one poll; a call is playing for two.
    func testANewcomerTakesOverOnlyAfterTwoPolls() {
        var picker = PlayingAppPicker()
        picker.update(playing: ["chrome"])
        XCTAssertEqual(picker.update(playing: ["chrome", "slack"]), "chrome", "one poll: a ding")
        XCTAssertEqual(picker.update(playing: ["chrome"]), "chrome", "and it is gone")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "chrome")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "zoom", "two polls: a call")
    }

    func testThePickStaysWhileItPlays() {
        var picker = PlayingAppPicker()
        picker.update(playing: ["chrome"])
        picker.update(playing: ["chrome", "zoom"])
        picker.update(playing: ["chrome", "zoom"])
        XCTAssertEqual(picker.pick, "zoom")
        // Chrome has been playing longer, and that changes nothing.
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "zoom")
        XCTAssertEqual(picker.update(playing: ["zoom", "chrome"]), "zoom")
    }

    /// The pick stops: of what is left, the app that started most recently is
    /// the likelier voice.
    func testWhenThePickStopsTheMostRecentlyStartedAppFollows() {
        var picker = PlayingAppPicker()
        picker.update(playing: ["chrome"])
        picker.update(playing: ["chrome", "music"])
        XCTAssertEqual(picker.update(playing: ["chrome", "music"]), "music")
        picker.update(playing: ["chrome", "music", "zoom"])
        XCTAssertEqual(picker.update(playing: ["chrome", "music", "zoom"]), "zoom")
        // Zoom stops. Music started after Chrome, so Music it is.
        XCTAssertEqual(picker.update(playing: ["chrome", "music"]), "music")
    }

    /// Two apps that started together: whichever was picked first keeps it,
    /// since neither came after the other.
    func testAppsThatStartedTogetherDoNotSwap() {
        var picker = PlayingAppPicker()
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "chrome")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "chrome")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "chrome")
    }

    /// The pick stops at the very moment a ding plays: the ding does not get the
    /// icon for the poll it lasts.
    func testADingDoesNotCatchTheFallback() {
        var picker = PlayingAppPicker()
        picker.update(playing: ["chrome"])
        picker.update(playing: ["chrome", "music"])
        XCTAssertEqual(picker.update(playing: ["chrome", "music"]), "music")
        XCTAssertEqual(picker.update(playing: ["chrome", "slack"]), "chrome")
    }

    func testResetForgetsThePickAndTheCounts() {
        var picker = PlayingAppPicker()
        picker.update(playing: ["chrome", "zoom"])
        picker.update(playing: ["chrome", "zoom"])
        picker.reset()
        XCTAssertNil(picker.pick)
        // Counts start again: zoom is a newcomer with one poll, not a takeover.
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"]), "chrome")
    }
}
