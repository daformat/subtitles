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
    static let corner: CGFloat = 16

    // MARK: shape

    /// The two corners a tab can take the roundness off.
    enum Corner: Hashable {
        case topLeft, topRight
    }

    /// A pill's path: a rounded rect, with any corner in `square` left as a
    /// right angle. The name tab sits flush with the box's edge and squares
    /// the corner under it, so tab and box read as one shape.
    static func pillPath(_ r: NSRect, radius: CGFloat, square: Set<Corner> = []) -> NSBezierPath {
        let p = NSBezierPath()
        // Nothing for nothing. A view is drawn once before it is laid out, at
        // zero size, and insetting that for a hairline yields the null rect,
        // whose infinities become NaN and a path with no current point.
        guard !r.isNull, r.width > 0, r.height > 0 else { return p }
        let rad = max(min(radius, r.width / 2, r.height / 2), 0)
        // Anticlockwise from the bottom edge, in y-up coordinates.
        p.move(to: NSPoint(x: r.minX + rad, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.minY + rad), radius: rad,
                    startAngle: 270, endAngle: 360)
        if square.contains(.topRight) {
            p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        } else {
            p.line(to: NSPoint(x: r.maxX, y: r.maxY - rad))
            p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.maxY - rad), radius: rad,
                        startAngle: 0, endAngle: 90)
        }
        if square.contains(.topLeft) {
            p.line(to: NSPoint(x: r.minX, y: r.maxY))
        } else {
            p.line(to: NSPoint(x: r.minX + rad, y: r.maxY))
            p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.maxY - rad), radius: rad,
                        startAngle: 90, endAngle: 180)
        }
        p.line(to: NSPoint(x: r.minX, y: r.minY + rad))
        p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.minY + rad), radius: rad,
                    startAngle: 180, endAngle: 270)
        p.close()
        return p
    }

    /// The outline of a pill and whatever it wears as one shape, grown by
    /// `grow` all round: what the ⇧ ring traces. A tab is part of the
    /// silhouette, its inner foot a sharp corner; a header changes nothing.
    static func silhouette(pill: NSRect, style: IconStyle, icon: Bool, name: String?,
                           size: CGFloat, rtl: Bool, grow: CGFloat) -> NSBezierPath {
        let p = pill.insetBy(dx: -grow, dy: -grow)
        let rp = corner + grow
        guard icon, style == .nameTab, !p.isNull, p.width > 0, p.height > 0 else {
            return pillPath(p, radius: rp)
        }
        let tab = tabRect(on: pill, name: name, size: size, rtl: rtl)
        // Traced with the tab on the left, and flipped for the right.
        let t = NSRect(x: p.minX, y: pill.maxY, width: tab.width + grow * 2, height: tab.height + grow)
        let rt = tabRadius + grow
        let path = NSBezierPath()
        path.move(to: NSPoint(x: p.minX + rp, y: p.minY))
        path.line(to: NSPoint(x: p.maxX - rp, y: p.minY))
        path.appendArc(withCenter: NSPoint(x: p.maxX - rp, y: p.minY + rp), radius: rp,
                       startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: p.maxX, y: p.maxY - rp))
        path.appendArc(withCenter: NSPoint(x: p.maxX - rp, y: p.maxY - rp), radius: rp,
                       startAngle: 0, endAngle: 90)
        // Along the pill's top to the tab's foot, up its concave curve — a
        // ring outside the shape takes the foot's radius less the growth —
        // and up the tab's inner side.
        let foot = NSPoint(x: pill.minX + tab.width + tabFoot, y: pill.maxY + tabFoot)
        path.line(to: NSPoint(x: foot.x, y: p.maxY))
        path.appendArc(withCenter: foot, radius: max(tabFoot - grow, 0),
                       startAngle: 270, endAngle: 180, clockwise: true)
        path.line(to: NSPoint(x: t.maxX, y: t.maxY - rt))
        path.appendArc(withCenter: NSPoint(x: t.maxX - rt, y: t.maxY - rt), radius: rt,
                       startAngle: 0, endAngle: 90)
        path.line(to: NSPoint(x: t.minX + rt, y: t.maxY))
        path.appendArc(withCenter: NSPoint(x: t.minX + rt, y: t.maxY - rt), radius: rt,
                       startAngle: 90, endAngle: 180)
        path.line(to: NSPoint(x: p.minX, y: p.minY + rp))
        path.appendArc(withCenter: NSPoint(x: p.minX + rp, y: p.minY + rp), radius: rp,
                       startAngle: 180, endAngle: 270)
        path.close()
        if rtl {
            // x' = 2·mid − x: the scale is applied to points first, then the
            // translation, which is the order NSAffineTransform prepends in.
            let flip = NSAffineTransform()
            flip.translateX(by: p.midX * 2, yBy: 0)
            flip.scaleX(by: -1, yBy: 1)
            path.transform(using: flip as AffineTransform)
        }
        return path
    }

    /// Which corners a style squares off: the tab's, on the text's leading
    /// side.
    static func squareCorners(style: IconStyle, icon: Bool, rtl: Bool) -> Set<Corner> {
        guard icon, style == .nameTab else { return [] }
        return [rtl ? .topRight : .topLeft]
    }

    /// Whether text runs right to left, from its first strong character — the
    /// rule natural alignment lays it out by, so the icon lands on the edge
    /// the text starts from. Letters only; digits and punctuation take the
    /// direction of what follows them.
    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            switch scalar.value {
            // Hebrew, Arabic, Syriac, Thaana, NKo, Samaritan, Mandaic, and
            // the Arabic presentation forms.
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF:
                return true
            // Latin, Greek, Cyrillic, Armenian, and the Indic, Thai, Georgian,
            // Hangul, CJK and other left-to-right scripts.
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x0370...0x058F,
                 0x0900...0x1FFF, 0x2C00...0xD7FF, 0xFF21...0xFF5A:
                return false
            default:
                continue
            }
        }
        return false
    }

    // MARK: outline

    /// A hairline round every box, one device pixel wide, just inside the
    /// pill's edge, the way the system edges its own panels. A shade lighter
    /// than the box in dark mode; a shade darker than it in light mode, where
    /// the picture behind is bright and a light rim reads as a glint from
    /// behind the box rather than its edge. Drawn by the app on every system.
    /// The rim Liquid Glass draws on macOS 26 is NSGlassEffectView's alone,
    /// which would replace the backdrop under the pill rather than this line
    /// — a change to make against the 26 SDK, on a machine that can show it.
    static let outlineInk = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 210 / 255, green: 210 / 255, blue: 211 / 255, alpha: 0.16)
            : NSColor.black.withAlphaComponent(0.55)
    }

    /// One device pixel, in points.
    private static func hairlineWidth(scale: CGFloat) -> CGFloat { 1 / max(scale, 1) }

    /// A pill's outline, inset by half the line so the stroke lands on the
    /// pixel inside the edge instead of straddling it.
    private static func hairline(_ rect: NSRect, radius: CGFloat, square: Set<Corner> = [],
                                 scale: CGFloat) -> NSBezierPath {
        let width = hairlineWidth(scale: scale)
        let path = pillPath(rect.insetBy(dx: width / 2, dy: width / 2),
                            radius: max(radius - width / 2, 0), square: square)
        path.lineWidth = width
        return path
    }

    /// The outline round a pill, leaving out where a tab sits on its edge: the
    /// tab wears its own, and a line running under it would show through its
    /// fill. `scale` is the window's backing scale.
    static func outline(pill: NSRect, style: IconStyle, icon: Bool, name: String?,
                        size: CGFloat, rtl: Bool, scale: CGFloat) {
        NSGraphicsContext.saveGraphicsState()
        if icon, style == .nameTab {
            // From where the tab's own line takes over, so the pill's stops
            // at its feet and neither runs under the other.
            let tab = tabRect(on: pill, name: name, size: size, rtl: rtl)
            let clip = NSBezierPath(rect: pill.insetBy(dx: -100, dy: -100))
            clip.appendRect(NSRect(x: rtl ? tab.minX - tabFoot : tab.minX, y: pill.maxY - 0.5,
                                   width: tab.width + tabFoot, height: 2.5))
            clip.windingRule = .evenOdd
            clip.addClip()
        }
        outlineInk.setStroke()
        hairline(pill, radius: corner, square: squareCorners(style: style, icon: icon, rtl: rtl),
                 scale: scale).stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: icon

    /// Where a box wears the icon of the app it transcribes, and its name.
    /// Chosen from the menu. Whichever it is sits on the text's leading edge:
    /// the left, or the right for a right-to-left script.
    enum IconStyle: String, CaseIterable {
        case off
        /// A tab on the top edge, flush with the leading side, squaring the
        /// corner under it.
        case nameTab
        /// A row inside the box above the text — the way Live Captions heads
        /// its box.
        case header

        var title: String {
            switch self {
            case .off: return "Off"
            case .nameTab: return "Name Tab"
            case .header: return "Header Row"
            }
        }
    }

    /// The room a style takes when there is an icon to draw: above the pill
    /// for the tab, inside it above the text for the header. Both boxes
    /// measure and draw through this, which is what keeps a history box the
    /// height of the live box it was.
    struct IconRoom: Equatable {
        var top: CGFloat = 0
        var inside: CGFloat = 0
        /// The narrowest the pill may be, for a header wider than its text.
        var minWidth: CGFloat = 0
    }

    /// `name` matters only to the header, whose width is the name's.
    static func room(_ style: IconStyle, size: CGFloat, icon: Bool, name: String? = nil) -> IconRoom {
        guard icon else { return IconRoom() }
        switch style {
        case .off:
            return IconRoom()
        case .nameTab:
            return IconRoom(top: tabHeight(ofSize: size))
        case .header:
            let side = headerIconSide(ofSize: size)
            let label = name.map { ceil(headerLabel($0, size: size, rtl: false).size().width) } ?? 0
            return IconRoom(inside: side + headerGap(ofSize: size),
                            minWidth: inset.width * 2 + side + (label > 0 ? headerNameGap + label : 0))
        }
    }

    /// The name's colour, in the tab and the header: a fixed light grey, on
    /// the live box and in the stack alike, rather than the text's white at
    /// the box's opacity.
    static let tabInk = NSColor(srgbRed: 210 / 255, green: 210 / 255, blue: 211 / 255, alpha: 1)

    /// The name tab: its icon, its type, its top corners, and the room inside
    /// it. The tab is flush with the pill's edge, so its ends take the text's
    /// own inset and the icon lines up with the caption under it; its height
    /// is the icon's with more room above it than below, so the icon and name
    /// sit close to the box they belong to.
    static func tabIconSide(ofSize size: CGFloat) -> CGFloat {
        (size * 0.5).rounded()
    }

    static func tabFont(ofSize size: CGFloat) -> NSFont {
        font(ofSize: (size * 0.42).rounded())
    }

    static let tabRadius: CGFloat = 16

    /// The foot: the concave curve where the tab's inner side meets the
    /// pill's top edge, so the tab flares into the box the way a browser tab
    /// does rather than meeting it at a right angle.
    static let tabFoot: CGFloat = 8

    static func tabHeight(ofSize size: CGFloat) -> CGFloat {
        tabIconSide(ofSize: size) + tabPadTop + tabPadBottom
    }

    static let tabEdge: CGFloat = Pill.inset.width
    static let tabGap: CGFloat = 7
    static let tabPadTop: CGFloat = 10
    static let tabPadBottom: CGFloat = 5

    /// The header row: its icon, the gap under it to the text, the gap
    /// between icon and name, and the name's type — smaller than the caption,
    /// as a heading over it rather than a line of it.
    static func headerIconSide(ofSize size: CGFloat) -> CGFloat {
        (size * 0.9).rounded()
    }

    static func headerGap(ofSize size: CGFloat) -> CGFloat {
        (size * 0.3).rounded()
    }

    static let headerNameGap: CGFloat = 10

    static func headerLabel(_ name: String, size: CGFloat, rtl: Bool) -> NSAttributedString {
        label(name, font: font(ofSize: (size * 0.6).rounded()), rtl: rtl)
    }

    private static func tabLabel(_ name: String, size: CGFloat, rtl: Bool) -> NSAttributedString {
        label(name, font: tabFont(ofSize: size), rtl: rtl)
    }

    /// A name on one line, cut short with an ellipsis where there is no room,
    /// set against the icon it sits beside.
    private static func label(_ name: String, font: NSFont, rtl: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = rtl ? .right : .left
        return NSAttributedString(string: name, attributes: [
            .font: font,
            .foregroundColor: tabInk,
            .paragraphStyle: paragraph,
        ])
    }

    /// The pill inside a box's frame: `pad` all round — the live box's ring
    /// margin, nothing for a history box — and the tab's room above it.
    static func pillRect(in bounds: NSRect, pad: CGFloat, room: IconRoom) -> NSRect {
        NSRect(x: bounds.minX + pad, y: bounds.minY + pad,
               width: bounds.width - pad * 2, height: bounds.height - pad * 2 - room.top)
    }

    /// Where the text goes in a pill: under the header, when there is one.
    static func textRect(in pill: NSRect, room: IconRoom) -> NSRect {
        NSRect(x: pill.minX + inset.width, y: pill.minY + inset.height,
               width: pill.width - inset.width * 2,
               height: pill.height - inset.height * 2 - room.inside)
    }

    /// The icon on a pill, in the style. `fill` is the pill's, for the tab.
    /// The icon itself is always at full strength: a box in the stack dims
    /// its text to sit behind the live one, but a dimmed icon reads as a
    /// disabled app rather than a box that sits back.
    static func draw(icon: NSImage, name: String?, style: IconStyle, on pill: NSRect,
                     size: CGFloat, fill: CGFloat, rtl: Bool, scale: CGFloat) {
        switch style {
        case .off:
            return
        case .nameTab:
            tab(icon, name: name, in: tabRect(on: pill, name: name, size: size, rtl: rtl), on: pill,
                size: size, fill: fill, rtl: rtl, scale: scale)
        case .header:
            header(icon, name: name, on: pill, size: size, rtl: rtl)
        }
    }

    /// The tab's rect above the pill, flush with its leading edge.
    static func tabRect(on pill: NSRect, name: String?, size: CGFloat, rtl: Bool) -> NSRect {
        let iconSide = tabIconSide(ofSize: size)
        let labelWidth = name.map { ceil(tabLabel($0, size: size, rtl: rtl).size().width) } ?? 0
        let wanted = tabEdge + iconSide + (labelWidth > 0 ? tabGap + labelWidth : 0) + tabEdge
        // No wider than the pill leaves room for, foot included: a long name
        // is cut short rather than the tab overrunning the box.
        let width = min(wanted, pill.width - corner - tabFoot)
        return NSRect(x: rtl ? pill.maxX - width : pill.minX, y: pill.maxY,
                      width: width, height: tabHeight(ofSize: size))
    }

    /// The tab's shape: rounded on top, flush with the pill's edge on the
    /// outside, and flaring into the pill's top edge on the inside through
    /// the foot. `offset` moves the path inward — a hairline half a pixel
    /// inside the edge — with the convex corners tightening and the foot
    /// widening by it. Open along the base, which is the pill's, unless
    /// `closed` for a fill; `baseDepth` carries a closed shape that far down
    /// into the pill, for a mask that must meet the pill's own without a
    /// seam. Built with the tab on the left and flipped for the right, and
    /// always wound the way `pillPath` is, so the two can share a fill rule.
    static func tabPath(tab: NSRect, pill: NSRect, rtl: Bool, offset o: CGFloat,
                        closed: Bool, baseDepth: CGFloat = 0) -> NSBezierPath {
        let x0 = pill.minX, x1 = pill.minX + tab.width
        let y0 = pill.maxY, y1 = tab.maxY
        let r = tabRadius - o
        let foot = NSPoint(x: x1 + tabFoot, y: y0 + tabFoot)
        let p = NSBezierPath()
        // From the base where the foot lands, up the foot, the inner side,
        // over the top, and down the outer side.
        p.move(to: NSPoint(x: foot.x, y: y0 - o))
        p.appendArc(withCenter: foot, radius: tabFoot + o, startAngle: 270, endAngle: 180,
                    clockwise: true)
        p.line(to: NSPoint(x: x1 - o, y: y1 - tabRadius))
        p.appendArc(withCenter: NSPoint(x: x1 - tabRadius, y: y1 - tabRadius), radius: r,
                    startAngle: 0, endAngle: 90)
        p.line(to: NSPoint(x: x0 + tabRadius, y: y1 - o))
        p.appendArc(withCenter: NSPoint(x: x0 + tabRadius, y: y1 - tabRadius), radius: r,
                    startAngle: 90, endAngle: 180)
        p.line(to: NSPoint(x: x0 + o, y: y0 - o))
        if closed {
            if baseDepth > 0 {
                p.line(to: NSPoint(x: x0 + o, y: y0 - o - baseDepth))
                p.line(to: NSPoint(x: foot.x, y: y0 - o - baseDepth))
            }
            p.close()
        }
        guard rtl else { return p }
        let flip = NSAffineTransform()
        flip.translateX(by: pill.midX * 2, yBy: 0)
        flip.scaleX(by: -1, yBy: 1)
        p.transform(using: flip as AffineTransform)
        // A mirror reverses the winding; put it back.
        return p.reversed
    }

    private static func header(_ icon: NSImage, name: String?, on pill: NSRect, size: CGFloat,
                               rtl: Bool) {
        let side = headerIconSide(ofSize: size)
        let iconRect = NSRect(x: rtl ? pill.maxX - inset.width - side : pill.minX + inset.width,
                              y: pill.maxY - inset.height - side, width: side, height: side)
        image(icon, in: iconRect)
        guard let name, !name.isEmpty else { return }
        let label = headerLabel(name, size: size, rtl: rtl)
        let height = ceil(label.size().height)
        let rect = rtl
            ? NSRect(x: pill.minX + inset.width, y: 0,
                     width: max(iconRect.minX - headerNameGap - pill.minX - inset.width, 0), height: height)
            : NSRect(x: iconRect.maxX + headerNameGap, y: 0,
                     width: max(pill.maxX - inset.width - iconRect.maxX - headerNameGap, 0), height: height)
        label.draw(with: NSRect(x: rect.minX, y: (iconRect.midY - height / 2).rounded(),
                                width: rect.width, height: height),
                   options: [.usesLineFragmentOrigin])
    }

    private static func image(_ icon: NSImage, in rect: NSRect) {
        icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1,
                  respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    private static func tab(_ icon: NSImage, name: String?, in tab: NSRect, on pill: NSRect,
                            size: CGFloat, fill: CGFloat, rtl: Bool, scale: CGFloat) {
        let iconSide = tabIconSide(ofSize: size)
        let edge = tabEdge, gap = tabGap

        // The fill stops exactly at the pill's edge, which is on a whole
        // point, so the two butt without a gap — and without overlapping,
        // since two translucent fills stacked make a darker line where they
        // meet. The hairline runs up the foot, over the top and down the
        // outer side, into the pill's own lines at either end — see
        // `outline`, which leaves the pill's top clear under it.
        NSColor.black.withAlphaComponent(fill).setFill()
        tabPath(tab: tab, pill: pill, rtl: rtl, offset: 0, closed: true).fill()
        let width = hairlineWidth(scale: scale)
        let line = tabPath(tab: tab, pill: pill, rtl: rtl, offset: width / 2, closed: false)
        line.lineWidth = width
        outlineInk.setStroke()
        line.stroke()

        let iconX = rtl ? tab.maxX - edge - iconSide : tab.minX + edge
        let iconY = tab.minY + tabPadBottom
        image(icon, in: NSRect(x: iconX, y: iconY, width: iconSide, height: iconSide))
        guard let name, !name.isEmpty else { return }
        let label = tabLabel(name, size: size, rtl: rtl)
        let height = ceil(label.size().height)
        let rect = rtl
            ? NSRect(x: tab.minX + edge, y: 0, width: max(iconX - gap - tab.minX - edge, 0), height: height)
            : NSRect(x: iconX + iconSide + gap, y: 0,
                     width: max(tab.maxX - edge - iconX - iconSide - gap, 0), height: height)
        // Centred on the icon, not the tab.
        label.draw(with: NSRect(x: rect.minX, y: (iconY + iconSide / 2 - height / 2).rounded(),
                                width: rect.width, height: height),
                   options: [.usesLineFragmentOrigin])
    }

    /// The site's `backdrop-filter: blur(6px)`: the standard deviation, in
    /// points, of the blur behind every box. The picture under a box is what
    /// makes dark text on a dark pill hard to read, and softening it is what
    /// lets the text stand off it. See BackdropBlur.swift for how a box gets
    /// it.
    static let backdropBlur: CGFloat = 6

    /// As far as the setting goes. The system's own materials sit at 30, and
    /// well before that the picture is gone and the pill is a frosted panel,
    /// which is a different design from a box over a softened one.
    static let maxBackdropBlur: CGFloat = 20

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

    /// How the caption sits in its box. Chosen from the menu.
    enum TextAlignment: String, CaseIterable {
        /// From the script's leading edge: the left for most, the right for
        /// Arabic and Hebrew. The box fills a word at a time, and a line that
        /// grows from a fixed edge is easier to follow than one re-centred
        /// on every word.
        case start
        /// Centred, the way broadcast subtitles are set.
        case center

        var title: String {
            switch self {
            case .start: return "Start Alignment"
            case .center: return "Center Alignment"
            }
        }
    }

    /// `rtl` is the text's direction, from `isRightToLeft`.
    static func paragraph(measuring: Bool, rtl: Bool, alignment: TextAlignment) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        // The direction is decided from the text itself, once, in
        // `isRightToLeft`, and set outright: natural alignment resolved to the
        // left whatever the text, and the icon's side follows the same
        // answer.
        //
        // Measured left-aligned regardless. A line at any other alignment
        // spans its whole container, so measuring it reports the ceiling width
        // rather than the width the glyphs actually need.
        switch (measuring, alignment) {
        case (true, _): p.alignment = .left
        case (false, .center): p.alignment = .center
        case (false, .start): p.alignment = rtl ? .right : .left
        }
        p.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
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
                           measuring: Bool = false, opacity: CGFloat = 1,
                           alignment: TextAlignment = .start) -> NSAttributedString {
        let style = paragraph(measuring: measuring,
                              rtl: isRightToLeft(committed.isEmpty ? tentative : committed),
                              alignment: alignment)
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
    /// history boxes have none, and pass 0. `room` is what the icon's style
    /// takes, which the frame grows by.
    static func fittingSize(_ text: NSAttributedString, size: CGFloat,
                            maxWidth: CGFloat, maxLines: Int, pad: CGFloat,
                            room: IconRoom = IconRoom()) -> NSSize {
        let m = metrics(text, textWidth: maxWidth - (inset.width + pad) * 2)
        guard m.lines > 0 else { return .zero }

        let capped = min(m.used.height, lineHeight(ofSize: size) * CGFloat(maxLines) + 4)
        // +2 of slack so a fractional advance never clips the final glyph.
        let hugging = m.used.width + 2 + (inset.width + pad) * 2
        // A floor stops one- or two-character updates producing a jittering
        // pill; a header wider than its text raises it for that box.
        let width = min(max(hugging, 140 + pad * 2, room.minWidth + pad * 2), maxWidth)
        return NSSize(width: width,
                      height: ceil(capped) + (inset.height + pad) * 2 + room.top + room.inside)
    }
}
