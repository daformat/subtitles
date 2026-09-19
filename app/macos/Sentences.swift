// Turning a growing transcript into translatable units.
//
// ── Why the box is the wrong unit ──
//
// The overlay pages by geometry: `showWords` fills to `maxLines` and then breaks
// wherever the text happened to spill, which is routinely mid-sentence. Feeding
// those pages to a translator one at a time is the obvious wiring and it is
// wrong twice over.
//
// It is wrong for quality, because half a sentence translates as half a
// sentence. "I gave the book to my sister" cut after "I gave the book" loses the
// dative in German, the gender agreement in French, and in Japanese the verb has
// not been said yet — the model has to guess a grammatical frame it has not been
// given, and it guesses differently once the rest arrives.
//
// It is wrong for stability, because the second box would then contradict the
// first: the reader watches a completed line rewrite itself.
//
// So the two units are separated. Translation happens on whole sentences;
// *display* paging keeps happening on geometry, over the translated text. A
// sentence split across two boxes is then only a line break in coherent prose —
// exactly what already happens in the source language today, and unremarkable.
//
// ── Why a sentence is not finished when it looks finished ──
//
// Streaming ASR revises. A terminator that has just arrived can still be taken
// back by the next chunk, and a sentence translated on arrival would be
// translated again a beat later with a different result. A sentence is therefore
// only released once something follows it — another word, an endpoint, or a
// pause — by which point the recogniser has committed to it.

import Foundation
import Translation
import CaptionCore

/// Drives translation for the live transcript.
///
/// Owns the one rule that keeps this affordable regardless of mode: **at most one
/// translation in flight**. `onWords` fires several times a second with the full
/// transcript, and spawning a task per callback is the same trap `FrameQueue`
/// exists to avoid — unbounded queued work, each item holding text, none of it
/// still wanted by the time it runs.
///
/// Settled sentences and the speculative tail share that one slot: they go out in
/// a single batch, which also happens to be the fast way to ask (measured here at
/// 117 ms for four sentences together against 319 ms one at a time).
@available(macOS 15, *)
@MainActor
final class TranslationPipeline {
    var mode: TranslationMode = .hybrid {
        didSet {
            guard mode != oldValue else { return }
            // The tail is drawn differently in each mode, and the old one belongs
            // to the mode that produced it.
            translatedTail = ""
            tailSource = ""
            emit()
        }
    }

    /// How long text stays live before it settles, in `hybrid`.
    ///
    /// It is the whole feel of that mode. Too short and everything is settled
    /// text, which is just `sentence` with worse translations; too long and the
    /// tail never stops moving, which is what waiting for punctuation gave.
    ///
    /// One second in practice: two left the churning tail on screen longer than
    /// it was useful. `minSettleWords` is what stops the shorter window from
    /// shaving off a word at a time — the age limit says when a chunk *may*
    /// settle, not that it is big enough to be worth translating.
    static let settleAfter: TimeInterval = 1.0

    private let translator: Translator
    private var buffer = SentenceBuffer()

    /// Translations already obtained, by sentence id. This is what makes the
    /// repeated full-transcript delivery cheap: a settled sentence is translated
    /// once, no matter how many times it is handed to us afterwards.
    private var done: [String: String] = [:]
    /// Emission order, since `done` is unordered and the overlay needs the
    /// sentences back in the order they were spoken.
    private var order: [Sentence] = []
    private var queued: [Sentence] = []

    /// The unfinished sentence, in the source language, and its translation.
    /// `tailSource` is what the in-flight or completed request covers, so a tail
    /// that has not changed is never re-sent.
    private var tail = ""
    private var tailSource = ""
    private var translatedTail = ""
    /// What `translatedTail` was made from, and the span it covers, as sent —
    /// the tail itself moves on underneath. It is drawn over its own span until
    /// a settled sentence reaches past it or a newer translation replaces it,
    /// so a clause promoted to a sentence stays on screen, dimmed, while its
    /// settled form is fetched. Cleared on promotion it vanished for the round
    /// trip — a blink, whenever another request happened to be in flight.
    private var translatedTailSource = ""
    private var translatedTailSpan: (start: TimeInterval, end: TimeInterval) = (0, 0)
    private var tailStart: TimeInterval = 0
    private var tailEnd: TimeInterval = 0

    /// How much of the transcript has been seen, so a discard can skip past it
    /// rather than settling it all again.
    private var seenWords = 0
    private var inFlight = false
    /// Set when the framework has refused this pair outright. Without it the
    /// retry below turns a permanent error into a hot loop: the request fails,
    /// `pump` is called again from the same task, the tail has not changed, and
    /// it fails again — measured at 15k attempts and 21% CPU in fourteen seconds.
    /// Cleared by `reset`, so the next utterance asks once more.
    private var suspended = false
    /// Set by `finish()` when work is still outstanding; applied once it lands.
    private var pendingReset = false

    /// Fires whenever the translated transcript changes: settled text, then the
    /// speculative tail to render dimmed.
    /// Translated words, the audio time the unsettled tail begins at, and the
    /// times each settled chunk begins at.
    ///
    /// The tail is words, not a string. It used to be handed over as text and only
    /// measured, which meant it took room in the box without ever being paged: the
    /// box overflowed because of it and could only evict *settled* words to make
    /// space, so a growing tail pushed out text the reader had not finished with,
    /// and the tail itself replaced itself wholesale instead of filling the box.
    private let onTranslated: (TranslatedTranscript) -> Void
    /// The transcript the last request was made from: what goes under the
    /// translation, matched by span, so the original shown is always the one
    /// the words on screen render.
    private var lastIngested: [TimedWord] = []
    /// Where in the recogniser's transcript the current turn begins. The
    /// transcript runs on across a whole conversation; a pause or an endpoint
    /// ends a turn here, and what came before it is never settled again.
    private var turnStart = 0
    /// Bumped when a turn closes or restarts, so a result still on its way for
    /// the state before is dropped rather than shown.
    private var turnGeneration = 0
    /// Words that arrived while a turn was closing: the next turn's, taken up
    /// once the close has landed. `heldEnded` if a boundary came with them.
    private var heldWords: [TimedWord]?
    private var heldEnded = false
    private let onError: (String) -> Void
    /// Apple refused the pair as source-equals-target. Authoritative and always
    /// current, unlike the recogniser's detection — see the note in `pump`.
    private let onSameLanguage: () -> Void
    /// Assigned after init by the controller, which cannot reference itself in its
    /// own initialiser.
    var onSameLanguageHandler: (() -> Void)?

    init(translator: Translator,
         onTranslated: @escaping (TranslatedTranscript) -> Void,
         onError: @escaping (String) -> Void = { _ in },
         onSameLanguage: @escaping () -> Void = {}) {
        self.translator = translator
        self.onTranslated = onTranslated
        self.onError = onError
        self.onSameLanguage = onSameLanguage
    }

    /// Feed the transcript exactly as `showWords` receives it.
    func ingest(_ words: [TimedWord], ended: Bool = false) {
        guard !words.isEmpty else { return }
        Self.trace("ingest \(words.count) words mode=\(mode.rawValue) ended=\(ended)")
        // A transcript that has got shorter is a restarted one: the turn begins
        // with it.
        if words.count < turnStart { turnStart = 0 }
        if pendingReset {
            // The previous turn is still closing — its last request is out — and
            // these words are the next turn's. Held until it has closed, so its
            // settle carries nothing of them and they are translated in a turn
            // of their own, under the pair their language asks for.
            heldWords = words
            heldEnded = heldEnded || ended
            return
        }
        seenWords = words.count
        lastIngested = words

        if mode == .speculative {
            // No settled text at all: the whole transcript is provisional and is
            // retranslated every update. Deliberately the naive shape, kept as the
            // thing the other two modes are judged against.
            tail = words.map(\.text).joined(separator: " ")
            tailStart = words[0].start
            tailEnd = words[words.count - 1].end
            pump()
            return
        }

        // Only `hybrid` reaches here — `speculative` returned above — so the
        // settle window always applies.
        let fresh = buffer.ingest(words, ended: ended, settleAfter: Self.settleAfter)
        for sentence in fresh where done[sentence.id] == nil {
            order.append(sentence)
            queued.append(sentence)
        }

        // Whatever the buffer has not released yet is the speech in progress.
        let remainder = words.suffix(from: min(buffer.released, words.count))
        // The translated tail is left as it is: it keeps its own span, and
        // `emit` stops drawing it once settled text reaches past it.
        tail = remainder.map(\.text).joined(separator: " ")
        if let first = remainder.first, let last = remainder.last {
            tailStart = first.start
            tailEnd = last.end
        }
        pump()
    }

    /// The utterance is over. Clear the accumulated transcript, but not before the
    /// translation in flight has landed — resetting immediately would wipe the
    /// last sentence a moment before it could be shown. The overlay keeps the
    /// pixels either way; this only clears what would otherwise accumulate for the
    /// life of the session.
    func finish() {
        turnStart = max(turnStart, lastIngested.count)
        if inFlight || !queued.isEmpty {
            pendingReset = true
        } else {
            closeTurn()
        }
    }

    /// Allow sending again after a refusal, without discarding the transcript.
    func resume() { suspended = false }

    /// The box faded: everything pending goes, and nothing said before this can
    /// ever be shown again.
    ///
    /// Not `reset`, which rewinds the buffer to the start of a transcript the
    /// recogniser is still growing and would settle the whole utterance a second
    /// time. This skips past what has been seen: the settled chunks, the clause in
    /// progress and any translation of it are dropped, and settling resumes with
    /// whatever is said next.
    func discardPending() {
        buffer.skip(to: seenWords)
        turnStart = seenWords
        heldWords = nil
        heldEnded = false
        clearTurn()
        pendingReset = false
    }

    /// The turn is over and its last translation has landed: from here on the
    /// transcript's earlier words are another turn's. Not a rewind of the
    /// buffer, which the recogniser keeps growing across a whole conversation:
    /// rewound, every earlier turn was settled and translated again, under
    /// whatever pair the new turn had brought. Words that arrived while the
    /// turn was closing are taken up now, as the next one.
    private func closeTurn() {
        buffer.skip(to: turnStart)
        clearTurn()
        pendingReset = false
        if let held = heldWords {
            heldWords = nil
            let ended = heldEnded
            heldEnded = false
            ingest(held, ended: ended)
            if ended { finish() }
        }
    }

    /// The pair changed under the current turn: translate it again from its
    /// first word, the new way. Nothing of it is kept — a translation the
    /// wrong way round is no head start — and a result still on its way from
    /// the old pair is dropped by the generation check in `pump`. While a turn
    /// is closing there is nothing to restart: the words that brought the new
    /// pair are held, and go out under it once the turn has closed.
    func restartTurn() {
        guard !pendingReset else { return }
        buffer.restart(at: turnStart)
        clearTurn()
    }

    private func clearTurn() {
        queued.removeAll()
        order.removeAll()
        done.removeAll()
        tail = ""
        tailSource = ""
        translatedTail = ""
        lastIngested = []
        suspended = false
        turnGeneration += 1
    }

    /// `SUBS_DEBUG_TRANSLATE=1` traces the pipeline, mirroring SUBS_DEBUG_PAGING.
    nonisolated static let debug =
        ProcessInfo.processInfo.environment["SUBS_DEBUG_TRANSLATE"] != nil
    nonisolated static func trace(_ message: String) {
        guard debug else { return }
        FileHandle.standardError.write("[tr] \(message)\n".data(using: .utf8)!)
    }

    private func pump() {
        guard !suspended else { return }
        if Self.debug {
            Self.trace("pump inFlight=\(inFlight) queued=\(queued.count) "
                + "tail=\(tail.count)ch tailSource=\(tailSource.count)ch")
        }
        guard !inFlight else { return }
        // The tail only earns a request when it has actually changed. Without this
        // an idle recogniser resending identical partials would translate the same
        // words several times a second forever.
        let needsTail = !tail.isEmpty && tail != tailSource
        guard !queued.isEmpty || needsTail else { return }

        let batch = queued
        queued.removeAll()
        let sending = needsTail ? tail : nil
        let span = (start: tailStart, end: tailEnd)
        if let sending { tailSource = sending }
        inFlight = true
        let generation = turnGeneration

        Task { [weak self] in
            guard let self else { return }
            let texts = batch.map(\.text) + (sending.map { [$0] } ?? [])
            Self.trace("sending \(texts.count) text(s)")
            do {
                let results = try await self.translator.translate(texts)
                // The turn restarted under another pair while this was out: the
                // answer is the old pair's, and is not shown.
                if generation == self.turnGeneration {
                    for (sentence, text) in zip(batch, results) {
                        self.done[sentence.id] = CaptionCase.matchingLeading(text, to: sentence.text)
                    }
                    // Kept if the tail is what was sent or has only grown since:
                    // the translation of its first words is still that, over the
                    // span sent, and the follow-up pump below is already fetching
                    // the rest. Dropped if the tail became something else.
                    if let sending, results.count == texts.count,
                       self.tail == sending || self.tail.hasPrefix(sending + " ") {
                        self.translatedTail = CaptionCase.matchingLeading(
                            results[results.count - 1], to: sending)
                        self.translatedTailSource = sending
                        self.translatedTailSpan = span
                    }
                    Self.trace("got \(results.count) result(s)")
                    self.emit()
                } else {
                    Self.trace("dropped \(results.count) result(s) from a restarted turn")
                }
            } catch {
                Self.trace("threw: \(error)")
                // Nothing is put back, and `tailSource` deliberately keeps the
                // text that just failed. Clearing it to force a retry is what
                // created the hot loop: `pump` runs again the moment this task
                // ends, sees an unsent tail, and re-sends the identical string
                // forever. Leaving it set means the retry happens when the
                // speaker produces different words, which is the only time a
                // retry could succeed anyway.
                //
                // Except for a session that stopped answering. That is not a
                // refusal, the translator has already replaced the session, and
                // a round of it costs ten seconds rather than a spin — so the
                // sentences go back to the front of the queue and the tail is
                // marked unsent, and the pump below asks the new session. This
                // is how a box that stalled mid-sentence still settles.
                if error is Translator.TimedOut, generation == self.turnGeneration {
                    self.queued = batch + self.queued
                    self.tailSource = ""
                } else
                // `unsupportedLanguagePairing` on a pair we checked as supported
                // means the audio turned out to already be the target language:
                // en → en is refused outright. This is the *fresh* answer to that
                // question. The recogniser's own detection cannot be used for it,
                // because it latches the first language of a session and does not
                // change again until an endpoint resets it — so a stale reading
                // could suppress translation for minutes of speech.
                if TranslationError.unsupportedLanguagePairing ~= error {
                    self.suspended = true
                    self.onSameLanguage()
                    self.onSameLanguageHandler?()
                } else {
                    self.onError(error.localizedDescription)
                }
            }
            self.inFlight = false
            if self.pendingReset, self.queued.isEmpty { self.closeTurn() }
            self.pump()
        }
    }

    /// Hand the translated transcript back as `TimedWord`s.
    ///
    /// Synthesising times rather than adding a second display path is the whole
    /// trick. Translation has no word alignment — word *order* changes, so there
    /// is none to have — but the overlay does not actually need real times. It
    /// needs times that increase, to anchor paging on and to notice a restart.
    /// Spreading each sentence's own span evenly across its translated words gives
    /// exactly that, and every existing behaviour — paging, the ⌥ history stack,
    /// the idle fade — keeps working untouched.
    private func emit() {
        if mode == .speculative {
            // Everything is provisional, but it is also all there is, so it goes
            // out as committed text rather than as a dimmed tail: a box that was
            // entirely dim would just look broken.
            guard !translatedTail.isEmpty else { return }
            // Nothing settles in this mode, so there are no boundaries to carry
            // and nothing to dim: it is all provisional, and a box drawn entirely
            // in the dimmed style would just look broken.
            let words = Self.spread(translatedTail, from: translatedTailSpan.start,
                                    to: translatedTailSpan.end)
            let passedThrough = TranslatedTranscript.sameWords(translatedTail, translatedTailSource)
            onTranslated(TranslatedTranscript(
                words: words, speculativeFrom: .greatestFiniteMagnitude, chunkStarts: [],
                source: passedThrough ? [] : lastIngested, settlesUtterance: pendingReset))
            return
        }

        var out: [TimedWord] = []
        var starts: [TimeInterval] = []
        for sentence in order {
            guard let text = done[sentence.id] else { continue }
            let spread = Self.spread(text, from: sentence.start, to: sentence.end)
            guard let first = spread.first else { continue }
            // The synthesised time of the chunk's first word, not the sentence's
            // own start: the overlay filters on the times it was handed, and the
            // two differ once a chunk's span is spread across its translation.
            starts.append(first.start)
            out.append(contentsOf: spread)
        }
        // The tail joins the words rather than riding alongside them as text, so
        // it is paged like everything else: the box fills with it and turns over
        // when it is full, instead of the tail evicting settled clauses to make
        // room for itself.
        //
        // Its own start is the boundary between solid and dimmed. It is not added
        // to `starts`: a clause that has not settled is not somewhere to carry a
        // page break to, since it will be rewritten as the speaker finishes it.
        var speculativeFrom = TimeInterval.greatestFiniteMagnitude
        if !translatedTail.isEmpty, !settledReaches(past: translatedTailSpan.start) {
            let spread = Self.spread(translatedTail, from: translatedTailSpan.start,
                                     to: translatedTailSpan.end)
            if let first = spread.first {
                speculativeFrom = first.start
                out.append(contentsOf: spread)
            }
        }
        guard !out.isEmpty else { return }
        onTranslated(TranslatedTranscript(
            words: out, speculativeFrom: speculativeFrom, chunkStarts: starts,
            source: original(), settlesUtterance: pendingReset))
    }

    /// The transcript for under the translation, less whatever came back as
    /// itself. A sentence the translator returned unchanged was already in the
    /// language asked for — the other speaker's words, in a transcript that
    /// ran on across a change of speaker without a pause to split it — and it
    /// is on screen once, above; under it too would be the same language
    /// twice. Spans rather than words, since the translated words are timed
    /// over the sentence they render and the overlay pairs by span.
    private func original() -> [TimedWord] {
        var passedThrough: [(start: TimeInterval, end: TimeInterval)] = []
        for sentence in order {
            guard let text = done[sentence.id],
                  TranslatedTranscript.sameWords(text, sentence.text) else { continue }
            passedThrough.append((sentence.start, sentence.end))
        }
        if !translatedTail.isEmpty,
           TranslatedTranscript.sameWords(translatedTail, translatedTailSource) {
            passedThrough.append(translatedTailSpan)
        }
        guard !passedThrough.isEmpty else { return lastIngested }
        return lastIngested.filter { word in
            !passedThrough.contains { $0.start <= word.start && word.start < $0.end }
        }
    }

    /// Whether settled text now reaches past `time`: the words a translated
    /// tail rendered have been released as a sentence and that sentence has
    /// come back, so the tail is superseded and not drawn again. Until then
    /// it stays, dimmed, in its place.
    private func settledReaches(past time: TimeInterval) -> Bool {
        order.contains { done[$0.id] != nil && $0.end > time + 0.001 }
    }

    private static func spread(_ text: String,
                               from start: TimeInterval,
                               to end: TimeInterval) -> [TimedWord] {
        let pieces = text.split(separator: " ").map(String.init)
        guard !pieces.isEmpty else { return [] }
        let span = max(end - start, 0.001)
        let step = span / Double(pieces.count)
        return pieces.enumerated().map { index, piece in
            let begin = start + step * Double(index)
            return TimedWord(text: piece, start: begin, end: begin + step)
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
