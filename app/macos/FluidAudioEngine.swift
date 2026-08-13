// FluidAudio engine — Parakeet on the Apple Neural Engine.
//
// Why this exists at all: Parakeet is the model we want (it emits punctuation and
// true casing itself, removing this project's sentence-casing hack), but its
// streaming export re-encodes 5.6 s of left context per 80 ms chunk. Measured
// through sherpa-onnx on CPU that is RTF 10.7–31.8 — about 100x too slow.
// FluidAudio runs the same family on the ANE via CoreML, which is what makes it
// viable. See PLAN.md §11.
//
// The Rust core keeps doing capture, resampling, gating and pre-roll — that
// pipeline is measured and worth keeping. Only the recogniser moves out here,
// through the core's `external_engine` seam.

import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// A selectable FluidAudio configuration.
///
/// Both families trade latency against accuracy through chunk size, which is the
/// axis worth exposing: this whole app is a latency argument.
enum FluidVariant: String, CaseIterable {
    case eou160, eou320, eou1280
    case nemotron560, nemotron1120, nemotron2240

    var displayName: String {
        switch self {
        case .eou160: return "Parakeet EOU · 160 ms"
        case .eou320: return "Parakeet EOU · 320 ms"
        case .eou1280: return "Parakeet EOU · 1280 ms"
        case .nemotron560: return "Nemotron · 560 ms"
        case .nemotron1120: return "Nemotron · 1120 ms"
        case .nemotron2240: return "Nemotron · 2240 ms"
        }
    }

    /// Upstream's own characterisation. Unlike the sherpa entries in
    /// ModelCatalog, these are not numbers this project has measured.
    var note: String {
        switch self {
        case .eou160: return "120M · lowest latency · ~8% WER"
        case .eou320: return "120M · balanced · ~5% WER"
        case .eou1280: return "120M · highest throughput"
        case .nemotron560: return "0.6B · lowest latency tier"
        case .nemotron1120: return "0.6B · the trained chunk size"
        case .nemotron2240: return "0.6B · default · highest throughput"
        }
    }

    var isEou: Bool {
        switch self {
        case .eou160, .eou320, .eou1280: return true
        default: return false
        }
    }

    var chunkSamples: Int {
        switch self {
        case .eou160: return 16000 * 160 / 1000
        case .eou320: return 16000 * 320 / 1000
        case .eou1280: return 16000 * 1280 / 1000
        case .nemotron560: return 16000 * 560 / 1000
        case .nemotron1120: return 16000 * 1120 / 1000
        case .nemotron2240: return 16000 * 2240 / 1000
        }
    }

    var eouChunkSize: StreamingChunkSize {
        switch self {
        case .eou320: return .ms320
        case .eou1280: return .ms1280
        default: return .ms160
        }
    }

    var nemotronChunkSize: NemotronChunkSize {
        switch self {
        case .nemotron560: return .ms560
        case .nemotron1120: return .ms1120
        default: return .ms2240
        }
    }
}

/// Drives one FluidAudio streaming manager.
///
/// An actor because both managers are actors and audio arrives from the core's
/// worker thread; serialising here keeps the feed ordered without locking on the
/// caller's side.
actor FluidAudioEngine {
    private let variant: FluidVariant
    private var eou: StreamingEouAsrManager?
    private var nemotron: StreamingNemotronAsrManager?

    private var pending: [Float] = []
    private var loaded = false

    /// Partial transcripts, delivered on the main thread.
    private let onPartial: @Sendable (String) -> Void
    private let onStatus: @Sendable (String) -> Void
    /// Fires once the models are actually usable. Without it, audio fed during
    /// the (minutes-long, first-run) load is dropped with nothing to show for it.
    private let onReady: @Sendable (Bool) -> Void

    /// Counts frames discarded because the engine was not loaded yet, so the
    /// "nothing is happening" case is observable instead of silent.
    private var droppedWhileLoading = 0

    /// Bound on queued audio, mirroring the core's ring backlog rule: falling
    /// behind should cost a few dropped words once, not permanent latency.
    private let maxPending = 16000 * 3

    init(variant: FluidVariant,
         onPartial: @escaping @Sendable (String) -> Void,
         onStatus: @escaping @Sendable (String) -> Void,
         onReady: @escaping @Sendable (Bool) -> Void) {
        self.variant = variant
        self.onPartial = onPartial
        self.onStatus = onStatus
        self.onReady = onReady
    }

    private static var pcmFormat: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                      channels: 1, interleaved: false)!
    }

    private func buffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        let format = Self.pcmFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                         frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buf.floatChannelData else { return nil }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            channel[0].update(from: src.baseAddress!, count: samples.count)
        }
        return buf
    }

    /// Downloads (first run) and loads the CoreML bundles. Slow — minutes on a
    /// cold cache, since the models come from HuggingFace.
    func load() async {
        guard !loaded else { return }
        onStatus("Loading \(variant.displayName)…")
        do {
            if variant.isEou {
                let manager = StreamingEouAsrManager(chunkSize: variant.eouChunkSize)
                let partial = onPartial
                await manager.setPartialTranscriptCallback { text in partial(text) }
                try await manager.loadModels()
                eou = manager
            } else {
                // Leave `configuration` nil: FluidAudio then picks
                // .cpuAndNeuralEngine. Passing a bare MLModelConfiguration()
                // means .all, under which CoreML routes the int8 encoder to the
                // GPU and runs roughly 10x slower — i.e. the exact trap this
                // engine exists to avoid.
                let manager = StreamingNemotronAsrManager(
                    requestedChunkSize: variant.nemotronChunkSize)
                let partial = onPartial
                await manager.setPartialCallback { text in partial(text) }
                try await manager.loadModels()
                nemotron = manager
            }
            loaded = true
            onStatus("")
            onReady(true)
            if droppedWhileLoading > 0 {
                onStatus("")
            }
        } catch {
            onStatus("FluidAudio failed to load: \(error.localizedDescription)")
            onReady(false)
        }
    }

    /// 16 kHz mono frames from the core.
    func feed(_ samples: [Float]) async {
        guard loaded else {
            droppedWhileLoading += samples.count
            return
        }
        pending.append(contentsOf: samples)
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }

        let chunk = variant.chunkSamples
        while pending.count >= chunk {
            let slice = Array(pending.prefix(chunk))
            pending.removeFirst(chunk)
            guard let buf = buffer(from: slice) else { continue }
            do {
                if let eou {
                    _ = try await eou.process(audioBuffer: buf)
                } else if let nemotron {
                    _ = try await nemotron.process(audioBuffer: buf)
                }
            } catch {
                onStatus("transcription error: \(error.localizedDescription)")
            }
        }
    }

    /// Called at the core's endpoint: flush and start a fresh utterance.
    func endUtterance() async {
        guard loaded else { return }
        pending.removeAll()
        do {
            if let eou {
                let text = try await eou.finish()
                if !text.isEmpty { onPartial(text) }
                await eou.reset()
            } else if let nemotron {
                let text = try await nemotron.finish()
                if !text.isEmpty { onPartial(text) }
                await nemotron.reset()
            }
        } catch {
            onStatus("finish failed: \(error.localizedDescription)")
        }
    }

    func shutdown() async {
        if let eou { await eou.cleanup() }
        if let nemotron { await nemotron.cleanup() }
        eou = nil
        nemotron = nil
        loaded = false
    }
}
