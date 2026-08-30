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

/// One transcribed word with the audio time it was spoken at.
///
/// Paging anchors on these times rather than on a word *count*. A count anchor
/// skips any words that happen to arrive in the same update as the anchor point,
/// so a new page could start part-way into a sentence; a time anchor cannot.
struct TimedWord: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// A selectable FluidAudio configuration.
///
/// Both families trade latency against accuracy through chunk size, which is the
/// axis worth exposing: this whole app is a latency argument.
enum FluidVariant: String, CaseIterable {
    case eou160, eou320, eou1280
    case nemotron560, nemotron1120, nemotron2240
    case unified
    /// The only variant that is not English-only. Which language it recognises is
    /// a separate setting — see `FluidLanguage`.
    case multilingual

    var displayName: String {
        switch self {
        case .eou160: return "Parakeet EOU · 160 ms"
        case .eou320: return "Parakeet EOU · 320 ms"
        case .eou1280: return "Parakeet EOU · 1280 ms"
        case .nemotron560: return "Nemotron · 560 ms"
        case .nemotron1120: return "Nemotron · 1120 ms"
        case .nemotron2240: return "Nemotron · 2240 ms"
        case .unified: return "Parakeet Unified · punctuated"
        case .multilingual: return "Multilingual · 560 ms"
        }
    }

    /// Download size, then whatever most distinguishes this variant.
    ///
    /// Size rather than the parameter count the model cards lead with (120M /
    /// 0.6B): those two track each other under int8 — roughly a byte per
    /// parameter — so the count adds nothing the size does not, and the size is
    /// the number being decided about. Switching model is minutes of download.
    ///
    /// Measured from the HuggingFace repos, compiled `.mlmodelc` only, which is
    /// all the downloader fetches. Multilingual is a range because its pack
    /// follows the language: 583 MB Latin-script, 633 MB full vocab.
    ///
    /// The rest is upstream's characterisation, not numbers this project has
    /// measured — except EOU 160's RTF, which is ours.
    var note: String {
        switch self {
        // Upstream calls this the lowest-latency tier, and in principle it is —
        // but measured here it runs at RTF 0.63–2.22, i.e. at or past real time,
        // because 160 ms chunks double the model invocations per second. eou320
        // manages 0.13–0.15 on the same machine.
        case .eou160: return "215 MB · no punctuation · ⚠︎ RTF 0.6–2.2 here"
        case .eou320: return "215 MB · no punctuation · RTF 0.13–0.15"
        case .eou1280: return "215 MB · no punctuation · highest throughput"
        case .nemotron560: return "612 MB · punctuated · lowest latency"
        case .nemotron1120: return "612 MB · punctuated · the trained chunk size"
        case .nemotron2240: return "612 MB · punctuated · highest throughput"
        case .unified: return "595 MB · punctuated · 2.08 s · Nemotron is faster"
        case .multilingual: return "583–633 MB · default · 8 languages · punctuated"
        }
    }

    var isEou: Bool {
        switch self {
        case .eou160, .eou320, .eou1280: return true
        default: return false
        }
    }

    /// True for the variant with its own context-window contract — one
    /// checkpoint serving both offline and streaming, over a [70,13,13] window.
    ///
    /// Not "the one that punctuates": every family except EOU emits punctuation
    /// and capitals itself.
    var isUnified: Bool { self == .unified }

    var isMultilingual: Bool { self == .multilingual }


    var chunkSamples: Int {
        switch self {
        case .multilingual: return 16000 * 560 / 1000
        case .unified: return UnifiedConfig().chunkSamples
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

/// A language the multilingual model can be pinned to, plus `auto`.
///
/// The repo ships two vocabularies and the download follows the language, not the
/// user: the six Latin-script languages share a pruned 2828-token pack (583 MB),
/// while zh/ja — and `auto`, which must be able to decode anything — need the full
/// 13087-token pack (633 MB). Switching within a pack is free; crossing between
/// them is another download, which is why the two groups are kept visibly apart in
/// the menu.
enum FluidLanguage: String, CaseIterable {
    case auto
    case en, es, fr, it, pt, de
    case zh, ja

    /// FLEURS-style code the model's prompt dictionary is keyed on.
    var code: String {
        switch self {
        case .auto: return "auto"
        case .en: return "en-US"
        case .es: return "es-ES"
        case .fr: return "fr-FR"
        case .it: return "it-IT"
        case .pt: return "pt-BR"
        case .de: return "de-DE"
        case .zh: return "zh-CN"
        case .ja: return "ja-JP"
        }
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .de: return "Deutsch"
        case .zh: return "中文"
        case .ja: return "日本語"
        }
    }

    /// True when this language is served by the smaller Latin-script pack.
    /// Mirrors `StreamingNemotronMultilingualAsrManager.languageDirectory`.
    var usesLatinPack: Bool {
        switch self {
        case .en, .es, .fr, .it, .pt, .de: return true
        case .auto, .zh, .ja: return false
        }
    }
}

/// Drives one FluidAudio streaming manager.
///
/// An actor because both managers are actors and audio arrives from the core's
/// worker thread; serialising here keeps the feed ordered without locking on the
/// caller's side.
/// Bounded hand-off between the core's worker thread and the engine actor.
///
/// The obvious implementation — `Task { await engine.feed(samples) }` per
/// callback — is a trap: if the engine falls behind real time the tasks queue
/// without bound, each holding a sample array, and memory pressure drags the
/// whole pipeline down. Observed as RTF climbing into the hundreds while the
/// core's ring dropped 1.6M samples.
///
/// This is the same discipline the Rust ring already uses: a fixed ceiling, and
/// drop the oldest audio rather than accumulate latency that can never be repaid.
final class FrameQueue: @unchecked Sendable {
    private var buffer: [Float] = []
    private let lock = NSLock()
    private let maxSamples = 16000 * 3  // 3 s
    private(set) var droppedSamples = 0

    /// Called on the core's worker thread — not the realtime audio thread, so a
    /// lock here is fine.
    func push(_ samples: UnsafeBufferPointer<Float>) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        if buffer.count > maxSamples {
            let excess = buffer.count - maxSamples
            buffer.removeFirst(excess)
            droppedSamples += excess
        }
    }

    /// Throw away whatever is queued. Used when the audio in flight has stopped
    /// being worth transcribing at all, rather than merely being late.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let out = buffer
        buffer.removeAll(keepingCapacity: true)
        return out
    }
}

/// De-duplicates download progress so the menu bar is repainted only when the
/// rendered line actually changes. `@unchecked Sendable` for the same reason as
/// `FrameQueue`: FluidAudio calls the handler on an unspecified queue.
final class LastProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func shouldReport(_ headline: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard headline != last else { return false }
        last = headline
        return true
    }
}

actor FluidAudioEngine {
    private let variant: FluidVariant
    private var eou: StreamingEouAsrManager?
    private var nemotron: StreamingNemotronAsrManager?
    private var unified: StreamingUnifiedAsrManager?
    private var multilingual: StreamingNemotronMultilingualAsrManager?
    /// Which language the multilingual variant is pinned to. Ignored by the
    /// English-only variants.
    private let language: FluidLanguage
    /// Optional: breaks the page when the speaker changes. nil when disabled.
    private var speakers: SpeakerTracker?
    /// Optional: decides what is speech, so music never reaches the recogniser.
    private var vad: VoiceDetector?

    // VAD gating state. `history` is a ~1 s pre-roll replayed at each speech
    // onset, so gating on VAD cannot clip the first word — the same mechanism
    // that fixed cold starts in the core.
    private var vadPending: [Float] = []
    private var asrPending: [Float] = []
    private var history: [Float] = []
    private var wasSpeech = false
    private let historyCap = 16000

    /// Unified's `consumeWordTimings()` *drains*, so the running transcript has to
    /// be accumulated here. Cleared at each utterance boundary so an always-on
    /// session cannot grow it without bound.
    private var accumulated: [TimedWord] = []

    private var pending: [Float] = []
    private var loaded = false

    /// Frames arrive here from the core and are drained by a single pump task, so
    /// there is exactly one consumer no matter how fast audio arrives.
    let queue = FrameQueue()
    private var pumpTask: Task<Void, Never>?

    /// Timed words for the current transcript, delivered on the main thread.
    private let onWords: @Sendable ([TimedWord]) -> Void
    private let onStatus: @Sendable (String) -> Void
    /// First-run model download, as (fraction complete, what to show). The models
    /// are ~600 MB from HuggingFace, so without this the app looks hung for
    /// minutes on a cold cache.
    private let onProgress: @Sendable (Double, String) -> Void
    /// Fires once the models are actually usable. Without it, audio fed during
    /// the (minutes-long, first-run) load is dropped with nothing to show for it.
    private let onFinal: @Sendable ([TimedWord]) -> Void
    private let onReady: @Sendable (Bool) -> Void
    /// Rolling real-time factor. The core can no longer measure this — it does not
    /// transcribe — so the health signal has to come from here.
    private let onRTF: @Sendable (Float) -> Void

    private var processedSeconds = 0.0
    private var computeSeconds = 0.0
    private var lastRTFReport = Date()

    /// Counts frames discarded because the engine was not loaded yet, so the
    /// "nothing is happening" case is observable instead of silent.
    private var droppedWhileLoading = 0

    /// Bound on queued audio, mirroring the core's ring backlog rule: falling
    /// behind should cost a few dropped words once, not permanent latency.
    private let maxPending = 16000 * 3

    init(variant: FluidVariant,
         language: FluidLanguage = .auto,
         onWords: @escaping @Sendable ([TimedWord]) -> Void,
         onStatus: @escaping @Sendable (String) -> Void,
         onProgress: @escaping @Sendable (Double, String) -> Void = { _, _ in },
         onFinal: @escaping @Sendable ([TimedWord]) -> Void,
         onReady: @escaping @Sendable (Bool) -> Void,
         onRTF: @escaping @Sendable (Float) -> Void,
         speakers: SpeakerTracker? = nil,
         vad: VoiceDetector? = nil) {
        self.variant = variant
        self.language = language
        self.onWords = onWords
        self.onStatus = onStatus
        self.onProgress = onProgress
        self.onFinal = onFinal
        self.onReady = onReady
        self.onRTF = onRTF
        self.speakers = speakers
        self.vad = vad
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

    /// Renders FluidAudio's progress callbacks into something worth showing, and
    /// drops the rest.
    ///
    /// The handler fires per downloaded chunk. Repainting the menu bar at that
    /// rate is pure waste, so a report only escapes when the *text a user would
    /// read* changes — which folds the percentage and the phase into one test.
    /// How much of FluidAudio's 0…1 scale the download occupies; the rest is
    /// reserved for compiling CoreML models.
    ///
    /// Mirrors `downloadPhaseWeight` upstream. It matters because our bundles
    /// arrive precompiled, so the compile phase never fires and the raw fraction
    /// stops dead at 0.5 — a finished, loaded model still reporting "50%".
    private static let downloadPhaseWeight = 0.5

    /// Reported as the fraction when there is no fraction to report: work is
    /// happening and its length is unknown. Anything drawing a bar shows a
    /// barber-pole for this rather than a position.
    static let indeterminate = -1.0

    private func makeProgressHandler() -> ProgressHandler {
        let last = LastProgress()
        let name = variant.displayName
        let report = onProgress
        return { progress in
            // Rescale so each phase fills the bar on its own. Nothing is lost by
            // not sharing it: the headline already says which phase is running.
            let raw = progress.fractionCompleted
            let weight = Self.downloadPhaseWeight
            let displayed: Double
            switch progress.phase {
            case .listing:
                displayed = 0
            case .downloading:
                displayed = min(1, raw / weight)
            case .compiling:
                displayed = min(1, max(0, (raw - weight) / (1 - weight)))
            }

            let percent = Int((displayed * 100).rounded())
            let headline: String
            switch progress.phase {
            case .listing:
                headline = "Finding \(name) files…"
            case let .downloading(done, total):
                headline = total > 0
                    ? "Downloading \(name) — \(percent)% (\(done)/\(total) files)"
                    : "Downloading \(name) — \(percent)%"
            case let .compiling(model):
                // `finished()` upstream emits an empty name at 1.0.
                headline = model.isEmpty
                    ? "Preparing \(name) — \(percent)%"
                    : "Compiling \(model) — \(percent)%"
            }
            // A phase that has reached 100% is not finished, it is between
            // phases: the bytes are down and CoreML is loading them onto the
            // Neural Engine, which reports nothing and takes long enough to look
            // like a hang. A full bar sitting there says "done" and is wrong, so
            // the bar goes indeterminate and the headline says what is happening.
            guard displayed < 1 else {
                let waiting = "Setting up \(name)…"
                guard last.shouldReport(waiting) else { return }
                report(Self.indeterminate, waiting)
                return
            }
            guard last.shouldReport(headline) else { return }
            report(displayed, headline)
        }
    }

    /// Downloads (first run) and loads the CoreML bundles. Slow — minutes on a
    /// cold cache, since the models come from HuggingFace.
    func load() async {
        guard !loaded else { return }
        onStatus("Loading \(variant.displayName)…")
        do {
            let progress = makeProgressHandler()
            if variant.isMultilingual {
                // Two steps rather than one: the download has to be told which
                // language it is for, because that decides which vocabulary pack
                // is fetched. `setLanguage` afterwards is the decode-time hint —
                // the prompt embedding — and is what "auto" leaves unset.
                let dir = try await StreamingNemotronMultilingualAsrManager.downloadVariant(
                    languageCode: language.code,
                    chunkMs: 560,
                    progressHandler: progress)
                let manager = StreamingNemotronMultilingualAsrManager()
                try await manager.loadModels(from: dir)
                await manager.setLanguage(language == .auto ? nil : language.code)
                multilingual = manager
            } else if variant.isUnified {
                // The only variant that punctuates and capitalises. Costs latency:
                // its [70,13,13] window is 2.08 s against EOU's 320 ms.
                let manager = StreamingUnifiedAsrManager()
                try await manager.loadModels(progressHandler: progress)
                unified = manager
            } else if variant.isEou {
                let manager = StreamingEouAsrManager(chunkSize: variant.eouChunkSize)
                try await manager.loadModels(progressHandler: progress)
                eou = manager
            } else {
                // Leave `configuration` nil: FluidAudio then picks
                // .cpuAndNeuralEngine. Passing a bare MLModelConfiguration()
                // means .all, under which CoreML routes the int8 encoder to the
                // GPU and runs roughly 10x slower — i.e. the exact trap this
                // engine exists to avoid.
                let manager = StreamingNemotronAsrManager(
                    requestedChunkSize: variant.nemotronChunkSize)
                try await manager.loadModels(progressHandler: progress)
                nemotron = manager
            }
            // Load the diarizer after the recogniser: subtitles are the point, and
            // this way they start working while the second model is still coming
            // down.
            //
            // Both get their own status line. Sortformer is another 229 MB, and
            // leaving the recogniser's headline up while it downloads reads as a
            // stall on a load that has actually moved on.
            if let speakers {
                onStatus("Loading speaker detection…")
                await speakers.load()
            }
            if let vad {
                onStatus("Loading voice detection…")
                await vad.load()
            }
            loaded = true
            startPump()
            onStatus("")
            onReady(true)
            if droppedWhileLoading > 0 {
                onStatus("")
            }
        } catch {
            // A switch mid-download cancels this task, which surfaces here as an
            // error — as `CancellationError` or as `URLError.cancelled`, depending
            // on how far in it got. Neither is a fault, and the load that
            // superseded it owns the status line now.
            guard !Task.isCancelled else { return }
            onStatus("FluidAudio failed to load: \(error.localizedDescription)")
            onReady(false)
        }
    }

    /// One long-lived consumer. Replaces a Task-per-callback, which could not
    /// apply backpressure.
    private func startPump() {
        guard pumpTask == nil else { return }
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let chunk = self.queue.drain()
                if chunk.isEmpty {
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10 ms
                    continue
                }
                await self.feed(chunk)
            }
        }
    }

    /// 16 kHz mono frames, drained from the queue by the pump.
    func feed(_ samples: [Float]) async {
        guard loaded else {
            droppedWhileLoading += samples.count
            return
        }
        // RTF is measured against *all* audio seen, not just what reaches the
        // recogniser. Counting only the latter would shrink the denominator
        // whenever the VAD rejects more, inflating RTF exactly when the pipeline
        // is doing less work — which read as "VAD costs 30% more" on first
        // measurement when total compute had actually gone down.
        processedSeconds += Double(samples.count) / 16000.0

        // Without a detector everything is speech and this is a straight pass.
        guard let vad, await vad.isLoaded else {
            pending.append(contentsOf: samples)
            if pending.count > maxPending {
                pending.removeFirst(pending.count - maxPending)
            }
            await drainToRecogniser()
            return
        }

        vadPending.append(contentsOf: samples)
        while vadPending.count >= VoiceDetector.chunkSamples {
            let chunk = Array(vadPending.prefix(VoiceDetector.chunkSamples))
            vadPending.removeFirst(VoiceDetector.chunkSamples)

            let speech = await vad.isSpeech(chunk)
            if speech {
                // Onset: replay the pre-roll so the first word is not clipped by
                // the detector's 256 ms decision granularity.
                if !wasSpeech { asrPending.append(contentsOf: history) }
                asrPending.append(contentsOf: chunk)
            }
            wasSpeech = speech

            history.append(contentsOf: chunk)
            if history.count > historyCap {
                history.removeFirst(history.count - historyCap)
            }
        }

        pending.append(contentsOf: asrPending)
        asrPending.removeAll(keepingCapacity: true)
        if pending.count > maxPending {
            pending.removeFirst(pending.count - maxPending)
        }
        await drainToRecogniser()
    }

    /// Feed whatever speech audio has accumulated to the recogniser.
    private func drainToRecogniser() async {

        let chunk = variant.chunkSamples
        while pending.count >= chunk {
            let slice = Array(pending.prefix(chunk))
            pending.removeFirst(chunk)
            guard let buf = buffer(from: slice) else { continue }
            let started = Date()
            do {
                if let unified {
                    // Unified separates buffering from decoding; it does its own
                    // windowing, so append then let it drain.
                    try await unified.appendAudio(buf)
                    try await unified.processBufferedAudio()
                } else if let eou {
                    _ = try await eou.process(audioBuffer: buf)
                } else if let nemotron {
                    _ = try await nemotron.process(audioBuffer: buf)
                } else if let multilingual {
                    _ = try await multilingual.process(audioBuffer: buf)
                }
            } catch {
                onStatus("transcription error: \(error.localizedDescription)")
            }

            // Poll timings after each chunk rather than using the partial-text
            // callback: the text alone cannot say *when* a word was spoken, and
            // that is what the overlay anchors on.
            let words = await currentWords()
            if !words.isEmpty { onWords(words) }

            if let speakers { await speakers.feed(slice) }

            computeSeconds += Date().timeIntervalSince(started)
            if let speakers { computeSeconds += await speakers.takeComputeSeconds() }
            if let vad { computeSeconds += await vad.takeComputeSeconds() }
            // Report about once a second, over a rolling window so a bad moment
            // does not haunt the average.
            if Date().timeIntervalSince(lastRTFReport) >= 1.0, processedSeconds > 0 {
                onRTF(Float(computeSeconds / processedSeconds))
                lastRTFReport = Date()
                computeSeconds = 0
                processedSeconds = 0
            }
        }
    }

    /// Words for the transcript so far, whichever manager is running.
    ///
    /// Unified hands back word boundaries directly; the other two only expose
    /// token timings, so words are reassembled using the leading-space convention
    /// the tokenisers share (a token beginning a word starts with a space).
    private func currentWords() async -> [TimedWord] {
        if let unified {
            let fresh = await unified.consumeWordTimings()
            accumulated.append(contentsOf: fresh.map {
                TimedWord(text: Self.clean($0.word), start: $0.startTime, end: $0.endTime)
            })
            return accumulated
        }
        if let nemotron {
            return Self.assemble(await nemotron.getTokenTimings())
        }
        // Same token-timing shape as Nemotron, and the language-tag token is
        // already excluded from these — upstream strips it from both the text and
        // the timings, so the word/time alignment paging relies on stays intact.
        if let multilingual {
            return Self.assemble(await multilingual.getTokenTimings())
        }
        if let eou {
            let tokens = await eou.getRawTokenStrings()
            let startsMs = await eou.getTokenTimestampsMs()
            return Self.assemble(tokens: tokens, startsMs: startsMs)
        }
        return []
    }

    /// Strip the word-start marker. Tokenisers mark it as U+2581 in the vocab and
    /// some APIs translate it to a plain space on the way out — the raw-token
    /// accessors do not, so both forms have to be handled or the marker is drawn
    /// on screen.
    private static func clean(_ piece: String) -> String {
        var t = piece
        while let f = t.first, f == " " || f == "\u{2581}" { t.removeFirst() }
        return t.trimmingCharacters(in: .whitespaces)
    }

    private static func assemble(_ timings: [TokenTiming]) -> [TimedWord] {
        var out: [TimedWord] = []
        for t in timings {
            let piece = t.token
            if piece.hasPrefix(" ") || piece.hasPrefix("\u{2581}") || out.isEmpty {
                out.append(TimedWord(text: clean(piece), start: t.startTime, end: t.endTime))
            } else {
                let last = out.removeLast()
                out.append(TimedWord(text: last.text + clean(piece),
                                     start: last.start, end: t.endTime))
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    private static func assemble(tokens: [String], startsMs: [Int]) -> [TimedWord] {
        var out: [TimedWord] = []
        for (i, piece) in tokens.enumerated() {
            let start = i < startsMs.count ? TimeInterval(startsMs[i]) / 1000 : 0
            if piece.hasPrefix(" ") || piece.hasPrefix("\u{2581}") || out.isEmpty {
                out.append(TimedWord(text: clean(piece), start: start, end: start))
            } else {
                let last = out.removeLast()
                out.append(TimedWord(text: last.text + clean(piece),
                                     start: last.start, end: start))
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    /// Drop the recogniser's context without emitting anything.
    ///
    /// Called when the overlay concludes speech has stopped even though audio is
    /// still flowing — i.e. music. The energy gate cannot tell a backing track
    /// from a voice, so the encoder keeps ingesting it, and when someone speaks
    /// again the first words are lost to a context still full of music. Measured:
    /// after 12 s of tone the recogniser silently dropped "god as a direct
    /// consequence" and resumed mid-sentence.
    ///
    /// The proper fix is a real VAD (Silero) so non-speech never reaches the
    /// recogniser at all; this is the cheap version using a signal we already have.
    func resetContext() async {
        guard loaded else { return }
        pending.removeAll()
        accumulated.removeAll()
        do {
            if let unified {
                try await unified.reset()
            } else if let eou {
                await eou.reset()
            } else if let nemotron {
                await nemotron.reset()
            } else if let multilingual {
                await multilingual.reset()
            }
        } catch {
            onStatus("reset failed: \(error.localizedDescription)")
        }
        if let speakers { await speakers.reset() }
        if let vad { await vad.reset() }
        vadPending.removeAll(); asrPending.removeAll(); history.removeAll()
        wasSpeech = false
    }

    /// Everything in flight, gone: queued audio as well as the recogniser's state.
    ///
    /// `resetContext()` above deliberately leaves the queue alone — it fires when
    /// text goes idle mid-session, and dropping audio there would clip the next
    /// word. Pausing is the opposite case: none of what is buffered will ever be
    /// worth showing, and leaving it queued means resuming replays it.
    func flush() async {
        queue.clear()
        await resetContext()
    }

    /// Called at the core's endpoint: flush and start a fresh utterance.
    func endUtterance() async {
        guard loaded else { return }
        pending.removeAll()
        accumulated.removeAll()
        if let speakers { await speakers.reset() }
        do {
            // Take the words before finishing: finish() resets some managers'
            // timing state, and the final text alone has no timestamps.
            let final = await currentWords()
            if let unified {
                _ = try await unified.finish()
                try await unified.reset()
            } else if let eou {
                _ = try await eou.finish()
                await eou.reset()
            } else if let nemotron {
                _ = try await nemotron.finish()
                await nemotron.reset()
            } else if let multilingual {
                _ = try await multilingual.finish()
                await multilingual.reset()
            }
            onFinal(final)
        } catch {
            onStatus("finish failed: \(error.localizedDescription)")
        }
    }

    /// Fraction of gated-on audio the detector called speech. Everything else is
    /// what the recogniser used to process for nothing.
    func speechFraction() async -> Double {
        guard let vad else { return 1 }
        return await vad.speechFraction()
    }

    func shutdown() async {
        pumpTask?.cancel()
        pumpTask = nil
        if let speakers { await speakers.shutdown() }
        if let unified { await unified.cleanup() }
        if let eou { await eou.cleanup() }
        if let nemotron { await nemotron.cleanup() }
        if let multilingual { await multilingual.cleanup() }
        unified = nil
        eou = nil
        nemotron = nil
        multilingual = nil
        loaded = false
    }
}
