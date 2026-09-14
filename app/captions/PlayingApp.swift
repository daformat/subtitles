// Which app a box belongs to, when the tap is listening to everything.
//
// A box wears the icon of the app whose audio it transcribed. With one app
// selected as the source that is simply the app; with all system audio it has
// to be worked out from what Core Audio says is playing, and that is noisier
// than it sounds. "Playing" means the process holds an output stream open, not
// that sound is coming out of it: Chromium keeps its stream open for ten
// seconds after the last sound, native players for a couple, so a notification
// ding looks like a ten-second playback, and a browser with a video paused
// looks like a browser playing a video.
//
// So the answer is sticky. Whatever is chosen stays chosen while it plays, and
// nothing else takes the icon unless it has earned it, by one of two rules:
//
//  - by time: it has been playing longer than any ding holds a stream open
//    (`Rules.takeover`), or
//  - by ear: someone listened to it for a moment and heard sustained sound
//    (`judge`), which the monitor does with a short-lived tap on that app when
//    the picker names it as a `candidate`.
//
// Either way an app that started after the pick and has earned it takes over,
// and one heard to be silent never does. When the pick stops, the icon falls to
// the best of the rest — earned before not, and the most recently started among
// equals, since the one that just began is the likelier voice — but never to an
// app heard to be silent. With nothing left at all the last pick is kept: the
// words on screen came from somewhere, and that is the best guess there is.
//
// Here rather than beside the tap so it can be tested. A heuristic with state
// is exactly the kind of thing that regresses in a way nobody notices until
// every box in the stack wears the wrong icon.

import Foundation

public struct PlayingAppPicker: Equatable {
    /// How a newcomer earns the icon while the pick plays on.
    public struct Rules: Equatable {
        /// Seconds an app must have been playing to have earned the icon on
        /// time alone. Infinite when only listening counts.
        public var takeover: TimeInterval
        /// Seconds an app must have been playing before it is worth listening
        /// to, or nil when nobody is going to listen.
        public var probeAfter: TimeInterval?
        /// Seconds after a silent verdict before an app still playing is
        /// listened to again: a burst of dings can become a call.
        public var recheck: TimeInterval

        /// Two seconds in, a ding's own sound is over and whatever is heard
        /// next is what the app is really doing. The thirty seconds are a
        /// backstop for an app nobody managed to listen to: one heard to be
        /// silent never takes over on time, however long it holds its stream.
        ///
        /// Time alone, with a twelve-second bar, was tried against the real
        /// thing and lost: a burst of dings holds a stream open for as long
        /// as the burst lasts, and took the icon for fourteen seconds.
        public static let byEar = Rules(takeover: 30, probeAfter: 2, recheck: 20)

        public init(takeover: TimeInterval, probeAfter: TimeInterval?, recheck: TimeInterval) {
            self.takeover = takeover
            self.probeAfter = probeAfter
            self.recheck = recheck
        }
    }

    /// What listening to an app found.
    public struct Verdict: Equatable {
        public let sustained: Bool
        public let at: TimeInterval
    }

    public let rules: Rules

    /// The app the boxes belong to right now, or nil before anything has played.
    public private(set) var pick: String?

    /// When each playing app's current run of playing began.
    private var since: [String: TimeInterval] = [:]
    /// Verdicts on apps still playing; an app that stops is judged afresh.
    private var verdicts: [String: Verdict] = [:]
    private var playing: [String] = []
    private var now: TimeInterval = 0

    public init(rules: Rules = .byEar) {
        self.rules = rules
    }

    /// Forget everything. For a change of source: what was playing under the old
    /// one says nothing about the new.
    public mutating func reset() {
        pick = nil
        since = [:]
        verdicts = [:]
        playing = []
    }

    /// One poll's worth: the apps playing now, in the tap's order, and when.
    @discardableResult
    public mutating func update(playing: [String], at now: TimeInterval) -> String? {
        var next: [String: TimeInterval] = [:]
        for app in playing { next[app] = since[app] ?? now }
        since = next
        verdicts = verdicts.filter { next[$0.key] != nil }
        self.playing = playing
        self.now = now
        decide()
        return pick
    }

    /// How long an app has been playing, or nil if it is not.
    public func age(of app: String) -> TimeInterval? {
        since[app].map { now - $0 }
    }

    /// The app worth listening to next, if any: one that is not the pick, has
    /// been playing long enough for its own ding to be over, and has not been
    /// heard — or was heard to be silent long enough ago to be worth a second
    /// listen. The most recently started first, since that is the decision at
    /// hand.
    ///
    /// Never the pick. Hearing it silent would only serve to hand over to
    /// something unheard, and the next thing unheard is as likely a ding as a
    /// call: the pick keeps the icon until something else is heard to be
    /// making sound.
    public func candidate() -> String? {
        guard let probeAfter = rules.probeAfter else { return nil }
        let due = playing.filter { app in
            guard app != pick, now - since[app]! >= probeAfter else { return false }
            guard let verdict = verdicts[app] else { return true }
            return !verdict.sustained && now - verdict.at >= rules.recheck
        }
        return due.max(by: { since[$0]! < since[$1]! })
    }

    /// What listening found. Ignored for an app that has stopped since: the
    /// verdict was about a run of playing that is over.
    @discardableResult
    public mutating func judge(_ app: String, sustained: Bool, at now: TimeInterval) -> String? {
        guard since[app] != nil else { return pick }
        verdicts[app] = Verdict(sustained: sustained, at: now)
        self.now = now
        decide()
        return pick
    }

    // MARK: - the rules

    /// Earned the icon (2), not yet (1), or heard to be silent (0). The pick is
    /// never heard, so it is never 0.
    private func rank(_ app: String) -> Int {
        if let verdict = verdicts[app] { return verdict.sustained ? 2 : 0 }
        return now - since[app]! >= rules.takeover ? 2 : 1
    }

    /// Best of a set: the highest rank, and the most recently started among
    /// equals. Ties on both go to the tap's order.
    private func best(of apps: [String]) -> String? {
        apps.max { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : since[a]! < since[b]!
        }
    }

    private mutating func decide() {
        if let pick, since[pick] != nil {
            // The pick plays on. It keeps the icon unless another app outranks
            // it, or has earned it too and started later — the newcomer. Two
            // apps that started together stay with whichever was picked first.
            guard let other = best(of: playing.filter { $0 != pick }) else { return }
            if rank(other) > rank(pick)
                || (rank(other) == 2 && rank(pick) == 2 && since[other]! > since[pick]!) {
                self.pick = other
            }
            return
        }
        // The pick has stopped, or there was none. The best of what is left,
        // never an app heard to be silent; with nothing left the last pick stays.
        if let fallback = best(of: playing.filter { rank($0) > 0 }) { pick = fallback }
    }
}
