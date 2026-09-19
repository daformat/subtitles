// One rendering of the transcript in the target language, as the translation
// pipeline hands it to the overlay.

import Foundation

public struct TranslatedTranscript {
    /// The translation, timed over the speech it renders: each sentence's
    /// words spread across that sentence's span.
    public let words: [TimedWord]
    /// The audio time the unsettled tail begins at; `.greatestFiniteMagnitude`
    /// once everything has settled.
    public let speculativeFrom: TimeInterval
    /// Where each settled sentence's words begin, for a page break to carry from.
    public let chunkStarts: [TimeInterval]
    /// The transcript this was made from, as spoken. The original to show under
    /// the translation is drawn from here, matched to the page by span — never
    /// from whatever the recogniser has said since, which may already be the
    /// next utterance in another language.
    public let source: [TimedWord]
    /// After the utterance's end: this settles the page on screen rather than
    /// beginning the next, and must reach that page.
    public let settlesUtterance: Bool

    public init(words: [TimedWord], speculativeFrom: TimeInterval, chunkStarts: [TimeInterval],
                source: [TimedWord], settlesUtterance: Bool) {
        self.words = words
        self.speculativeFrom = speculativeFrom
        self.chunkStarts = chunkStarts
        self.source = source
        self.settlesUtterance = settlesUtterance
    }

    /// Whether two texts are the same words, whatever their case and
    /// punctuation — or near enough to be a translation that came back as its
    /// own original: a translator asked to render a language into itself drops
    /// or adds an article and hands the rest back as it was, so most of the
    /// words in common is already the same language twice, where a real
    /// translation shares a name or a number. Three words at least before
    /// overlap counts: a name shared by a two-word original and its
    /// translation is not the same language.
    public static func sameWords(_ a: String, _ b: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        guard min(x.count, y.count) >= 3 else { return false }
        let common = Set(x).intersection(y).count
        return Double(common) / Double(max(x.count, y.count)) >= 0.6
    }
}
