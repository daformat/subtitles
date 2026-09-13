// Which app the boxes belong to, and its icon.
//
// The live box wears the icon of the app whose audio it is transcribing, and
// each box in the ⌥ stack the icon of the app it transcribed — a Zoom box over
// a Chrome box, when that is what happened. With one app chosen as the source
// the answer is that app. With all system audio it is worked out from what
// Core Audio says is playing, through the rules in PlayingAppPicker: sticky,
// and slow to hand over, because "playing" is a noisy set — browsers hold the
// audio device open with a video paused, and a notification sound is an app
// playing for half a second.
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

    /// The family ids are SystemAudioTap's: a bundle id, or `pid:N` for an
    /// unbundled process.
    private static func resolve(_ family: String) -> NSImage? {
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
    private var picker = PlayingAppPicker()
    private var lastSource: AudioSource?
    private var timer: Timer?

    /// The enumeration is a round trip to coreaudiod for the process list,
    /// several milliseconds, so it runs off the main thread: once a second on
    /// it would cost the cursor reveal a frame each time. Both halves are safe
    /// there — Core Audio's property reads and NSWorkspace's application list
    /// — and the pick itself is only ever touched on main.
    private let queue = DispatchQueue(label: "dev.mat.subtitles.playing-app", qos: .utility)
    private var inFlight = false

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
            deliver(id)
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
                    deliver(picker.update(playing: playing))
                }
            }
        }
    }

    private func deliver(_ next: String?) {
        guard next != app else { return }
        app = next
        onChange(next)
    }
}
