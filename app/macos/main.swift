// Application entry point.
//
// tap → ring → resample → gate → ASR → stabilizer → overlay (and stdout).
// The overlay lives in Overlay.swift; --headless drops back to the Phase 1
// terminal renderer, which stays useful for debugging the pipeline.
//
// Must be launched as a bundle via `open` (see run.sh). Executing the binary
// directly makes the terminal the TCC-responsible process and the tap then
// delivers all-zero audio with no error anywhere — Spike 0B Finding 2.

import AppKit
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
var modelDir: String?
var threads: Int32 = 2
var useInt8 = false
var showStatus = true
var useOverlay = true
var fontSize: CGFloat = 30
var resetPosition = false
var listSources = false

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--model" where i + 1 < args.count: modelDir = args[i + 1]; i += 1
    case "--threads" where i + 1 < args.count: threads = Int32(args[i + 1]) ?? 2; i += 1
    case "--int8": useInt8 = true
    case "--quiet": showStatus = false
    case "--headless": useOverlay = false
    case "--reset-position": resetPosition = true
    case "--list-sources": listSources = true
    case "--font-size" where i + 1 < args.count:
        fontSize = CGFloat(Double(args[i + 1]) ?? 30); i += 1
    case "--help", "-h":
        print("""
        usage: subtitles [options]

          --model DIR       model directory
          --threads N       ASR threads (default 2)
          --int8            use int8 weights
          --headless        no overlay, stdout only
          --font-size N     overlay text size (default 30)
          --reset-position  put the overlay back to bottom-centre
          --list-sources    print audio sources and exit (no permission needed)
          --quiet           suppress status lines

        Shows live subtitles for system audio. The overlay is click-through;
        hold ⌥ to drag it, and its position is remembered.

        Launch via run.sh, not directly — TCC attributes the audio-capture
        grant to the launching process.
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
        let mark = p.isPlaying ? "●" : " "
        print("  \(mark) \(p.name)  [\(p.pids.count) proc]  \(p.id)")
    }
    print("\n● = currently playing")
    exit(0)
}

/// The catalogue entry to start with: last used, else the first one installed.
func resolveInitialModel() -> ModelSpec? {
    if let id = UserDefaults.standard.string(forKey: Defaults.modelID),
       let spec = ModelCatalog.spec(withID: id),
       ModelCatalog.isInstalled(spec) { return spec }
    return ModelCatalog.all.first { ModelCatalog.isInstalled($0) }
}

/// Model lookup: explicit flag wins, then the catalogue, then the app bundle.
func resolveModelDir() -> String? {
    if let modelDir { return modelDir }
    if let spec = resolveInitialModel() { return ModelCatalog.directory(for: spec).path }
    if let res = Bundle.main.resourceURL?.appendingPathComponent("model").path,
       FileManager.default.fileExists(atPath: res) { return res }
    return nil
}

guard let model = resolveModelDir() else {
    err("\(red)no model installed\(reset) — run ./scripts/fetch-deps.sh, or pass --model DIR")
    exit(1)
}
nonisolated(unsafe) var currentModelSpec: ModelSpec? = resolveInitialModel()
/// Non-nil while a model is downloading or loading.
nonisolated(unsafe) var modelBusyMessage: String?
let modelInstaller = ModelInstaller()

// ── persisted settings ──
enum Defaults {
    static let fontSize = "overlay.fontSize"
    static let sourceID = "source.id"
    static let modelID = "model.id"
    static let sourceName = "source.name"
}

/// Read by the realtime audio callback, written from the main thread. A plain
/// word-sized Bool: no tearing on arm64, and the cost of a lock in the audio
/// callback would be far worse than a missed frame at the moment of toggling.
nonisolated(unsafe) var isPaused = false

// Touch NSApplication before any window exists. .accessory is applied at the
// bottom of this file, just before the run loop starts.
let app = NSApplication.shared

// ── engine ──
// Global rather than captured: the audio callback must not touch ARC.
nonisolated(unsafe) var engine: OpaquePointer?

/// Renderer state. Events are marshalled onto the main thread before reaching
/// this, because the overlay is AppKit and the core calls back from its worker.
final class Renderer {
    private var committed = ""
    private var tentative = ""
    private var warnedAboutSilence = false
    private var lastStatus = ""

    /// nil in --headless mode.
    var overlay: OverlayController?

    /// Called after every status update so the menu bar can reflect health.
    var onStatusRefresh: (() -> Void)?

    /// Latest figures, for the menu bar status line.
    private(set) var lastRTF: Float = 0
    private(set) var audioHealthy = true

    func redraw() {
        let line = committed + (tentative.isEmpty ? "" : "\(dim)\(tentative)\(reset)")
        FileHandle.standardOutput.write("\r\(clearLine)\(line)".data(using: .utf8)!)
    }

    /// Deliberately does not redraw: the core always follows a COMMITTED with a
    /// TENTATIVE, so redrawing here too would paint the newly committed word
    /// alongside a stale tail for one frame.
    func commit(_ text: String) {
        committed += text
        overlay?.appendCommitted(text)
    }

    func tentative(_ text: String) {
        tentative = text
        redraw()
        overlay?.setTentative(text)
    }

    /// End of utterance: freeze the line and start a new one.
    func endpoint() {
        let trimmed = committed.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            FileHandle.standardOutput.write("\r\(clearLine)\(trimmed)\n".data(using: .utf8)!)
        }
        committed = ""
        tentative = ""
        // endUtterance folds in any commit that arrived without a following
        // tentative, so the flushed tail of an uncertain utterance still shows.
        overlay?.endUtterance()
    }

    func status(_ text: String, rtf: Float, silentSeconds: Float, dropped: UInt64) {
        // Spike 0B Finding 1: a missing audio-capture grant yields perfectly
        // timed, correctly sized, all-zero buffers with noErr everywhere. The
        // only way to tell that apart from genuine quiet is to ask whether
        // anything is actually playing.
        if silentSeconds > 4, !warnedAboutSilence {
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
                // Surfaced as a red dot on the menu bar icon, not on the
                // overlay: the overlay is for subtitles, and covering it with a
                // diagnostic is exactly when the user is least able to tell what
                // is wrong.
                audioHealthy = false
            }
        } else if silentSeconds == 0 {
            warnedAboutSilence = false
            audioHealthy = true
        }

        lastRTF = rtf
        onStatusRefresh?()
        guard showStatus else { return }
        // RTF above ~0.8 means the pipeline is close to falling behind
        // permanently (PLAN.md §8a Finding 2).
        let rtfColor = rtf > 0.8 ? red : (rtf > 0.5 ? yellow : green)
        var s = "[\(text)  rtf \(rtfColor)\(String(format: "%.2f", rtf))\(reset)"
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
    // Copy out of the event before leaving the callback: `text` is only valid for
    // its duration, and everything below runs later on another thread.
    let text = ev.text.map { String(cString: $0) } ?? ""
    let kind = ev.kind, rtf = ev.rtf, silent = ev.silent_seconds, dropped = ev.dropped
    DispatchQueue.main.async {
        switch kind {
        case SUBS_EVENT_COMMITTED: renderer.commit(text)
        case SUBS_EVENT_TENTATIVE: renderer.tentative(text)
        case SUBS_EVENT_ENDPOINT: renderer.endpoint()
        case SUBS_EVENT_PAUSE: renderer.overlay?.markPause()
        case SUBS_EVENT_STATUS:
            renderer.status(text, rtf: rtf, silentSeconds: silent, dropped: dropped)
        default: break
        }
    }
}

// Startup order matters. `prepare()` creates the tap and reports its format
// without starting IO; the worker is fully running before a single sample is
// captured. Starting capture first buries the opening seconds of speech behind a
// model load's worth of buffered audio.
let tap = SystemAudioTap { samples, count in
    // Realtime thread. subs_push_audio copies into the ring and returns.
    if isPaused { return }
    subs_push_audio(engine, samples, UInt(count))
}

if let saved = UserDefaults.standard.object(forKey: Defaults.fontSize) as? Double {
    fontSize = CGFloat(saved)
}

// Restore the chosen source. Stored as a bundle prefix rather than a pid, so it
// survives the app being relaunched; prepare() falls back to all system audio if
// nothing matches.
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
err("model: \(model)")
err("loading model…")

// The pointer from withCString is only valid inside the closure, so build the
// config and call subs_create there. subs_create copies the path into
// Rust-owned storage before returning.
engine = model.withCString { modelPtr in
    var cfg = subs_config_t(
        model_dir: modelPtr,
        num_threads: threads,
        input_sample_rate: UInt32(format.sampleRate),
        input_channels: UInt16(format.channels),
        int8: useInt8 ? 1 : 0)
    return subs_create(&cfg)
}

guard engine != nil else {
    err("\(red)subs_create failed\(reset)")
    exit(1)
}
subs_set_callback(engine, onEvent, nil)

let rc = subs_start(engine)
if rc != 0 {
    err("\(red)subs_start failed (\(rc))\(reset) — is \(model) a valid model directory?")
    exit(1)
}

// Only now does audio start flowing.
do {
    try tap.start()
} catch {
    err("\(red)capture failed:\(reset) \(error)")
    exit(1)
}

func togglePause() {
    isPaused.toggle()
    if isPaused { renderer.overlay?.clearAndHide() }
    err(isPaused ? "paused" : "resumed")
}

/// Rebuild the engine against a different model directory.
///
/// Loading takes seconds, so it runs off the main thread; the audio callback sees
/// `engine == nil` meanwhile and drops samples, which is preferable to queueing a
/// backlog of audio recorded against the old model.
func swapEngine(toDirectory dir: String, label: String) {
    modelBusyMessage = "Loading \(label)…"
    statusMenu?.updateHealthIndicator()
    renderer.overlay?.clearAndHide()

    // Stop capture *before* touching the engine. Clearing the global is not
    // enough on its own: the realtime callback may already have loaded the old
    // pointer and be inside subs_push_audio, so destroying it here would be a
    // use-after-free. AudioDeviceStop is synchronous — once it returns no IOProc
    // is in flight and the swap is safe.
    tap.stop()

    DispatchQueue.global(qos: .userInitiated).async {
        let old = engine
        engine = nil
        subs_stop(old)
        subs_destroy(old)

        let created: OpaquePointer? = dir.withCString { ptr in
            var cfg = subs_config_t(
                model_dir: ptr,
                num_threads: threads,
                input_sample_rate: UInt32(format.sampleRate),
                input_channels: UInt16(format.channels),
                int8: useInt8 ? 1 : 0)
            return subs_create(&cfg)
        }
        guard let created else {
            DispatchQueue.main.async {
                modelBusyMessage = nil
                err("\(red)could not create engine for \(label)\(reset)")
                resumeCapture()
            }
            return
        }
        subs_set_callback(created, onEvent, nil)
        let rc = subs_start(created)
        DispatchQueue.main.async {
            if rc == 0 {
                // Publish only once the worker is running, so nothing queues up
                // behind a model that is still loading.
                engine = created
                err("model: \(label)")
            } else {
                subs_destroy(created)
                err("\(red)subs_start failed (\(rc)) for \(label)\(reset)")
            }
            modelBusyMessage = nil
            statusMenu?.updateHealthIndicator()
            resumeCapture()
        }
    }
}

/// Restart capture after a model swap, keeping whatever source was selected.
func resumeCapture() {
    do {
        try tap.prepare(source: tap.source)
        try tap.start()
    } catch {
        err("\(red)could not restart capture:\(reset) \(error)")
    }
}

/// Switch to a catalogue model, downloading it first if necessary.
func applyModel(_ spec: ModelSpec) {
    guard modelBusyMessage == nil else { return }
    UserDefaults.standard.set(spec.id, forKey: Defaults.modelID)

    if ModelCatalog.isInstalled(spec) {
        currentModelSpec = spec
        swapEngine(toDirectory: ModelCatalog.directory(for: spec).path, label: spec.name)
        return
    }
    modelInstaller.install(spec, onProgress: { message in
        modelBusyMessage = message
        statusMenu?.updateHealthIndicator()
    }, onFinish: { result in
        switch result {
        case let .success(installed):
            currentModelSpec = installed
            swapEngine(toDirectory: ModelCatalog.directory(for: installed).path,
                       label: installed.name)
        case let .failure(error):
            modelBusyMessage = nil
            statusMenu?.updateHealthIndicator()
            err("\(red)could not install \(spec.name):\(reset) \(error.localizedDescription)")
        }
    })
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
    menu.currentModelID = { currentModelSpec?.id ?? "" }
    menu.modelBusy = { modelBusyMessage }
    menu.onSelectModel = { applyModel($0) }
    menu.statusLine = {
        if let busy = modelBusyMessage { return (busy, true) }
        if !renderer.audioHealthy { return ("No audio reaching Subtitles", false) }
        if isPaused { return ("Paused", true) }
        // RTF over ~0.8 means the pipeline is close to falling behind for good
        // (PLAN.md §8a Finding 2), so surface it rather than burying it in a log.
        return (String(format: "Listening · RTF %.2f", renderer.lastRTF),
                renderer.lastRTF < 0.8)
    }
    menu.onTogglePause = { togglePause() }
    menu.onResetPosition = { controller.resetPosition() }
    menu.onQuit = { shutdownCleanly() }

    menu.onFontSize = { size in
        fontSize = size
        controller.setFontSize(size)
        UserDefaults.standard.set(Double(size), forKey: Defaults.fontSize)
    }

    menu.onSelectSource = { source in
        do {
            let sameFormat = try tap.switchTo(source: source)
            if !sameFormat {
                err("\(yellow)new source reports a different audio format; restart to apply it cleanly\(reset)")
            }
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
    renderer.onStatusRefresh = { [weak menu] in menu?.updateHealthIndicator() }
    statusMenu = menu

    // ⌥⌘S. Carbon, so it needs no Accessibility permission — see Hotkey.swift.
    hotkey = Hotkey(keyCode: kVK_ANSI_S, modifiers: cmdKey | optionKey) { togglePause() }
    if hotkey == nil { err("could not register ⌥⌘S (already taken?)") }

    err("overlay on — click-through; hold ⌥ to drag it. ⌥⌘S pauses. Menu bar has settings.")
}

err("listening. ctrl-C to stop.\n")

// ── shutdown ──
let shutdown: @convention(c) (Int32) -> Void = { _ in
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    shutdownCleanly()
}
// SIGUSR1 cycles to the next installed model. Makes A/B comparison scriptable
// (`pkill -USR1 -f Subtitles.app`) and gives the menu path a testable equivalent.
let cycleModel: @convention(c) (Int32) -> Void = { _ in
    DispatchQueue.main.async {
        // Cycles the whole catalogue, not just what is installed — applyModel
        // downloads on demand, so this also exercises that path.
        let all = ModelCatalog.all
        guard all.count > 1 else { return }
        let index = all.firstIndex { $0.id == currentModelSpec?.id } ?? 0
        applyModel(all[(index + 1) % all.count])
    }
}
signal(SIGUSR1, cycleModel)
signal(SIGINT, shutdown)
signal(SIGTERM, shutdown)

// .accessory: no Dock icon, no menu bar, and critically the app never becomes
// active — combined with .nonactivatingPanel the overlay cannot steal focus.
app.setActivationPolicy(.accessory)
app.run()
