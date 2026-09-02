import Foundation

/// A complete sentence, with the span of audio it was spoken over.
public struct Sentence: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    /// Stable across the repeated full-transcript callbacks that deliver it.
    /// Start time alone is not enough — a revision can rewrite a sentence without
    /// moving its first word — so the text takes part in the identity too.
    public var id: String { "\(start.rounded(toPlaces: 2))|\(text)" }
}

/// Splits the running transcript into sentences that are safe to translate.
///
/// Fed the *whole* transcript each time, like `showWords` is, and returns only
/// what has newly become stable.
public struct SentenceBuffer {
    public init() {}

    /// Characters that end a sentence, including the CJK forms — the multilingual
    /// checkpoint emits `。` and `？` for Japanese and Chinese, not the ASCII ones.
    private static let terminators: Set<Character> = [
        ".", "!", "?", "…", "。", "！", "？", "؟",
    ]

    /// How far into the transcript has already been released.
    private var consumed = 0

    /// Word count already handed out as settled sentences. Everything after this
    /// is the sentence in progress — which is what the live modes translate.
    public var released: Int { consumed }

    /// Weaker boundaries, used only by the time-based fallback below. A clause
    /// break is a much better place to cut than mid-phrase, and these are the
    /// marks that reliably indicate one.
    private static let softBreaks: Set<Character> = [",", ";", ":", "、", "，", "；"]

    /// Fewest words the time-based fallback will release as a chunk when there is
    /// no punctuation to cut at. Below roughly this, a fragment carries too little
    /// for the translator to place it — subject with no verb, preposition with no
    /// object — and reads worse than the live tail it replaced.
    private static let minSettleWords = 5

    /// Newly stable sentences. `ended` is set at an endpoint or a pause, which
    /// releases the trailing fragment even without a terminator.
    ///
    /// `settleAfter` releases text that has simply got old, independently of
    /// punctuation. Waiting for a terminator turned out to be the wrong bet in
    /// practice: the multilingual checkpoint punctuates unreliably enough that the
    /// live tail could run for the length of a paragraph and never settle at all.
    /// With this, anything spoken longer ago than `settleAfter` is released — at a
    /// terminator if there is one in reach, at a clause break otherwise, and
    /// failing both simply at the age limit.
    public mutating func ingest(_ words: [TimedWord], ended: Bool,
                         settleAfter: TimeInterval? = nil) -> [Sentence] {
        // A transcript that has got shorter is a restarted transcript, not a
        // revised one — the engine has reset and the old offset points into audio
        // that no longer exists. `showWords` keys on the same event.
        if words.count < consumed { consumed = 0 }
        guard consumed < words.count else { return [] }

        var out: [Sentence] = []
        var start = consumed
        var index = consumed

        while index < words.count {
            let isLast = index == words.count - 1
            let terminated = words[index].text.last.map(Self.terminators.contains) ?? false
            // A terminator on the final word is not yet trustworthy unless the
            // utterance is over: the next chunk may still revise it.
            let stable = terminated && (!isLast || ended)
            if stable || (isLast && ended) {
                let slice = Array(words[start...index])
                if let sentence = Self.make(slice) { out.append(sentence) }
                start = index + 1
                consumed = start
            }
            index += 1
        }

        // Punctuation-independent fallback, applied to whatever the loop above
        // left behind.
        if let settleAfter, !ended, consumed < words.count, let newest = words.last {
            let cutoff = newest.end - settleAfter
            var limit = -1
            var scan = consumed
            while scan < words.count, words[scan].end <= cutoff {
                limit = scan
                scan += 1
            }
            if limit >= consumed {
                // Age alone is not enough to cut on. Settling the moment the
                // oldest word crosses the line releases it on its own, and the
                // next one a beat later, so the translator is handed one or two
                // words at a time — worse than not settling at all. Cut at a
                // boundary if the aged region contains one, and otherwise only
                // once there is enough of it to stand as a phrase.
                let cut = Self.boundary(in: words, from: consumed, through: limit)
                let enough = limit - consumed + 1 >= Self.minSettleWords
                if let at = cut ?? (enough ? limit : nil),
                   let sentence = Self.make(Array(words[consumed...at])) {
                    out.append(sentence)
                    consumed = at + 1
                }
            }
        }
        return out
    }

    /// The latest decent place to cut, at or before `through`. Terminators are
    /// preferred over clause breaks; nil means neither is present and the caller
    /// should cut at the age limit.
    private static func boundary(in words: [TimedWord], from: Int, through: Int) -> Int? {
        for marks in [terminators, softBreaks] {
            var index = through
            while index >= from {
                if let last = words[index].text.last, marks.contains(last) { return index }
                index -= 1
            }
        }
        return nil
    }

    private static func make(_ words: [TimedWord]) -> Sentence? {
        let text = words.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let first = words.first, let last = words.last else { return nil }
        return Sentence(text: text, start: first.start, end: last.end)
    }

    public mutating func reset() { consumed = 0 }
}

/// How much the translator is allowed to guess ahead of the speaker.
///
/// Measured on this machine, translating a sentence costs 40–125 ms and barely
/// varies with length, so neither of these is chosen for throughput — the choice
/// is entirely about what the reader is shown while a sentence is still being
/// spoken, and both are affordable.
///
/// A third mode, which showed nothing until a sentence was finished, was tried
/// and dropped: waiting for a terminator is not a subtitle experience, and the
/// multilingual checkpoint punctuates too unreliably to hang a mode on.
public enum TranslationMode: String, CaseIterable, Sendable {
    /// Settled text stays put; the last second or so of speech is translated on
    /// every update and shown dimmed. Near-zero lag, and the tail visibly churns —
    /// worst where the verb comes last, since the German or Japanese reading can
    /// invert when it finally lands.
    case hybrid
    /// The whole visible transcript is retranslated every update, so even text
    /// that already looked settled can change. What a naive implementation does,
    /// and viable in practice on close language pairs.
    case speculative

    public var displayName: String {
        switch self {
        case .hybrid: return "Live, Then Settle"
        case .speculative: return "Always Live"
        }
    }

    public var note: String {
        switch self {
        case .hybrid: return "tail is dimmed until it settles · recommended"
        case .speculative: return "no lag · anything on screen may change"
        }
    }
}

/// Case repair for text that came back from a translator.
public enum CaptionCase {
    /// Undo the capital Apple's translator puts on every string it is handed.
    ///
    /// Each chunk goes over as its own request, and the framework has no way to
    /// know it is a fragment, so it capitalises the first letter every time —
    /// which reads as a new sentence starting at each settle boundary, several
    /// times a sentence.
    ///
    /// The source chunk is the authority: if it began lower-case, it was
    /// mid-sentence and the translation should be too. Mirroring it rather than
    /// tracking sentence state also gets the genuine sentence starts right for
    /// free, since those are capitalised in the source as well.
    ///
    /// Left alone when the translated word is all-caps (an acronym) or when the
    /// source began with a capital. The case this gets wrong is a target language
    /// that capitalises words the source does not — German nouns — where a chunk
    /// beginning with a noun will be lower-cased incorrectly. That is one word per
    /// settle against every chunk, which is the better trade.
    public static func matchingLeading(_ translated: String, to source: String) -> String {
        guard let sourceFirst = source.first, sourceFirst.isLowercase,
              let translatedFirst = translated.first, translatedFirst.isUppercase
        else { return translated }
        let firstWord = translated.prefix { !$0.isWhitespace }
        guard firstWord.dropFirst().contains(where: { $0.isLowercase }) else { return translated }
        return translatedFirst.lowercased() + translated.dropFirst()
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
