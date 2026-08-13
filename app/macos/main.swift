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
import CSubs
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
var fontSize: CGFloat = 30
var resetPosition = false
var listSources = false
var variantOverride: FluidVariant?

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--quiet": showStatus = false
    case "--headless": useOverlay = false
    case "--reset-position": resetPosition = true
    case "--list-sources": listSources = true
    case "--font-size" where i + 1 < args.count:
        fontSize = CGFloat(Double(args[i + 1]) ?? 30); i += 1
    case "--variant" where i + 1 < args.count:
        variantOverride = FluidVariant(rawValue: args[i + 1]); i += 1
    case "--help", "-h":
        print("""
        usage: subtitles [options]

          --variant NAME    \(FluidVariant.allCases.map(\.rawValue).joined(separator: " | "))
          --headless        no overlay, stdout only
          --font-size N     overlay text size (default 30)
          --reset-position  put the overlay back to bottom-centre
          --list-sources    print audio sources and exit (no permission needed)
          --quiet           suppress status lines

        Live subtitles for system audio, transcribed on the Apple Neural Engine.
        The overlay is click-through; hold ⇧ to drag it, and its position is
        remembered.

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
    exit(0)
}

// ── persisted settings ──
enum Defaults {
    static let fontSize = "overlay.fontSize"
    static let sourceID = "source.id"
    static let sourceName = "source.name"
    static let variant = "engine.variant"
    static let speakerBreaks = "engine.speakerBreaks"
    static let useVAD = "engine.vad"
}

/// Read by the realtime audio callback, written from the main thread. A plain
/// word-sized Bool: no tearing on arm64, and a lock in the audio callback would
/// cost far more than a missed frame at the moment of toggling.
nonisolated(unsafe) var isPaused = false

let app = NSApplication.shared

// ── engine ──
// Globals rather than captures: the audio callback must not touch ARC.
nonisolated(unsafe) var engine: OpaquePointer?
nonisolated(unsafe) var fluidEngine: FluidAudioEngine?
/// Nemotron 560 rather than EOU 320: it is the tier actually in use here, so the
/// bundle a cold cache pulls is the one the app will go on running. Note this
/// avoids downloading a *second* family that never gets used — a genuinely fresh
/// machine still fetches this one from HuggingFace on first launch.
nonisolated(unsafe) var currentVariant: FluidVariant = .nemotron560
/// Non-nil while a model is downloading or loading.
nonisolated(unsafe) var engineBusyMessage: String?
/// How far that load has got, 0…1. Only read while `engineBusyMessage` is set.
nonisolated(unsafe) var engineBusyProgress: Double = 0
/// Rolling real-time factor reported by the engine; > 0.8 means trouble.
nonisolated(unsafe) var lastRTF: Float = 0
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

if let saved = UserDefaults.standard.object(forKey: Defaults.fontSize) as? Double {
    fontSize = CGFloat(saved)
}
if let override = variantOverride {
    currentVariant = override
} else if let raw = UserDefaults.standard.string(forKey: Defaults.variant),
          let v = FluidVariant(rawValue: raw) {
    currentVariant = v
}

/// Gated, pre-rolled 16 kHz frames from the core. Runs on the core's worker
/// thread, not the audio thread, so hopping into the actor here is safe.
let onAudioFrames: @convention(c) (UnsafePointer<Float>?, UInt, UnsafeMutableRawPointer?) -> Void = {
    ptr, count, _ in
    guard let ptr, count > 0, let fluid = fluidEngine else { return }
    // Hand off to a bounded queue rather than spawning a task per callback: an
    // engine that falls behind must drop audio, not accumulate tasks.
    fluid.queue.push(UnsafeBufferPointer(start: ptr, count: Int(count)))
}

/// Renderer state. Events are marshalled onto the main thread before reaching
/// this, because the overlay is AppKit and the core calls back from its worker.
final class Renderer {
    /// nil in --headless mode.
    var overlay: OverlayController?
    var onStatusRefresh: (() -> Void)?

    private var line = ""
    private var warnedAboutSilence = false
    private var lastStatus = ""
    private(set) var audioHealthy = true

    /// FluidAudio reports the whole transcript each update rather than deltas,
    /// with the audio time of every word — which is what the overlay pages on.
    func setWords(_ words: [TimedWord]) {
        line = words.map(\.text).joined(separator: " ")
        overlay?.showWords(words)
        FileHandle.standardOutput.write("\r\(clearLine)\(line)".data(using: .utf8)!)
    }

    /// End of utterance: freeze the line and start a new one.
    func endpoint() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            FileHandle.standardOutput.write("\r\(clearLine)\(trimmed)\n".data(using: .utf8)!)
        }
        line = ""
        overlay?.endUtterance()
    }

    func pause() {
        overlay?.markPause()
    }

    func status(_ text: String, peak: Float, silentSeconds: Float, dropped: UInt64) {
        // A missing audio-capture grant yields perfectly timed, correctly sized,
        // all-zero buffers with noErr everywhere. The only way to tell that apart
        // from genuine quiet is to ask whether anything is actually playing.
        if silentSeconds > 4, !warnedAboutSilence {
            let playing = SystemAudioTap.processesOutputtingAudio()
            if !playing.isEmpty {
                warnedAboutSilence = true
                audioHealthy = false
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
            audioHealthy = true
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
    startingSource = .app(id: id, name: name)
}

let format: TapFormat
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

func resumeCapture() {
    do {
        try tap.prepare(source: tap.source)
        try tap.start()
    } catch {
        err("\(red)could not restart capture:\(reset) \(error)")
    }
}

/// Build the core and the FluidAudio engine for `variant`, replacing whatever is
/// running.
func applyVariant(_ variant: FluidVariant, initial: Bool = false) {
    guard engineBusyMessage == nil else { return }
    currentVariant = variant
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
        onWords: { words in
            DispatchQueue.main.async { renderer.setWords(words) }
        },
        onStatus: { message in
            DispatchQueue.main.async {
                engineBusyMessage = message.isEmpty ? nil : message
                if message.isEmpty { engineBusyProgress = 0 }
                statusMenu?.updateHealthIndicator()
                if !message.isEmpty { err(message) }
            }
        },
        onProgress: { fraction, headline in
            DispatchQueue.main.async {
                engineBusyMessage = headline
                engineBusyProgress = fraction
                statusMenu?.updateHealthIndicator()
                err(headline)
            }
        },
        onFinal: { words in
            DispatchQueue.main.async {
                if !words.isEmpty { renderer.setWords(words) }
                renderer.overlay?.endUtterance()
            }
        },
        onReady: { ok in
            DispatchQueue.main.async {
                err(ok ? "engine ready: \(variant.displayName)"
                       : "\(red)engine failed to load\(reset)")
                engineBusyMessage = nil
                engineBusyProgress = 0
                statusMenu?.updateHealthIndicator()
            }
        },
        onRTF: { rtf in
            DispatchQueue.main.async { lastRTF = rtf }
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

    DispatchQueue.global(qos: .userInitiated).async {
        let old = engine
        engine = nil
        subs_stop(old)
        subs_destroy(old)

        guard let created = makeCore() else {
            DispatchQueue.main.async {
                engineBusyMessage = nil
                engineBusyProgress = 0
                resumeCapture()
            }
            return
        }
        subs_set_callback(created, onEvent, nil)
        subs_set_audio_callback(created, onAudioFrames, nil)
        let rc = subs_start(created)

        // First run downloads the CoreML bundles from HuggingFace; progress goes
        // to the status line via onStatus.
        Task { await fluid.load() }

        DispatchQueue.main.async {
            engine = rc == 0 ? created : nil
            if rc != 0 {
                subs_destroy(created)
                err("\(red)subs_start failed (\(rc))\(reset)")
            }
            resumeCapture()
            statusMenu?.updateHealthIndicator()
        }
    }
}

func togglePause() {
    isPaused.toggle()
    if isPaused { renderer.overlay?.clearAndHide() }
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
    renderer.overlay = controller

    let menu = StatusMenuController()
    menu.isPaused = { isPaused }
    menu.currentSource = { tap.source }
    menu.currentFontSize = { fontSize }
    menu.currentVariantID = { currentVariant.rawValue }
    menu.engineBusy = { engineBusyMessage }
    menu.engineProgress = { engineBusyProgress }
    menu.statusLine = {
        if let busy = engineBusyMessage { return (busy, true) }
        if !renderer.audioHealthy { return ("No audio reaching Subtitles", false) }
        if isPaused { return ("Paused", true) }
        return (String(format: "%@ · RTF %.2f", currentVariant.displayName, lastRTF),
                lastRTF < 0.8)
    }
    menu.onTogglePause = { togglePause() }
    menu.onResetPosition = { controller.resetPosition() }
    menu.onQuit = { shutdownCleanly() }
    menu.onSelectVariant = { applyVariant($0) }
    menu.speakerBreaksEnabled = { speakerBreaksEnabled }
    menu.vadEnabled = { useVAD }
    menu.onToggleVAD = {
        useVAD.toggle()
        UserDefaults.standard.set(useVAD, forKey: Defaults.useVAD)
        applyVariant(currentVariant)   // detector is built with the engine
    }
    menu.onToggleSpeakerBreaks = {
        speakerBreaksEnabled.toggle()
        UserDefaults.standard.set(speakerBreaksEnabled, forKey: Defaults.speakerBreaks)
        // Cheapest correct path: the tracker is built with the engine, so rebuild.
        applyVariant(currentVariant)
    }
    menu.onFontSize = { size in
        fontSize = size
        controller.setFontSize(size)
        UserDefaults.standard.set(Double(size), forKey: Defaults.fontSize)
    }
    menu.onSelectSource = { source in
        do {
            _ = try tap.switchTo(source: source)
            switch source {
            case .allSystemAudio:
                UserDefaults.standard.removeObject(forKey: Defaults.sourceID)
                UserDefaults.standard.removeObject(forKey: Defaults.sourceName)
            case let .app(id, name):
                UserDefaults.standard.set(id, forKey: Defaults.sourceID)
                UserDefaults.standard.set(name, forKey: Defaults.sourceName)
            }
            controller.clearAndHide()
            err("listening to: \(source.label)")
        } catch {
            err("\(red)could not switch source:\(reset) \(error)")
        }
    }
    // Speech has stopped even if audio has not. Drop the recogniser's context so
    // a backing track cannot swallow the first words of whoever speaks next.
    controller.onFaded = {
        if let fluid = fluidEngine { Task { await fluid.resetContext() } }
    }
    renderer.onStatusRefresh = { [weak menu] in menu?.updateHealthIndicator() }
    statusMenu = menu

    // ⌥⌘S. Carbon, so it needs no Accessibility permission — see Hotkey.swift.
    hotkey = Hotkey(keyCode: kVK_ANSI_S, modifiers: cmdKey | optionKey) { togglePause() }
    if hotkey == nil { err("could not register ⌥⌘S (already taken?)") }

    err("overlay on — click-through; hold ⇧ to drag it. ⌥⌘S pauses.")
}

applyVariant(currentVariant, initial: true)
do {
    try tap.start()
} catch {
    err("\(red)capture failed:\(reset) \(error)")
    exit(1)
}
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

let shutdown: @convention(c) (Int32) -> Void = { _ in
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    shutdownCleanly()
}
signal(SIGINT, shutdown)
signal(SIGTERM, shutdown)

// .accessory: no Dock icon, no menu bar, and the app never becomes active —
// combined with .nonactivatingPanel the overlay cannot steal focus.
app.setActivationPolicy(.accessory)
app.run()
