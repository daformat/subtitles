// Which app a box belongs to, under all system audio.
//
// The rules the picker keeps: sticky while the pick plays, a newcomer takes
// over only once it has earned the icon — by playing longer than any ding holds
// a stream open, or by being heard — and when the pick stops the icon falls to
// the best of the rest, never to an app heard to be silent.

import XCTest
@testable import CaptionCore

final class PlayingAppTests: XCTestCase {
    /// The time rule on its own. Not what ships — listening does — but the
    /// backstop is this rule with a longer bar, and it is easier to pin here.
    private let byTime = PlayingAppPicker.Rules(takeover: 12, probeAfter: nil, recheck: 20)

    // MARK: - by time

    func testTheFirstPollPicksStraightAway() {
        var picker = PlayingAppPicker(rules: byTime)
        XCTAssertEqual(picker.update(playing: ["chrome"], at: 0), "chrome")
    }

    func testNothingPlayingKeepsTheLastPick() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        XCTAssertEqual(picker.update(playing: [], at: 1), "chrome",
                       "the words on screen came from somewhere")
    }

    /// Chromium holds its stream open for ten seconds after a ding.
    func testADingDoesNotTakeOverHoweverLongItHoldsTheStream() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        for t in stride(from: 5.0, through: 15.5, by: 0.5) {
            XCTAssertEqual(picker.update(playing: ["chrome", "slack"], at: t), "chrome", "at \(t)")
        }
        XCTAssertEqual(picker.update(playing: ["chrome"], at: 16), "chrome")
    }

    func testACallTakesOverOnceItHasPlayedLongerThanADingCould() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 5)
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 16.9), "chrome", "not yet")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 17), "zoom")
    }

    func testThePickStaysWhileItPlays() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 5)
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 17), "zoom")
        // Chrome has been playing longer, and that changes nothing.
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 60), "zoom")
        XCTAssertEqual(picker.update(playing: ["zoom", "chrome"], at: 61), "zoom")
    }

    /// The pick stops: of what is left, the app that started most recently is
    /// the likelier voice.
    func testWhenThePickStopsTheMostRecentlyStartedAppFollows() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "music"], at: 5)
        XCTAssertEqual(picker.update(playing: ["chrome", "music"], at: 17), "music")
        picker.update(playing: ["chrome", "music", "zoom"], at: 20)
        XCTAssertEqual(picker.update(playing: ["chrome", "music", "zoom"], at: 32), "zoom")
        // Zoom stops. Music started after Chrome, so Music it is.
        XCTAssertEqual(picker.update(playing: ["chrome", "music"], at: 40), "music")
    }

    /// Two apps that started together: whichever was picked first keeps it,
    /// since neither came after the other.
    func testAppsThatStartedTogetherDoNotSwap() {
        var picker = PlayingAppPicker(rules: byTime)
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 0), "chrome")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 12), "chrome")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 30), "chrome")
    }

    /// The pick stops at the very moment a ding plays: an app that has earned
    /// the icon is preferred to one that has not.
    func testADingDoesNotCatchTheFallback() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "music"], at: 5)
        XCTAssertEqual(picker.update(playing: ["chrome", "music"], at: 17), "music")
        XCTAssertEqual(picker.update(playing: ["chrome", "slack"], at: 20), "chrome")
    }

    /// With nothing earned yet the fallback can only guess, and a ding can catch
    /// it; the guess is corrected as soon as something has earned the icon.
    func testAnAppThatHasEarnedTheIconOutranksAPickThatHasNot() {
        var picker = PlayingAppPicker(rules: byTime)
        XCTAssertEqual(picker.update(playing: ["chrome", "music"], at: 0), "chrome")
        picker.update(playing: ["chrome", "music", "slack"], at: 5)
        XCTAssertEqual(picker.update(playing: ["music", "slack"], at: 6), "slack", "a guess")
        XCTAssertEqual(picker.update(playing: ["music", "slack"], at: 11), "slack")
        XCTAssertEqual(picker.update(playing: ["music", "slack"], at: 12), "music", "corrected")
    }

    func testResetForgetsThePickAndTheAges() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome", "zoom"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 30)
        picker.reset()
        XCTAssertNil(picker.pick)
        // Ages start again: neither has earned anything, chrome is first in order.
        XCTAssertEqual(picker.update(playing: ["zoom", "chrome"], at: 31), "zoom")
    }

    func testAgeIsHowLongAnAppHasBeenPlaying() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 3)
        picker.update(playing: ["chrome", "zoom"], at: 10)
        XCTAssertEqual(picker.age(of: "chrome"), 7)
        XCTAssertEqual(picker.age(of: "zoom"), 0)
        XCTAssertNil(picker.age(of: "slack"))
        // A stop and a restart is a new run.
        picker.update(playing: ["zoom"], at: 11)
        picker.update(playing: ["zoom", "chrome"], at: 12)
        XCTAssertEqual(picker.age(of: "chrome"), 0)
    }

    func testByTimeNeverAsksAnyoneToListen() {
        var picker = PlayingAppPicker(rules: byTime)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 5)
        picker.update(playing: ["chrome", "zoom"], at: 9)
        XCTAssertNil(picker.candidate())
    }

    // MARK: - by ear

    /// The backstop: an app nobody managed to listen to takes over on time,
    /// after long enough that no burst of dings is likely to still be going.
    func testByEarAnAppNobodyListenedToTakesOverAfterTheBackstop() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 5)
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 34), "chrome")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 35), "zoom")
    }

    func testByEarAnAppHeardToBeSilentNeverTakesOverOnTime() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "slack"], at: 5)
        picker.judge("slack", sustained: false, at: 8)
        XCTAssertEqual(picker.update(playing: ["chrome", "slack"], at: 600), "chrome")
    }

    /// Nothing to listen to with one app playing; a newcomer once it has been
    /// playing long enough for its own ding to be over.
    func testTheCandidateIsTheNewcomerOnceItIsWorthListeningTo() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        XCTAssertNil(picker.candidate(), "nothing to decide")
        picker.update(playing: ["chrome", "slack"], at: 5)
        XCTAssertNil(picker.candidate(), "its ding is still sounding")
        picker.update(playing: ["chrome", "slack"], at: 7)
        XCTAssertEqual(picker.candidate(), "slack")
    }

    /// Two newcomers: the one that started most recently is the decision at hand.
    func testTheMostRecentNewcomerIsListenedToFirst() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "slack"], at: 5)
        picker.update(playing: ["chrome", "slack", "zoom"], at: 6)
        XCTAssertEqual(picker.update(playing: ["chrome", "slack", "zoom"], at: 8), "chrome")
        XCTAssertEqual(picker.candidate(), "zoom")
    }

    func testASustainedVerdictTakesOver() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 5)
        picker.update(playing: ["chrome", "zoom"], at: 7)
        XCTAssertEqual(picker.judge("zoom", sustained: true, at: 10), "zoom")
        XCTAssertEqual(picker.update(playing: ["chrome", "zoom"], at: 11), "zoom")
    }

    /// A silent verdict keeps the icon where it was; the silent app comes round
    /// again after the recheck interval, since a burst of dings can become a call.
    func testASilentVerdictDoesNotTakeOverAndIsRecheckedLater() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "slack"], at: 5)
        picker.update(playing: ["chrome", "slack"], at: 7)
        XCTAssertEqual(picker.judge("slack", sustained: false, at: 10), "chrome")
        picker.update(playing: ["chrome", "slack"], at: 29)
        XCTAssertNil(picker.candidate(), "judged, and not yet due again")
        picker.update(playing: ["chrome", "slack"], at: 30)
        XCTAssertEqual(picker.candidate(), "slack", "due again")
        XCTAssertEqual(picker.judge("slack", sustained: true, at: 33), "slack", "the burst became a call")
    }

    /// An app that stops is judged afresh when it plays again.
    func testAVerdictIsForgottenWhenTheAppStops() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "slack"], at: 5)
        picker.judge("slack", sustained: false, at: 8)
        picker.update(playing: ["chrome"], at: 10)
        picker.update(playing: ["chrome", "slack"], at: 15)
        picker.update(playing: ["chrome", "slack"], at: 17)
        XCTAssertEqual(picker.candidate(), "slack")
    }

    func testTheFallbackNeverPicksAnAppHeardToBeSilent() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "slack"], at: 5)
        picker.judge("slack", sustained: false, at: 8)
        XCTAssertEqual(picker.update(playing: ["slack"], at: 9), "chrome",
                       "chrome stopped, but slack is only holding a stream open")
    }

    /// The pick is never listened to: hearing it silent could only hand the
    /// icon to something unheard, which is as likely a ding as a call.
    func testThePickIsNeverACandidate() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "slack"], at: 5)
        picker.update(playing: ["chrome", "slack"], at: 7)
        XCTAssertEqual(picker.candidate(), "slack")
        picker.judge("slack", sustained: false, at: 10)
        picker.update(playing: ["chrome", "slack"], at: 11)
        XCTAssertNil(picker.candidate())
    }

    func testJudgingAnAppThatHasStoppedChangesNothing() {
        var picker = PlayingAppPicker(rules: .byEar)
        picker.update(playing: ["chrome"], at: 0)
        picker.update(playing: ["chrome", "zoom"], at: 5)
        picker.update(playing: ["chrome"], at: 8)
        XCTAssertEqual(picker.judge("zoom", sustained: true, at: 9), "chrome")
        picker.update(playing: ["chrome", "zoom"], at: 10)
        picker.update(playing: ["chrome", "zoom"], at: 12)
        XCTAssertEqual(picker.candidate(), "zoom", "the stale verdict did not stick")
    }
}
