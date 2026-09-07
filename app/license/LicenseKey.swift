// A Gumroad licence key, normalised.
//
// Gumroad issues keys as four groups of eight hex digits, upper case, joined
// by hyphens: 4B1C2D3E-5F607182-93A4B5C6-D7E8F9A0. People paste them from a
// receipt, an email, or a library page, with whatever came along — spaces,
// a trailing newline, lower case from a phone keyboard, and sometimes the
// hyphens dropped. All of that is the same key, and this type is the one
// place that says so.

import Foundation

public struct LicenseKey: Equatable, Hashable, Codable, CustomStringConvertible {
    /// The canonical form: `XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`, upper case.
    public let formatted: String

    /// Hex digits per group, and groups per key, as Gumroad shapes them.
    public static let groupLength = 8
    public static let groups = 4

    /// Reads a key out of whatever was typed or pasted, or nil if what is
    /// there is not a key. Whitespace anywhere is dropped; hyphens are
    /// optional; case is folded. Anything that is not then 32 hex digits is
    /// refused, so a partial paste is caught here rather than by Gumroad.
    public init?(parsing text: String) {
        let hex = text.uppercased().filter { $0.isHexDigit && $0.isASCII }
        // Filtering hex digits alone would accept "ab cd ..." with junk between:
        // count what was thrown away, and allow only whitespace and hyphens.
        let dropped = text.uppercased().filter { !($0.isHexDigit && $0.isASCII) }
        guard dropped.allSatisfy({ $0 == "-" || $0.isWhitespace || $0.isNewline }) else { return nil }
        guard hex.count == Self.groupLength * Self.groups else { return nil }
        var groups: [String] = []
        var rest = Substring(hex)
        while !rest.isEmpty {
            groups.append(String(rest.prefix(Self.groupLength)))
            rest = rest.dropFirst(Self.groupLength)
        }
        formatted = groups.joined(separator: "-")
    }

    /// True when `text` could still become a key with more typing: only
    /// characters a key may contain, and not yet too many of them. For a
    /// field that wants to refuse junk without refusing a half-typed key.
    public static func couldBecomeKey(_ text: String) -> Bool {
        let upper = text.uppercased()
        guard upper.allSatisfy({ ($0.isHexDigit && $0.isASCII) || $0 == "-" || $0.isWhitespace }) else {
            return false
        }
        return upper.filter { $0.isHexDigit }.count <= groupLength * groups
    }

    public var description: String { formatted }
}
