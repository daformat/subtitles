// The glow a voice raises along the bottom of the box.
//
// While the app listens, whatever it listens to, the live box wears a band
// of colour along its bottom edge: seven soft lobes fanned out from the
// centre, each following a band of the sound, so speech makes the colours ripple outward
// rather than one blob pumping. The lobes slide sideways while a voice is
// heard, so every colour takes a turn at the centre, and settle when it
// stops; in silence it is gone, and the box is its plain self until someone
// speaks. The envelope is quick enough to follow syllables, so a voice makes
// the glow pulse rather than sit lit. Over the glow, one translucent curve
// per band of the voice, lows to highs, each a hill filled with a colour of
// the palette that rises with its band: the curves of the voice, layered
// like an aurora.
//
// This file is the driver: the arithmetic that turns a loudness into a frame
// of lobe positions, sizes and colours, and the curves. It knows nothing of
// how the frame is painted, and it is written to be transliterated line for
// line into the site's JavaScript, where the same frame becomes CSS custom
// properties on a stack of radial gradients and a canvas for the curves
// (the construction Jakub Antalík's voice-glow uses, which this takes its
// shape from). Every number in it is in px at the reference scale of a
// ~350 pt wide box, and the painter scales them.

import Foundation

public struct AudioBorealis {
    /// The knobs, with the tuned defaults.
    public struct Config: Equatable {
        /// Input gain on the loudness; raise for a quiet microphone. A voice
        /// across a desk, an RMS near 0.01, should show without being raised.
        public var sensitivity = 3.0
        /// The noise gate, on the gained loudness: below it is silence. A
        /// room through a laptop microphone sits near -51 dBFS, 0.042 gained.
        public var threshold = 0.06
        /// How the glow answers the level: the exponent on it. Below 1 a
        /// quiet voice already shows and a loud one is not much bigger.
        public var curve = 0.6
        /// Automatic gain: the gated level and the bands are scaled to their
        /// recent peak, so a voice across a desk fills the same range as a
        /// film's soundtrack. The floor is the least a peak counts for, in
        /// the gated 0-1, so a quiet room is not scaled up into a voice; the
        /// release is the seconds the remembered peak takes to fall away.
        public var autoGain = true
        public var autoGainFloor = 0.3
        public var autoGainRelease = 4.0
        /// Seconds to rise toward a louder level, and to settle after the
        /// sound drops. Syllable speed: a voice pulses the glow.
        public var attack = 0.05
        public var release = 0.2
        /// The resting presence while silent, 0-1, and the period of its
        /// breathing. Nothing: the glow is gone until someone speaks.
        public var idle = 0.0
        public var breatheDuration = 5.2
        /// Height at full level, and the width gained by then. Both grow from
        /// nothing with the voice, so silence is flat.
        public var reach = 1.7
        public var spread = 1.05
        /// Sideways travel of the lobes, px/s at full level; negative reverses, 0 holds.
        public var flow = 60.0
        /// Multiplies the resting distance between lobes, and so the ring they travel around.
        public var lobeSpacing = 0.85
        /// The slow drift of every colour's hue: its range in degrees each way, and its period.
        public var hueRange = 24.0
        public var hueDuration = 12.0
        /// The colours: where on the hue wheel they start, in degrees, how
        /// far round it they spread (360 the whole wheel, 0 a single hue),
        /// their saturation, and whether they are colours at all, or white
        /// or black alone.
        public var hueStart = 0.0
        public var hueWidth = 360.0
        public var saturation = 0.85
        public var colorMode = ColorMode.spectrum
        /// The whole effect's opacity, 0-1, over everything below. The
        /// menu's Medium.
        public var opacity = 0.5
        /// The glow's soft layers' opacity, as a share of their tuned
        /// strength; 0 leaves the curves alone.
        public var glowOpacity = 1.0
        /// The bend: px the glow's ceiling humps up at the centre at full level.
        public var bend = 60.0
        /// The curves. How many (each on a band of the voice, spread from
        /// the lows to the highs; more than there are bands and some share
        /// one); their fill's opacity and their top edge's; the ceiling
        /// they rise toward as a share of the glow's ceiling, and the share
        /// of the box's height that ceiling may never pass (so the curves
        /// stay under the text's baseline); the band every curve stands on,
        /// px across the whole box at full level (it grows with the voice,
        /// so silence is empty), and the px shift of every curve on top of
        /// it (negative sinks them under the edge: a few px, so a band that
        /// has barely risen does not draw a flat line along the edge before
        /// its hill shows); the hill's shape, its
        /// bell exponent (below 2 cusp-like,
        /// 2 gaussian, above flat-topped) and width against its half-range;
        /// and their layout, how far from the centre the outermost hills
        /// rest, the half-width of the hill at the centre and of one at the
        /// edge (shares of the box's width), and how far each wanders with
        /// the flow.
        public var curveCount = 5
        public var curveOpacity = 0.2
        public var curveEdge = 0.35
        /// The fill is anchored at the bottom edge and fades toward the
        /// hill's crest to this share of its opacity (1 keeps it flat); and
        /// how the fills combine where hills overlap, added like light so
        /// hues brighten one another, or laid over one another.
        public var curveFade = 0.35
        public var curveBlend = CurveBlend.normal
        public var curvePosition = 0.25
        public var curveCeiling = 0.55
        public var curveBase = 0.0
        public var curveOffset = -1.5
        public var curveShape = 1.75
        public var curveSpread = 0.87
        public var curveSpan = 0.5
        public var curveWidthCentre = 0.55
        public var curveWidthEdge = 0.32
        public var curveWander = 0.084

        public init() {}

        /// The switches and modes as numbers, for a control that keeps numbers.
        public var autoGainIndex: Int {
            get { autoGain ? 1 : 0 }
            set { autoGain = newValue != 0 }
        }
        public var colorModeIndex: Int {
            get { colorMode.rawValue }
            set { colorMode = ColorMode(rawValue: newValue) ?? .spectrum }
        }
        public var curveBlendIndex: Int {
            get { curveBlend.rawValue }
            set { curveBlend = CurveBlend(rawValue: newValue) ?? .normal }
        }
    }

    public enum ColorMode: Int, CaseIterable {
        case spectrum, white, black
    }

    /// The looks the menu offers: each a setting of the colours, laid over
    /// the config's other knobs.
    public enum Look: String, CaseIterable {
        case rainbow, northernLights, autumn, whiteHaze

        public var title: String {
            switch self {
            case .rainbow: return "Rainbow"
            case .northernLights: return "Northern Lights"
            case .autumn: return "Autumn"
            case .whiteHaze: return "White Haze"
            }
        }

        public func apply(to config: inout Config) {
            switch self {
            case .rainbow:
                config.colorMode = .spectrum
                config.hueStart = 0
                config.hueWidth = 360
            case .northernLights:
                config.colorMode = .spectrum
                config.hueStart = 100
                config.hueWidth = 180
            case .autumn:
                config.colorMode = .spectrum
                config.hueStart = 310
                config.hueWidth = 90
            case .whiteHaze:
                config.colorMode = .white
            }
        }
    }

    /// The strengths the menu offers: the effect's opacity.
    public enum Strength: String, CaseIterable {
        case strong, medium, subtle

        public var title: String {
            switch self {
            case .strong: return "Strong"
            case .medium: return "Medium"
            case .subtle: return "Subtle"
            }
        }

        public var opacity: Double {
            switch self {
            case .strong: return 1
            case .medium: return 0.5
            case .subtle: return 0.35
            }
        }

        public func apply(to config: inout Config) {
            config.opacity = opacity
        }
    }

    public enum CurveBlend: Int, CaseIterable {
        case normal, additive
    }

    /// The bands of the voice the meter reads, low to high: the upper edge
    /// of each in Hz, the last open. Lows (fundamentals and chest), low
    /// mids, mids (vowels), high mids (presence), highs (sibilance). Each
    /// drives a curve, and the lobes follow them too.
    public static let bandEdges: [Double] = [250, 600, 1500, 3500]
    public static var bandCount: Int { bandEdges.count + 1 }

    /// One lobe: where it rests, how big it is, and which band of the voice
    /// lifts it.
    public struct Lobe: Equatable {
        public let x: Double
        public let width: Double
        public let height: Double
        public let band: Int
    }

    /// Seven lobes: the centre on the lows, its neighbours on the mids, the
    /// outer pair on the highs and the far pair on the low mids.
    public static let lobes: [Lobe] = [
        Lobe(x: 0, width: 74, height: 46, band: 0),
        Lobe(x: -36, width: 54, height: 40, band: 2),
        Lobe(x: 36, width: 54, height: 40, band: 2),
        Lobe(x: -72, width: 48, height: 32, band: 4),
        Lobe(x: 72, width: 48, height: 32, band: 4),
        Lobe(x: -108, width: 42, height: 26, band: 1),
        Lobe(x: 108, width: 42, height: 26, band: 1),
    ]

    /// Resting distance between neighbouring lobes, and the width of the ring
    /// they travel around: one full turn of the flow.
    public static let lobeSpacing = 36.0
    public static var lobeSpan: Double { lobeSpacing * Double(lobes.count) }

    /// The ceiling: the ellipse the glow is masked to, as radii in px at
    /// multiplier 1, and the share of its width the tuned look keeps. The
    /// curves rise toward the same hump.
    public static let ceilingHalfWidth = 170.0
    public static let ceilingHeight = 64.0
    public static let rangeWidth = 0.75

    /// Where on the hue wheel each of the seven colours sits, as a share of
    /// the configured width from the start, in the order the lobes wear
    /// them: shuffled, so neighbours contrast rather than shade into one
    /// another. The reference palette's hues, as shares of the wheel. The
    /// curves take the first ones, low band to high.
    public static let hueShares: [Double] = [0.94, 0.56, 0.76, 0.40, 0.08, 0.65, 0.49]

    /// The curves' layout. Of `count` curves, the `index`th rests at this
    /// share of the box's width from the centre: the first at the centre,
    /// the rest alternating outward to either side, evenly, the outermost
    /// at `span`. So the lows are the hill at the centre and the higher
    /// bands the hills to either side.
    public static func curveOffset(_ index: Int, of count: Int, span: Double) -> Double {
        guard count > 1 else { return 0 }
        // Slots from the left, evenly; then the centre-most first, the left
        // of a pair before the right.
        var slots: [Double] = []
        let step: Double = 2 * span / Double(count - 1)
        for i in 0..<count { slots.append(-span + step * Double(i)) }
        slots.sort { (a: Double, b: Double) -> Bool in
            let da = abs(a), db = abs(b)
            if da != db { return da < db }
            return a < b
        }
        return slots[min(index, count - 1)]
    }

    /// The band the `index`th of `count` curves follows: spread from the
    /// lows to the highs, evenly.
    public static func curveBand(_ index: Int, of count: Int) -> Int {
        guard count > 1 else { return 0 }
        return Int((Double(index) * Double(bandCount - 1) / Double(count - 1)).rounded())
    }

    /// What one frame of the glow looks like. Positions and sizes multiply
    /// the lobes' reference px; the painter applies its own scale on top.
    public struct Frame: Equatable {
        /// The knobs this frame was made with, for what the painter derives.
        public var config: Config
        /// The followed level, 0-1: how loud the voice is right now.
        public var level: Double
        /// Each band's followed level, 0-1, low to high.
        public var bands: [Double]
        /// Presence, 0-1: what every layer's opacity is multiplied by.
        public var glow: Double
        /// Height and width multipliers on every lobe and on the mask around them.
        public var height: Double
        public var width: Double
        /// The hue drift, in degrees.
        public var hue: Double
        /// The bend: the ceiling's extra height at the centre, px, and its
        /// strength 0-1, which the curves fade in with.
        public var lift: Double
        public var bend: Double
        /// The flow's phase, 0-1 of one turn of the lobes' ring.
        public var flow: Double
        /// Per lobe: its offset from the centre along the flow, px, and its
        /// amplitude, the band it follows lifting it between 0.6 and 1.3 of the
        /// shared height and the wrap's edge fading it out.
        public var lobeX: [Double]
        public var lobeAmplitude: [Double]
    }

    public var config: Config

    // The envelope, kept across frames.
    private var level = 0.0
    private var bands = [Double](repeating: 0, count: AudioBorealis.bandCount)
    /// The recent peaks the automatic gain scales to: of the gated level,
    /// and of the loudest band.
    private var levelPeak = 0.0
    private var bandPeak = 0.0
    /// Flow phase in px, 0 ≤ phase < span.
    private var phase = 0.0
    /// The glow's own clock, seconds.
    private var time = 0.0

    // Gain applied before `sensitivity`: a laptop microphone at conversational
    // distance gives an RMS of roughly 0.03-0.2, which this lifts into the
    // 0.15-1 range the shaping curve expects.
    static let baseGain = 5.0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Back to silence, with the clock at zero.
    public mutating func reset() {
        level = 0
        bands = [Double](repeating: 0, count: Self.bandCount)
        levelPeak = 0
        bandPeak = 0
        phase = 0
        time = 0
    }

    /// Advance by `dt` seconds on a loudness reading.
    ///
    /// `loudness` is the RMS of the microphone's samples, 0-1, before any
    /// gain. `bands` are the bands of the voice, low to high, as 0-1
    /// loudnesses on a dB scale (see VoiceMeter), or nil where there is no
    /// spectrum to read, in which case the bands are synthesised from the
    /// level so the lobes and curves still move apart rather than in lockstep.
    public mutating func step(dt: Double, loudness: Double, bands input: [Double]?) -> Frame {
        time += dt
        let c = config
        let n = Self.bandCount

        // Raw level and bands from the source.
        let rawLevel = loudness * Self.baseGain * c.sensitivity
        var rawBands = [Double](repeating: 0, count: n)
        if let input, input.count == n {
            rawBands = input
        } else {
            let raw = Self.clamp01(rawLevel)
            for b in 0..<n {
                let wobble = sin(time * (7.3 + 3.1 * Double(b)) + Double(b) * 1.9)
                rawBands[b] = raw * (0.55 + 0.45 * wobble) * (1 - 0.12 * Double(b))
            }
        }

        // Shape and follow: gate, soft saturation, then an attack/release
        // envelope. The bands are gated but not saturated, so they keep
        // their differences: a vowel is lows, a sibilant highs. With the
        // automatic gain, both are scaled to the peak of the last few
        // seconds, floored, so a quiet source fills the range a loud one
        // does and a quiet room stays at nothing.
        var target = Self.shape(rawLevel, threshold: c.threshold)
        var targets = [Double](repeating: 0, count: n)
        for b in 0..<n {
            targets[b] = Self.clamp01((rawBands[b] - c.threshold * 0.6) / max(0.001, 1 - c.threshold * 0.6))
        }
        if c.autoGain {
            let decay = exp(-dt / max(0.05, c.autoGainRelease))
            let floor = max(0.01, min(1, c.autoGainFloor))
            levelPeak = max(target, levelPeak * decay, floor)
            target = min(1, target / levelPeak)
            bandPeak = max(targets.max() ?? 0, bandPeak * decay, floor)
            for b in 0..<n { targets[b] = min(1, targets[b] / bandPeak) }
        }
        level = Self.follow(level, toward: target, dt: dt, attack: c.attack, release: c.release)
        for b in 0..<n {
            bands[b] = Self.follow(bands[b], toward: targets[b], dt: dt, attack: c.attack, release: c.release * 1.15)
        }

        // Idle breathing folded under the voice, when there is any.
        let breathe = 0.5 + 0.5 * sin(2 * .pi * time / c.breatheDuration)
        let eff = level + (1 - level) * c.idle * breathe
        // Everything grows from nothing with the voice, on the curve, so a
        // quiet voice already shows: silence is dark and flat.
        let rise = pow(Self.clamp01(eff), max(0.1, c.curve))
        let glow = rise
        let height = c.reach * rise
        let width = 0.85 + c.spread * rise

        // Flow: the spectrum slides sideways as the voice comes in.
        let span = Self.lobeSpan * c.lobeSpacing
        if c.flow != 0 {
            phase = Self.wrap(phase + c.flow * rise * dt, span: span)
        }

        // Each lobe: its offset along the flow, and its amplitude.
        var xs: [Double] = []
        var amps: [Double] = []
        xs.reserveCapacity(Self.lobes.count)
        amps.reserveCapacity(Self.lobes.count)
        for lobe in Self.lobes {
            let x = Self.wrapX(lobe.x * c.lobeSpacing + phase, span: span)
            let bandLift = 0.6 + 0.7 * bands[min(lobe.band, n - 1)]
            xs.append(x)
            amps.append(bandLift * Self.edgeEnvelope(x, span: span))
        }

        // Hue drift: there and back across the range.
        let hue = c.hueRange == 0 ? 0
            : -c.hueRange + 2 * c.hueRange * Self.pingPong(time / c.hueDuration)

        // Bend: the ceiling humps up with the voice. Flat at silence.
        let lift = max(0, c.bend * rise)
        let bend = c.bend > 0 ? min(1, lift / c.bend) : 0

        return Frame(config: c, level: level, bands: bands, glow: glow, height: height, width: width,
                     hue: hue, lift: lift, bend: bend, flow: phase / max(1, span),
                     lobeX: xs, lobeAmplitude: amps)
    }

    // MARK: - the curves

    /// The curves, `curveCount` of them on bands from the lows to the highs,
    /// each left to right: a point every step across the box as (x, y), x
    /// from the box's left edge and y the height above its bottom edge, in
    /// the box's px. `width` and `height` are the box's; `scaleX` and
    /// `scaleY` are what turn reference px into the box's (1 at the ~350 pt
    /// reference). Each is a hill standing on a band that runs the whole
    /// box: the band `curveBase` px tall at full level, growing with the
    /// voice from nothing, shifted by `curveOffset`; the hill a bell at its
    /// resting place wandering a little with the flow, rising toward the
    /// glow's ceiling as far as its band of the voice is heard, and
    /// running flat into the sides. The ceiling never passes
    /// `curveCeiling` of the box's height.
    public static func curves(_ frame: Frame, width: Double, height: Double,
                              scaleX: Double = 1, scaleY: Double = 1,
                              samples: Int = 40) -> [[(x: Double, y: Double)]] {
        let c = frame.config
        let ceiling = min(height * c.curveCeiling,
                          (ceilingHeight * frame.height + frame.lift) * c.curvePosition * scaleY)
        let base = (c.curveOffset + c.curveBase * frame.bend) * scaleY
        let x0 = 0.0
        let x1 = width
        let steps = max(1, samples)
        let count = max(1, c.curveCount)
        var out: [[(x: Double, y: Double)]] = []
        for k in 0..<count {
            let b = min(curveBand(k, of: count), frame.bands.count - 1)
            let band = b >= 0 ? frame.bands[b] : 0
            let apex = ceiling * (0.15 + 0.85 * band)
            let offset = curveOffset(k, of: count, span: c.curveSpan)
            let wander = c.curveWander * sin(2 * .pi * frame.flow + Double(k) * 1.7)
            let centre = width * (0.5 + offset + wander)
            // Narrower toward the edges.
            let share = c.curveSpan > 0 ? min(1, abs(offset) / c.curveSpan) : 0
            let half = max(1, width * (c.curveWidthCentre + (c.curveWidthEdge - c.curveWidthCentre) * share))
            var points: [(x: Double, y: Double)] = []
            points.reserveCapacity(steps + 1)
            for i in 0...steps {
                let x = x0 + (x1 - x0) * Double(i) / Double(steps)
                let t = max(-1, min(1, (x - centre) / half))
                let y = bell(t, exponent: c.curveShape, sigma: c.curveSpread, skew: 0)
                points.append((x, base + apex * y))
            }
            out.append(points)
        }
        return out
    }

    /// A hill, 1 at the centre and exactly 0 at the ends: exp(-(|t| / σ)^p)
    /// with the tail value subtracted out. `p` below 2 gives the
    /// exponential, cusp-like rise of a bent surface; above 2 a flatter
    /// top. `skew` widens one side and narrows the other.
    static func bell(_ t: Double, exponent p: Double, sigma: Double, skew: Double) -> Double {
        let side = t < 0 ? 1 - skew : 1 + skew
        let s = max(0.05, sigma * side)
        let v = exp(-pow(abs(t) / s, p))
        let tail = exp(-pow(1 / s, p))
        return max(0, (v - tail) / (1 - tail))
    }

    // MARK: - colour

    /// The `index`th colour, as `r, g, b` in 0-1: its share of the hue
    /// wheel from the start, turned by the frame's `drift`, at the
    /// configured saturation and full brightness; or white or black alone.
    /// The site's `hsl()` gives the same colour from the same numbers.
    public static func color(_ index: Int, config c: Config, drift: Double)
        -> (r: Double, g: Double, b: Double) {
        switch c.colorMode {
        case .white: return (1, 1, 1)
        case .black: return (0, 0, 0)
        case .spectrum:
            let share = hueShares[index % hueShares.count]
            let hue = wrap(c.hueStart + c.hueWidth * share + drift, span: 360)
            return hsb(hue / 360, clamp01(c.saturation), 1)
        }
    }

    /// Hue, saturation and brightness in 0-1 to `r, g, b` in 0-1.
    static func hsb(_ h: Double, _ s: Double, _ v: Double) -> (r: Double, g: Double, b: Double) {
        let sector = h * 6
        let i = Int(sector.rounded(.down)) % 6
        let f = sector - sector.rounded(.down)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: - arithmetic

    static func clamp01(_ v: Double) -> Double { v < 0 ? 0 : (v > 1 ? 1 : v) }

    /// Noise gate then soft saturation, so a shout rounds off instead of clipping.
    static func shape(_ raw: Double, threshold: Double) -> Double {
        if raw <= threshold { return 0 }
        let t = (raw - threshold) / max(0.001, 1 - threshold)
        return clamp01((1 - exp(-3 * t)) / (1 - exp(-3)))
    }

    /// One-pole follower: fast up (attack), slow down (release).
    static func follow(_ prev: Double, toward target: Double, dt: Double,
                       attack: Double, release: Double) -> Double {
        let tau = target > prev ? attack : release
        let a = 1 - exp(-dt / max(0.001, tau))
        return prev + (target - prev) * a
    }

    /// Into [0, span).
    static func wrap(_ v: Double, span: Double) -> Double {
        let m = v.truncatingRemainder(dividingBy: span)
        return m < 0 ? m + span : m
    }

    /// A lobe offset into [-span/2, span/2).
    static func wrapX(_ x: Double, span: Double) -> Double {
        wrap(x + span / 2, span: span) - span / 2
    }

    /// How much of a lobe shows at offset x: full at the centre, gone at the
    /// wrap's edge, so a lobe never pops from one side to the other.
    static func edgeEnvelope(_ x: Double, span: Double) -> Double {
        let t = x / (span / 2 + 4)
        return max(0, 1 - t * t)
    }

    /// 0 → 1 → 0 over one unit of phase, smoothly.
    static func pingPong(_ phase: Double) -> Double {
        (1 - cos(2 * .pi * phase)) / 2
    }
}
