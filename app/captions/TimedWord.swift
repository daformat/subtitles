import Foundation

/// One transcribed word with the audio time it was spoken at.
///
/// Paging anchors on these times rather than on a word *count*. A count anchor
/// skips any words that happen to arrive in the same update as the anchor point,
/// so a new page could start part-way into a sentence; a time anchor cannot.
public struct TimedWord: Equatable, Sendable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}
