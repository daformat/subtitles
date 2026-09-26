// The source, muted where it plays, heard again from the app at a level the
// app sets: how the original is lowered under the translation read aloud.
//
// Core Audio's process tap can mute what it taps. Played back through the
// aggregate device the tap already runs on, whose output is the output
// device, the sound comes back on the same clock a buffer later, and the app
// holds its volume. Nothing else macOS offers can lower one app's sound: the
// system volume would lower the voice too, and changes a setting that is the
// user's.
//
// Pure buffer arithmetic, here so the tests can reach it. Runs on the
// realtime thread: no allocation, no locks.

import CoreAudio

/// The level the original is played back at. `target` is written from the
/// main thread, `current` only on the realtime thread, which moves it toward
/// the target a sample at a time, so a change is a ramp and not a click.
/// Plain word-sized floats: no tearing on arm64, and a lock on the realtime
/// thread would cost more than a sample late.
public final class DuckGain {
    public var target: Float = 1
    public internal(set) var current: Float = 1
    public init() {}
}

public enum DuckedPlayback {
    /// The tap's buffer into the output's. The tap's audio is interleaved;
    /// the output may be one interleaved buffer or a buffer per channel, so
    /// channels are counted across buffers. Left and right go to the first
    /// two, a mono output gets their mix, and any further channels are left
    /// as they are. `down` and `up` are the ramp's step per sample.
    public static func play(_ tap: AudioBuffer, into output: UnsafeMutableAudioBufferListPointer,
                            duck: DuckGain, down: Float, up: Float) {
        guard let inData = tap.mData, tap.mNumberChannels > 0 else { return }
        let inChannels = Int(tap.mNumberChannels)
        let input = inData.assumingMemoryBound(to: Float.self)
        let frames = Int(tap.mDataByteSize) / MemoryLayout<Float>.size / inChannels
        let totalOut = output.reduce(0) { $0 + Int($1.mNumberChannels) }
        guard frames > 0, totalOut > 0 else { return }

        // Every channel ramps from the same start over the same frames, so each
        // ends where the others do; the last one's end is where the next
        // callback starts.
        let start = duck.current, target = duck.target
        var end = start
        var firstChannel = 0
        for buffer in output {
            let channels = Int(buffer.mNumberChannels)
            defer { firstChannel += channels }
            guard let outData = buffer.mData, channels > 0 else { continue }
            let out = outData.assumingMemoryBound(to: Float.self)
            let outFrames = min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size / channels)
            for c in 0..<channels where firstChannel + c < 2 {
                let channel = firstChannel + c
                var g = start
                for f in 0..<outFrames {
                    if g > target { g = max(target, g - down) } else if g < target { g = min(target, g + up) }
                    let sample = totalOut == 1 && inChannels > 1
                        ? (input[f * inChannels] + input[f * inChannels + 1]) * 0.5
                        : input[f * inChannels + min(channel, inChannels - 1)]
                    out[f * channels + c] = sample * g
                }
                end = g
            }
        }
        duck.current = end
    }
}
