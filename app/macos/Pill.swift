// Shared pill geometry and text.
//
// Extracted from SubtitleView when ⌥ gained the ability to bring the last few
// boxes back: a history box *is* the live box a minute ago, so the two must
// measure and draw text identically. A stray point of inset or a different line
// height between them is invisible in isolation and glaring the moment they sit
// stacked on top of each other.

import AppKit

enum Pill {
    static let inset = NSSize(width: 22, height: 14)
    static let corner: CGFloat = 14

    /// A rounded, heavy face reads better at a glance against arbitrary video.
    static func font(ofSize size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    /// Nominal height of one wrapped line, used only for the `maxLines` ceiling.
    static func lineHeight(ofSize size: CGFloat) -> CGFloat {
        let f = font(ofSize: size)
        return f.ascender - f.descender + f.leading + 2
    }

    static func paragraph(centered: Bool) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        // Measured left-aligned, drawn centred. A centred line fragment spans the
        // whole container, so measuring it reports the ceiling width rather than
        // the width the glyphs actually need.
        p.alignment = centered ? .center : .left
        p.lineBreakMode = .byWordWrapping
        p.lineSpacing = 2
        return p
    }

    /// Committed text at full strength, the in-flight tail dimmed.
    ///
    /// `opacity` scales both, and is how the ⌥ history sits behind the live box.
    /// One value for the whole stack — an ageing ramp down the stack was tried
    /// and reads as each box fading on its own, which fights the gradient across
    /// the scroll view that is meant to be doing exactly that.
    static func attributed(committed: String, tentative: String, size: CGFloat,
                           centered: Bool = true, opacity: CGFloat = 1) -> NSAttributedString {
        let style = paragraph(centered: centered)
        let f = font(ofSize: size)
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: committed, attributes: [
            .font: f,
            .foregroundColor: NSColor.white.withAlphaComponent(opacity),
            .paragraphStyle: style,
        ]))
        out.append(NSAttributedString(string: tentative, attributes: [
            .font: f,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55 * opacity),
            .paragraphStyle: style,
        ]))
        return out
    }

    /// Exact text extent and wrapped line count, from the real layout engine.
    ///
    /// `boundingRect` under-reports width by enough to clip the last word, and
    /// dividing its height by a nominal line height is off-by-one near the
    /// boundary — either error shows up directly as clipped or mis-paged text.
    static func metrics(_ text: NSAttributedString,
                        textWidth: CGFloat) -> (used: NSSize, lines: Int) {
        guard text.length > 0 else { return (.zero, 0) }

        let container = NSTextContainer(
            size: CGSize(width: textWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        let storage = NSTextStorage(attributedString: text)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)

        var lines = 0
        var index = 0
        var widest: CGFloat = 0
        while index < manager.numberOfGlyphs {
            var range = NSRange()
            _ = manager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            let used = manager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: nil)
            widest = max(widest, used.width)
            index = NSMaxRange(range)
            lines += 1
        }
        let height = manager.usedRect(for: container).height
        return (NSSize(width: ceil(widest), height: ceil(height)), lines)
    }

    /// Size a box hugging `text` needs, given a ceiling on its width.
    ///
    /// `pad` is the transparent margin the live box reserves for the ⇧ ring;
    /// history boxes have none, and pass 0.
    static func fittingSize(_ text: NSAttributedString, size: CGFloat,
                            maxWidth: CGFloat, maxLines: Int, pad: CGFloat) -> NSSize {
        let m = metrics(text, textWidth: maxWidth - (inset.width + pad) * 2)
        guard m.lines > 0 else { return .zero }

        let capped = min(m.used.height, lineHeight(ofSize: size) * CGFloat(maxLines) + 4)
        // +2 of slack so a fractional advance never clips the final glyph.
        let hugging = m.used.width + 2 + (inset.width + pad) * 2
        // A floor stops one- or two-character updates producing a jittering pill.
        let width = min(max(hugging, 140 + pad * 2), maxWidth)
        return NSSize(width: width, height: ceil(capped) + (inset.height + pad) * 2)
    }
}
