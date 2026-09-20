// How loud what the app listens to is right now, for the glow.
//
// Fed every buffer from the tap's realtime callback and read at frame rate
// from the main thread. It keeps the loudness (RMS of the samples) and the
// loudness of each band of the voice the glow draws, low to high (the edges
// are the glow's, `AudioBorealis.bandEdges`). The bands come from a chain of
// one-pole low-passes rather than a transform, each band the difference of
// two: the glow wants "how much is there in this band", not a spectrum, and
// a multiply a sample per edge is what the realtime thread can spare.
//
// The two threads share the numbers without a lock. Each is a 32-bit float
// written whole, so a read sees either the old value or the new one; a torn
// frame is not possible, and a frame that reads a buffer late is a frame
// nobody can tell from the one before it.

import CaptionCore
import Foundation

final class VoiceMeter {
    /// [0] loudness, then one per band low to high. Written on the realtime
    /// thread, read on the main thread.
    private static let bandCount = AudioBorealis.bandCount
    private let slots = UnsafeMutablePointer<Float>.allocate(capacity: 1 + VoiceMeter.bandCount)

    /// The input's rate, for the band filters, and the number of floats from
    /// one frame's first sample to the next's: the channel count for
    /// interleaved audio, 1 otherwise. Set from the main thread when the
    /// format is known; the realtime thread reads them each buffer.
    private var sampleRate: Double = 48000
    private var stride = 1

    // The low-passes, one per band edge: their coefficients for the rate
    // (set with the format, read on the realtime thread) and their state
    // (realtime thread only), and the bands' sums for a buffer. Raw memory
    // rather than arrays, so the realtime thread allocates nothing.
    private static let edgeCount = AudioBorealis.bandEdges.count
    private let coefficients = UnsafeMutablePointer<Float>.allocate(capacity: VoiceMeter.edgeCount)
    private let lows = UnsafeMutablePointer<Float>.allocate(capacity: VoiceMeter.edgeCount)
    private let sums = UnsafeMutablePointer<Float>.allocate(capacity: VoiceMeter.edgeCount + 1)

    /// The bands as the glow reads them: a loudness on a dB scale, 0 at
    /// -60 dBFS (a room), 1 at -20 dBFS (a raised voice close to the mic).
    private static let bandFloor = Float(-60)
    private static let bandRange = Float(40)

    /// Smoothing on the way into the slots, seconds: enough that a 60 Hz
    /// reader never misses a 10 ms buffer's peak, short enough to stay live.
    private static let smoothing = 0.03

    init() {
        slots.initialize(repeating: 0, count: 1 + Self.bandCount)
        lows.initialize(repeating: 0, count: Self.edgeCount)
        sums.initialize(repeating: 0, count: Self.edgeCount + 1)
        coefficients.initialize(repeating: 0, count: Self.edgeCount)
        setCoefficients()
    }

    /// What the tap delivers, as it is (re)prepared.
    func configure(for format: TapFormat) {
        sampleRate = format.sampleRate
        stride = format.isInterleaved ? max(1, Int(format.channels)) : 1
        setCoefficients()
    }

    /// One-pole coefficients for the rate, one per edge.
    private func setCoefficients() {
        for e in 0..<Self.edgeCount {
            coefficients[e] = Float(1 - exp(-2 * Double.pi * AudioBorealis.bandEdges[e] / sampleRate))
        }
    }

    deinit {
        slots.deallocate()
        lows.deallocate()
        sums.deallocate()
        coefficients.deallocate()
    }

    /// One buffer of samples, on the realtime thread. Only the first channel
    /// is heard: a microphone is mono, and a stereo mix's two sides agree
    /// closely enough for a glow.
    func feed(_ samples: UnsafePointer<Float>, count: Int) {
        let stride = self.stride
        let rate = sampleRate
        guard count > 0, stride > 0, rate > 0 else { return }
        let edges = Self.edgeCount
        let a = coefficients, lows = self.lows, sums = self.sums

        var sum: Float = 0
        for b in 0...edges { sums[b] = 0 }
        var n: Float = 0
        var i = 0
        while i < count {
            let x = samples[i]
            sum += x * x
            // Each low-pass follows the input; each band is what one
            // low-pass has that the one below it has not.
            var below: Float = 0
            for e in 0..<edges {
                lows[e] += a[e] * (x - lows[e])
                let band = lows[e] - below
                sums[e] += band * band
                below = lows[e]
            }
            let top = x - below
            sums[edges] += top * top
            n += 1
            i += stride
        }
        guard n > 0 else { return }

        // The buffer's share of the smoothing window.
        let seconds = Double(n) / rate
        let k = Float(1 - exp(-seconds / Self.smoothing))
        func settle(_ slot: Int, _ value: Float) {
            slots[slot] += (value - slots[slot]) * k
        }
        settle(0, (sum / n).squareRoot())
        for b in 0...edges { settle(1 + b, Self.bandLoudness(sums[b] / n)) }
    }

    /// Mean square → the 0-1 loudness the glow's bands take.
    private static func bandLoudness(_ meanSquare: Float) -> Float {
        guard meanSquare > 0 else { return 0 }
        let dB = 10 * log10(meanSquare)
        return min(1, max(0, (dB - bandFloor) / bandRange))
    }

    /// The latest reading, from the main thread.
    func read() -> (loudness: Double, bands: [Double]) {
        (Double(slots[0]), (0..<Self.bandCount).map { Double(slots[1 + $0]) })
    }

    /// Back to silence, so a source switch does not open on the last thing heard.
    func clear() {
        for i in 0...Self.bandCount { slots[i] = 0 }
    }
}
