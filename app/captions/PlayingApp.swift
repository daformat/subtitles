// Which app a box belongs to, when the tap is listening to everything.
//
// A box wears the icon of the app whose audio it transcribed. With one app
// selected as the source that is simply the app; with all system audio it has
// to be worked out from what Core Audio says is playing, and that is noisier
// than it sounds. Browsers hold the audio device open long after a video is
// paused, so "playing" is a set of a few apps rather than the one making the
// noise, and a notification sound is an app playing for half a second.
//
// So the answer is sticky and slow to change. Whatever is chosen stays chosen
// while it plays, and nothing else takes over unless it has been playing for
// two polls running: a ding is gone before its second poll, while a call or a
// video that starts is still there. When the chosen app stops, the pick falls
// to whichever of the rest started most recently, since the one that just
// began is the likelier voice. With nothing playing at all the last pick is
// kept: the words on screen came from somewhere, and that is the best guess
// there is.
//
// Here rather than beside the tap so it can be tested. A heuristic with state
// is exactly the kind of thing that regresses in a way nobody notices until
// every box in the stack wears the wrong icon.

import Foundation

public struct PlayingAppPicker: Equatable {
    /// The app the boxes belong to right now, or nil before anything has played.
    public private(set) var pick: String?

    /// How many consecutive polls each playing app has been seen for.
    private var seen: [String: Int] = [:]

    /// Polls a newcomer must be playing for before it takes over.
    private static let takeover = 2

    public init() {}

    /// Forget everything. For a change of source: what was playing under the old
    /// one says nothing about the new.
    public mutating func reset() {
        pick = nil
        seen = [:]
    }

    /// One poll's worth: the apps playing now, in the tap's order.
    @discardableResult
    public mutating func update(playing: [String]) -> String? {
        var next: [String: Int] = [:]
        for app in playing { next[app] = (seen[app] ?? 0) + 1 }
        seen = next

        // Anything that has outlasted a ding.
        let established = playing.filter { seen[$0]! >= Self.takeover }

        if let pick, let age = seen[pick] {
            // The pick plays on. It keeps the icon unless something that started
            // after it has now been playing long enough to be more than a ding.
            // Two apps that started together stay with whichever was picked
            // first: neither is the newcomer.
            if age > Self.takeover,
               let newcomer = established.first(where: { seen[$0] == Self.takeover }) {
                self.pick = newcomer
            }
            return self.pick
        }
        // The pick has stopped, or there was none. The most recently started of
        // what is left, preferring anything that has outlasted a ding; with
        // nothing left at all the last pick stays.
        let candidates = established.isEmpty ? playing : established
        if let fallback = candidates.min(by: { seen[$0]! < seen[$1]! }) { pick = fallback }
        return pick
    }
}
