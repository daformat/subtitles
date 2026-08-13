// Speaker-change detection, used only to break the subtitle page.
//
// This deliberately does not label or colour speakers. All the overlay needs is
// an edge: "someone else is talking now, start a fresh box" — the same treatment
// a pause or an endpoint already gets. That keeps the feature cheap and means a
// wrong speaker index costs a page break rather than a wrong name on screen.
//
// Diarization is inherently retrospective: Sortformer needs ~1 s of warmup and
// reports on a ~0.48 s cadence, so the change is detected slightly *after* the
// new speaker starts. A word or two of theirs can therefore land on the outgoing
// page before it clears. Waiting for the label instead would delay every subtitle
// by the diarizer's cadence, which is a far worse trade for a latency-first app.

import CoreML
import FluidAudio
import Foundation

actor SpeakerTracker {
    private let diarizer = SortformerDiarizer()
    private var loaded = false
    private var currentSpeaker: Int?

    private let onChange: @Sendable () -> Void
    private let onStatus: @Sendable (String) -> Void

    /// Seconds of compute, for folding into the engine's RTF report — a second
    /// model on the ANE is not free and should be visible in the health signal.
    private(set) var computeSeconds = 0.0

    init(onChange: @escaping @Sendable () -> Void,
         onStatus: @escaping @Sendable (String) -> Void) {
        self.onChange = onChange
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
        do {
            guard let update = try diarizer.process() else { return }
            // Prefer a finalized segment; fall back to the tentative frontier so a
            // change is noticed as early as the model allows.
            let latest = update.finalizedSegments.last ?? update.tentativeSegments.last
            guard let latest else { return }

            if let current = currentSpeaker, current != latest.speakerIndex {
                onChange()
            }
            currentSpeaker = latest.speakerIndex
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
    func reset() {
        currentSpeaker = nil
        diarizer.reset()
    }

    func shutdown() {
        diarizer.cleanup()
        loaded = false
    }
}
