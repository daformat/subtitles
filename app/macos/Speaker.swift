// Reads the translation aloud, for someone who cannot read the box.
//
// ── Why the app speaks rather than VoiceOver ──
//
// VoiceOver can be asked to announce text, and it would read it in the
// listener's own voice. But it only does so while it is running, it says
// nothing about when an announcement has finished, and its own speech cuts
// in over it. Lowering the original while the translation is read needs to
// know exactly when speech starts and stops, which only a synthesizer of our
// own reports; and a voice per target language reads French as French,
// where an English VoiceOver voice would read it with an English accent.
//
// So the app speaks, through AVSpeechSynthesizer, whose audio plays from
// this process (measured: the process's own audio object runs output while
// it speaks, no daemon does). That is why the all-audio tap excludes the app
// itself: otherwise the recognizer would hear the translation and transcribe
// it, and the ducked replay would feed on its own output.
//
// ── What is read ──
//
// Each settled chunk of the translation, once, as it lands: never the dimmed
// tail, which is rewritten while the speaker is still talking. Nothing
// translated back the other way with both languages showing, since the
// original is then already in the listener's language. Nothing skipped and
// nothing hurried: see `SpeechQueue`.

import AppKit
import AVFoundation
import CaptionCore

/// Main thread only, like the rest of main.swift's objects; not `@MainActor`,
/// since main.swift's top level, which drives it, is not isolated either.
final class Speaker: NSObject {
    enum Mode: String, CaseIterable {
        case off
        /// The default: someone running VoiceOver hears the translation without
        /// having to find a setting first, and nobody else is surprised by a voice.
        case withVoiceOver
        case always

        var displayName: String {
            switch self {
            case .off: return L("speech|Off", "Speak Translation choice: the translation is not read aloud")
            case .withVoiceOver: return L("When VoiceOver Is On", "Speak Translation choice: the translation is read aloud only while VoiceOver is running")
            case .always: return L("Always", "Speak Translation choice: the translation is always read aloud")
            }
        }
    }

    /// How loud the original stays while the translation is read. About
    /// -12 dB: still there to follow, no longer competing with the voice.
    static let duckedGain: Float = 0.25

    var mode: Mode = .withVoiceOver {
        didSet { if mode != oldValue { refresh() } }
    }
    /// Lower the original while speaking. What makes it possible, a tap that
    /// mutes the source and plays it back, is main.swift's to set up.
    var lowersOriginal = true {
        didSet { if lowersOriginal != oldValue { onStateChanged?() } }
    }
    /// Hold what is to be read until nobody has been heard for `quietAfter`.
    /// For a microphone with the sound on loudspeakers: voice processing
    /// keeps the voice out of the captions (SystemAudioTap.cancelsEcho), but
    /// in the room it still talks over whoever is being captioned, so it
    /// waits for a pause. Someone who starts again while it reads is still
    /// captioned.
    var waitsForQuiet = false {
        didSet { if waitsForQuiet != oldValue, current == nil { speakNext() } }
    }
    /// About the pause between two people's turns: longer than the breath
    /// inside a sentence, short enough to answer in.
    static let quietAfter: TimeInterval = 1.2
    /// The language the voice reads, the translation's target.
    /// nil with translation off, when there is nothing to read.
    var language: Locale.Language? {
        didSet {
            guard language != oldValue else { return }
            voice = nil
            stop()
            if (language == nil) != (oldValue == nil) { onStateChanged?() }
        }
    }

    /// Speaking is on: the mode says so, VoiceOver is running if it has to
    /// be, and the source allows it.
    private(set) var isActive = false
    /// Whether the original should be lowered and played back by the app:
    /// only with something to read over it. With translation off the source
    /// is left to play as it always has.
    var wantsDucking: Bool { isActive && lowersOriginal && language != nil }

    /// Told when `isActive`, `wantsDucking` or VoiceOver's state may have
    /// changed: main.swift rebuilds the tap, whose exclusions and mute
    /// depend on all three.
    var onStateChanged: (() -> Void)?
    /// True while an utterance is being read, false once nothing is left:
    /// the original goes down and comes back up with it.
    var onSpeaking: ((Bool) -> Void)?
    /// True while any voice of the app's is sounding, the translation's or a
    /// line of the app's own: the echo gate shuts the microphone for it.
    var onVoice: ((Bool) -> Void)?
    private var announcing = false
    private var voiceSounding = false
    private func syncVoice() {
        let now = current != nil || announcing
        guard now != voiceSounding else { return }
        voiceSounding = now
        onVoice?(now)
    }

    private let synthesizer = AVSpeechSynthesizer()
    /// A second voice for the app's own lines, so one never cuts the
    /// translation's queue short or waits behind it.
    private let announcer = AVSpeechSynthesizer()
    private var queue = SpeechQueue()
    private var voice: AVSpeechSynthesisVoice?
    private var current: AVSpeechUtterance?
    private var lastSpoken: String?
    /// When a new word was last recognized, and the audio time it ended at,
    /// to tell new words from the recognizer resending the ones it has.
    private var lastHeard = Date.distantPast
    private var lastHeardEnd: TimeInterval = -1
    private var quietTimer: Timer?
    private var voiceOverObservation: NSKeyValueObservation?
    private(set) var voiceOverRunning = NSWorkspace.shared.isVoiceOverEnabled

    override init() {
        super.init()
        synthesizer.delegate = self
        announcer.delegate = self
        voiceOverObservation = NSWorkspace.shared.observe(\.isVoiceOverEnabled) { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                let running = NSWorkspace.shared.isVoiceOverEnabled
                guard running != self.voiceOverRunning else { return }
                self.voiceOverRunning = running
                err("VoiceOver \(running ? "on" : "off")")
                self.refresh(force: true)
            }
        }
        refresh()
    }

    private func refresh(force: Bool = false) {
        let active: Bool
        switch mode {
        case .off: active = false
        case .withVoiceOver: active = voiceOverRunning
        case .always: active = true
        }
        let changed = active != isActive
        isActive = active
        if !active { stop() }
        if changed { err(active ? "reading the translation aloud" : "not reading the translation aloud") }
        if changed || force { onStateChanged?() }
    }

    /// A line of the app's own, the offer to save the transcript or the
    /// trial's end, said at once for someone running VoiceOver, whatever the
    /// Speak Translation setting. In VoiceOver's voice and at its rate, in
    /// the app's language: VoiceOver itself only reads announcements from
    /// the app in front, and a menu bar app never is.
    func announce(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.prefersAssistiveTechnologySettings = true
        utterance.voice = AVSpeechSynthesisVoice(language: Localization.language)
        announcer.stopSpeaking(at: .immediate)
        // Before it sounds: the gate shuts ahead of the voice, not after.
        announcing = true
        syncVoice()
        announcer.speak(utterance)
        err("said: \(text)")
    }

    /// The transcript as recognized, on every update: new words mean someone
    /// is talking. See `waitsForQuiet`.
    func noteWords(_ words: [TimedWord]) {
        guard let end = words.last?.end, end != lastHeardEnd else { return }
        lastHeardEnd = end
        lastHeard = Date()
    }

    /// Read `text` aloud, after whatever is being read now.
    func say(_ text: String) {
        guard isActive else { return }
        queue.add(text)
        if current == nil { speakNext() }
    }

    /// Stop reading and forget what was waiting. The last line stays for
    /// `repeatLast`.
    func stop() {
        queue.clear()
        guard current != nil else { return }
        current = nil
        synthesizer.stopSpeaking(at: .immediate)
        onSpeaking?(false)
        syncVoice()
    }

    /// The hotkey: silence while reading, the last line again while not.
    func stopOrRepeat() {
        guard isActive else { return }
        if current != nil {
            stop()
        } else if let lastSpoken {
            queue.add(lastSpoken)
            speakNext()
        }
    }

    private func speakNext() {
        // Waiting for the room: try again once it has been quiet long enough,
        // measured afresh then, since someone may have spoken in the meantime.
        // Only before a first utterance; once reading, what piled up follows
        // on, since the microphone is silenced for the voice anyway.
        if current == nil, waitsForQuiet, !queue.pending.isEmpty {
            let wait = lastHeard.addingTimeInterval(Self.quietAfter).timeIntervalSinceNow
            if wait > 0 {
                quietTimer?.invalidate()
                quietTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
                    self?.speakNext()
                }
                return
            }
        }
        guard let text = queue.next() else {
            if current != nil {
                current = nil
                onSpeaking?(false)
                syncVoice()
            }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = resolvedVoice()
        if current == nil { onSpeaking?(true) }
        current = utterance
        syncVoice()
        lastSpoken = text
        synthesizer.speak(utterance)
    }

    /// The best installed voice for the target language: its own region
    /// first when the target names one (pt-BR, not pt-PT), then the best
    /// quality. nil leaves it to the system, which reads in its own language.
    private func resolvedVoice() -> AVSpeechSynthesisVoice? {
        if let voice { return voice }
        guard let language, let code = language.languageCode?.identifier else { return nil }
        var region = language.region?.identifier
        // A script says which country's voice to want: Simplified is the
        // mainland's, Traditional Taiwan's.
        if region == nil, code == "zh" {
            region = language.script?.identifier == "Hant" ? "TW" : "CN"
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter {
            Locale.Language(identifier: $0.language).languageCode?.identifier == code
        }
        let best = candidates.max { a, b in
            let ar = region != nil && Locale.Language(identifier: a.language).region?.identifier == region
            let br = region != nil && Locale.Language(identifier: b.language).region?.identifier == region
            if ar != br { return !ar }
            return a.quality.rawValue < b.quality.rawValue
        }
        voice = best ?? AVSpeechSynthesisVoice(language: language.minimalIdentifier)
        if let voice { err("speaking with \(voice.name) (\(voice.language))") }
        return voice
    }
}

extension Speaker: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didFinish utterance: AVSpeechUtterance) {
        if synthesizer === announcer { return announcerStopped() }
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.finished(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                                       didCancel utterance: AVSpeechUtterance) {
        if synthesizer === announcer { return announcerStopped() }
        let id = ObjectIdentifier(utterance)
        DispatchQueue.main.async { self.finished(id) }
    }

    /// A line of the app's own ended. Checked against the synthesizer, not
    /// taken as said: a new line cancels the one before, whose callback lands
    /// after the new one has started.
    private func announcerStopped() {
        DispatchQueue.main.async {
            guard !self.announcer.isSpeaking else { return }
            self.announcing = false
            self.syncVoice()
        }
    }

    /// Only the utterance still current moves the queue on: a cancelled one's
    /// callback lands after `stop()` has already let go of it.
    private func finished(_ utterance: ObjectIdentifier) {
        guard let current, ObjectIdentifier(current) == utterance else { return }
        speakNext()
    }
}
