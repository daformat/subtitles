// What is waiting to be read aloud.
//
// Speech is slower than reading. A subtitle can sit on screen while the next
// one arrives; a sentence read aloud takes the time it takes, and a fast talk
// show translated into a wordier language outruns a voice at its usual pace.
//
// Nothing is dropped: someone listening instead of reading has no other way
// to get what was said, and a line skipped to stay near the picture is a
// line they never hear. Whatever arrived while the voice was busy is taken
// next as one utterance, which also reads better than a pause at every settle
// boundary, since a settled chunk is often a clause rather than a sentence.
// Read at the voice's usual pace, whatever the backlog: a voice hurried to
// catch up was harder to follow than one running behind (Mat, 26 Sept 2026).
// It catches up in the pauses between speakers instead.

import Foundation

public struct SpeechQueue {
    /// About 170 words a minute, a voice's default pace.
    public static let wordsPerSecond = 2.8
    /// Chinese and Japanese, which a voice reads at about five characters a
    /// second and which have no spaces to count words by.
    public static let ideographsPerSecond = 5.0

    public private(set) var pending: [String] = []

    public init() {}

    public mutating func add(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending.append(trimmed)
    }

    /// Everything waiting, as one utterance, or nil when nothing is.
    public mutating func next() -> String? {
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll() }
        return pending.joined(separator: " ")
    }

    public mutating func clear() { pending.removeAll() }

    /// How long what is waiting would take to say at the usual pace.
    public var backlog: TimeInterval {
        pending.reduce(0) { $0 + Self.duration(of: $1) }
    }

    /// An estimate of how long `text` takes to say: words at
    /// `wordsPerSecond`, and ideographs and kana one by one at
    /// `ideographsPerSecond`, whatever the spaces around them.
    public static func duration(of text: String) -> TimeInterval {
        var ideographs = 0
        var words = 0
        var inWord = false
        for scalar in text.unicodeScalars {
            if isIdeographic(scalar) {
                ideographs += 1
                inWord = false
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                if !inWord { words += 1 }
                inWord = true
            } else {
                inWord = false
            }
        }
        return Double(words) / wordsPerSecond + Double(ideographs) / ideographsPerSecond
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF,   // hiragana, katakana
             0x3400...0x4DBF,   // CJK extension A
             0x4E00...0x9FFF,   // CJK unified ideographs
             0xF900...0xFAFF,   // compatibility ideographs
             0x20000...0x2FA1F: // the supplementary planes' ideographs
            return true
        default:
            return false
        }
    }
}
