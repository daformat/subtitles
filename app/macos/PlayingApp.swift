// Which app the boxes belong to, and its icon.
//
// The live box wears the icon of the app whose audio it is transcribing, and
// each box in the ⌥ stack the icon of the app it transcribed — a Zoom box over
// a Chrome box, when that is what happened. With one app chosen as the source
// the answer is that app. With all system audio it is worked out from what
// Core Audio says is playing, through the rules in PlayingAppPicker: sticky,
// and slow to hand over, because "playing" is a noisy set — browsers hold the
// audio device open with a video paused, and a notification ding holds it for
// seconds after the sound. Under `Rules.byEar` the picker also names an app
// worth listening to, and the monitor puts a LevelMeter on it for a moment
// and reports back whether it was really making sound.
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
        if family == AudioSource.microphoneID { return AudioSource.microphone.label }
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
    /// call is labelled while its first sentence is still on screen.
    private var meter: LevelMeter?
    private let listenFor: TimeInterval = 3
    /// Apps a meter could not be put on, and when: tried again after a while
    /// rather than on every poll.
    private var unlistenable: [String: TimeInterval] = [:]

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

    func poll() {
        let source = source()
        // What was playing under the old source says nothing about the new.
        if source != lastSource {
            picker.reset()
            lastSource = source
        }
        guard !isPaused() else { return }

        switch source {
        case let .app(id, _):
            deliver(id, why: "the source")
        case .microphone:
            deliver(AudioSource.microphoneID, why: "the source")
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
                    let previous = picker.pick
                    let next = picker.update(playing: playing, at: now)
                    deliver(next, why: reason(previous: previous))
                    listenIfDue()
                }
            }
        }
    }

    /// Put a meter on whichever app the picker wants heard, if none is on.
    private func listenIfDue() {
        guard meter == nil, let app = picker.candidate() else { return }
        if let failedAt = unlistenable[app], now - failedAt < picker.rules.recheck { return }
        let name = name(app)
        let meter: LevelMeter
        do {
            meter = try LevelMeter(family: app)
        } catch {
            log("listen to \(name): \(error)")
            unlistenable[app] = now
            return
        }
        self.meter = meter
        unlistenable[app] = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + listenFor) { [self] in
            let reading = meter.stop()
            self.meter = nil
            guard let fraction = reading.loudFraction else {
                log("listened to \(name) for \(seconds(listenFor)): no audio delivered")
                unlistenable[app] = now
                return
            }
            let sustained = fraction >= Self.sustainedFraction
            log(String(format: "listened to %@ for %@: %.0f%% of blocks above the floor → %@",
                       name, seconds(listenFor), fraction * 100, sustained ? "sound" : "silence"))
            deliver(picker.judge(app, sustained: sustained, at: now),
                    why: sustained ? "heard" : "\(name) heard to be silent")
        }
    }

    /// Share of ~10 ms blocks above the floor that counts as sound. Speech with
    /// its pauses runs well above half; a ding in a three-second window, or a
    /// stream held open playing zeros, nowhere near.
    static let sustainedFraction = 0.3

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
}
