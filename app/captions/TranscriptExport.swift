// A saved transcript, in the format chosen in the save panel.
//
// The overlay hands over the ⌥ stack as entries, one per box, and this sets
// them out as plain text, Markdown or SubRip. Here rather than in the app
// target so the formats can be tested without AppKit: SRT in particular is a
// format other programs read, and a malformed timestamp is only found by one
// of them refusing the file.
//
// The times are when each box was on screen, not the recognizer's audio
// times. Those restart at every endpoint, so across a session they say
// nothing about order; the clock does.

import Foundation

public enum TranscriptFormat: String, CaseIterable, Sendable {
    case text, markdown, srt

    public var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .srt: return "srt"
        }
    }
}

public struct TranscriptEntry: Equatable, Sendable {
    public let text: String
    /// The other language, when both were on hand; empty otherwise.
    public let under: String
    /// The app's name as shown, or nil when nothing was known to be playing.
    public let app: String?
    /// Who spoke it, already numbered for the reader (1, 2, …), or nil when
    /// speakers are not named.
    public let speaker: Int?
    /// When its first and last words reached the screen.
    public let shown: Date
    public let lastWord: Date

    public init(text: String, under: String = "", app: String? = nil, speaker: Int? = nil,
                shown: Date, lastWord: Date) {
        self.text = text
        self.under = under
        self.app = app
        self.speaker = speaker
        self.shown = shown
        self.lastWord = lastWord
    }
}

public enum TranscriptExport {
    /// How long a cue stays up past its last word when nothing follows it
    /// sooner, and the least any cue is given.
    static let linger: TimeInterval = 2
    static let shortest: TimeInterval = 1

    /// `title` heads the Markdown; `speaker` names a speaker's number, in the
    /// reader's language.
    public static func render(_ entries: [TranscriptEntry], as format: TranscriptFormat,
                              title: String, speaker: (Int) -> String) -> String {
        switch format {
        case .text: return text(entries, speaker: speaker)
        case .markdown: return markdown(entries, title: title, speaker: speaker)
        case .srt: return srt(entries)
        }
    }

    /// A paragraph per box, its other language on the line under it, the
    /// app's name in brackets over the first box from each app, and the
    /// speaker over the first box of each turn.
    static func text(_ entries: [TranscriptEntry], speaker: (Int) -> String) -> String {
        var out: [String] = []
        walk(entries) { entry, newApp, newTurn in
            if newApp, let app = entry.app { out.append("[\(app)]") }
            var paragraph = entry.under.isEmpty ? entry.text : entry.text + "\n" + entry.under
            if newTurn, let number = entry.speaker { paragraph = speaker(number) + "\n" + paragraph }
            out.append(paragraph)
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// The same, as Markdown: the title a heading, each app a section, the
    /// speaker in bold ahead of their turn, and the other language in italics
    /// on a line of its own.
    static func markdown(_ entries: [TranscriptEntry], title: String,
                         speaker: (Int) -> String) -> String {
        var out = ["# " + escape(title)]
        walk(entries) { entry, newApp, newTurn in
            if newApp, let app = entry.app { out.append("## " + escape(app)) }
            var paragraph = escape(entry.text)
            if newTurn, let number = entry.speaker {
                paragraph = "**" + escape(speaker(number)) + ":** " + paragraph
            }
            if !entry.under.isEmpty { paragraph += "  \n*" + escape(entry.under) + "*" }
            out.append(paragraph)
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    /// One cue per box, timed from the first box: up when its first word
    /// reached the screen, down when the next came up, or a moment after its
    /// last word when the next was a while coming. Just the words: no app,
    /// and no speaker, whose name would be read as part of the line.
    static func srt(_ entries: [TranscriptEntry]) -> String {
        guard let origin = entries.first?.shown else { return "" }
        var cues: [String] = []
        var index = 0
        walk(entries) { entry, _, _ in
            let start = entry.shown.timeIntervalSince(origin)
            var end = entry.lastWord.timeIntervalSince(origin) + linger
            let following = entries.indices.contains(index + 1) ? entries[index + 1] : nil
            if let following { end = min(end, following.shown.timeIntervalSince(origin)) }
            end = max(end, start + shortest)
            let body = entry.under.isEmpty ? entry.text : entry.text + "\n" + entry.under
            cues.append("\(cues.count + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(body)")
            index += 1
        }
        return cues.joined(separator: "\n\n") + "\n"
    }

    /// Each entry, and whether it opens an app's run and a speaker's turn. A
    /// new app opens a turn too: the name over it has to be said again.
    private static func walk(_ entries: [TranscriptEntry],
                             _ body: (TranscriptEntry, _ newApp: Bool, _ newTurn: Bool) -> Void) {
        var app: String?
        var voice: Int?
        for (i, entry) in entries.enumerated() {
            let newApp = entry.app != nil && (i == 0 || entry.app != app)
            if newApp { voice = nil }
            app = entry.app
            let newTurn = entry.speaker != nil && entry.speaker != voice
            if newTurn { voice = entry.speaker }
            body(entry, newApp, newTurn)
        }
    }

    /// SubRip's clock: hours, minutes, seconds and milliseconds, the last
    /// after a comma.
    static func timestamp(_ seconds: TimeInterval) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d",
                      ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    /// What Markdown would otherwise read as emphasis, links or markup.
    static func escape(_ text: String) -> String {
        var out = ""
        for c in text {
            if "\\*_[]<>`#".contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }
}
