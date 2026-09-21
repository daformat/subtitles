// Whether the words one ear heard are the words on screen.
//
// The playing-app monitor listens to an app for a moment and, when there is a
// voice in it, has that moment transcribed on its own. The question is then
// whether those words are the ones the captions are showing, which is what
// decides the name on the box: a song's lyrics are a voice too, and the box
// belongs to whichever app the words on screen come from. Two transcriptions
// of the same speech agree on most of it and disagree on some, one having
// heard a clean feed and the other the mix, so the test is a share, and it is
// taken over content words: the short ones ("the", "and", "you") are in every
// transcript and in every song.
//
// In CaptionCore so it can be tested: the numbers here are the difference
// between a call keeping its name and a playlist taking it.

import Foundation

public enum TranscriptMatch {
    /// Shortest word that counts. A four-letter word is usually a content
    /// word; the three-letter ones are the articles, pronouns and
    /// auxiliaries of every transcript and every song ("the", "you", "can").
    public static let minimumLength = 4
    /// Fewest content words a listen must yield to be judged at all. Below
    /// this a match is luck and no match nothing.
    public static let minimumWords = 3

    /// How much of what was heard was on screen.
    public struct Match: Equatable {
        /// Content words heard that were on screen, out of content words heard.
        public let matched: Int
        public let total: Int
        public var share: Double { Double(matched) / Double(total) }

        public init(matched: Int, total: Int) {
            self.matched = matched
            self.total = total
        }
    }

    /// The content words of `heard` held against those of `shown`, or nil
    /// when there is too little on either side to judge: too few words
    /// heard, or nothing on screen to hold them against.
    public static func compare(heard: [String], shown: [String]) -> Match? {
        let candidates = words(heard)
        let screen = Set(words(shown))
        guard candidates.count >= minimumWords, !screen.isEmpty else { return nil }
        return Match(matched: candidates.filter { screen.contains($0) }.count,
                     total: candidates.count)
    }

    /// The content words of a transcript: lowercased, stripped of anything
    /// that is not a letter or a digit, no shorter than `minimumLength`, and
    /// each once. Repeats count once because a chorus is one claim, not five.
    public static func words(_ transcript: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in transcript {
            let word = raw.lowercased().filter { $0.isLetter || $0.isNumber }
            guard word.count >= minimumLength, seen.insert(word).inserted else { continue }
            out.append(word)
        }
        return out
    }
}
