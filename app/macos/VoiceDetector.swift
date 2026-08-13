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
