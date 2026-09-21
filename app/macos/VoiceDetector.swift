// Silero VAD — decides what is speech, so music never reaches the recogniser.
//
// The energy gate in the Rust core only knows loud from quiet. A backing track is
// loud, so it feeds the recogniser continuously; the encoder context fills with
// music and the first words of whoever speaks next are lost. That was measured:
// after 12 s of tone the recogniser silently dropped "god as a direct
// consequence" and resumed mid-sentence.
//
// Wired as a *parallel gate*, never in the delay path. Audio is not held waiting
// for a verdict — the verdict only decides whether to keep feeding. So the 256 ms
// decision window is granularity, not latency: at worst a quarter-second of music
// slips through, or the cut lands a quarter-second late. Buffering-then-releasing
// would have added 256 ms to every subtitle, which is the wrong trade for this app.

import CoreML
import FluidAudio
import Foundation

actor VoiceDetector {
    private var manager: VadManager?
    private var state: VadStreamState?
    private var loaded = false

    private let onStatus: @Sendable (String) -> Void

    /// Silero decides on 4096-sample chunks at 16 kHz — 256 ms.
    static let chunkSamples = 4096

    // Measurements, reported rather than assumed: this project has twice been
    // caught out by a model being slower than its reputation.
    private(set) var computeSeconds = 0.0
    private(set) var speechChunks = 0
    private(set) var totalChunks = 0

    init(onStatus: @escaping @Sendable (String) -> Void) {
        self.onStatus = onStatus
    }

    var isLoaded: Bool { loaded }

    func load() async {
        guard !loaded else { return }
        do {
            let m = try await VadManager()
            state = await m.makeStreamState()
            manager = m
            loaded = true
        } catch {
            // Non-fatal: without it we simply fall back to the energy gate.
            onStatus("VAD unavailable: \(error.localizedDescription)")
        }
    }

    /// True if this 256 ms chunk is inside speech.
    ///
    /// Uses Silero's own hysteresis state machine (`triggered`) rather than
    /// thresholding a raw probability, so brief dips mid-word do not chop the
    /// audio into fragments.
    func isSpeech(_ chunk: [Float]) async -> Bool {
        guard loaded, let manager, let current = state else { return true }
        let started = Date()
        defer { computeSeconds += Date().timeIntervalSince(started) }
        do {
            let result = try await manager.processStreamingChunk(chunk, state: current)
            state = result.state
            totalChunks += 1
            if result.state.triggered { speechChunks += 1 }
            return result.state.triggered
        } catch {
            onStatus("VAD error: \(error.localizedDescription)")
            // Fail open: a broken detector must not silence the subtitles.
            return true
        }
    }

    /// The probability a 256 ms chunk must reach to count as a voice when
    /// the question is "is there one", rather than the gate's "might there
    /// be". The gate takes the model's own bar (0.85) and fails open, since a
    /// missed word costs more than a chunk of music let through; here a
    /// false yes hands a music player the box. Measured 2026-09-21 on this
    /// machine: speech, recorded or synthesized, scores 1.00 on nearly every
    /// chunk and rap 0.98 and above between its beats, while instrumental
    /// music sits near zero with a synth lead or a string swell reaching
    /// 0.85 to 0.89 on a chunk here and there.
    static let sureVoice: Float = 0.95

    /// How much of a stretch of audio is a voice: the share of its 256 ms
    /// chunks that reach `sureVoice`, judged from a fresh state so the
    /// stream's own is left where it was. For the playing-app monitor, which
    /// has listened to an app and wants to know whether the sound it heard
    /// has words in it. Nil when the detector is not loaded, or the audio is
    /// shorter than one chunk: no answer rather than a wrong one. Not counted
    /// in the compute the engine reports, which is per second of the audio
    /// it transcribes.
    func speechFraction(in samples: [Float]) async -> Double? {
        guard loaded, let manager else { return nil }
        let whole = samples.prefix(samples.count / Self.chunkSamples * Self.chunkSamples)
        guard !whole.isEmpty else { return nil }
        do {
            let results = try await manager.process(Array(whole))
            guard !results.isEmpty else { return nil }
            return Double(results.filter { $0.probability >= Self.sureVoice }.count)
                / Double(results.count)
        } catch {
            onStatus("VAD error: \(error.localizedDescription)")
            return nil
        }
    }

    /// Compute seconds since the last call, for folding into the engine's RTF.
    func takeComputeSeconds() -> Double {
        let value = computeSeconds
        computeSeconds = 0
        return value
    }

    /// Fraction of gated-on audio that is actually speech. The interesting number:
    /// whatever is left is what the recogniser used to chew through for nothing.
    func speechFraction() -> Double {
        totalChunks == 0 ? 1 : Double(speechChunks) / Double(totalChunks)
    }

    func reset() async {
        guard let manager else { return }
        state = await manager.makeStreamState()
    }
}
