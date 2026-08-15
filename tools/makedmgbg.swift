// Draws the DMG window background: two icons, an arrow, and the instruction.
//
// Generated rather than committed as a binary so the one place that defines the
// layout is the same place that defines the geometry the AppleScript in
// release.sh positions icons with. A hand-made PNG drifts from those coordinates
// the first time anyone nudges the window size, and the arrow ends up pointing
// at nothing.
//
// Light, not dark, despite the app being a black overlay. Finder draws icon
// labels in the system label colour — black in Light Mode, white in Dark — and
// a background image cannot respond to either. Light loses less: black labels
// on a light panel are correct for most people, and white labels still carry a
// faint shadow. A dark background inverts that into unreadable-by-default.
//
// Output is a multi-representation TIFF, 1x and 2x. Finder picks the matching
// scale; a lone PNG at 2x renders at twice the window size, and at 1x it is
// visibly soft on every Mac sold in a decade.
//
// Usage: swift makedmgbg.swift <out.tiff>

import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: makedmgbg.swift <out.tiff>\n".data(using: .utf8)!)
    exit(2)
}

// Window content size in points. release.sh sizes the Finder window to match,
// and positions icons in this same coordinate space — but measured from the top
// left, the way AppleScript does, whereas AppKit draws from the bottom left.
// `flip` is the only bridge between the two; keep every constant below in
// AppleScript coordinates and convert at the point of drawing.
let W: CGFloat = 640
let H: CGFloat = 400
func flip(_ y: CGFloat) -> CGFloat { H - y }

let iconY: CGFloat = 180        // centre line of both icons
let appX: CGFloat = 170         // Subtitles.app
let destX: CGFloat = 470        // Applications symlink

let indigo = NSColor(srgbRed: 0.345, green: 0.337, blue: 0.839, alpha: 1)   // systemIndigo
let ink    = NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1)
let muted  = NSColor(srgbRed: 0.43, green: 0.43, blue: 0.47, alpha: 1)

func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
    return NSFont(descriptor: d, size: size) ?? base
}

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let px = (Int(W * scale), Int(H * scale))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px.0, pixelsHigh: px.1,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        FileHandle.standardError.write("cannot allocate bitmap\n".data(using: .utf8)!)
        exit(1)
    }
    // Marking the rep's size in points is what makes this a @2x representation
    // rather than a second, larger image — and it is also what scales drawing:
    // NSGraphicsContext(bitmapImageRep:) maps points to pixels using this, so
    // everything below is written once, in points, for both scales. Applying
    // `scale` a second time by hand draws the 2x rep at 4x, off the canvas.
    rep.size = NSSize(width: W, height: H)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Ground. A near-white vertical gradient rather than flat white: flat white
    // makes the window's own edges vanish and the icons look like they are
    // floating on the desktop.
    NSGradient(colors: [
        NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1),
    ])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // A wide indigo wash behind the app side, so the eye starts on the left and
    // travels the direction the arrow is asking for.
    // Drawn into the whole canvas with the centre pushed left, not into a rect
    // around the app icon: a radial gradient is clipped to its rect, and a rect
    // that stops mid-canvas leaves a hard vertical seam straight down the middle.
    NSGradient(colors: [indigo.withAlphaComponent(0.10), indigo.withAlphaComponent(0)])?
        .draw(in: NSRect(x: 0, y: 0, width: W, height: H),
              relativeCenterPosition: NSPoint(x: -0.45, y: 0))

    // The arrow. Shaft stops short of both icons; an arrow that touches them
    // reads as a connector rather than an instruction.
    // Symmetric insets, so the arrow's midpoint is the midpoint of the gap
    // between the two icons rather than sitting a few points off it.
    let shaftFrom = appX + 85
    let shaftTo = destX - 85
    let y = flip(iconY)

    let shaft = NSBezierPath()
    shaft.move(to: NSPoint(x: shaftFrom, y: y))
    shaft.line(to: NSPoint(x: shaftTo, y: y))
    shaft.lineWidth = 7
    shaft.lineCapStyle = .round
    indigo.setStroke()
    shaft.stroke()

    // Chevron head, drawn as two stroked strokes rather than a filled triangle
    // so its weight matches the shaft exactly at both scales.
    let head = NSBezierPath()
    head.move(to: NSPoint(x: shaftTo - 17, y: y + 17))
    head.line(to: NSPoint(x: shaftTo + 2, y: y))
    head.line(to: NSPoint(x: shaftTo - 17, y: y - 17))
    head.lineWidth = 7
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    func centred(_ s: String, _ font: NSFont, _ colour: NSColor, y top: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: (W - size.width) / 2, y: flip(top) - size.height),
               withAttributes: attrs)
    }

    centred("Install Subtitles", rounded(20, .semibold), ink, y: 52)
    centred("Drag the app onto your Applications folder.",
            rounded(13, .medium), muted, y: 84)
    // Sits below the icon labels Finder draws at roughly y=250.
    centred("Everything runs on-device. Nothing is ever uploaded.",
            rounded(11, .regular), muted.withAlphaComponent(0.75), y: 330)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let image = NSImage(size: NSSize(width: W, height: H))
image.addRepresentation(draw(scale: 1))
image.addRepresentation(draw(scale: 2))

guard let tiff = image.tiffRepresentation else {
    FileHandle.standardError.write("cannot encode tiff\n".data(using: .utf8)!)
    exit(1)
}
do {
    try tiff.write(to: URL(fileURLWithPath: args[1]))
} catch {
    FileHandle.standardError.write("cannot write \(args[1]): \(error)\n".data(using: .utf8)!)
    exit(1)
}
