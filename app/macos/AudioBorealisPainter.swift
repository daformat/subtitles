// Paints a frame of the borealis along the bottom of a box.
//
// The picture: soft colour rising from the box's bottom edge, the lobes
// sliding sideways while a voice is heard, and over it one translucent hill
// per band of the voice, lows to highs, each filled with a colour of the
// palette, layered like an aurora.
// Layers, in paint order and clipped to the box's silhouette (the pill and
// whatever it wears): the bloom (the lobes big and soft, the haze) and the
// inner light (the lobes as colour, brightest at the edge), both masked to
// the glow's ceiling, an ellipse that grows with the voice and gains the
// bend's lift at the centre; then the curves, each a hill filled at a fifth
// of opacity with a faint edge along its top.
//
// The frame's numbers are px at the reference scale of a ~350 pt box; the
// painter scales them sideways by the pill's width and vertically by the
// type size, which is what the box's height follows.
//
// This runs at frame rate inside the box's own draw, and CoreGraphics
// evaluates a gradient per pixel on the CPU, so: the soft layers are painted
// at half a point per pixel into a bitmap kept between frames and drawn
// onto the box with bicubic interpolation (an eighth of a Retina display's
// pixels; it is the bilinear scaling of an earlier draft that showed its
// pixels, not the resolution: the layers are softer than that), and the
// curves are filled straight onto the box at the screen's resolution, where
// a fill costs little and a crisp edge is the point. Every gradient is
// cached by its colour (the hue is quantised to the degree). The
// silhouette is clipped inside the bitmap, never on its draw onto the box:
// an image composited through a path clip costs four times as much as one
// laid down plain. At no presence nothing is painted at all.

import AppKit
import CaptionCore

enum AudioBorealisPainter {
    /// Baked multipliers on the reference geometry (the tuned `default` type).
    private static let glowWidth = 0.65
    private static let glowHeight = 1.25

    /// Pixels per point of the glow's bitmap.
    private static let glowResolution: CGFloat = 0.5

    /// The bitmaps between frames, one per box size in play (the live box,
    /// the debug window's preview), kept while the sizes hold.
    private static var glowScratch: [CGContext] = []

    /// Points along each curve. The hills are smooth.
    private static let curveSamples = 40

    /// Draw `frame` along the bottom of `pill` in `ctx`, inside `path`: the
    /// box's silhouette, the pill with its tab when it wears one. `fontSize`
    /// is the box's type size.
    static func draw(_ frame: AudioBorealis.Frame, in ctx: CGContext, pill: NSRect,
                     path: NSBezierPath, fontSize: CGFloat) {
        guard pill.width > 0, pill.height > 0, frame.glow > 0.002 else { return }
        let bounds = path.bounds.union(pill)
        let sx = min(2.4, max(0.9, pill.width / 350))
        let sy = max(0.5, fontSize / 30)

        let opacity = CGFloat(min(1, max(0, frame.config.opacity)))
        guard opacity > 0 else { return }
        if frame.config.glowOpacity > 0,
           let glow = rendered(at: glowResolution, over: bounds, { bitmap in
               paintGlow(frame, in: bitmap, pill: pill, path: path, sx: sx, sy: sy)
           }) {
            ctx.saveGState()
            ctx.setAlpha(opacity)
            ctx.interpolationQuality = .high
            ctx.draw(glow.image, in: glow.rect)
            ctx.restoreGState()
        }

        paintCurves(frame, in: ctx, pill: pill, path: path, sx: sx, sy: sy)
    }

    /// Run `body` in a bitmap of `bounds` at `resolution`, reusing one of
    /// that size while it holds, and hand back the picture and where it
    /// goes. Nil when the body had nothing to paint.
    private static func rendered(at resolution: CGFloat, over bounds: NSRect,
                                 _ body: (CGContext) -> Bool) -> (image: CGImage, rect: CGRect)? {
        let width = Int((bounds.width * resolution).rounded(.up))
        let height = Int((bounds.height * resolution).rounded(.up))
        guard width > 0, height > 0 else { return nil }
        let found = glowScratch.first { $0.width == width && $0.height == height }
        let made = found ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let bitmap = made else { return nil }
        if found == nil {
            glowScratch.append(bitmap)
            if glowScratch.count > 4 { glowScratch.removeFirst() }
        }
        bitmap.clear(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.saveGState()
        bitmap.scaleBy(x: resolution, y: resolution)
        bitmap.translateBy(x: -bounds.minX, y: -bounds.minY)
        let painted = body(bitmap)
        bitmap.restoreGState()
        guard painted, let image = bitmap.makeImage() else { return nil }
        return (image, CGRect(x: bounds.minX, y: bounds.minY,
                              width: CGFloat(width) / resolution, height: CGFloat(height) / resolution))
    }

    // MARK: - the glow

    /// The two soft layers of lobes: how they are sized against the
    /// reference geometry, how their colour fades over the radius (alpha
    /// stops, eased out so they end in nothing), and their opacity at full
    /// presence.
    private enum Layer: Int, CaseIterable {
        case bloom, inner

        var sizeX: Double { self == .bloom ? 1.15 * 1.15 : 1 }
        var sizeY: Double { self == .bloom ? 1.5 * 1.15 : 1.1 }
        var stops: [(CGFloat, CGFloat)] {
            switch self {
            case .bloom: return [(0, 0.5), (0.4, 0.22), (0.75, 0.05), (1, 0)]
            case .inner: return [(0, 0.6), (0.45, 0.3), (0.8, 0.06), (1, 0)]
            }
        }
        var opacity: Double { self == .bloom ? 0.5 : 0.6 }
        /// The mask's ellipse: reference px before the bend's lift, and how
        /// it fades over the radius.
        var maskSize: (rx: Double, ry: Double) {
            self == .bloom
                ? (200 * AudioBorealis.rangeWidth, 130)
                : (AudioBorealis.ceilingHalfWidth * AudioBorealis.rangeWidth, AudioBorealis.ceilingHeight)
        }
        var maskStops: [(CGFloat, CGFloat)] {
            switch self {
            case .bloom: return [(0, 1), (0.35, 0.5), (0.8, 0.1), (1, 0)]
            case .inner: return [(0, 1), (0.45, 0.5), (0.85, 0.2), (1, 0)]
            }
        }
    }

    /// The bloom and the inner light, at full size in `ctx`.
    private static func paintGlow(_ frame: AudioBorealis.Frame, in ctx: CGContext, pill: NSRect,
                                  path: NSBezierPath, sx: CGFloat, sy: CGFloat) -> Bool {
        let centre = NSPoint(x: pill.midX, y: pill.minY)
        let colors = ColorKey(frame)
        var painted = false

        ctx.saveGState()
        ctx.addPath(path.cgPath)
        ctx.clip()

        for layer in Layer.allCases {
            let opacity = min(1, layer.opacity * frame.glow * frame.config.glowOpacity)
            guard opacity > 0 else { continue }
            let mask = layer.maskSize
            let rx = CGFloat(mask.rx * frame.width) * sx
            let ry = CGFloat(mask.ry * frame.height + frame.lift) * sy
            guard rx > 0.5, ry > 0.5 else { continue }
            painted = true
            ctx.saveGState()
            // Nothing outside the mask's ellipse survives it, so the layer's
            // buffer need not be any bigger than its box.
            ctx.clip(to: CGRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2))
            ctx.setAlpha(CGFloat(opacity))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            for (i, lobe) in AudioBorealis.lobes.enumerated() {
                let lrx = CGFloat(lobe.width * glowWidth * layer.sizeX * frame.width) * sx
                let lry = CGFloat(lobe.height * glowHeight * layer.sizeY * frame.height
                                  * frame.lobeAmplitude[i]) * sy
                guard lrx > 0.5, lry > 0.5,
                      let gradient = lobeGradient(layer, lobe: i, colors: colors) else { continue }
                let x = centre.x + CGFloat(frame.lobeX[i] * frame.width) * sx
                ellipse(ctx, gradient, at: NSPoint(x: x, y: centre.y), rx: lrx, ry: lry)
            }
            // Keep only what falls under the mask's ellipse.
            if let maskGradient = whiteGradient(.mask(layer)) {
                ctx.setBlendMode(.destinationIn)
                ellipse(ctx, maskGradient, at: centre, rx: rx, ry: ry, beyond: true)
            }
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }

        ctx.restoreGState()
        return painted
    }

    // MARK: - the curves

    /// One hill per band, low to high, each filled with its colour from the
    /// box's bottom edge, where the fill is at its configured opacity, up
    /// to its curve, where it has faded by the configured share, with a
    /// line along the hill's edge (not along the flat band it stands on,
    /// which would draw a line across the box before any hill rose); the
    /// fills add like light where hills overlap, when so configured. Their
    /// height is what the voice moves, so the
    /// opacities are the configured ones as they stand; a quiet curve is
    /// under the edge, not faint. The clip is kept to the curves' own box,
    /// since a fill through a path clip costs by the clip's area.
    private static func paintCurves(_ frame: AudioBorealis.Frame, in ctx: CGContext, pill: NSRect,
                                    path: NSBezierPath, sx: CGFloat, sy: CGFloat) {
        let c = frame.config
        let opacity = CGFloat(min(1, max(0, c.opacity)))
        let fill = CGFloat(c.curveOpacity) * opacity
        let edge = CGFloat(c.curveEdge) * opacity
        guard fill > 0.003 || edge > 0.003 else { return }
        let curves = AudioBorealis.curves(frame, width: pill.width, height: pill.height,
                                          scaleX: sx, scaleY: sy, samples: curveSamples)
        let top = curves.flatMap { $0 }.map(\.y).max() ?? 0
        guard top > 0.3 else { return }

        let fade = CGFloat(min(1, max(0, c.curveFade)))
        // Where the band every hill stands on ends: the line is drawn only
        // above it.
        let band = pill.minY + CGFloat((c.curveOffset + c.curveBase * frame.bend)) * sy
        ctx.saveGState()
        ctx.clip(to: CGRect(x: pill.minX, y: pill.minY, width: pill.width, height: CGFloat(top) + 2))
        ctx.addPath(path.cgPath)
        ctx.clip()
        ctx.setLineWidth(1)
        ctx.setLineJoin(.round)
        for (b, curve) in curves.enumerated() where curve.contains(where: { $0.y > 0.3 }) {
            let color = AudioBorealis.color(b, config: c, drift: frame.hue)
            let points = curve.map { CGPoint(x: pill.minX + $0.x, y: pill.minY + $0.y) }
            let crest = pill.minY + CGFloat(curve.map(\.y).max() ?? 0)
            // The hill: from below the bottom edge at one end, along the
            // curve, and back down; the fill is everything under the curve,
            // its colour anchored at the bottom edge and fading toward the
            // crest.
            // (`addLines(between:)` would start a new subpath at the first
            // point, and the close would then run diagonally back to it.)
            let ground = pill.minY - 4
            ctx.saveGState()
            ctx.beginPath()
            ctx.move(to: CGPoint(x: points[0].x, y: ground))
            for p in points { ctx.addLine(to: p) }
            ctx.addLine(to: CGPoint(x: points[points.count - 1].x, y: ground))
            ctx.closePath()
            ctx.clip()
            if c.curveBlend == .additive { ctx.setBlendMode(.plusLighter) }
            if fill > 0.003, let gradient = gradient(r: color.r, g: color.g, b: color.b,
                                                    stops: [(0, fill), (1, fill * fade)]) {
                ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: pill.minY),
                                       end: CGPoint(x: 0, y: max(crest, pill.minY + 1)),
                                       options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            ctx.restoreGState()
            // The hill's edge, above the band only.
            guard edge > 0.003, crest > band + 1.5 else { continue }
            ctx.saveGState()
            ctx.clip(to: CGRect(x: pill.minX, y: band + 1.5, width: pill.width, height: crest - band))
            ctx.beginPath()
            ctx.addLines(between: points)
            ctx.setStrokeColor(CGColor(srgbRed: color.r, green: color.g, blue: color.b, alpha: edge))
            ctx.strokePath()
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    /// A radial gradient squashed into an ellipse. CoreGraphics radial
    /// gradients are circles, so the ellipse comes from scaling the space it
    /// is drawn in. `beyond` paints the last stop's colour past the radius too.
    private static func ellipse(_ ctx: CGContext, _ gradient: CGGradient, at centre: NSPoint,
                                rx: CGFloat, ry: CGFloat, beyond: Bool = false) {
        guard rx > 0, ry > 0 else { return }
        ctx.saveGState()
        if !beyond {
            // Nothing is painted past the radius, so nothing need be
            // evaluated there either.
            ctx.clip(to: CGRect(x: centre.x - rx, y: centre.y - ry, width: rx * 2, height: ry * 2))
        }
        ctx.translateBy(x: centre.x, y: centre.y)
        ctx.scaleBy(x: 1, y: ry / rx)
        ctx.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                               endCenter: .zero, endRadius: rx,
                               options: beyond ? [.drawsAfterEndLocation] : [])
        ctx.restoreGState()
    }

    // MARK: - gradients, cached

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// What decides the colours of a frame, quantised so a slow drift does
    /// not make a new gradient every frame.
    private struct ColorKey: Hashable {
        let mode: AudioBorealis.ColorMode
        let hue: Int
        let width: Int
        let saturation: Int

        init(_ frame: AudioBorealis.Frame) {
            mode = frame.config.colorMode
            hue = Int((frame.config.hueStart + frame.hue).rounded())
            width = Int(frame.config.hueWidth.rounded())
            saturation = Int((frame.config.saturation * 100).rounded())
        }

        /// A config that makes these colours, for the driver's colour function.
        var config: AudioBorealis.Config {
            var c = AudioBorealis.Config()
            c.colorMode = mode
            c.hueStart = Double(hue)
            c.hueWidth = Double(width)
            c.saturation = Double(saturation) / 100
            return c
        }
    }

    private struct LobeKey: Hashable {
        let layer: Layer
        let lobe: Int
        let colors: ColorKey
    }

    private enum White: Hashable {
        case mask(Layer)
    }

    private static var lobeCache: [LobeKey: CGGradient] = [:]
    private static var whiteCache: [White: CGGradient] = [:]

    /// A lobe's colour, fading over the layer's stops.
    private static func lobeGradient(_ layer: Layer, lobe: Int, colors: ColorKey) -> CGGradient? {
        let key = LobeKey(layer: layer, lobe: lobe, colors: colors)
        if let cached = lobeCache[key] { return cached }
        if lobeCache.count > 4096 { lobeCache.removeAll() }
        let c = AudioBorealis.color(lobe, config: colors.config, drift: 0)
        let gradient = self.gradient(r: c.r, g: c.g, b: c.b, stops: layer.stops)
        lobeCache[key] = gradient
        return gradient
    }

    private static func whiteGradient(_ which: White) -> CGGradient? {
        if let cached = whiteCache[which] { return cached }
        let stops: [(CGFloat, CGFloat)]
        switch which {
        case let .mask(layer): stops = layer.maskStops
        }
        let gradient = self.gradient(r: 1, g: 1, b: 1, stops: stops)
        whiteCache[which] = gradient
        return gradient
    }

    /// One colour at each stop's alpha. The same colour throughout rather
    /// than a fade to clear black, which would darken the tail.
    private static func gradient(r: Double, g: Double, b: Double,
                                 stops: [(CGFloat, CGFloat)]) -> CGGradient? {
        var components: [CGFloat] = []
        var locations: [CGFloat] = []
        for (at, alpha) in stops {
            components += [CGFloat(r), CGFloat(g), CGFloat(b), alpha]
            locations.append(at)
        }
        return CGGradient(colorSpace: space, colorComponents: components,
                          locations: locations, count: locations.count)
    }
}
