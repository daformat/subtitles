// Live translation via Apple's Translation framework.
//
// Why Apple's and not the recogniser's: canary-1b-v2 (FluidAudio PR #833, still
// open) translates speech directly, but only en ↔ X, and X is 24 European
// languages. Half this app's language menu — ja, ko, zh, ar, hi, vi — is not in
// that set, and no pair among them works at all, because there is no pivot: the
// model takes audio, so fr → en → de would need the second leg to be text, which
// it cannot do. Apple's framework covers all 240 ordered pairs of our sixteen.
//
// The cost is macOS 15, against the app's 14.2 floor, so everything here is
// behind `@available(macOS 15, *)` and the framework is weak-linked. On 14.2 this
// file compiles, links, and is never entered.
//
// ── The session cannot simply be constructed ──
//
// `TranslationSession` has no public initialiser; the only way to get one is
// SwiftUI's `.translationTask` modifier, so a session's lifetime is a *view's*
// lifetime. That is an awkward shape for an AppKit menu-bar app with no windows,
// and it is the reason for the hidden window below. Measured, not assumed: a
// window that is never ordered front, under `.accessory` activation policy,
// still yields a working session.
//
// Apple's guidance is not to store the session beyond the closure it arrives in.
// So we don't. The closure stays alive for as long as the configuration does,
// parked on an `AsyncStream` of jobs, and every translation runs *inside* it.
// Work reaches it through the channel; the session never escapes.

import AppKit
import CaptionCore
import SwiftUI
import Translation

/// One unit of work handed to the live session.
///
/// Carries an id rather than its own reply closure. The waiting continuation is
/// held by the `Translator` instead, which is what lets a session teardown fail
/// the jobs it is about to strand — see `use(source:target:)`.
@available(macOS 15, *)
private struct Job {
    let id: UUID
    let texts: [String]
}

/// A fresh mailbox per session. `AsyncStream` can only be iterated once, and the
/// `.translationTask` closure restarts whenever the configuration changes, so a
/// single shared stream would leave the second closure iterating a dead one.
@available(macOS 15, *)
private final class Channel {
    let stream: AsyncStream<Job>
    let send: AsyncStream<Job>.Continuation

    init() {
        var captured: AsyncStream<Job>.Continuation!
        stream = AsyncStream { captured = $0 }
        send = captured
    }
}

@available(macOS 15, *)
private final class Box: ObservableObject {
    @Published var config: TranslationSession.Configuration?
    /// Read inside the task closure. Set in the same main-actor turn as `config`,
    /// so the closure that starts for a configuration always sees its own channel.
    var channel: Channel?
    var onSession: ((TranslationSession) -> Void)?
    var onResult: ((UUID, Result<[String], Error>) -> Void)?
}

@available(macOS 15, *)
private struct SessionHost: View {
    @ObservedObject var box: Box

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(box.config) { session in
                box.onSession?(session)
                guard let channel = box.channel else { return }
                // Parking here is what keeps `session` valid. The loop ends when
                // the channel is finished, which is also when this closure is
                // being torn down for a new configuration.
                for await job in channel.stream {
                    let result: Result<[String], Error>
                    do {
                        let requests = job.texts.map {
                            TranslationSession.Request(sourceText: $0)
                        }
                        let responses = try await session.translations(from: requests)
                        result = .success(responses.map(\.targetText))
                    } catch {
                        result = .failure(error)
                    }
                    await MainActor.run { box.onResult?(job.id, result) }
                }
            }
    }
}

/// Translates text through Apple's on-device models.
///
/// One instance owns one hidden window for the lifetime of the app. Changing
/// languages swaps the configuration rather than rebuilding the host, because
/// rebuilding the view is what invalidates the session.
@available(macOS 15, *)
@MainActor
final class Translator {
    /// What the framework can do for a pair, as far as the UI needs to care.
    enum Readiness: Equatable {
        /// Models are on disk. Translation is immediate.
        case ready
        /// Supported, but the pack has to come down first.
        case needsDownload
        /// The framework will not translate this pair at all.
        case unsupported
    }

    private let box = Box()
    private var window: NSWindow?
    private var source: Locale.Language?
    private var target: Locale.Language?
    private var sessionIsLive = false
    /// Callers parked in `translate`, by job id. Held here rather than inside the
    /// job so that tearing a session down can fail them: `AsyncStream.finish()`
    /// discards whatever it had buffered without delivering it, so a job caught
    /// mid-swap would otherwise leave its caller awaiting a reply that can never
    /// come — and the pipeline, which allows one translation in flight, wedged for
    /// good. This is exactly what changing language used to do.
    private var waiting: [UUID: (Result<[String], Error>) -> Void] = [:]

    /// Progress reporting reuses the engine's channel, and deliberately only ever
    /// reports `FluidAudioEngine.indeterminate`. See `prepare()`.
    private let onStatus: (String) -> Void
    private let onProgress: (Double, String) -> Void

    init(onStatus: @escaping (String) -> Void = { _ in },
         onProgress: @escaping (Double, String) -> Void = { _, _ in }) {
        self.onStatus = onStatus
        self.onProgress = onProgress
    }

    // MARK: availability

    /// Every language the framework can handle on *this* machine.
    ///
    /// Queried rather than hardcoded: the set grows with the OS version, and it
    /// is per-device. A table baked in here would be wrong on the next release.
    static func supportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    static func readiness(from source: Locale.Language,
                          to target: Locale.Language) async -> Readiness {
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return .ready
        case .supported: return .needsDownload
        case .unsupported: return .unsupported
        @unknown default: return .unsupported
        }
    }

    // MARK: session

    /// Point the translator at a language pair. Cheap to call repeatedly with the
    /// same pair: an unchanged configuration does not restart the session.
    func use(source: Locale.Language?, target: Locale.Language) {
        guard self.source != source || self.target != target else { return }
        self.source = source
        self.target = target
        sessionIsLive = false

        ensureHost()
        failEverythingOutstanding()
        // Order matters. The old channel is finished first so its closure's `for
        // await` returns and the session is released, then a new channel and
        // configuration go out together in this same turn.
        box.channel?.send.finish()
        box.channel = Channel()
        box.config = TranslationSession.Configuration(source: source, target: target)
    }

    /// The hidden host. Never ordered front — verified to still produce a session.
    private func ensureHost() {
        guard window == nil else { return }
        box.onSession = { [weak self] _ in
            Task { @MainActor in self?.sessionIsLive = true }
        }
        box.onResult = { [weak self] id, result in
            self?.waiting.removeValue(forKey: id)?(result)
        }
        // Titled and real-sized, though it spends nearly all its life hidden. The
        // download consent sheet is presented by the framework onto this window,
        // and a 1-pixel borderless one is not somewhere a sheet can go — which is
        // how the first translation after picking an undownloaded language came to
        // block forever waiting for a consent nobody could give.
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 130),
                           styleMask: [.titled],
                           backing: .buffered,
                           defer: false)
        win.title = "Preparing translation…"
        win.contentView = NSHostingView(rootView: SessionHost(box: box))
        win.alphaValue = 0
        window = win
    }

    /// Make the host visible.
    ///
    /// Only for the download flow. The framework presents its own consent sheet,
    /// and a sheet needs a window the user can actually see; the rest of the time
    /// the host stays hidden. See the note on `prepare()`.
    private func revealHost(_ visible: Bool) {
        guard let window else { return }
        if visible {
            window.alphaValue = 1
            window.center()
            window.orderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            window.orderOut(nil)
            window.alphaValue = 0
        }
    }

    // MARK: work

    /// Translate one string.
    func translate(_ text: String) async throws -> String {
        let out = try await translate([text])
        return out.first ?? ""
    }

    /// Translate a batch in one round trip.
    ///
    /// Batching matters more than it looks: each call crosses into the framework's
    /// own process, and a page's worth of sentences sent one at a time is several
    /// times the latency of sending them together.
    func translate(_ texts: [String]) async throws -> [String] {
        guard !texts.isEmpty else { return [] }
        guard let channel = box.channel else { throw TranslationError.internalError }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiting[id] = { continuation.resume(with: $0) }
            // `yield` returning `.terminated` means the session went away between
            // the check above and here — a language change mid-flight. Failing is
            // correct; the caller's text belongs to the old target language.
            if case .terminated = channel.send.yield(Job(id: id, texts: texts)) {
                waiting.removeValue(forKey: id)?(.failure(TranslationError.internalError))
            }
        }
    }

    /// Fail every parked caller. Called before a session is replaced, so nothing
    /// is left awaiting a reply from a session that no longer exists.
    private func failEverythingOutstanding() {
        let stranded = waiting
        waiting.removeAll()
        for reply in stranded.values { reply(.failure(TranslationError.internalError)) }
    }

    /// Force the language pack down, if it is not already here.
    ///
    /// ── There is no progress to report ──
    ///
    /// The whole public surface of the Translation framework is 139 lines and
    /// contains no `Progress`, no byte counts, no phase, and no callback.
    /// `prepareTranslation()` is `async throws` and tells you one thing, once: it
    /// came back. The download UI belongs to the system, which presents its own
    /// sheet; we cannot draw a bar for it because we are not told anything to put
    /// in one.
    ///
    /// So this reports `indeterminate` and nothing else, which the menu bar
    /// already renders as a barber-pole — the same treatment a CoreML compile
    /// gets, and for the same reason: work is happening and its length is unknown.
    func prepare() async -> Readiness {
        guard let target else { return .unsupported }
        // With no source there is no pair to ask about, so this cannot say whether
        // a pack is missing and must not pretend otherwise. Claiming ready here is
        // what let someone pick a language whose pack was not installed and get
        // nothing at all: no download was ever requested, and the requests that
        // followed had no window to raise a consent sheet on.
        //
        // Inventing a source is worse still. Defaulting to English probes
        // en → target, which for an English target is `.unsupported`, and that
        // declared every auto-detect session unavailable from the outset.
        //
        // So: not ready, briefly. The original is shown meanwhile, and the moment
        // the recogniser names a language `setSource` asks this again with a real
        // pair, which is a word or two of speech away.
        guard let source else { return .unsupported }
        let state = await Self.readiness(from: source, to: target)
        guard state == .needsDownload else {
            onProgress(0, "")
            return state
        }

        let name = Self.displayName(target)
        onProgress(FluidAudioEngine.indeterminate, "Downloading \(name) translation…")
        // The consent sheet needs a window it can attach to, so the host comes up
        // for the duration of the ask and goes away again after.
        revealHost(true)
        defer {
            revealHost(false)
            onProgress(0, "")
        }
        do {
            // Real words, not a placeholder: the framework rejects whitespace with
            // `nothingToTranslate`, which looks like a failed download and is in
            // fact a request it never made.
            _ = try await translate(["Hello."])
        } catch {
            onStatus("Translation unavailable: \(error.localizedDescription)")
            return .unsupported
        }
        return await Self.readiness(from: source, to: target)
    }

    static func displayName(_ language: Locale.Language) -> String {
        let code = language.minimalIdentifier
        return Locale.current.localizedString(forIdentifier: code) ?? code
    }
}

/// Everything the app needs to hold on to for live translation, in one object so
/// `main.swift` carries a single optional rather than a translator, a pipeline
/// and a language.
@available(macOS 15, *)
@MainActor
final class TranslationController {
    let translator: Translator
    let pipeline: TranslationPipeline
    private(set) var target: Locale.Language
    private(set) var lastWords: [TimedWord] = []
    /// True once the pack is confirmed present *and* there is anything to do.
    /// While it is false the app shows source-language captions instead of nothing
    /// at all — a download runs for minutes, and an empty overlay for that long
    /// reads as a broken app.
    var isReady: Bool { packReady && !isIdentity }
    private var packReady = false
    /// Set when Apple refuses the pair because the audio is already in the target
    /// language — en → en is `.unsupported` and throws outright, so this is not
    /// optional. Cleared at every utterance boundary so it is re-probed rather
    /// than latched: one refused request per utterance costs nothing, and the
    /// alternative is being stuck on a stale answer.
    private var isIdentity = false
    private var currentSource: Locale.Language?

    var mode: TranslationMode {
        get { pipeline.mode }
        set { pipeline.mode = newValue }
    }

    init(target: Locale.Language,
         source: Locale.Language?,
         trustedSource: Bool = false,
         mode: TranslationMode,
         onTranslated: @escaping ([TimedWord], TimeInterval, [TimeInterval]) -> Void,
         onStatus: @escaping (String) -> Void,
         onProgress: @escaping (Double, String) -> Void) {
        self.target = target
        translator = Translator(onStatus: onStatus, onProgress: onProgress)
        pipeline = TranslationPipeline(translator: translator,
                                       onTranslated: onTranslated,
                                       onError: onStatus)
        pipeline.onSameLanguageHandler = { [weak self] in
            guard let self, !self.isIdentity else { return }
            self.isIdentity = true
            onStatus("audio is already \(Translator.displayName(target)) — not translating")
        }
        pipeline.mode = mode
        currentSource = source
        let sameAsTarget = source?.minimalIdentifier == target.minimalIdentifier
        isIdentity = trustedSource && sameAsTarget
        if !isIdentity {
            translator.use(source: sameAsTarget ? nil : source, target: target)
        }
    }

    /// Point at a different source language without rebuilding anything. Called
    /// when the recogniser's language changes underneath us.
    ///
    /// `trusted` separates the two ways a source becomes known, which want
    /// opposite handling when it equals the target:
    ///
    /// - Trusted — the user pinned a language, or the variant is English-only and
    ///   cannot produce anything else. Same-as-target is then a fact, so stop
    ///   translating immediately and never send a request that cannot succeed.
    /// - Untrusted — auto-detect. The checkpoint latches the first language of a
    ///   session, so a reading equal to the target may simply be stale. Ask the
    ///   framework instead and let a refusal settle it.
    func setSource(_ source: Locale.Language?, trusted: Bool = false) {
        // The detector reports on nearly every decode; without this guard each one
        // would tear the session down and re-prepare it.
        guard source != currentSource else { return }
        currentSource = source
        pipeline.reset()
        packReady = false
        let sameAsTarget = source?.minimalIdentifier == target.minimalIdentifier
        isIdentity = trusted && sameAsTarget
        guard !isIdentity else {
            pipeline.resume()
            return
        }
        // An untrusted reading equal to the target cannot be configured as a
        // session at all, so fall back to letting the framework identify per
        // request: weaker, but never stale.
        translator.use(source: sameAsTarget ? nil : source, target: target)
        pipeline.resume()
        Task { @MainActor in _ = await self.prepare() }
    }

    /// Fetch the pack if it is not already here, reporting through the engine's
    /// own progress channel. See `Translator.prepare()` for why it is
    /// indeterminate.
    func prepare() async -> Translator.Readiness {
        let state = await translator.prepare()
        packReady = state == .ready
        return state
    }

    func ingest(_ words: [TimedWord]) {
        lastWords = words
        pipeline.ingest(words, ended: false)
    }

    /// End of utterance or a pause: release the trailing fragment, then clear the
    /// accumulated transcript once the last translation has landed.
    /// The box faded. Drop everything not yet on screen so the next box cannot
    /// open with something said before it.
    func discardPending() {
        lastWords = []
        pipeline.discardPending()
    }

    func finish() {
        if !lastWords.isEmpty { pipeline.ingest(lastWords, ended: true) }
        lastWords = []
        pipeline.finish()
        // Re-probe next utterance rather than staying suppressed: the speaker may
        // have switched language, and one refused request is a cheap way to ask.
        // The pipeline stops sending after a refusal, so it has to be let go of
        // too, or the flag clears here and nothing ever asks again.
        isIdentity = false
        pipeline.resume()
    }
}
