// Shapes a full-bleed square image into a macOS app icon master.
//
// macOS does not round an icon for you: a square PNG dropped into an .icns stays
// a square tile next to every other app. The art has to be masked and inset to
// Apple's grid before iconutil ever sees it.
//
// The grid, on a 1024 canvas: an 824x824 body centred with 100pt margins, corner
// radius 185.4. The margins are not padding for its own sake — they are what the
// drop shadow lives in.
//
// The corner is `cornerCurve = .continuous`, not a plain rounded rect. AppKit's
// `NSBezierPath(roundedRect:)` draws circular-arc corners, which read as
// noticeably rounder than a squircle at icon sizes; CALayer is the only
// straightforward way to get Apple's actual curve.
//
// Usage: swift makeappicon.swift <source.png> <out.png>

import AppKit
import QuartzCore

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: makeappicon.swift <source.png> <out.png>\n".data(using: .utf8)!)
    exit(2)
}

let canvas: CGFloat = 1024
let body: CGFloat = 824
let radius: CGFloat = 185.4
let inset = (canvas - body) / 2

guard let source = NSImage(contentsOfFile: args[1]),
      let sourceCG = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read \(args[1])\n".data(using: .utf8)!)
    exit(1)
}

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(canvas), pixelsHigh: Int(canvas),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
    FileHandle.standardError.write("cannot create canvas\n".data(using: .utf8)!)
    exit(1)
}

// Shadow first, painted under the body rather than by the layer, so its opacity
// is not also applied to the artwork.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
              color: NSColor.black.withAlphaComponent(0.32).cgColor)
let shape = CGPath(roundedRect: CGRect(x: inset, y: inset, width: body, height: body),
                   cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.addPath(shape)
ctx.setFillColor(NSColor.black.cgColor)
ctx.fillPath()
ctx.restoreGState()

// The body itself, through a continuous-curve layer.
//
// `render(in:)` ignores the layer's frame *origin* and draws at the context
// origin, so the placement has to come from the CTM. Setting `frame` and
// trusting it puts the art a margin's width too low, running off the bottom
// edge — no bottom margin, and nowhere for the shadow to fall.
let layer = CALayer()
layer.frame = CGRect(origin: .zero, size: CGSize(width: body, height: body))
layer.contents = sourceCG
layer.contentsGravity = .resizeAspectFill
layer.cornerRadius = radius
layer.cornerCurve = .continuous
layer.masksToBounds = true
// No `isGeometryFlipped`: a bitmap-backed context and CALayer both use a
// bottom-left origin on macOS, so flipping mirrors the artwork vertically —
// invisible in an alpha check, because the source is opaque edge to edge.
ctx.saveGState()
ctx.translateBy(x: inset, y: inset)
layer.render(in: ctx)
ctx.restoreGState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("cannot encode png\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: URL(fileURLWithPath: args[2]))
print("    shaped \(Int(canvas))x\(Int(canvas)) · body \(Int(body)) · radius \(radius)")
