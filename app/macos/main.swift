// Application entry point.
//
// tap → ring → resample → gate → pre-roll → FluidAudio (Parakeet on the ANE)
//     → overlay (and stdout).
//
// The Rust core does everything up to the frames; FluidAudio does the
// transcribing. The overlay lives in Overlay.swift; --headless drops back to a
// terminal renderer, which is often easier to debug.
//
// Must be launched as a bundle via `open` (see run.sh). Executing the binary
// directly makes the terminal the TCC-responsible process and the tap then
// delivers all-zero audio with no error anywhere — PLAN.md §8b.

import AppKit
import AVFoundation
import NaturalLanguage
import CaptionCore
import CSubs
// [main-edition]
import LicenseCore
// [/main-edition]
import Carbon.HIToolbox
import Darwin
import Foundation

// ── ANSI ──
let esc = "\u{1B}["
let dim = "\(esc)2m", bold = "\(esc)1m", reset = "\(esc)0m"
let yellow = "\(esc)33m", red = "\(esc)31m", green = "\(esc)32m", clearLine = "\(esc)2K"

func err(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

// ── args ──
var threads: Int32 = 2
var showStatus = true
var useOverlay = true
/// Named because "reset to defaults" has to be able to say it too, and two
/// literals that must agree are one literal too many.
let defaultFontSize: CGFloat = 30
var fontSize = defaultFontSize
var resetPosition = false
var listSources = false
var listModels = false
var variantOverride: FluidVariant?
// [main-edition]
/// An appcast URL for the updater, instead of the one in Info.plist.
var feedOverride: String?
/// Where licence keys are verified, instead of Gumroad.
var verifyOverride: URL?
// [/main-edition]

// The main edition's own options, spliced into --help below. Inside the
// literal a marker would print, so the lines live here.
// [main-edition]
let editionOptions = """
  --feed URL        check for updates against this appcast, not the shipped one
  --verify URL      verify licence keys against this URL, not Gumroad's

"""
// [/main-edition]
// [0bsd-edition]
// let editionOptions = ""
// [/0bsd-edition]

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--quiet": showStatus = false
    case "--headless": useOverlay = false
    case "--reset-position": resetPosition = true
    case "--list-sources": listSources = true
    case "--list-models": listModels = true
    case "--font-size" where i + 1 < args.count:
        fontSize = (Double(args[i + 1]) as Double?).map { CGFloat($0) } ?? defaultFontSize; i += 1
    case "--variant" where i + 1 < args.count:
        variantOverride = FluidVariant(rawValue: args[i + 1]); i += 1
    // [main-edition]
    case "--feed" where i + 1 < args.count:
        feedOverride = args[i + 1]; i += 1
    case "--verify" where i + 1 < args.count:
        verifyOverride = URL(string: args[i + 1]); i += 1
    // [/main-edition]
    case "--help", "-h":
        print("""
        usage: subtitles [options]

          --variant NAME    \(FluidVariant.allCases.map(\.rawValue).joined(separator: " | "))
          --headless        no overlay, stdout only
          --font-size N     overlay text size (default 30)
          --reset-position  put the overlay back to bottom-centre
          --list-sources    print audio sources and exit (no permission needed)
          --list-models     print the model cache and what is unused, and exit
        \(editionOptions)  --quiet           suppress status lines

        Live subtitles for system audio, transcribed on the Apple Neural Engine.
        The overlay is click-through; hold ⇧ to drag it, and its position is
        remembered. Hold ⌥ to stack the last few boxes back up above it.

        Launch via run.sh, not directly — TCC attributes the audio-capture grant
        to the launching process.
        """)
        exit(0)
    default: err("unknown argument: \(args[i])")
    }
    i += 1
}

if listSources {
    // Deliberately before any tap is created: enumerating processes needs no
    // audio-capture grant, so this stays usable even when permission is the very
    // thing being debugged.
    let all = SystemAudioTap.audioSources()
    print("audio sources (\(all.count) app families):")
    for p in all {
        print("  \(p.isPlaying ? "●" : " ") \(p.name)  [\(p.pids.count) proc]  \(p.id)")
    }
    print("\n● = currently playing")
    print("microphone: \(SystemAudioTap.defaultInputName() ?? "none")")
    exit(0)
}

// ── persisted settings ──
enum Defaults {
    static let fontSize = "overlay.fontSize"
    static let reveal = "overlay.reveal"
    static let history = "overlay.history"
    static let historyDepth = "overlay.historyDepth"
    static let maxLines = "overlay.maxLines"
    static let boxOpacity = "overlay.boxOpacity"
    static let backdropBlur = "overlay.backdropBlur"
    static let historyTextOpacity = "overlay.historyTextOpacity"
    // Seconds. A new key rather than the minutes one it replaces: the old
    // values are numerically valid seconds, so reusing it would quietly turn
    // someone's five minutes into five seconds.
    static let historyExpiry = "overlay.historyExpirySeconds"
    static let historyExpires = "overlay.historyExpires"
    static let revealOpacity = "overlay.revealOpacity"
    static let revealWidth = "overlay.revealWidth"
    static let revealHeight = "overlay.revealHeight"
    static let sourceID = "source.id"
    static let sourceName = "source.name"
    static let variant = "engine.variant"
    static let language = "engine.language"
    static let speakerBreaks = "engine.speakerBreaks"
    static let useVAD = "engine.vad"
    static let screenShare = "overlay.screenShare"
    /// See `Pill.IconStyle` and `Pill.TextAlignment`.
    static let iconStyle = "overlay.iconStyle"
    static let textAlignment = "overlay.textAlignment"
    static let translateTo = "translate.target"
    static let translateMode = "translate.mode"
    static let bothLanguages = "translate.bothLanguages"
}

/// Read by the realtime audio callback, written from the main thread. A plain
/// word-sized Bool: no tearing on arm64, and a lock in the audio callback would
/// cost far more than a missed frame at the moment of toggling.
nonisolated(unsafe) var isPaused = false

let app = NSApplication.shared

// [main-edition]
// ── licence ──
// Started here, before anything writes a default: whether a build older than
// this one left preferences behind is what decides grandfathering (§24), and
// the first write below would count as evidence. The gate itself is in
// `togglePause` and the wiring further down.
let license = LicenseController()
license.verifyOverride = verifyOverride
license.start()
/// True while the licence, not the person, is what paused the app — so
/// activating a key can resume it, and a pause the person chose is kept.
var pausedByLicense = false
if !license.entitlement.allowsTranscription {
    isPaused = true
    pausedByLicense = true
}
// [/main-edition]

// ── engine ──
// Globals rather than captures: the audio callback must not touch ARC.
nonisolated(unsafe) var engine: OpaquePointer?
nonisolated(unsafe) var fluidEngine: FluidAudioEngine?
/// Multilingual on auto-detect, because a default should work before it is
/// configured and the English-only checkpoints simply do not, for most of the
/// world's audio. It costs nothing measurable: RTF 0.08–0.11 on French here,
/// indistinguishable from Nemotron 560 on English.
///
/// Paired with `currentLanguage` defaulting to `.auto`, which routes the first
/// download to the full-vocab pack (633 MB) rather than the Latin-script one —
/// auto has to be able to decode anything.
nonisolated(unsafe) var currentVariant: FluidVariant = .multilingual
/// Only read by the multilingual variant. Kept even while an English-only model
/// is selected, so switching back does not lose the choice.
nonisolated(unsafe) var currentLanguage: FluidLanguage = .auto
/// Non-nil while a model is downloading or loading.
nonisolated(unsafe) var engineBusyMessage: String?
/// How far that load has got, 0…1, or negative for "unknown length" — the gap
/// after a download completes, while CoreML loads the bundles and reports
/// nothing. Only read while `engineBusyMessage` is set.
nonisolated(unsafe) var engineBusyProgress: Double = 0
/// Rolling real-time factor reported by the engine; > 0.8 means trouble.
nonisolated(unsafe) var lastRTF: Float = 0
/// Set when the recogniser could not be loaded at all. Persistent, unlike
/// `engineBusyMessage`, because the condition is: there is no transcript and
/// there will not be one until something changes. Until this existed the only
/// sign was a line on stderr and an overlay that never appeared, which is
/// indistinguishable from no audio, a missing permission, or a bug anywhere else
/// in the pipeline.
nonisolated(unsafe) var engineFailure: String?
/// Fraction of gated-on audio the VAD called speech; -1 until known.
nonisolated(unsafe) var lastSpeechFraction: Double = -1
/// Break the subtitle page when the speaker changes. Off by default: it is a
/// second model on the ANE, so it should be an opt-in cost.
nonisolated(unsafe) var speakerBreaksEnabled =
    UserDefaults.standard.bool(forKey: Defaults.speakerBreaks)
/// Skip non-speech before it reaches the recogniser. Defaults ON: it fixes a real
/// bug (music poisoning the encoder context) and should *reduce* load, since the
/// recogniser stops chewing through backing tracks.
nonisolated(unsafe) var useVAD =
    UserDefaults.standard.object(forKey: Defaults.useVAD) as? Bool ?? true
/// Target language for live translation, or nil for off. A `FluidLanguage` rather
/// than a `Locale.Language` so the setting survives on 14.2, where the framework
/// that would consume it does not exist.
/// The last language the multilingual checkpoint said it was hearing.
///
/// Kept because the engine only reports a *change*: by the time a translation
/// target is picked, the detection that matters has usually already happened and
/// will not happen again. Without this the translator was built with no source at
/// all, which meant it could not check whether the pair needed downloading, so
/// picking a language whose pack was missing quietly produced nothing.
nonisolated(unsafe) var lastDetectedLanguage: FluidLanguage?
/// The last language heard that was not the translation's target: what a
/// speaker of the target is translated back into when both languages are on
/// screen — see `translationPair()`. Kept whether or not translation is on, so
/// the language heard before it was switched on counts.
nonisolated(unsafe) var lastOtherLanguage: FluidLanguage?
/// The language of the words on screen, read from the text itself, for as long
/// as the multilingual checkpoint has not named one. Its tag arrives at the
/// start of a sentence as the model hears one, not on the first words, so a
/// session that begins mid-sentence goes untagged until the next full stop,
/// and a translation turned on in that stretch would wait as long for a
/// source. A guess, so the translator is told it is one, and the tag replaces
/// it when it comes.
nonisolated(unsafe) var guessedLanguage: FluidLanguage?
nonisolated(unsafe) var translateTo: FluidLanguage?
nonisolated(unsafe) var translationMode: TranslationMode = .hybrid
/// Live translation, while a target is set. Typed `AnyObject?` because a global of
/// a macOS 15 type cannot be declared on a 14.2 floor; every use casts inside an
/// `#available` check.
nonisolated(unsafe) var translationBox: AnyObject?

@available(macOS 15, *)
var translation: TranslationController? { translationBox as? TranslationController }

if let saved = UserDefaults.standard.object(forKey: Defaults.fontSize) as? Double {
    fontSize = CGFloat(saved)
}
if let override = variantOverride {
    currentVariant = override
} else if let raw = UserDefaults.standard.string(forKey: Defaults.variant),
          let v = FluidVariant(rawValue: raw) {
    currentVariant = v
}
if let raw = UserDefaults.standard.string(forKey: Defaults.language),
   let l = FluidLanguage(rawValue: raw) {
    currentLanguage = l
}
if let raw = UserDefaults.standard.string(forKey: Defaults.translateMode),
   let m = TranslationMode(rawValue: raw) {
    translationMode = m
}
if let raw = UserDefaults.standard.string(forKey: Defaults.translateTo),
   let l = FluidLanguage(rawValue: raw) {
    translateTo = l
}

if listModels {
    // The read-only half of the Clear Model Cache button: same two calls, same
    // answers, nothing removed. A button that deletes gigabytes should have a way
    // to say what it would delete without being pressed.
    let keeping = ModelCache.inUse(variant: currentVariant, speakerBreaks: speakerBreaksEnabled)
    print("models directory: \(ModelCache.directory.path)\n")
    print("in use, never removed:")
    for folder in keeping.sorted() { print("  \(folder)") }

    let removable = ModelCache.removable(keeping: keeping)
    if removable.isEmpty {
        print("\nnothing unused on disk")
    } else {
        print("\nremovable:")
        for entry in removable {
            print("  \(ModelCache.format(entry.bytes))\t\(entry.name)"
                + "  [\(entry.url.path.replacingOccurrences(of: ModelCache.directory.path + "/", with: ""))]")
        }
        let total = removable.reduce(0) { $0 + $1.bytes }
        print("\ntotal \(ModelCache.format(total))")
    }

    // Broken bundles are worth naming here even though the engine now clears them
    // on its own: this is the one place to ask what is on disk without starting
    // anything, and "the model you picked cannot load" is the single most useful
    // thing the cache can tell you.
    let broken = ModelCache.incompleteBundles(under: ModelCache.directory)
    if broken.isEmpty {
        print("\nall compiled models look complete")
    } else {
        print("\nincomplete — will be refetched on next load:")
        for url in broken {
            print("  \(url.path.replacingOccurrences(of: ModelCache.directory.path + "/", with: ""))")
        }
    }
    exit(0)
}

/// Gated, pre-rolled 16 kHz frames from the core. Runs on the core's worker
/// thread, not the audio thread, so hopping into the actor here is safe.
let onAudioFrames: @convention(c) (UnsafePointer<Float>?, UInt, UnsafeMutableRawPointer?) -> Void = {
    ptr, count, _ in
    // Paused check here as well as at the tap: stopping the tap does not empty
    // the core's ring, and its worker goes on draining what was already captured
    // for a moment afterwards. Without this the engine keeps being fed — and
    // keeps transcribing — audio from before the pause.
    guard !isPaused, let ptr, count > 0, let fluid = fluidEngine else { return }
    // Hand off to a bounded queue rather than spawning a task per callback: an
    // engine that falls behind must drop audio, not accumulate tasks.
    fluid.queue.push(UnsafeBufferPointer(start: ptr, count: Int(count)))
}

/// Renderer state. Events are marshalled onto the main thread before reaching
/// this, because the overlay is AppKit and the core calls back from its worker.
final class Renderer {
    /// nil in --headless mode.
    var overlay: OverlayController?

    /// Where the current turn begins in the transcript: the word count at the
    /// last pause or endpoint. The recogniser keeps one transcript across a
    /// conversation, so anything that should look at what is being said *now*
    /// — naming its language, above all — reads from here.
    private var turnStartWords = 0
    private var lastWordCount = 0

    /// The words of the current turn.
    func turnWords(_ words: [TimedWord]) -> [TimedWord] {
        if words.count < turnStartWords { turnStartWords = 0 }
        return Array(words.dropFirst(turnStartWords))
    }
    var onStatusRefresh: (() -> Void)?

    private var line = ""
    private var warnedAboutSilence = false
    private var lastStatus = ""

    /// Whether audio is actually arriving right now, as opposed to no fault
    /// having been detected.
    ///
    /// Starts false, which is the whole point. The flag this replaced began true —
    /// nothing having gone wrong yet — and reading that as "listening" lit the
    /// live badge at launch whether or not anything was playing.
    ///
    /// Tolerates a couple of seconds of quiet so the badge does not blink out
    /// between sentences; it is reporting "something is playing", not "someone is
    /// talking".
    private(set) var receivingAudio = false
    private let silenceGrace: Float = 2
    /// How long nothing has been arriving, as the core last reported it. For
    /// whatever needs to tell a quiet Mac from one mid-film; the main
    /// edition's updater does, before opening a window unasked.
    private(set) var silentSeconds: Float = 0

    /// FluidAudio reports the whole transcript each update rather than deltas,
    /// with the audio time of every word — which is what the overlay pages on.
    func setWords(_ words: [TimedWord]) {
        lastWordCount = words.count
        line = words.map(\.text).joined(separator: " ")
        // With translation on the overlay is driven by the pipeline instead, which
        // calls back once the target-language text exists. The terminal line below
        // stays in the source language: it is the transcript, not the subtitle.
        // `assumeIsolated` rather than a hop: every caller here is already on the
        // main thread (the engine's callbacks all land through DispatchQueue.main),
        // and hopping would reorder these against the overlay updates beside them.
        //
        // `isReady` is false while a language pack downloads, which takes minutes.
        // Falling back to the source language for that stretch is the difference
        // between "not translated yet" and an app that looks broken.
        // The overlay is handed the spoken transcript unconditionally, whether or
        // not it is what gets drawn: ⌃ shows the original, and it has to be there
        // the moment the key goes down rather than at the next word.
        var translated = false
        if #available(macOS 15, *), let t = translation {
            translated = MainActor.assumeIsolated {
                // The overlay needs to know whether to expect translated words at
                // all: not ready means a pack still downloading, or audio already
                // in the target language, and in both cases the original is what
                // should be on screen.
                overlay?.translationProducesOutput = t.isReady
                guard t.isReady else { return false }
                t.ingest(words)
                return true
            }
        } else {
            overlay?.translationProducesOutput = false
        }
        overlay?.setSourceWords(words)
        if #available(macOS 15, *) {
            TranslationPipeline.trace("setWords \(words.count) routed=\(translated ? "pipeline" : "overlay")")
        }
        FileHandle.standardOutput.write("\r\(clearLine)\(line)".data(using: .utf8)!)
    }

    /// End of utterance: freeze the line and start a new one.
    func endpoint() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            FileHandle.standardOutput.write("\r\(clearLine)\(trimmed)\n".data(using: .utf8)!)
        }
        line = ""
        turnStartWords = lastWordCount
        if #available(macOS 15, *) { MainActor.assumeIsolated { translation?.finish() } }
        overlay?.endUtterance()
    }

    /// Drop the line without printing it. Used when the audio underneath changes
    /// source: the half-sentence on screen belongs to an app we are no longer
    /// listening to, so committing it to the terminal would be a lie.
    func discardLine() {
        line = ""
    }

    /// Let the silence warning fire again. Called when pausing, so a warning
    /// raised before the pause does not suppress a later one — the tap it was
    /// complaining about is gone, and the judgement has to be made afresh once
    /// audio is flowing again.
    func clearHealthWarning() {
        warnedAboutSilence = false
        // Nothing is arriving with the tap down, and no status event will come to
        // say so — leaving this set would light the live badge on resume before a
        // single sample had been seen.
        receivingAudio = false
    }

    func pause() {
        turnStartWords = lastWordCount
        if #available(macOS 15, *) { MainActor.assumeIsolated { translation?.finish() } }
        overlay?.markPause()
    }

    func status(_ text: String, peak: Float, silentSeconds: Float, dropped: UInt64) {
        receivingAudio = silentSeconds < silenceGrace
        self.silentSeconds = silentSeconds

        // A missing audio-capture grant yields perfectly timed, correctly sized,
        // all-zero buffers with noErr everywhere. The only way to tell that apart
        // from genuine quiet is to ask whether anything is actually playing.
        // `!isPaused` because the watchdog exists to catch a *missing permission*,
        // which looks identical to a pause from in here: perfectly timed all-zero
        // buffers. Letting it fire while paused turns our own teardown into a
        // scary permission warning in the log.
        // Not for the microphone either: what it hears has no process to ask
        // about, and a quiet room is only a quiet room.
        if !isPaused, tap.source != .microphone, silentSeconds > 4, !warnedAboutSilence {
            let playing = SystemAudioTap.processesOutputtingAudio()
            if !playing.isEmpty {
                warnedAboutSilence = true
                err("""

                \(red)\(bold)Receiving only silence while audio is playing.\(reset)
                \(playing.count) process(es) are outputting audio \
                (\(playing.prefix(3).joined(separator: ", "))), but every sample \
                we receive is exactly zero.

                This is what a missing audio-capture permission looks like — Core
                Audio reports no error. Check System Settings → Privacy & Security,
                and make sure you launched via run.sh rather than running the
                binary directly.
                """)
            }
        } else if silentSeconds == 0 {
            warnedAboutSilence = false
        }

        onStatusRefresh?()

        guard showStatus else { return }
        let rtfColor = lastRTF > 0.8 ? red : (lastRTF > 0.5 ? yellow : green)
        var s = "[\(text) \(String(format: "%.0f", peak))dB  "
        s += "rtf \(rtfColor)\(String(format: "%.2f", lastRTF))\(reset)"
        if useVAD, lastSpeechFraction >= 0 {
            s += "  speech \(Int(lastSpeechFraction * 100))%"
        }
        if dropped > 0 { s += "  \(red)dropped \(dropped)\(reset)" }
        s += "]"
        if s != lastStatus {
            lastStatus = s
            err(s)
        }
    }
}

let renderer = Renderer()

let onEvent: @convention(c) (UnsafePointer<subs_event_t>?, UnsafeMutableRawPointer?) -> Void = {
    ev, _ in
    guard let ev = ev?.pointee else { return }
    // Copy out before leaving the callback: `text` is only valid for its
    // duration, and everything below runs later on another thread.
    let text = ev.text.map { String(cString: $0) } ?? ""
    let kind = ev.kind, peak = ev.peak_dbfs
    let silent = ev.silent_seconds, dropped = ev.dropped
    DispatchQueue.main.async {
        switch kind {
        case SUBS_EVENT_PAUSE: renderer.pause()
        case SUBS_EVENT_ENDPOINT:
            renderer.endpoint()
            // FluidAudio's final text arrives asynchronously, after endpoint()
            // has armed the fade; the engine re-arms it via onFinal.
            if let fluid = fluidEngine { Task { await fluid.endUtterance() } }
        case SUBS_EVENT_STATUS:
            renderer.status(text, peak: peak, silentSeconds: silent, dropped: dropped)
        default: break
        }
    }
}

// ── capture ──
// Startup order matters. `prepare()` creates the tap and reports its format
// without starting IO, so the worker is running before a single sample is
// captured; starting capture first buries the opening seconds of speech behind a
// model load's worth of buffered audio.
let tap = SystemAudioTap { samples, count in
    if isPaused { return }
    subs_push_audio(engine, samples, UInt(count))
}

var startingSource: AudioSource = .allSystemAudio
if let name = UserDefaults.standard.string(forKey: Defaults.sourceName),
   let id = UserDefaults.standard.string(forKey: Defaults.sourceID) {
    startingSource = id == AudioSource.microphoneID ? .microphone : .app(id: id, name: name)
}
// The microphone's grant can have gone since it was chosen — withdrawn in
// System Settings, or reset. Without it the HAL delivers silence and no error,
// so start on system audio and say so rather than listen to nothing. A status
// read, not a request: the prompt belongs to choosing the microphone, and
// picking it again asks again.
if startingSource == .microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
    err("\(yellow)microphone access is not granted\(reset) — listening to all system audio instead")
    startingSource = .allSystemAudio
}

/// The input format the core is built for. A `var` because the microphone
/// can differ from the taps' 48 kHz stereo, and `resumeCapture` rebuilds the
/// core when it does.
nonisolated(unsafe) var format: TapFormat
do {
    format = try tap.prepare(source: startingSource)
} catch {
    err("\(red)capture setup failed:\(reset) \(error)")
    exit(1)
}
err("\(bold)subtitles\(reset) — \(Int(format.sampleRate)) Hz, \(format.channels) ch")

// ── engine lifecycle ──

func makeCore() -> OpaquePointer? {
    var cfg = subs_config_t(
        input_sample_rate: UInt32(format.sampleRate),
        input_channels: UInt16(format.channels))
    return subs_create(&cfg)
}

/// Core rebuilds queued and not yet finished. Capture stays down while one is:
/// the rebuild destroys the core, and a tap started in the meantime would be
/// pushing into it from the realtime thread as it went.
nonisolated(unsafe) var coreRebuildsPending = 0

func resumeCapture() {
    // Paused means the tap stays down, whoever is asking. Variant and source
    // switches both end by calling this, and without the guard a model change
    // while paused would quietly put the app back to capturing.
    guard !isPaused, coreRebuildsPending == 0 else { return }
    do {
        let live = try tap.prepare(source: tap.source)
        // The core downmixes and resamples whatever it was built for, but it is
        // built for one format. Every process tap is 48 kHz stereo; a microphone
        // is usually mono and not always 48 kHz, and the input device can change
        // under it. The rebuild ends back here, with the two now agreeing.
        if live != format {
            err("input is \(Int(live.sampleRate)) Hz, \(live.channels) ch — rebuilding the audio core for it")
            format = live
            rebuildCore(generation: loadGeneration)
            return
        }
        try tap.start()
    } catch {
        err("\(red)could not restart capture:\(reset) \(error)")
    }
}

// Sound settings' input changed under the microphone: follow it. Through
// `resumeCapture`, so a new device's format is handled and a change made while
// paused waits for the resume.
tap.onDefaultInputChanged = {
    err("microphone is now \(SystemAudioTap.defaultInputName() ?? "none") — following it")
    resumeCapture()
}

/// Serialises core teardown and creation. Switching used to be blocked while a
/// load ran, so this could not overlap; now that a second switch may arrive mid
/// download, two destroy/create pairs running at once is exactly the
/// use-after-free the comment below warns about.
let variantQueue = DispatchQueue(label: "dev.mat.subtitles.variant")

/// Bumped by every switch. Callbacks capture the value they were built with and
/// drop anything that arrives after they have been superseded, so a cancelled
/// 600 MB download cannot write status for a model nobody selected.
nonisolated(unsafe) var loadGeneration = 0
/// The in-flight model load, held so the next switch can cancel it.
nonisolated(unsafe) var loadTask: Task<Void, Never>?

/// Tear the core down and build it again for `format`, then bring capture back
/// up. Capture must be down when this is called: the realtime callback may
/// otherwise have loaded the old pointer and be inside subs_push_audio as it is
/// destroyed. Cheap — the core is the ring and the resampler, not the model —
/// which is what lets a source with another format be switched to without a
/// reload.
func rebuildCore(generation: Int) {
    coreRebuildsPending += 1
    variantQueue.async {
        // A later switch may have landed while this one sat in the queue.
        guard generation == loadGeneration else {
            DispatchQueue.main.async { coreRebuildsPending -= 1 }
            return
        }
        let old = engine
        engine = nil
        subs_stop(old)
        subs_destroy(old)

        guard let created = makeCore() else {
            DispatchQueue.main.async {
                err("\(red)could not create the audio core\(reset)")
                coreRebuildsPending -= 1
                resumeCapture()
            }
            return
        }
        subs_set_callback(created, onEvent, nil)
        subs_set_audio_callback(created, onAudioFrames, nil)
        let rc = subs_start(created)

        DispatchQueue.main.async {
            engine = rc == 0 ? created : nil
            if rc != 0 {
                subs_destroy(created)
                err("\(red)subs_start failed (\(rc))\(reset)")
            }
            coreRebuildsPending -= 1
            resumeCapture()
            statusMenu?.updateHealthIndicator()
        }
    }
}

/// Build the core and the FluidAudio engine for `variant`, replacing whatever is
/// running.
func applyVariant(_ variant: FluidVariant, initial: Bool = false) {
    loadGeneration += 1
    let generation = loadGeneration
    // Before anything else: the variant decides what language the transcript will
    // be in, so the translator has to hear about it.
    currentVariant = variant
    refreshTranslationSource()
    // Abandon whatever was loading. The user has asked for something else, and a
    // download for a model they no longer want should neither hold up the new one
    // nor keep writing to the status line.
    loadTask?.cancel()
    if let previous = fluidEngine {
        // The actor serialises this behind the cancelled load, so it cannot tear
        // models out from under a call still inside `loadModels`.
        Task { await previous.shutdown() }
    }

    UserDefaults.standard.set(variant.rawValue, forKey: Defaults.variant)

    engineBusyMessage = "Loading \(variant.displayName)…"
    engineBusyProgress = 0
    statusMenu?.updateHealthIndicator()
    renderer.overlay?.clearAndHide()

    // Stop capture before touching the core. Clearing the global is not enough:
    // the realtime callback may already have loaded the old pointer and be inside
    // subs_push_audio, so destroying it there is a use-after-free.
    // AudioDeviceStop is synchronous — once it returns no IOProc is in flight.
    if !initial { tap.stop() }

    let tracker: SpeakerTracker? = speakerBreaksEnabled
        ? SpeakerTracker(
            onChange: {
                // Same treatment as a pause: the words already shown stay put and
                // the next ones start a fresh box.
                DispatchQueue.main.async { renderer.overlay?.markPause() }
            },
            onStatus: { message in DispatchQueue.main.async { err(message) } })
        : nil

    let detector: VoiceDetector? = useVAD
        ? VoiceDetector(onStatus: { message in DispatchQueue.main.async { err(message) } })
        : nil

    let fluid = FluidAudioEngine(
        variant: variant,
        language: currentLanguage,
        onWords: { words in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                guessLanguage(from: renderer.turnWords(words))
                renderer.setWords(words)
            }
        },
        onStatus: { message in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                engineBusyMessage = message.isEmpty ? nil : message
                if message.isEmpty { engineBusyProgress = 0 }
                statusMenu?.updateHealthIndicator()
                if !message.isEmpty { err(message) }
            }
        },
        onProgress: { fraction, headline in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                engineBusyMessage = headline
                engineBusyProgress = fraction
                statusMenu?.updateHealthIndicator()
                err(headline)
            }
        },
        onFinal: { words in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                if !words.isEmpty { renderer.setWords(words) }
                renderer.overlay?.endUtterance()
            }
        },
        onReady: { ok in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                err(ok ? "engine ready: \(variant.displayName)"
                       : "\(red)engine failed to load\(reset)")
                engineFailure = ok
                    ? nil
                    : "\(variant.displayName) failed to load — pick another model"
                engineBusyMessage = nil
                engineBusyProgress = 0
                statusMenu?.updateHealthIndicator()
                // [main-edition]
                // The trial clock starts here and nowhere else: a launch
                // spent downloading the model has not started it.
                if ok { license.noteEngineReady() }
                // [/main-edition]
            }
        },
        onLanguage: { code in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                guard let detected = FluidLanguage.matching(code: code) else { return }
                lastDetectedLanguage = detected
                if detected != translateTo { lastOtherLanguage = detected }
                err("detected \(detected.displayName)")
                // Only meaningful on auto-detect: with the language pinned, the
                // translator was already told and the model is only confirming it.
                guard currentLanguage == .auto else { return }
                // Untrusted on purpose — see `setSource(_:trusted:)` — and
                // possibly the other way round: see `translationPair()`.
                refreshTranslationSource()
            }
        },
        onPause: {
            // The detector's pause, for a microphone — see FluidAudioEngine. The
            // same boundary the core's gate sends for system audio; both may
            // come for one silence, and the second changes nothing.
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                renderer.pause()
            }
        },
        onRTF: { rtf in
            DispatchQueue.main.async {
                guard generation == loadGeneration else { return }
                lastRTF = rtf
            }
            // Sampled alongside RTF so the two health numbers stay in step.
            Task {
                if let f = await fluidEngine?.speechFraction() {
                    DispatchQueue.main.async { lastSpeechFraction = f }
                }
            }
        },
        speakers: tracker,
        vad: detector)
    fluidEngine = fluid

    // Start the load now rather than after the core swap. It needs nothing from
    // the core, and on a cold cache this is a ~600 MB download — no reason to
    // spend even the teardown on it.
    loadTask = Task { await fluid.load() }

    rebuildCore(generation: generation)
}

/// Switch the multilingual model to another language.
///
/// A full engine rebuild rather than a live `setLanguage`: crossing between the
/// Latin-script pack and the full one is a different model download, and even
/// within a pack the decoder's prompt seeds its state at reset. Rebuilding is the
/// one path already known to handle a download, a cancel and a clean swap.
func applyLanguage(_ language: FluidLanguage) {
    currentLanguage = language
    UserDefaults.standard.set(language.rawValue, forKey: Defaults.language)
    // Translating from a language into itself is not a thing to do.
    if translateTo == language { applyTranslation(nil) }
    refreshTranslationSource()
    applyVariant(.multilingual)
}

/// The language the recogniser will actually produce, when that is known without
/// having to listen.
///
/// Seven of the eight variants are English checkpoints and can emit nothing else,
/// so with one of those selected the source is English no matter what the
/// language menu says — that setting only applies to the multilingual model. Nil
/// means genuinely unknown: multilingual on auto-detect.
var spokenLanguage: FluidLanguage? {
    guard currentVariant.isMultilingual else { return .en }
    guard currentLanguage == .auto else { return currentLanguage }
    // On auto, whatever was last heard, or read off the transcript until then.
    // A guess, and marked as one below, but a guess is enough to ask whether
    // the pair needs downloading, and nil is not.
    return lastDetectedLanguage ?? guessedLanguage
}

var effectiveSource: Locale.Language? { spokenLanguage?.locale }

/// Name the language from the transcript: while the checkpoint has not, and
/// again when what is being said reads as another language than the one it
/// named. Eight words are enough for NaturalLanguage to tell the sixteen
/// apart, and the last sixteen are what it reads, so a change of speaker is
/// caught within a sentence. The checkpoint's own tag is latched per decode
/// session and can outlive the speaker it was decided on — a French turn came
/// through under an English tag whole — and a stale tag is what a translation
/// the wrong way round is made from. Overriding a tag asks for more certainty
/// than first naming a language does, so the two cannot take turns on a
/// fragment.
func guessLanguage(from words: [TimedWord]) {
    // Eight words to name a language from nothing; two to notice a change, at
    // the higher bar below — "Bonjour John, je m'appelle Mathieu" reads as
    // French at 0.98 and a turn in a conversation is often that short.
    guard currentVariant.isMultilingual, currentLanguage == .auto,
          words.count >= (lastDetectedLanguage == nil ? 8 : 2) else { return }
    let recognizer = NLLanguageRecognizer()
    recognizer.languageConstraints = [
        .english, .spanish, .french, .italian, .portuguese, .german, .dutch, .turkish,
        .russian, .arabic, .hindi, .japanese, .korean, .vietnamese, .ukrainian, .simplifiedChinese,
    ]
    recognizer.processString(words.suffix(16).map(\.text).joined(separator: " "))
    let needed = lastDetectedLanguage == nil ? 0.5 : (words.count >= 8 ? 0.8 : 0.9)
    guard let best = recognizer.languageHypotheses(withMaximum: 1).max(by: { $0.value < $1.value }),
          best.value >= needed,
          let guess = FluidLanguage.matching(code: best.key.rawValue),
          guess != spokenLanguage else { return }
    guessedLanguage = guess
    lastDetectedLanguage = guess
    if guess != translateTo { lastOtherLanguage = guess }
    err("language from text: \(guess.displayName)")
    refreshTranslationSource()
}

/// True when `effectiveSource` is a fact rather than a guess — see
/// `TranslationController.setSource(_:trusted:)`.
var effectiveSourceIsTrusted: Bool {
    !currentVariant.isMultilingual || currentLanguage != .auto
}

/// Which way the translator should be working right now, and whether its
/// source is a fact — nil with translation off.
///
/// One way normally: whatever is heard, into the target. With both languages on
/// screen the pair is a conversation's: a speaker of the target language is
/// translated back into the other one — the recogniser's pinned language, or on
/// auto-detect the last language heard that was not the target — so both sides
/// of a French–English exchange read each other, each in their own language
/// above the other's words. Until a second language has been heard there is
/// nothing to translate back into, and the target being spoken is what it
/// always was: shown as it is.
func translationPair() -> (source: Locale.Language?, target: Locale.Language, trusted: Bool)? {
    guard let target = translateTo else { return nil }
    let spoken = spokenLanguage
    let home = currentVariant.isMultilingual && currentLanguage == .auto ? lastOtherLanguage : spoken
    if renderer.overlay?.showsBothLanguages == true,
       let spoken, spoken == target, let home, home != target {
        return (spoken.locale, home.locale, effectiveSourceIsTrusted)
    }
    return (spoken?.locale, target.locale, effectiveSourceIsTrusted)
}

/// Turn live translation on for a target language, or off with nil.
///
/// Rebuilds the controller rather than retargeting one: changing target changes
/// the session's configuration, which restarts it anyway, and a fresh controller
/// also drops the half-translated transcript belonging to the old language.
func applyTranslation(_ target: FluidLanguage?) {
    translateTo = target
    if let target {
        UserDefaults.standard.set(target.rawValue, forKey: Defaults.translateTo)
    } else {
        UserDefaults.standard.removeObject(forKey: Defaults.translateTo)
    }
    guard #available(macOS 15, *) else { return }
    MainActor.assumeIsolated {
        guard let target else {
            translationBox = nil
            renderer.overlay?.prefersTranslation = false
            renderer.overlay?.translationBelow = false
            // Whatever is on screen is in the old target language; the next words
            // are the source language again, so do not leave the two mixed.
            renderer.overlay?.markPause()
            return
        }
        // `auto` leaves the source unset and lets the framework identify it.
        // Worth knowing that it is identifying per request, on one sentence at
        // a time, which is the weakest position to ask it from.
        let pair = translationPair()
            ?? (source: effectiveSource, target: target.locale, trusted: effectiveSourceIsTrusted)
        let controller = TranslationController(
            target: pair.target,
            source: pair.source,
            trustedSource: pair.trusted,
            mode: translationMode,
            onTranslated: { renderer.overlay?.setTranslatedWords($0) },
            onStatus: { message in err(message) },
            onProgress: { fraction, headline in
                engineBusyMessage = headline.isEmpty ? nil : headline
                engineBusyProgress = fraction
                statusMenu?.updateHealthIndicator()
            })
        controller.onReadiness = { renderer.overlay?.translationProducesOutput = $0 }
        translationBox = controller
        renderer.overlay?.prefersTranslation = true
        renderer.overlay?.translationBelow = pair.target != target.locale
        err("translating to \(target.displayName) · \(translationMode.displayName)")
        // A fresh decode from here. The multilingual checkpoint latches its
        // language tag for a decode session and the engine reports it once, so
        // a translator built mid-utterance would otherwise hear no source until
        // the recogniser next started over, at a fade or a switch of source,
        // and the words until then would show untranslated. Same path as a
        // switch of source: the transcript and the encoder context go, the next
        // words start a fresh box, and the first of them carries the tag again.
        renderer.overlay?.markPause()
        renderer.discardLine()
        if let fluid = fluidEngine { Task { await fluid.resetContext() } }
        Task { @MainActor in
            let state = await controller.prepare()
            if state == .unsupported {
                err("\(red)translation unavailable for this pair\(reset)")
            }
        }
    }
}

/// Re-point the translator after anything that changes what the recogniser will
/// produce — a variant switch as much as a language switch. Without the variant
/// half, selecting an English-only model while translating to English left the
/// translator believing the source was still whatever the language menu said, and
/// every request was refused as source-equals-target.
func refreshTranslationSource() {
    guard #available(macOS 15, *), let pair = translationPair(), let target = translateTo else { return }
    MainActor.assumeIsolated {
        translation?.setPair(source: pair.source, target: pair.target, trusted: pair.trusted)
    }
    // Which way round the box draws the pair: the target stays on top either
    // way — see `OverlayController.translationBelow`.
    renderer.overlay?.translationBelow = pair.target != target.locale
}

func applyTranslationMode(_ mode: TranslationMode) {
    translationMode = mode
    UserDefaults.standard.set(mode.rawValue, forKey: Defaults.translateMode)
    guard #available(macOS 15, *) else { return }
    MainActor.assumeIsolated { translation?.mode = mode }
    err("translation timing: \(mode.displayName)")
}

/// Point capture at a different source. One path, shared by the menu and by
/// SIGUSR2, so what a test exercises is what the menu does.
func selectSource(_ source: AudioSource, overlay: OverlayController? = nil) {
    if source == .microphone {
        // A grant of its own, separate from audio capture, and asked for here
        // and nowhere else: the first time the microphone is chosen, never at
        // launch. Asked rather than left to the HAL's own prompt so a refusal
        // can be said out loud — to the HAL a client without the grant is one
        // that hears silence.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    if granted {
                        selectSource(.microphone, overlay: overlay)
                    } else {
                        err("\(yellow)microphone access was declined\(reset) — still listening to \(tap.source.label)")
                    }
                }
            }
            return
        default:
            // Refused before, and the only way past is System Settings: open it
            // at the microphone list, the way Check Audio Permission… opens the
            // other grant's pane.
            err("\(red)microphone access is denied\(reset) — allow Subtitles under Privacy & Security › Microphone")
            if let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
            return
        }
    }
    tap.select(source)
    resumeCapture()
    switch source {
    case .allSystemAudio:
        UserDefaults.standard.removeObject(forKey: Defaults.sourceID)
        UserDefaults.standard.removeObject(forKey: Defaults.sourceName)
    case .microphone:
        UserDefaults.standard.set(AudioSource.microphoneID, forKey: Defaults.sourceID)
        UserDefaults.standard.set(source.label, forKey: Defaults.sourceName)
    case let .app(id, name):
        UserDefaults.standard.set(id, forKey: Defaults.sourceID)
        UserDefaults.standard.set(name, forKey: Defaults.sourceName)
    }
    overlay?.clearAndHide()
    renderer.discardLine()
    // Clearing the overlay is not enough on its own: the recogniser keeps its
    // accumulated transcript and its encoder context, so the new source's first
    // words arrive appended to a sentence the previous one was saying.
    if let fluid = fluidEngine { Task { await fluid.resetContext() } }
    err("listening to: \(source.label)")
}

func togglePause() {
    // [main-edition]
    // Resume is refused while the licence says no — the trial is over, or the
    // key was refunded — and the licence window is what opens instead. The
    // pause itself is allowed, so the person can always stop the tap.
    if isPaused, !license.entitlement.allowsTranscription {
        license.present()
        return
    }
    pausedByLicense = false
    // [/main-edition]
    isPaused.toggle()
    renderer.overlay?.setPaused(isPaused)
    // Tear the tap down rather than discarding the samples it delivers.
    // Discarding kept the aggregate device and its IOProc alive, so macOS went on
    // reporting the app as capturing audio for as long as it was "paused" — which
    // is both untrue and exactly the thing a pause button is supposed to settle.
    if isPaused {
        tap.stop()
        // Then drop what is already buffered. With `onAudioFrames` gated above,
        // nothing refills it while paused, so resuming starts from silence
        // instead of replaying the seconds before the pause.
        renderer.discardLine()
        renderer.clearHealthWarning()
        if let fluid = fluidEngine { Task { await fluid.flush() } }
    } else {
        resumeCapture()
    }
    // Say so immediately. This used to wait on the next status event from the
    // core, which never arrives when no audio is reaching the app — and never
    // arrives at all once paused, since the tap is now stopped. Via ⌥⌘S the
    // result was a shortcut that looked like it had done nothing.
    statusMenu?.updateHealthIndicator()
    err(isPaused ? "paused" : "resumed")
}

func shutdownCleanly() -> Never {
    subs_stop(engine)
    subs_destroy(engine)
    engine = nil
    exit(0)
}

// Held for the process lifetime; releasing either would unregister it.
var statusMenu: StatusMenuController?
var hotkey: Hotkey?

if useOverlay {
    let controller = OverlayController(fontSize: fontSize)
    if resetPosition { controller.resetPosition() }
    // `object(forKey:)` rather than `bool(forKey:)`: the latter reports false for
    // a key that was never written, which would ship the feature off by default
    // for everyone who has not touched the menu.
    var revealEnabled = UserDefaults.standard.object(forKey: Defaults.reveal) as? Bool ?? true
    // Defaults on: an overlay that silently vanishes from a screen share is the
    // surprising behaviour, so hiding it should be something the user chose.
    var screenShareEnabled =
        UserDefaults.standard.object(forKey: Defaults.screenShare) as? Bool ?? true
    controller.isVisibleInScreenShare = screenShareEnabled
    controller.isRevealEnabled = revealEnabled
    var historyEnabled = UserDefaults.standard.object(forKey: Defaults.history) as? Bool ?? true
    controller.isHistoryEnabled = historyEnabled
    // Where the source app's icon and name go, and how the text sits, both
    // from the menu. A stored value the current build does not know — a style
    // since dropped — falls back to the default.
    var iconStyle = UserDefaults.standard.string(forKey: Defaults.iconStyle)
        .flatMap(Pill.IconStyle.init(rawValue:)) ?? .header
    controller.iconStyle = iconStyle
    var textAlignment = UserDefaults.standard.string(forKey: Defaults.textAlignment)
        .flatMap(Pill.TextAlignment.init(rawValue:)) ?? .start
    controller.textAlignment = textAlignment
    // The original under the translation, from the Translate To menu. Off
    // unless chosen: `bool(forKey:)` is false for a key never written.
    controller.showsBothLanguages = UserDefaults.standard.bool(forKey: Defaults.bothLanguages)

    // Dials behind those switches, all live-adjustable in the settings window.
    let defaultSize = SubtitleView.defaultMaskSize
    // Clamped on the way in: the floor was lowered after this key was already
    // being written, so a stored value can predate it.
    controller.revealOpacity = min(max(CGFloat(
        UserDefaults.standard.object(forKey: Defaults.revealOpacity) as? Double
            ?? Double(SubtitleView.defaultMaskStrength)), SubtitleView.minMaskStrength), 1)
    controller.revealSize = NSSize(
        width: UserDefaults.standard.object(forKey: Defaults.revealWidth) as? Double
            ?? Double(defaultSize.width),
        height: UserDefaults.standard.object(forKey: Defaults.revealHeight) as? Double
            ?? Double(defaultSize.height))
    // Clamped on the way in, like the expiry below it. These arrive as bare
    // `as? Int` from a plist anyone can edit, and neither has a sane reading
    // below its floor: a depth under zero asks the stack to drop more boxes than
    // it holds, and a box allowed zero lines can never fit a word, so it never
    // pages and simply clips whatever it is given. No ceiling on the depth: the
    // slider's Unlimited stop is stored as `unlimitedHistoryDepth`, and the
    // overlay caps what it actually keeps.
    controller.historyDepth = max(
        UserDefaults.standard.object(forKey: Defaults.historyDepth) as? Int
            ?? OverlayController.defaultHistoryDepth, 0)
    controller.maxLines = max(
        UserDefaults.standard.object(forKey: Defaults.maxLines) as? Int
            ?? SubtitleView.defaultMaxLines, 1)
    controller.historyExpiry = (UserDefaults.standard.object(forKey: Defaults.historyExpiry)
        as? Double).map { max($0, 0) } ?? OverlayController.defaultHistoryExpiry
    controller.isHistoryExpiryEnabled =
        UserDefaults.standard.object(forKey: Defaults.historyExpires) as? Bool ?? true
    controller.historyTextOpacity = min(max(CGFloat(
        UserDefaults.standard.object(forKey: Defaults.historyTextOpacity) as? Double
            ?? Double(HistoryPillView.defaultTextOpacity)),
        HistoryPillView.minTextOpacity), 1)
    controller.boxOpacity = CGFloat(
        UserDefaults.standard.object(forKey: Defaults.boxOpacity) as? Double
            ?? Double(SubtitleView.defaultBackgroundOpacity))
    controller.backdropBlur = min(max(CGFloat(
        UserDefaults.standard.object(forKey: Defaults.backdropBlur) as? Double
            ?? Double(Pill.backdropBlur)), 0), Pill.maxBackdropBlur)

    // Read back from the controller rather than from a copy: the window is built
    // fresh on every open, and the overlay is the thing that actually holds these.
    let settings = SettingsWindow.shared
    settings.revealOpacity = { controller.revealOpacity }
    settings.onRevealOpacity = { value in
        controller.revealOpacity = value
        UserDefaults.standard.set(Double(value), forKey: Defaults.revealOpacity)
    }
    settings.revealSize = { controller.revealSize }
    settings.onRevealSize = { size in
        controller.revealSize = size
        UserDefaults.standard.set(Double(size.width), forKey: Defaults.revealWidth)
        UserDefaults.standard.set(Double(size.height), forKey: Defaults.revealHeight)
    }
    settings.revealEnabled = { revealEnabled }
    settings.onToggleReveal = { on in
        revealEnabled = on
        controller.isRevealEnabled = on
        UserDefaults.standard.set(on, forKey: Defaults.reveal)
    }
    // Both rebuild the engine, so they refuse a no-op: `windowDidBecomeKey` sets
    // the switches from these same values, and a stray reload on every focus
    // change would be a few seconds of dead air each time.
    settings.historyEnabled = { historyEnabled }
    settings.onToggleHistory = { on in
        historyEnabled = on
        controller.isHistoryEnabled = on
        UserDefaults.standard.set(on, forKey: Defaults.history)
    }
    settings.vadEnabled = { useVAD }
    settings.onToggleVAD = { on in
        guard on != useVAD else { return }
        useVAD = on
        UserDefaults.standard.set(useVAD, forKey: Defaults.useVAD)
        applyVariant(currentVariant)   // detector is built with the engine
    }
    settings.speakerBreaksEnabled = { speakerBreaksEnabled }
    settings.onToggleSpeakerBreaks = { on in
        guard on != speakerBreaksEnabled else { return }
        speakerBreaksEnabled = on
        UserDefaults.standard.set(speakerBreaksEnabled, forKey: Defaults.speakerBreaks)
        applyVariant(currentVariant)   // tracker is built with the engine
    }
    settings.onResetDefaults = {
        // Forget them rather than write the defaults back: a key that is absent
        // follows the default if the default ever changes, and a key holding the
        // same number by coincidence does not.
        for key in [Defaults.fontSize, Defaults.reveal, Defaults.history,
                    Defaults.historyDepth, Defaults.historyTextOpacity,
                    Defaults.historyExpiry, Defaults.historyExpires,
                    Defaults.maxLines, Defaults.boxOpacity, Defaults.backdropBlur,
                    Defaults.revealOpacity,
                    Defaults.revealWidth, Defaults.revealHeight,
                    Defaults.iconStyle, Defaults.textAlignment] {
            UserDefaults.standard.removeObject(forKey: key)
        }

        // Then apply them to the running overlay, since nothing re-reads the
        // defaults until launch.
        fontSize = defaultFontSize
        controller.setFontSize(fontSize)
        revealEnabled = true
        controller.isRevealEnabled = true
        historyEnabled = true
        controller.isHistoryEnabled = true
        iconStyle = .header
        controller.iconStyle = .header
        textAlignment = .start
        controller.textAlignment = .start
        controller.maxLines = SubtitleView.defaultMaxLines
        controller.boxOpacity = SubtitleView.defaultBackgroundOpacity
        controller.backdropBlur = Pill.backdropBlur
        controller.historyDepth = OverlayController.defaultHistoryDepth
        controller.historyTextOpacity = HistoryPillView.defaultTextOpacity
        controller.historyExpiry = OverlayController.defaultHistoryExpiry
        controller.isHistoryExpiryEnabled = true
        controller.revealOpacity = SubtitleView.defaultMaskStrength
        controller.revealSize = SubtitleView.defaultMaskSize
        // Owns its own key, so it clears it itself.
        controller.resetPosition()
    }
    settings.modelsInUse = {
        ModelCache.inUse(variant: currentVariant, speakerBreaks: speakerBreaksEnabled)
    }
    settings.historyExpiry = { controller.historyExpiry }
    settings.onHistoryExpiry = { seconds in
        controller.historyExpiry = max(seconds, 0)
        UserDefaults.standard.set(seconds, forKey: Defaults.historyExpiry)
    }
    settings.historyExpires = { controller.isHistoryExpiryEnabled }
    settings.onHistoryExpires = { on in
        controller.isHistoryExpiryEnabled = on
        UserDefaults.standard.set(on, forKey: Defaults.historyExpires)
    }
    settings.historyTextOpacity = { controller.historyTextOpacity }
    settings.onHistoryTextOpacity = { value in
        controller.historyTextOpacity = value
        UserDefaults.standard.set(Double(value), forKey: Defaults.historyTextOpacity)
    }
    settings.fontSize = { fontSize }
    settings.boxOpacity = { controller.boxOpacity }
    settings.onBoxOpacity = { value in
        controller.boxOpacity = value
        UserDefaults.standard.set(Double(value), forKey: Defaults.boxOpacity)
    }
    settings.backdropBlur = { controller.backdropBlur }
    settings.onBackdropBlur = { value in
        controller.backdropBlur = value
        UserDefaults.standard.set(Double(value), forKey: Defaults.backdropBlur)
    }
    settings.maxLines = { controller.maxLines }
    settings.onMaxLines = { lines in
        controller.maxLines = lines
        UserDefaults.standard.set(lines, forKey: Defaults.maxLines)
    }
    settings.historyDepth = { controller.historyDepth }
    settings.onHistoryDepth = { depth in
        controller.historyDepth = depth
        UserDefaults.standard.set(depth, forKey: Defaults.historyDepth)
    }
    renderer.overlay = controller

    // Which app the boxes belong to: the live box wears its icon, and each box
    // in the ⌥ stack the icon of the app it transcribed. See PlayingApp.swift.
    let playingApp = PlayingAppMonitor(rules: .byEar)
    playingApp.source = { tap.source }
    playingApp.isPaused = { isPaused }
    playingApp.onChange = { controller.playingApp = $0 }
    playingApp.start()
    settings.iconStyle = { iconStyle }
    settings.textAlignment = { textAlignment }

    let menu = StatusMenuController()
    menu.isPaused = { isPaused }
    menu.currentSource = { tap.source }
    menu.currentFontSize = { fontSize }
    menu.currentVariantID = { currentVariant.rawValue }
    menu.engineBusy = { engineBusyMessage }
    menu.engineProgress = { engineBusyProgress }
    menu.statusLine = {
        if let busy = engineBusyMessage { return (busy, .normal) }
        // Above pause and audio health: with no recogniser loaded, neither of
        // those is the reason nothing is on screen.
        if let failure = engineFailure { return (failure, .warning) }
        // Paused outranks the rest. Receiving no audio while paused is the tap
        // being stopped on purpose, not a fault, and it is certainly not the app
        // listening. A model load still shows through above: that carries on
        // regardless of capture.
        // [main-edition]
        // A licence pause says why, in the default colour: not a fault, and
        // not nothing either — the one line here that asks for something.
        if isPaused, let blocked = license.entitlement.blockedStatusLine {
            return (blocked, .normal)
        }
        // [/main-edition]
        if isPaused { return ("Paused", .idle) }
        // One message, and not a red one. Distinguishing "nothing is playing" from
        // "the grant is missing" needs `processesOutputtingAudio()`, and that is
        // not trustworthy enough to accuse anyone with: browsers hold the audio
        // device open with IsRunningOutput true long after playback stops, so the
        // fault case fires the moment a video is paused. Phrasing the permission
        // as a conditional hint is honest in both cases, and stays quiet in the
        // one that is overwhelmingly more common.
        if !renderer.receivingAudio {
            if tap.source == .microphone {
                return ("No sound from the microphone — check permission if you are speaking",
                        .idle)
            }
            return ("No audio reaching Subtitles — check permission if audio is playing",
                    .idle)
        }
        return (String(format: "%@ · RTF %.2f", currentVariant.displayName, lastRTF),
                lastRTF < 0.8 ? .normal : .warning)
    }
    menu.onTogglePause = { togglePause() }
    menu.onResetPosition = { controller.resetPosition() }
    menu.onQuit = { shutdownCleanly() }

    // [main-edition]
    // Updates (§23). Started before the menu is wired to it, so a build that
    // cannot update — no Info.plist around the binary — simply has no items.
    let updater = Updater()
    updater.feedOverride = feedOverride
    // Paused counts as quiet for as long as it lasts: nobody is reading
    // captions that are not there.
    updater.quietFor = { isPaused ? .infinity : TimeInterval(renderer.silentSeconds) }
    updater.mayInterrupt = { !WelcomeWindow.shared.isVisible }
    updater.start()
    if updater.started {
        menu.itemsUnderPause = { updater.menuItems() }
        updater.onPendingChange = { menu.updateHealthIndicator() }
    }
    // One red badge for whatever waits on the person: an update found, or a
    // key to enter once the trial is over. Wired whether or not the updater
    // started, since a build without a bundle still has a trial.
    let attention = AttentionBadge()
    menu.decorateStatusButton = { button, glyph in
        attention.decorate(button, glyph: glyph,
                           count: (updater.pendingVersion != nil ? 1 : 0)
                               + (license.entitlement.allowsTranscription ? 0 : 1))
    }
    // [/main-edition]
    menu.onSelectVariant = { applyVariant($0) }
    menu.onSelectLanguage = { applyLanguage($0) }
    menu.currentLanguageID = { currentLanguage.rawValue }
    menu.onSelectTranslation = { applyTranslation($0) }
    menu.currentTranslationID = { translateTo?.rawValue }
    menu.onSelectTranslationMode = { applyTranslationMode($0) }
    menu.currentTranslationMode = { translationMode }
    menu.showsBothLanguages = { controller.showsBothLanguages }
    menu.onToggleBothLanguages = {
        controller.showsBothLanguages.toggle()
        UserDefaults.standard.set(controller.showsBothLanguages, forKey: Defaults.bothLanguages)
        err(controller.showsBothLanguages ? "showing both languages"
                                          : "showing the translation alone")
        // The direction can depend on it — see `translationPair()`.
        refreshTranslationSource()
    }
    menu.screenShareEnabled = { screenShareEnabled }
    menu.onToggleScreenShare = {
        screenShareEnabled.toggle()
        controller.isVisibleInScreenShare = screenShareEnabled
        UserDefaults.standard.set(screenShareEnabled, forKey: Defaults.screenShare)
    }
    menu.revealEnabled = { revealEnabled }
    menu.onToggleReveal = {
        revealEnabled.toggle()
        controller.isRevealEnabled = revealEnabled
        settings.refreshPreview(changed: [.revealEnabled])
        UserDefaults.standard.set(revealEnabled, forKey: Defaults.reveal)
    }
    menu.historyEnabled = { historyEnabled }
    menu.onToggleHistory = {
        historyEnabled.toggle()
        controller.isHistoryEnabled = historyEnabled
        settings.refreshPreview(changed: [.historyEnabled])
        UserDefaults.standard.set(historyEnabled, forKey: Defaults.history)
    }
    menu.onFontSize = { size in
        fontSize = size
        controller.setFontSize(size)
        settings.refreshPreview(changed: [.fontSize])
        UserDefaults.standard.set(Double(size), forKey: Defaults.fontSize)
    }
    menu.onSelectSource = { source in
        selectSource(source, overlay: controller)
    }
    menu.currentTextAlignment = { textAlignment }
    menu.onSelectTextAlignment = { choice in
        textAlignment = choice
        controller.textAlignment = choice
        settings.refreshPreview(changed: [.textAlignment])
        UserDefaults.standard.set(choice.rawValue, forKey: Defaults.textAlignment)
        err("text alignment: \(choice.title)")
    }
    menu.currentIconStyle = { iconStyle }
    menu.onSelectIconStyle = { style in
        iconStyle = style
        controller.iconStyle = style
        settings.refreshPreview(changed: [.iconStyle])
        UserDefaults.standard.set(style.rawValue, forKey: Defaults.iconStyle)
        err("app icon on boxes: \(style.title)")
    }
    // Speech has stopped even if audio has not. Drop the recogniser's context so
    // a backing track cannot swallow the first words of whoever speaks next.
    controller.onFaded = {
        if let fluid = fluidEngine { Task { await fluid.resetContext() } }
        // The translator owes nothing for a box that has gone. Anything still in
        // flight would arrive into the *next* box, which is text from before a
        // pause turning up after it.
        if #available(macOS 15, *) {
            MainActor.assumeIsolated { translation?.discardPending() }
        }
    }
    renderer.onStatusRefresh = { [weak menu] in menu?.updateHealthIndicator() }
    statusMenu = menu

    // [main-edition]
    license.onChange = { [weak menu] in menu?.updateHealthIndicator() }
    menu.itemsAboveSettings = { [license.menuItem()] }
    AboutWindow.shared.licenseLine = { license.entitlement.aboutLine }
    if isPaused { controller.setPaused(true) }
    // [/main-edition]

    // Restore a saved target now rather than at load time: the controller needs
    // the overlay and the menu, both of which exist only here.
    if let target = translateTo { applyTranslation(target) }

    // ⌥⌘S. Carbon, so it needs no Accessibility permission — see Hotkey.swift.
    hotkey = Hotkey(keyCode: kVK_ANSI_S, modifiers: cmdKey | optionKey) { togglePause() }
    if hotkey == nil { err("could not register ⌥⌘S (already taken?)") }

    err("overlay on — click-through; hold ⇧ to drag it, ⌥ for recent boxes. ⌥⌘S pauses.")
}

// [main-edition]
// The licence gate (§24). Expiry takes the pause path, so the tap comes down,
// the icon dims and the overlay clears exactly as Pause does; the status line
// says why, and Resume opens the licence window. Outside the overlay block:
// --headless is gated the same way.
license.onBlocked = {
    guard !isPaused else { return }
    togglePause()
    pausedByLicense = true
}
license.onUnblocked = {
    guard isPaused, pausedByLicense else { return }
    pausedByLicense = false
    isPaused = false
    renderer.overlay?.setPaused(false)
    resumeCapture()
    statusMenu?.updateHealthIndicator()
    err("resumed — licensed")
}
// [/main-edition]

applyVariant(currentVariant, initial: true)

// First run, or a run with nothing cached: both are launches where the app can
// do nothing for several minutes, and the welcome window is what fills them.
//
// After `applyVariant`, not before: that is what sets the load going, and a
// window opened ahead of it polls once, sees nothing loading, and concludes the
// download it is there to report has already finished.
if useOverlay {
    WelcomeWindow.shared.engineBusy = { engineBusyMessage }
    WelcomeWindow.shared.engineProgress = { engineBusyProgress }
    // The demo draws the box the overlay is drawing: the settings window's
    // getters are the one place all of these are already gathered, and its
    // preview the one place every change to them already reports.
    WelcomeWindow.shared.settings = { SettingsWindow.shared.currentStyle() }
    SettingsWindow.shared.onStyleChange = { WelcomeWindow.shared.follow($0, changed: $1) }
    // [main-edition]
    WelcomeWindow.shared.trialLine = {
        guard case .trial = license.entitlement else { return nil }
        return "Your free trial runs for \(LicenseRecord.trialDays) days, and starts when the captions do."
    }
    // [/main-edition]
    if WelcomeWindow.shouldShowAtLaunch {
        WelcomeWindow.shared.show(markAsSeen: true)
    }
}
// [main-edition]
// Not while the licence has paused it: `resumeCapture` brings the tap up
// once a key is entered, the same as after any pause.
if isPaused {
    err("\(yellow)not listening:\(reset) \(license.entitlement.blockedStatusLine ?? "paused")")
} else {
    do {
        try tap.start()
    } catch {
        err("\(red)capture failed:\(reset) \(error)")
        exit(1)
    }
}
// [/main-edition]
// [0bsd-edition]
// do {
//     try tap.start()
// } catch {
//     err("\(red)capture failed:\(reset) \(error)")
//     exit(1)
// }
// [/0bsd-edition]
err("listening. ctrl-C to stop.\n")

// SIGUSR1 cycles variants, so A/B comparison is scriptable.
let cycleVariant: @convention(c) (Int32) -> Void = { _ in
    DispatchQueue.main.async {
        let all = FluidVariant.allCases
        let index = all.firstIndex(of: currentVariant) ?? 0
        applyVariant(all[(index + 1) % all.count])
    }
}
signal(SIGUSR1, cycleVariant)

// SIGUSR2 cycles sources over what is audible right now, for the same reason:
// exercising the switch path otherwise needs a hand on the menu, and this is the
// path where a stale tap shows up.
let cycleSource: @convention(c) (Int32) -> Void = { _ in
    DispatchQueue.main.async {
        var options: [AudioSource] = [.allSystemAudio]
        options += SystemAudioTap.audioSources()
            .filter(\.isPlaying)
            .map { AudioSource.app(id: $0.id, name: $0.name) }
        let index = options.firstIndex(of: tap.source) ?? 0
        selectSource(options[(index + 1) % options.count], overlay: renderer.overlay)
    }
}
signal(SIGUSR2, cycleSource)

let shutdown: @convention(c) (Int32) -> Void = { _ in
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    shutdownCleanly()
}
signal(SIGINT, shutdown)
signal(SIGTERM, shutdown)

// An Edit menu, though no menu bar ever shows it. ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z
// reach a text field only as the key equivalents of these menu items, so
// without them what was on the clipboard could be typed into a field but
// never pasted into it. A nil target is the first responder, which while a
// field is editing is its field editor. The first item of a main menu is the
// application menu whatever it is called, so Edit is the second.
let edit = NSMenu(title: "Edit")
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
edit.addItem(.separator())
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
let mainMenu = NSMenu()
mainMenu.addItem(withTitle: "Subtitles", action: nil, keyEquivalent: "").submenu = NSMenu()
mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
app.mainMenu = mainMenu

// .accessory: no Dock icon, no menu bar, and the app never becomes active —
// combined with .nonactivatingPanel the overlay cannot steal focus.
app.setActivationPolicy(.accessory)
app.run()
