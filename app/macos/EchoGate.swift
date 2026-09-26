// Keeps VoiceOver, and the app's own voice, out of a microphone's captions,
// when voice processing cannot: the fallback to SystemAudioTap.cancelsEcho,
// which takes them out of the microphone and leaves the room captioned.
// This silences the room with them.
//
// A process tap can leave VoiceOver out of the Mac's audio, but a microphone
// hears the room, and VoiceOver through the loudspeakers is in the room. So
// while the microphone is the source and nothing but headphones would keep
// them apart, the recognizer gets silence in place of what the microphone
// heard whenever something the app knows of is speaking, and for half a
// second after: VoiceOver, heard through a tap on its process, and the app's
// own voice, which the app knows without listening.
//
// Not a tap on the app's own process. With one running, the app's next
// microphone start never returns (measured 26 Sept 2026: AudioDeviceStart
// on the main thread, and coreaudiod times the IO thread out after 15 s),
// which froze the menu. For the same reason the VoiceOver tap is taken down
// before the microphone is started and put back once it runs: a tap made
// after the microphone was measured fine.
//
// Silence rather than nothing: the recognizer's clock runs on the samples it
// is given, and a gap in them would join the words either side of it.
// Whoever speaks over the voice is lost for that time. With headphones on
// there is nothing to keep out, and the gate stays down.

import CoreAudio
import Darwin

final class EchoGate {
    /// How long after the last loud block the gate stays shut: the voice's
    /// tail in the room, and the microphone's buffer behind the tap's.
    static let hangover: Double = 0.5
    /// About -50 dBFS: VoiceOver's quietest syllable is well above it.
    static let floor: Float = 0.003

    /// `mach_absolute_time` of the last loud block, or of the app's voice
    /// stopping. Written on the VoiceOver tap's realtime thread and the main
    /// thread, read on the microphone's: a plain word, as `isPaused` is.
    private var lastLoud: UInt64 = 0
    /// The app's own voice is speaking now.
    private var appSpeaking = false
    /// The gate applies at all, for the realtime side, which must not touch
    /// `tap` itself: loading a class reference retains it.
    private var enabled = false
    private let hangoverTicks: UInt64
    private var tap: SystemAudioTap?
    private var listeningTo: [AudioObjectID] = []
    /// Zeros to hand the recognizer in place of the microphone's samples.
    private let silence = UnsafeMutablePointer<Float>.allocate(capacity: 4096)

    init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        hangoverTicks = UInt64(Self.hangover * 1e9) * UInt64(timebase.denom) / UInt64(timebase.numer)
        silence.initialize(repeating: 0, count: 4096)
    }

    /// Gate the microphone or not, listening to VoiceOver's `objectIDs`
    /// (empty until VoiceOver has spoken, or with it off). The tap is made
    /// again only when that list changes, so calling this on every event is
    /// cheap. Only while the microphone is already running: see the header.
    func set(enabled: Bool, voiceOver objectIDs: [AudioObjectID]) {
        if enabled != self.enabled {
            err(enabled ? "echo gate on: the microphone is silenced while VoiceOver or Subtitles speaks"
                        : "echo gate off")
        }
        self.enabled = enabled
        let wanted = enabled ? objectIDs.sorted() : []
        guard wanted != listeningTo || (!wanted.isEmpty && tap?.isRunning != true) else { return }
        suspend()
        listeningTo = wanted
        guard !wanted.isEmpty else { return }
        let gate = SystemAudioTap { [unowned self] samples, count in
            var peak: Float = 0
            for i in 0..<count { peak = max(peak, abs(samples[i])) }
            if peak > Self.floor { self.lastLoud = mach_absolute_time() }
        }
        do {
            try gate.prepare(processes: wanted)
            try gate.start()
            tap = gate
        } catch {
            listeningTo = []
            err("echo gate could not listen to VoiceOver: \(error)")
        }
    }

    /// Take the VoiceOver tap down, before the microphone is started. The
    /// next `set` puts it back.
    func suspend() {
        tap?.stop()
        tap = nil
        listeningTo = []
    }

    /// The app's own voice started or stopped. Stopping leaves the hangover
    /// to run, for the voice's tail in the room.
    func appIsSpeaking(_ speaking: Bool) {
        appSpeaking = speaking
        if !speaking { lastLoud = mach_absolute_time() }
    }

    /// Whether the microphone's samples should be withheld now. Realtime.
    var isShut: Bool {
        guard enabled else { return false }
        if appSpeaking { return true }
        return lastLoud != 0 && mach_absolute_time() &- lastLoud < hangoverTicks
    }

    /// `count` zeros, handed to `push` in pieces it can take. Realtime.
    func pushSilence(_ count: Int, _ push: (UnsafePointer<Float>, Int) -> Void) {
        var left = count
        while left > 0 {
            let n = min(left, 4096)
            push(silence, n)
            left -= n
        }
    }
}
