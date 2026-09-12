// The picture under a box, softened.
//
// The site's demo draws every box over a six-pixel blur of whatever is under
// it, for legibility: a dark pill over a dark, busy picture is dark on dark,
// and softening the picture is what lets the text stand off it. Nothing this
// process draws can sample what is under the overlay — other apps' windows,
// composited beneath it by the window server long after the pill is drawn —
// so the blur has to be the server's, and the one public way to ask for it is
// NSVisualEffectView in behind-window mode: a backdrop layer the server fills
// with what is behind the window, blurred, under the tint layers that make it
// a material. The material is the problem. Every one of them is a frosted
// panel with a colour of its own, at five times the site's radius, and under a
// black pill the darkest of them reads as solid.
//
// So the view is stripped to its blur: the tint layers hidden, the filters cut
// down to the gaussian, its radius set to the site's. That reaches into the
// view's own layers, which is not API; it is done by class name and key path,
// and a release that rearranges them leaves the material standing rather than
// crashing — a frosted pill, not a broken app.
//
// The server has an older route, CGSSetWindowBackgroundBlurRadius, which
// blurs behind a whole window. Measured, it blurs behind every pixel with any
// alpha at all, at full strength, so the reveal's hole — the pill at a few per
// cent — was blurred too, and the only answer was switching the blur off while
// a hole was open. This view is a layer, and a layer takes a mask: the hole is
// cut out of the blur exactly as it is cut out of the pill.
//
// Within-window mode is the same layer sampling the window's own contents,
// which is what the Settings preview needs: its desktop is its own drawing.

import AppKit

final class BackdropBlurView: NSVisualEffectView {
    /// What the blur is under: a pill's rounded rect, in this view's bounds,
    /// and the reveal's hole through it if one is open.
    struct Shape: Equatable {
        var rect: CGRect
        var corner: CGFloat
        var hole: Hole?

        /// The reveal as SubtitleView draws it: an ellipse about the pointer,
        /// clear to `strength` for most of its radius and easing off at the rim.
        struct Hole: Equatable {
            var center: CGPoint
            var size: CGSize
            var strength: CGFloat
        }
    }

    /// The pill's outline, as the layer's mask; the hole, as the outline's own.
    private let outline = CAShapeLayer()
    private let hole = CAGradientLayer()
    private var holeStrength: CGFloat?

    /// The backdrop layer and its blur filter, once found, so a change of
    /// radius need not walk the layers again.
    private weak var backdrop: CALayer?
    private var blur: AnyObject?

    /// The blur's standard deviation, in points. Zero is no blur, and no
    /// backdrop either: a filter at nought still costs the server a pass.
    var radius: CGFloat = Pill.backdropBlur {
        didSet {
            guard radius != oldValue else { return }
            applyRadius()
            apply()
        }
    }

    init(blending: BlendingMode) {
        super.init(frame: .zero)
        blendingMode = blending
        material = .hudWindow
        // Never the inactive look: the overlay's panels are never key.
        state = .active
        wantsLayer = true
        hole.type = .radial
        layer?.mask = outline
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Nil is no blur at all — the pill at zero, or no text to put one behind.
    var shape: Shape? {
        didSet { if shape != oldValue { apply() } }
    }

    override func layout() {
        super.layout()
        apply()
    }

    // The view relayers itself on these, and each is a chance for the tints to
    // come back or the mask to go.
    override func updateLayer() {
        super.updateLayer()
        strip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        strip()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        strip()
    }

    /// Hide the material, keep the blur, at the radius asked for.
    private func strip() {
        guard let layer else { return }
        if layer.mask !== outline { layer.mask = outline }
        guard let found = Self.backdrop(in: layer), let siblings = found.superlayer?.sublayers else { return }
        for tint in siblings where tint !== found { tint.isHidden = true }
        backdrop = found
        blur = (found.filters ?? []).first { filter in
            let object = filter as AnyObject
            return object.responds(to: NSSelectorFromString("type"))
                && (object.value(forKey: "type") as? String) == "gaussianBlur"
        }.map { $0 as AnyObject }
        applyRadius()
    }

    /// A filter's values are copied into the layer when the array is assigned,
    /// and a change to the object afterwards goes nowhere on its own — not
    /// even assigned again, since the same object is the same array. So the
    /// radius goes in with the array the first time, and after that through
    /// the layer's own key path to the filter, by name, which is what the
    /// layer watches.
    private func applyRadius() {
        guard let backdrop, let blur else { return }
        let wanted = max(radius, 0)
        if backdrop.filters?.count != 1 {
            blur.setValue(wanted, forKey: "inputRadius")
            backdrop.filters = [blur]
            return
        }
        if let name = blur.value(forKey: "name") as? String, !name.isEmpty {
            backdrop.setValue(wanted, forKeyPath: "filters.\(name).inputRadius")
        } else {
            blur.setValue(wanted, forKey: "inputRadius")
            backdrop.filters = []
            backdrop.filters = [blur]
        }
    }

    private static func backdrop(in layer: CALayer) -> CALayer? {
        if String(describing: type(of: layer)).contains("Backdrop") { return layer }
        for sublayer in layer.sublayers ?? [] {
            if let found = backdrop(in: sublayer) { return found }
        }
        return nil
    }

    private func apply() {
        // No implicit animation: the hole follows the pointer at frame rate, and
        // a quarter-second interpolation would leave it trailing behind.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = layer?.bounds ?? self.bounds
        outline.frame = bounds
        guard let shape, radius > 0 else {
            outline.path = nil
            outline.mask = nil
            return
        }
        let corner = min(shape.corner, shape.rect.width / 2, shape.rect.height / 2)
        outline.path = CGPath(roundedRect: shape.rect, cornerWidth: corner, cornerHeight: corner,
                              transform: nil)

        guard let cut = shape.hole, bounds.width > 0, bounds.height > 0 else {
            outline.mask = nil
            return
        }
        // A radial gradient's ellipse runs from its start point, the centre, to
        // its end point, the corner of the ellipse's box, both in unit
        // coordinates of the layer — so the layer is the whole view and the
        // ellipse is placed by those two points. Past the ellipse the gradient
        // holds its last colour, which is what keeps the rest of the pill.
        hole.frame = bounds
        hole.startPoint = CGPoint(x: cut.center.x / bounds.width, y: cut.center.y / bounds.height)
        hole.endPoint = CGPoint(x: (cut.center.x + cut.size.width / 2) / bounds.width,
                                y: (cut.center.y + cut.size.height / 2) / bounds.height)
        if holeStrength != cut.strength {
            holeStrength = cut.strength
            (hole.colors, hole.locations) = Self.holeStops(strength: cut.strength)
        }
        if outline.mask !== hole { outline.mask = hole }
    }

    /// What the blur keeps across the hole: one minus the reveal, whose falloff
    /// is `SubtitleView`'s — flat out to seven tenths of the radius, then a
    /// smoothstep to the rim, sampled because a gradient interpolates linearly
    /// between stops and a straight ramp shows its edge.
    private static func holeStops(strength: CGFloat) -> ([CGColor], [NSNumber]) {
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        func stop(_ location: CGFloat, keep: CGFloat) {
            colors.append(NSColor.black.withAlphaComponent(keep).cgColor)
            locations.append(NSNumber(value: Double(location)))
        }
        let plateau: CGFloat = 0.7
        stop(0, keep: 1 - strength)
        stop(plateau, keep: 1 - strength)
        let steps = 32
        for i in 1...steps {
            let u = CGFloat(i) / CGFloat(steps)
            stop(plateau + u * (1 - plateau), keep: 1 - strength * (1 - u * u * (3 - 2 * u)))
        }
        return (colors, locations)
    }
}
