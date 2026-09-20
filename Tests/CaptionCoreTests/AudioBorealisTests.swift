// The borealis's driver: silence is dark, a voice raises it, and it settles.
//
// The painter and the site's JavaScript both take the driver's frames as
// given, so what the frames promise is pinned here: a lobe never leaves its
// ring, the colours never leave the range, a level rises faster than it
// falls, and each band has a curve of its own.

import XCTest
@testable import CaptionCore

final class AudioBorealisTests: XCTestCase {
    private let dt = 1.0 / 60
    private let n = AudioBorealis.bandCount
    private var silent: [Double] { [Double](repeating: 0, count: n) }
    private var full: [Double] { [Double](repeating: 1, count: n) }

    private func run(_ glow: inout AudioBorealis, seconds: Double, loudness: Double,
                     bands: [Double]? = nil) -> AudioBorealis.Frame {
        var frame = glow.step(dt: dt, loudness: loudness, bands: bands)
        var t = dt
        while t < seconds {
            frame = glow.step(dt: dt, loudness: loudness, bands: bands)
            t += dt
        }
        return frame
    }

    func testSilenceIsDarkAndFlat() {
        var glow = AudioBorealis()
        for _ in 0..<Int(glow.config.breatheDuration * 60) {
            let frame = glow.step(dt: dt, loudness: 0, bands: silent)
            XCTAssertEqual(frame.level, 0, accuracy: 1e-9)
            XCTAssertEqual(frame.glow, 0, accuracy: 1e-9)
            XCTAssertEqual(frame.height, 0, accuracy: 1e-9)
            XCTAssertEqual(frame.lift, 0, accuracy: 1e-9)
            XCTAssertEqual(frame.bend, 0, accuracy: 1e-9)
        }
        // With a resting presence asked for, it breathes: on the response
        // curve, so a fifth of presence shows as a good third.
        glow.config.idle = 0.2
        var lowest = 1.0, highest = 0.0
        for _ in 0..<Int(glow.config.breatheDuration * 60) {
            let frame = glow.step(dt: dt, loudness: 0, bands: silent)
            lowest = min(lowest, frame.glow)
            highest = max(highest, frame.glow)
        }
        XCTAssertLessThan(highest, 0.45)
        XCTAssertGreaterThan(highest - lowest, 0.05)
    }

    func testAVoiceRaisesTheGlowAndItSettlesSlower() {
        var glow = AudioBorealis()
        let quiet = run(&glow, seconds: 1, loudness: 0, bands: silent)
        let loud = run(&glow, seconds: 1, loudness: 0.2, bands: full)
        XCTAssertGreaterThan(loud.level, 0.9)
        XCTAssertGreaterThan(loud.height, quiet.height)
        XCTAssertGreaterThan(loud.width, quiet.width)
        XCTAssertGreaterThan(loud.glow, quiet.glow)
        XCTAssertGreaterThan(loud.lift, 50)

        // Most of the way up within the attack time, and still a third of the
        // way up one release time after the voice stops.
        var rising = AudioBorealis()
        let early = run(&rising, seconds: rising.config.attack, loudness: 0.2, bands: full)
        XCTAssertGreaterThan(early.level, 0.55)
        let held = run(&glow, seconds: glow.config.release, loudness: 0, bands: silent)
        XCTAssertGreaterThan(held.level, 0.3)
        XCTAssertLessThan(held.level, loud.level)
        let gone = run(&glow, seconds: 2, loudness: 0, bands: silent)
        XCTAssertLessThan(gone.level, 0.01)
    }

    func testSpeechAcrossADeskShowsWithoutBeingRaised() {
        // A laptop microphone gives an RMS near 0.01 for a voice across the
        // desk and 0.05 for a raised one: without the automatic gain, the
        // quiet voice must already show, on the slope where syllables do,
        // and the raised one be bigger.
        var config = AudioBorealis.Config()
        config.autoGain = false
        var soft = AudioBorealis(config: config)
        let low = run(&soft, seconds: 1, loudness: 0.01, bands: full)
        var firm = AudioBorealis(config: config)
        let high = run(&firm, seconds: 1, loudness: 0.05, bands: full)
        XCTAssertGreaterThan(low.level, 0.2)
        XCTAssertLessThan(low.level, 0.7)
        XCTAssertGreaterThan(low.glow, 0.4)
        XCTAssertGreaterThan(high.level - low.level, 0.25)
    }

    func testAutoGainMakesAQuietSourceFillTheRangeOfALoudOne() {
        // The microphone at a desk and a film's soundtrack: with the
        // automatic gain, a second in, both sit near the top, the quiet
        // bands of the one scaled like the loud bands of the other; and a
        // room's noise is still nothing, floor or no floor.
        var mic = AudioBorealis()
        let quiet = run(&mic, seconds: 1.5, loudness: 0.01, bands: [0.35, 0.3, 0.2, 0.1, 0.05])
        var film = AudioBorealis()
        let loud = run(&film, seconds: 1.5, loudness: 0.2, bands: [0.9, 0.8, 0.6, 0.4, 0.2])
        // The floor keeps a whisper short of the top; a desk voice gets most
        // of the way.
        XCTAssertGreaterThan(quiet.level, 0.8)
        XCTAssertGreaterThan(loud.level, 0.9)
        XCTAssertEqual(quiet.bands[0], loud.bands[0], accuracy: 0.1)
        XCTAssertGreaterThan(quiet.bands[0], 0.85)
        var room = AudioBorealis()
        let noise = run(&room, seconds: 2, loudness: 0.0028, bands: [0.05, 0.03, 0.02, 0.01, 0])
        XCTAssertEqual(noise.level, 0, accuracy: 1e-9)
        XCTAssertLessThan(noise.bands.max()!, 0.2)
        // And the peak lets go: silence after a shout falls all the way.
        let gone = run(&film, seconds: 2, loudness: 0, bands: silent)
        XCTAssertLessThan(gone.level, 0.01)
    }

    func testSyllablesShowInTheEnvelope() {
        // A voice pulsing at 5 Hz: the level must swing by a good share of
        // its peak, not smooth to a plateau.
        var glow = AudioBorealis()
        var lowest = 1.0, highest = 0.0
        var t = 0.0
        for i in 0..<600 {
            let on = (t * 5).truncatingRemainder(dividingBy: 1) < 0.5
            let frame = glow.step(dt: dt, loudness: on ? 0.1 : 0.002, bands: full)
            if i >= 300 {
                lowest = min(lowest, frame.level)
                highest = max(highest, frame.level)
            }
            t += dt
        }
        XCTAssertGreaterThan(highest - lowest, 0.3)
    }

    func testRoomNoiseStaysUnderTheGate() {
        var glow = AudioBorealis()
        // -51 dBFS: a room through a laptop microphone.
        let frame = run(&glow, seconds: 2, loudness: 0.0028, bands: silent)
        XCTAssertEqual(frame.level, 0, accuracy: 1e-9)
    }

    func testBandsKeepTheirDifferences() {
        // A vowel is lows, a sibilant highs: the bands must not all saturate
        // to the same value the moment there is sound.
        var glow = AudioBorealis()
        let vowel = run(&glow, seconds: 1, loudness: 0.05, bands: [0.8, 0.6, 0.4, 0.2, 0.1])
        XCTAssertEqual(vowel.bands.count, n)
        XCTAssertGreaterThan(vowel.bands[0] - vowel.bands[4], 0.4)
        let sibilant = run(&glow, seconds: 1, loudness: 0.05, bands: [0.1, 0.2, 0.4, 0.6, 0.8])
        XCTAssertGreaterThan(sibilant.bands[4] - sibilant.bands[0], 0.4)
    }

    func testLobesStayOnTheirRingWhileFlowing() {
        var glow = AudioBorealis()
        let span = AudioBorealis.lobeSpan * glow.config.lobeSpacing
        for _ in 0..<600 {
            let frame = glow.step(dt: dt, loudness: 0.2, bands: nil)
            XCTAssertEqual(frame.lobeX.count, AudioBorealis.lobes.count)
            for (x, amp) in zip(frame.lobeX, frame.lobeAmplitude) {
                XCTAssertGreaterThanOrEqual(x, -span / 2)
                XCTAssertLessThan(x, span / 2)
                XCTAssertGreaterThanOrEqual(amp, 0)
                XCTAssertLessThanOrEqual(amp, 1.3)
            }
            XCTAssertGreaterThanOrEqual(frame.flow, 0)
            XCTAssertLessThan(frame.flow, 1)
        }
        // The flow moved the centre lobe off the centre.
        let frame = glow.step(dt: dt, loudness: 0.2, bands: nil)
        XCTAssertNotEqual(frame.lobeX[0], 0, accuracy: 0.5)
    }

    func testFlowHoldsAtZero() {
        var glow = AudioBorealis()
        glow.config.flow = 0
        let frame = run(&glow, seconds: 3, loudness: 0.2, bands: nil)
        XCTAssertEqual(frame.lobeX[0], 0, accuracy: 1e-9)
    }

    func testHueDriftsWithinItsRange() {
        var glow = AudioBorealis()
        var seen: [Double] = []
        for _ in 0..<Int(glow.config.hueDuration * 60) {
            seen.append(glow.step(dt: dt, loudness: 0, bands: nil).hue)
        }
        XCTAssertLessThanOrEqual(seen.max()!, glow.config.hueRange + 1e-9)
        XCTAssertGreaterThanOrEqual(seen.min()!, -glow.config.hueRange - 1e-9)
        XCTAssertGreaterThan(seen.max()! - seen.min()!, glow.config.hueRange)
    }

    func testColoursComeFromTheHueWheelOrNone() {
        var config = AudioBorealis.Config()
        // Every colour in range whatever the start and the drift, and the
        // seven all different across the whole wheel.
        for start in stride(from: 0.0, through: 360, by: 45) {
            config.hueStart = start
            var seen: [String] = []
            for i in 0..<AudioBorealis.lobes.count {
                let c = AudioBorealis.color(i, config: config, drift: -20)
                for v in [c.r, c.g, c.b] {
                    XCTAssertGreaterThanOrEqual(v, 0)
                    XCTAssertLessThanOrEqual(v, 1)
                }
                seen.append(String(format: "%.2f %.2f %.2f", c.r, c.g, c.b))
            }
            XCTAssertEqual(Set(seen).count, AudioBorealis.lobes.count)
        }
        // No width: one hue for all, the start's.
        config.hueStart = 120
        config.hueWidth = 0
        config.saturation = 1
        let one = AudioBorealis.color(0, config: config, drift: 0)
        XCTAssertEqual(one.g, 1, accuracy: 1e-9)
        XCTAssertEqual(one.r, 0, accuracy: 1e-9)
        for i in 0..<AudioBorealis.lobes.count {
            let c = AudioBorealis.color(i, config: config, drift: 0)
            XCTAssertEqual(c.r, one.r, accuracy: 1e-9)
            XCTAssertEqual(c.g, one.g, accuracy: 1e-9)
            XCTAssertEqual(c.b, one.b, accuracy: 1e-9)
        }
        // No saturation: grey, whatever the hue.
        config.saturation = 0
        let grey = AudioBorealis.color(3, config: config, drift: 90)
        XCTAssertEqual(grey.r, grey.g, accuracy: 1e-9)
        XCTAssertEqual(grey.g, grey.b, accuracy: 1e-9)
        // White or black alone.
        config.colorMode = .white
        let white = AudioBorealis.color(2, config: config, drift: 30)
        XCTAssertEqual(white.r + white.g + white.b, 3, accuracy: 1e-9)
        config.colorMode = .black
        let black = AudioBorealis.color(2, config: config, drift: 30)
        XCTAssertEqual(black.r + black.g + black.b, 0, accuracy: 1e-9)
        config.colorModeIndex = 0
        XCTAssertEqual(config.colorMode, .spectrum)
    }

    func testEachBandHasACurveThatRisesWithIt() {
        var glow = AudioBorealis()
        // With a band under the hills, to see it in the numbers, and no
        // wander, so each hill peaks where the layout rests it.
        glow.config.curveBase = 8
        glow.config.curveWander = 0
        let width = 600.0, height = 63.0
        // Silence: no curve above the edge.
        let quiet = run(&glow, seconds: 1, loudness: 0, bands: silent)
        for curve in AudioBorealis.curves(quiet, width: width, height: height) {
            XCTAssertLessThanOrEqual(curve.map(\.y).max()!, 1e-9)
        }
        // A vowel: the low band's curve is the tallest, the high band's the
        // lowest, none past the ceiling, and each hill peaks near its own
        // resting place.
        let vowel = run(&glow, seconds: 1, loudness: 0.05, bands: [0.9, 0.6, 0.4, 0.2, 0.05])
        let curves = AudioBorealis.curves(vowel, width: width, height: height)
        XCTAssertEqual(curves.count, vowel.config.curveCount)
        let peaks = curves.map { $0.map(\.y).max()! }
        XCTAssertGreaterThan(peaks[0], peaks[4] + 5)
        // Every curve stands on its band: never below the base, at the
        // sides included, where only the hill's flank is left.
        let base = vowel.config.curveBase * vowel.bend + vowel.config.curveOffset
        XCTAssertGreaterThan(base, 5)
        for (k, curve) in curves.enumerated() {
            XCTAssertLessThanOrEqual(peaks[k], height * vowel.config.curveCeiling + base + 1e-9)
            XCTAssertGreaterThanOrEqual(curve.map(\.y).min()!, base - 1e-9)
            let at = curve.max { $0.y < $1.y }!.x
            let rest = width * (0.5 + AudioBorealis.curveOffset(k, of: curves.count, span: vowel.config.curveSpan))
            // At its resting place, to a sample's width (an outer hill rests
            // at a side and peaks at the very end).
            let leeway = width * 0.05
            XCTAssertEqual(min(max(at, 0), width), min(max(rest, 0), width), accuracy: leeway,
                           "curve \(k) peaks at \(at), rests at \(rest)")
        }
        // The layout for any count: the first the centre-most (at the centre
        // itself for an odd count; an even count straddles it), the rest
        // alternating outward, the outermost at the span; the bands spread
        // from the lows to the highs.
        for count in 1...7 {
            let offsets = (0..<count).map { AudioBorealis.curveOffset($0, of: count, span: 0.4) }
            XCTAssertEqual(abs(offsets[0]), offsets.map(abs).min()!, accuracy: 1e-9)
            if count % 2 == 1 { XCTAssertEqual(offsets[0], 0, accuracy: 1e-9) }
            XCTAssertEqual(offsets.map(abs).max()!, count > 1 ? 0.4 : 0, accuracy: 1e-9)
            XCTAssertEqual(Set(offsets).count, count)
            XCTAssertEqual(AudioBorealis.curveBand(0, of: count), 0)
            XCTAssertEqual(AudioBorealis.curveBand(count - 1, of: count), count > 1 ? n - 1 : 0)
        }
        var few = vowel
        few.config.curveCount = 3
        XCTAssertEqual(AudioBorealis.curves(few, width: width, height: height).count, 3)
        // Every curve spans the box from side to side.
        for curve in curves {
            XCTAssertEqual(curve.first!.x, 0, accuracy: 1e-9)
            XCTAssertEqual(curve.last!.x, width, accuracy: 1e-9)
        }
    }
}
