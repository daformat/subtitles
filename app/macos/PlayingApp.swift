// Which app the boxes belong to, and its icon.
//
// The live box wears the icon of the app whose audio it is transcribing, and
// each box in the ⌥ stack the icon of the app it transcribed — a Zoom box over
// a Chrome box, when that is what happened. With one app chosen as the source
// the answer is that app. With all system audio it is worked out from what
// Core Audio says is playing, through the rules in PlayingAppPicker: sticky,
// and slow to hand over, because "playing" is a noisy set — browsers hold the
// audio device open with a video paused, and a notification ding holds it for
// seconds after the sound, and a music player is playing in every sense
// without the words on screen being its. Under `Rules.byEar` the picker
// also names an app worth listening to, and the monitor puts a LevelMeter
// on it for a moment, asks the voice detector whether there is a voice in
// what it heard and, when there is, has the word probe transcribe it and
// holds those words against the ones the captions showed. It reports back
// one of three things: the app is saying the words on screen, it is making
// some other sound (music, lyrics, a voice that is not the one captioned),
// or it is silent.
//
// Polled once a second rather than asked when words arrive. Words arrive many
// times a second, and the enumeration walks every process Core Audio knows
// about; once a second is plenty for something that changes when a call
// starts, and the overlay is only told when the answer changes.

import AppKit
import CaptionCore
import UniformTypeIdentifiers

// MARK: - Icons and names

/// App icons and names by the tap's family id, resolved once and kept.
///
/// Kept for good, and the icons handed out as the same instance every time.
/// The stack decides whether it has changed by comparing entries, icon
/// identity included, sixty times a second; a fresh NSImage per lookup would
/// rebuild it on every poll. A few dozen apps over a session is nothing to
/// keep.
final class AppCatalog {
    static let shared = AppCatalog()

    private var icons: [String: NSImage] = [:]
    private var names: [String: String] = [:]

    /// Always an icon: the app's, or the generic application icon when the
    /// process has gone or never had one. A box with an app and no icon would
    /// be laid out narrower than the live box it was, and the text in it would
    /// break differently.
    func icon(for family: String) -> NSImage {
        if let known = icons[family] { return known }
        let icon = Self.resolve(family) ?? NSWorkspace.shared.icon(for: .applicationBundle)
        icons[family] = icon
        return icon
    }

    /// The app's name, as the source picker would show it.
    func name(for family: String) -> String {
        if let known = names[family] { return known }
        let name = Self.resolveName(family)
        names[family] = name
        return name
    }

    private static func resolveName(_ family: String) -> String {
        if family == AudioSource.microphoneID { return AudioSource.microphone.displayName }
        if family.hasPrefix("pid:") {
            guard let pid = pid_t(family.dropFirst(4)) else { return family }
            return NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        }
        if let name = NSRunningApplication.runningApplications(withBundleIdentifier: family)
            .first?.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: family) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return family.split(separator: ".").last.map(String.init) ?? family
    }

    /// The family ids are SystemAudioTap's: a bundle id, `pid:N` for an
    /// unbundled process, or the microphone's own.
    private static func resolve(_ family: String) -> NSImage? {
        if family == AudioSource.microphoneID { return microphoneIcon() }
        if family.hasPrefix("pid:") {
            guard let pid = pid_t(family.dropFirst(4)) else { return nil }
            return NSRunningApplication(processIdentifier: pid)?.icon
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: family).first,
           let icon = running.icon {
            return icon
        }
        // Not running any more, or a helper with no running-application entry
        // of its own: the bundle on disk still has the icon.
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: family) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    /// The microphone's stand-in for an app icon: a white mic on a red rounded
    /// square, drawn on the app-icon grid — the square inset the way an app's
    /// is on its canvas — so it sits in a row of real icons at their size. The
    /// red is the system's, the one the microphone button wears in dictation
    /// and Siri (#FF453A), fixed rather than `.systemRed` so the tile is the
    /// same colour whichever appearance the box is drawn in.
    private static func microphoneIcon() -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { canvas in
            let tile = canvas.insetBy(dx: canvas.width * 0.1, dy: canvas.height * 0.1)
            NSColor(srgbRed: 1.0, green: 0.271, blue: 0.227, alpha: 1).setFill()
            NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.height * 0.22)
                .fill()
            let configuration = NSImage.SymbolConfiguration(pointSize: tile.height * 0.55,
                                                            weight: .medium)
                .applying(.init(paletteColors: [.white]))
            guard let glyph = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { return true }
            let size = glyph.size
            glyph.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2,
                                  width: size.width, height: size.height))
            return true
        }
    }
}

// MARK: - Monitor

/// Polls what is playing and reports which app the boxes belong to.
final class PlayingAppMonitor {
    /// The tap's source, read on every poll.
    var source: () -> AudioSource = { .allSystemAudio }
    /// Paused, the tap is down and nothing is being transcribed; the last
    /// answer stands for whatever is still on screen.
    var isPaused: () -> Bool = { false }
    /// The answer changed: an app's family id, or nil while nothing is known.
    var onChange: (String?) -> Void = { _ in }
    /// The engine's voice detector, asked whether the sound a listen heard
    /// has a voice in it. Nil with Skip non-speech off, and not loaded yet
    /// while the models are; either way sound is taken for a voice, as it
    /// was before the detector had a say. No answer is not a verdict.
    var voice: () -> VoiceDetector? = { nil }
    /// The engine's word probe, which transcribes a listen on its own so its
    /// words can be held against the ones on screen. Nil under a model
    /// without one, and until the model is loaded; then a voice is taken for
    /// the words' source, as it was before the probe had a say.
    var probe: () async -> WordProbe? = { nil }
    /// Whether the source has gone quiet, by Core Audio's account, on every
    /// poll: nothing playing under all system audio, the chosen app not
    /// playing. Nil for the microphone, which Core Audio says nothing about.
    /// An app's own word for it, so a browser holds its output open for ten
    /// seconds past a pause and is quiet only then.
    var onSilence: (Bool?) -> Void = { _ in }

    private(set) var app: String?
    private var picker: PlayingAppPicker
    private var lastSource: AudioSource?
    private var timer: Timer?

    /// The enumeration is a round trip to coreaudiod for the process list,
    /// several milliseconds, so it runs off the main thread: once a second on
    /// it would cost the cursor reveal a frame each time. Both halves are safe
    /// there — Core Audio's property reads and NSWorkspace's application list
    /// — and the pick itself is only ever touched on main.
    private let queue = DispatchQueue(label: "dev.mat.subtitles.playing-app", qos: .utility)
    private var inFlight = false

    /// The meter listening right now, if any, and how long a listen lasts.
    /// Three seconds is enough speech to be sure of, and short enough that a
    /// call is labeled while its first sentence is still on screen.
    private var meter: LevelMeter?
    private let listenFor: TimeInterval = 3
    /// The app a listen is about, from the meter going on to the verdict:
    /// longer than the meter is on, since the words of a listen are held
    /// against the captions only once they have had time to reach the
    /// screen, and a second listen in that gap would be about the same app.
    private var listening: String?
    /// Apps a meter could not be put on, and when: tried again after a while
    /// rather than on every poll.
    private var unlistenable: [String: TimeInterval] = [:]
    /// Apps whose last listen heard a voice saying too few words to place.
    /// Listened to again at once, since a call opens on "hi, can you hear
    /// me"; a second such listen is sound until the recheck.
    private var inconclusive: Set<String> = []

    /// What the captions showed, as it arrived: the running transcript at
    /// each update, stamped, kept for as long as a listen looks back.
    private var shown: [(at: TimeInterval, words: [TimedWord])] = []
    private static let shownFor: TimeInterval = 30

    init(rules: PlayingAppPicker.Rules) {
        picker = PlayingAppPicker(rules: rules)
    }

    /// Monotonic, so a clock change cannot age an app by an hour.
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Start polling. The timer holds the monitor, so a caller need not: it
    /// lives for as long as the app does, like the tap it watches.
    func start() {
        let timer = Timer(timeInterval: 1, repeats: true) { [self] _ in poll() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    /// The captions' running transcript, each time it changes. On main.
    func noteWords(_ words: [TimedWord]) {
        guard !words.isEmpty else { return }
        let now = now
        shown.append((now, words))
        shown.removeAll { now - $0.at > Self.shownFor }
    }

    /// The words on screen from `since` on. The running transcript is
    /// cumulative within an utterance and can reach back a paragraph, so
    /// each update contributes only its last stretch, the words spoken in
    /// the seconds before it.
    private func wordsShown(since: TimeInterval) -> [String] {
        var out: [String] = []
        for update in shown where update.at >= since {
            guard let last = update.words.last else { continue }
            out.append(contentsOf: update.words
                .filter { last.end - $0.end <= Self.wordsReach }
                .map(\.text))
        }
        return out
    }
    private static let wordsReach: TimeInterval = 10

    func poll() {
        let source = source()
        // What was playing under the old source says nothing about the new.
        if source != lastSource {
            picker.reset()
            inconclusive = []
            lastSource = source
        }
        guard !isPaused() else { return }

        switch source {
        case let .app(id, _):
            deliver(id, why: "the source")
            queue.async { [self] in
                let playing = SystemAudioTap.audioSources().contains { $0.id == id && $0.isPlaying }
                DispatchQueue.main.async { [self] in
                    guard lastSource == source else { return }
                    onSilence(!playing)
                }
            }
        case .microphone:
            deliver(AudioSource.microphoneID, why: "the source")
            onSilence(nil)
        case .allSystemAudio:
            // A poll still on its way is left to finish; the next is a second off.
            guard !inFlight else { return }
            inFlight = true
            queue.async { [self] in
                let playing = SystemAudioTap.audioSources().filter(\.isPlaying).map(\.id)
                DispatchQueue.main.async { [self] in
                    inFlight = false
                    // The source or the pause may have changed underneath, and
                    // an answer about all system audio says nothing about an app.
                    guard lastSource == .allSystemAudio, !isPaused() else { return }
                    onSilence(playing.isEmpty)
                    let previous = picker.pick
                    let next = picker.update(playing: playing, at: now)
                    inconclusive = inconclusive.filter { picker.age(of: $0) != nil }
                    deliver(next, why: reason(previous: previous))
                    listenIfDue()
                }
            }
        }
    }

    /// Put a meter on whichever app the picker wants heard, if none is on.
    private func listenIfDue() {
        guard listening == nil, let app = picker.candidate() else { return }
        if let failedAt = unlistenable[app], now - failedAt < picker.rules.recheck { return }
        let name = name(app)
        let meter: LevelMeter
        do {
            meter = try LevelMeter(family: app, seconds: listenFor)
        } catch {
            log("listen to \(name): \(error)")
            unlistenable[app] = now
            return
        }
        self.meter = meter
        listening = app
        unlistenable[app] = nil
        let started = now
        DispatchQueue.main.asyncAfter(deadline: .now() + listenFor) { [self] in
            let reading = meter.stop()
            self.meter = nil
            let ended = now
            guard let fraction = reading.loudFraction else {
                log("listened to \(name) for \(seconds(listenFor)): no audio delivered")
                unlistenable[app] = now
                listening = nil
                return
            }
            let level = String(format: "%.0f%% of blocks above the floor", fraction * 100)
            guard fraction >= Self.sustainedFraction else {
                conclude(app, name, .silence, detail: level, verdict: "silence",
                         why: "\(name) heard to be silent")
                return
            }
            // Sustained sound. Whether there is a voice in it, and whose
            // words it is saying, are the detector's and the probe's calls,
            // made off the main thread; the verdict lands back here, and the
            // picker ignores it if the app has stopped meanwhile.
            let detector = voice()
            let probe = probe
            Task { [self] in
                let ear = await self.hear(reading.samples, detector: detector, probe: probe)
                // The captions run a second or two behind the audio: the
                // words of the listen are given time to reach the screen
                // before the two are held against each other.
                if case .voice(_, .some) = ear {
                    let wait = ended + Self.captionLag - self.now
                    if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                }
                DispatchQueue.main.async { [self] in
                    judge(app, name, ear, level: level, listenedFrom: started)
                }
            }
        }
    }

    /// What the detector and the probe make of a listen's sound.
    private enum Ear {
        /// No detector to ask.
        case noDetector
        /// A voice, this share of the listen, and the words the probe heard
        /// in it: nil with no probe to ask, or a probe that failed.
        case voice(Double, words: [String]?)
        /// Sound with no voice in it, or not enough of one.
        case noVoice(Double)
    }

    private func hear(_ samples: [Float], detector: VoiceDetector?,
                      probe: () async -> WordProbe?) async -> Ear {
        guard let speech = await detector?.speechFraction(in: samples) else { return .noDetector }
        guard speech >= Self.speechFraction else { return .noVoice(speech) }
        guard let probe = await probe() else { return .voice(speech, words: nil) }
        return .voice(speech, words: await probe.words(in: samples))
    }

    /// The verdict on a listen, on main.
    private func judge(_ app: String, _ name: String, _ ear: Ear, level: String,
                       listenedFrom started: TimeInterval) {
        switch ear {
        case .noDetector:
            conclude(app, name, .speech, detail: "\(level), no voice detection to ask",
                     verdict: "speech", why: "heard speaking")
        case let .noVoice(speech):
            conclude(app, name, .sound, detail: "\(level), \(percent(speech)) of it a voice",
                     verdict: "sound, no voice", why: "\(name) heard playing sound, no voice")
        case let .voice(speech, nil):
            conclude(app, name, .speech, detail: "\(level), \(percent(speech)) of it a voice",
                     verdict: "speech", why: "heard speaking")
        case let .voice(speech, .some(heard)):
            let quoted = "\"" + heard.joined(separator: " ") + "\""
            let detail = "\(level), \(percent(speech)) of it a voice, heard \(quoted)"
            let screen = wordsShown(since: started - Self.wordsBefore)
            guard let match = TranscriptMatch.compare(heard: heard, shown: screen) else {
                // Too few words to place, or nothing on screen to place them
                // against. Once more right away, since a call opens on a few
                // words and the captions may be a moment behind; a second
                // time it is sound until the recheck.
                let why = TranscriptMatch.words(screen).isEmpty
                    ? "nothing on screen to place them against" : "too few words to place"
                if inconclusive.insert(app).inserted {
                    log("listened to \(name) for \(seconds(listenFor)): \(detail), "
                        + "\(why), listening again")
                    listening = nil
                    return
                }
                conclude(app, name, .sound, detail: "\(detail), \(why)",
                         verdict: "sound", why: "\(name) heard, \(why)")
                return
            }
            let placed = "\(match.matched) of \(match.total) words on screen"
            if match.share >= Self.wordsFraction {
                conclude(app, name, .speech, detail: "\(detail), \(placed)",
                         verdict: "speech", why: "heard saying the words on screen")
            } else {
                conclude(app, name, .sound, detail: "\(detail), \(placed)",
                         verdict: "sound, other words", why: "\(name) heard, not the words on screen")
            }
        }
    }

    private func conclude(_ app: String, _ name: String, _ heard: PlayingAppPicker.Heard,
                          detail: String, verdict: String, why: String) {
        inconclusive.remove(app)
        listening = nil
        log("listened to \(name) for \(seconds(listenFor)): \(detail) → \(verdict)")
        // A verdict that lands after the source has changed is about a
        // picker that has since been reset: nothing to judge, and no answer
        // to give.
        guard lastSource == .allSystemAudio else { return }
        deliver(picker.judge(app, heard: heard, at: now), why: why)
    }

    /// Share of ~10 ms blocks above the floor that counts as sound. Speech with
    /// its pauses runs well above half; a ding in a three-second window, or a
    /// stream held open playing zeros, nowhere near.
    static let sustainedFraction = 0.3

    /// Share of the detector's 256 ms chunks that must be a voice, at the
    /// detector's surer bar (`VoiceDetector.sureVoice`), for sound to count
    /// as a voice: half of a three-second listen. Measured 2026-09-21: speech
    /// scored 73% (rap, between its beats) to 100% of a listen, instrumental
    /// music 0% at that bar and never more than 27% at the gate's looser
    /// one. A listen that lands on a pause in a call falls short and is
    /// tried again after the recheck; music that fools the model on half a
    /// listen would go on to the probe, which is the costlier mistake.
    static let speechFraction = 0.5

    /// Share of a listen's content words that must be on screen for the
    /// words to be that app's. Two runs of the same recognizer over the same
    /// speech, one on the app's own feed and one on the mix, agree on most
    /// of it; lyrics under a call share the odd word with it and no more.
    static let wordsFraction = 0.5
    /// How far behind the audio the captions run, at most, before the words
    /// of a listen are looked for on screen.
    static let captionLag: TimeInterval = 2.5
    /// How far before the listen the screen is read from, since the words of
    /// its first moments reach the screen while it runs.
    static let wordsBefore: TimeInterval = 2

    private func deliver(_ next: String?, why: String) {
        guard next != app else { return }
        let was = app.map(name) ?? "nothing"
        app = next
        log("playing app: \(was) → \(next.map(name) ?? "nothing") (\(why))")
        onChange(next)
    }

    /// Why a poll changed the pick, for the log. Worked out before it is known
    /// whether anything changed, which is cheap: three dictionary lookups.
    private func reason(previous: String?) -> String {
        guard let previous else { return "first seen" }
        if picker.age(of: previous) == nil { return "\(name(previous)) stopped" }
        if let next = picker.pick, let age = picker.age(of: next) {
            return "took over after \(seconds(age))"
        }
        return "changed"
    }

    private func name(_ family: String) -> String {
        AppCatalog.shared.name(for: family)
    }

    /// Stamped, unlike the rest of the log: these lines are read against a
    /// clock — when the ding was, when the call started — or not at all.
    private func log(_ line: String) {
        err("\(Self.clock.string(from: Date())) \(line)")
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func seconds(_ t: TimeInterval) -> String {
        String(format: "%.1fs", t)
    }

    private func percent(_ share: Double) -> String {
        String(format: "%.0f%%", share * 100)
    }
}
