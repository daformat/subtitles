// Speaker-change detection, used only to break the subtitle page.
//
// This deliberately does not label or colour speakers. All the overlay needs is
// an edge: "someone else is talking now, start a fresh box" — the same treatment
// a pause or an endpoint already gets. That keeps the feature cheap and means a
// wrong speaker index costs a page break rather than a wrong name on screen.
//
// Diarization is inherently retrospective: Sortformer needs ~1 s of warmup and
// reports on a ~0.48 s cadence, so the change is detected a second or two
// *after* the new speaker starts. Waiting for the label instead would delay
// every subtitle by the diarizer's cadence, which is a far worse trade for a
// latency-first app. So the change is reported with the time the new speaker's
// segment began, on the same clock as the recognizer's words (both are fed the
// same slices and reset together), and the overlay moves the words they had
// already said out of the outgoing speaker's box and into theirs.
//
// The index is passed on as well, for one use: the saved transcript names
// who said each box when more than one person spoke. For the index to mean the
// same person all session, the diarizer is never reset between utterances. It
// keeps its speaker memory and its own clock, and each utterance's times are
// given from where that utterance began, on the recognizer's restarted clock.
// A session ends where the history does, cleared by the idle expiry, a saved
// transcript or a pause, and `forgetSpeakers` starts the diarizer over there.

import CoreML
import FluidAudio
import Foundation

actor SpeakerTracker {
    private let diarizer = SortformerDiarizer()
    private var loaded = false
    private var currentSpeaker: Int?

    /// Seconds of audio fed since the diarizer last really reset, and where
    /// the current utterance began among them: the recognizer's zero.
    private var fed: Float = 0
    private var origin: Float = 0

    private let onChange: @Sendable (TimeInterval) -> Void
    /// Who is talking, from `time` in the utterance's clock: the first voice
    /// heard in each utterance, and each change after it.
    private let onSpeaker: @Sendable (TimeInterval, Int) -> Void
    private let onStatus: @Sendable (String) -> Void

    /// How long a new speaker must have been talking before it counts. A
    /// cough, a laugh or a one-frame flicker between labels otherwise breaks
    /// the page, and now takes a word or two with it.
    static let minimumTurn: Float = 0.5

    /// How far back a change may reach from the newest audio. The diarizer
    /// names a change well within this; a segment that seems to start further
    /// back is a relabelling of speech long since paged, and moving words that
    /// old would rewrite boxes the reader has finished with.
    static let maximumReach: Float = 4

    private static let debug = ProcessInfo.processInfo.environment["SUBS_DEBUG_PAGING"] != nil

    /// Seconds of compute, for folding into the engine's RTF report — a second
    /// model on the ANE is not free and should be visible in the health signal.
    private(set) var computeSeconds = 0.0

    init(onChange: @escaping @Sendable (TimeInterval) -> Void,
         onSpeaker: @escaping @Sendable (TimeInterval, Int) -> Void,
         onStatus: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
        self.onSpeaker = onSpeaker
        self.onStatus = onStatus
    }

    func load() async {
        guard !loaded else { return }
        do {
            let models = try await SortformerModels.loadFromHuggingFace(config: .default)
            diarizer.initialize(models: models)
            loaded = true
        } catch {
            // Non-fatal: subtitles work fine without page breaks on speaker change.
            onStatus("speaker detection unavailable: \(error.localizedDescription)")
        }
    }

    var isLoaded: Bool { loaded }

    /// Same 16 kHz mono frames the recogniser gets.
    func feed(_ samples: [Float]) {
        guard loaded else { return }
        let started = Date()
        diarizer.addAudio(samples)
        fed += Float(samples.count) / Float(diarizer.config.sampleRate)
        do {
            guard let update = try diarizer.process() else { return }
            // The segment reaching furthest into the audio, finalized or not, so a
            // change is noticed as early as the model allows. Not the last
            // finalized one first: finalizing lags the frontier, and preferring it
            // read the outgoing speaker's older segment as a change back to them.
            let latest = (update.finalizedSegments + update.tentativeSegments)
                .max { ($0.endFrame, $0.startFrame) < ($1.endFrame, $1.startFrame) }
            // The diarizer runs behind the audio, so a segment reported now
            // may be all before this utterance: that is the last one's.
            guard let latest, latest.endTime > origin else { return }

            if let current = currentSpeaker, current != latest.speakerIndex {
                // Too short to count yet: the same segment is reported again
                // as it grows, and counts once it is long enough.
                if latest.duration >= Self.minimumTurn {
                    let heard = Float(diarizer.numFramesProcessed)
                        * diarizer.config.frameDurationSeconds
                    let time = max(latest.startTime, heard - Self.maximumReach, origin) - origin
                    if Self.debug {
                        FileHandle.standardError.write(String(
                            format: "[speaker] %d → %d, segment %.2f–%.2f s, heard %.2f s\n",
                            current, latest.speakerIndex, latest.startTime, latest.endTime, heard)
                            .data(using: .utf8)!)
                    }
                    // Who first: the boxes the change closes are told apart
                    // by which side of it they start.
                    onSpeaker(TimeInterval(time), latest.speakerIndex)
                    onChange(TimeInterval(time))
                    currentSpeaker = latest.speakerIndex
                }
            } else if currentSpeaker == nil {
                currentSpeaker = latest.speakerIndex
                onSpeaker(TimeInterval(max(latest.startTime - origin, 0)), latest.speakerIndex)
            }
        } catch {
            onStatus("speaker detection error: \(error.localizedDescription)")
        }
        computeSeconds += Date().timeIntervalSince(started)
    }

    func takeComputeSeconds() -> Double {
        let value = computeSeconds
        computeSeconds = 0
        return value
    }

    /// At an utterance boundary the next speaker is unknown again; forgetting the
    /// previous one avoids a spurious break when the same person resumes.
    ///
    /// The diarizer itself carries on, so it still knows the voices: only the
    /// clock is moved to where the recognizer's restarts.
    func reset() {
        currentSpeaker = nil
        origin = fed
    }

    /// A new session: every voice forgotten, the next one heard numbered
    /// first. The diarizer's clock restarts with it, and the utterance's
    /// clock does not, so the origin is put where the two still agree.
    func forgetSpeakers() {
        guard loaded else { return }
        let intoUtterance = fed - origin
        diarizer.reset()
        fed = 0
        origin = -intoUtterance
        currentSpeaker = nil
    }

    func shutdown() {
        diarizer.cleanup()
        loaded = false
    }
}
