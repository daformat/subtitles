// Finding a query in a history box.
//
// Here rather than in the overlay so it can be tested: the matching is the one
// part of searching the stack that has rules — case folds, accents fold, every
// occurrence counts — and none of them needs a view to be checked.

import Foundation

public enum HistorySearch {
    /// Every place `query` occurs in `text`, as UTF-16 ranges for an attributed
    /// string to highlight. Case and diacritics are ignored on both sides, so
    /// "ete" finds "été" and "Zurich" finds "Zürich".
    ///
    /// An empty query matches nowhere: an empty field means "show everything",
    /// which is the caller's decision to make, not a match on every box.
    public static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        var found: [NSRange] = []
        var from = text.startIndex
        while from < text.endIndex,
              let hit = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                   range: from..<text.endIndex) {
            found.append(NSRange(hit, in: text))
            from = hit.upperBound
        }
        return found
    }

    public static func matches(_ text: String, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}
