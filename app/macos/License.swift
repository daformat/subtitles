// The trial and the licence, as the app sees them (PLAN.md §24).
//
// LicenseCore holds the rules; this object holds the record, keeps it saved,
// asks Gumroad when a key needs asking about, and tells main.swift the one
// thing it needs to know: whether transcription is allowed right now. When
// that changes to no — the trial's seventh day, a monthly check that came
// back "refunded" — the app pauses, by the same path the menu's Pause takes,
// and Resume opens the licence window instead of resuming. Nothing else in
// the pipeline knows the licence exists.
//
// What leaves the machine: the key and the product id, to Gumroad, once at
// activation and once a month after. A trial sends nothing at all.

import AppKit
import LicenseCore

final class LicenseController {
    /// Fired on the main thread whenever the entitlement may have changed:
    /// the menu re-reads its title, About its line.
    var onChange: (() -> Void)?
    /// Transcription is no longer allowed. main.swift pauses.
    var onBlocked: (() -> Void)?
    /// Allowed again — a key just activated. main.swift resumes, if the
    /// block was what paused it.
    var onUnblocked: (() -> Void)?

    /// Where keys are checked. `--verify URL` points it elsewhere, for trying
    /// activation against a local server — the licence's `--feed`.
    var verifyOverride: URL? {
        didSet { verifier.endpoint = verifyOverride ?? LicenseVerifier.endpoint }
    }

    private let store = LicenseStore()
    private let verifier = LicenseVerifier()
    private let window = LicenseWindow()
    /// An activation in flight; a second Return while it runs does nothing.
    private var activating = false
    private var record = LicenseRecord()
    private var timer: Timer?
    /// The last reading, to notice when it crosses from allowed to not.
    private var wasAllowed = true
    /// A monthly check in flight, so the timer does not start another.
    private var checking = false

    /// Re-read this often. Hourly rather than daily: the trial ends at an
    /// hour of the day, not at midnight, and the reading costs nothing.
    private static let tick: TimeInterval = 3_600

    var entitlement: Entitlement { record.entitlement(now: Date()) }

    /// For the licence window: the key on file, if any.
    var key: LicenseKey? { record.key }

    // MARK: lifecycle

    /// Called once, before anything else writes to the defaults: the
    /// grandfathering check reads whether a build before this one left
    /// preferences behind, and 1.6's own would be mistaken for them.
    func start() {
        let now = Date()
        record = store.load(now: now)
        record.migrate(existingPreferences: store.hasExistingPreferences)
        record.observe(now: now)
        store.save(record)
        wasAllowed = entitlement.allowsTranscription
        err("license: \(describe(entitlement))")

        timer = Timer.scheduledTimer(withTimeInterval: Self.tick, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
        // A check that is due runs at the first `engine ready`, through
        // `evaluate`, which is seconds after launch on a warm cache — or here,
        // a minute in, for a launch whose engine never comes up. Not at the
        // instant of launch: that races the network coming up, and there is
        // no hurry, the interval being a month.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.reverifyIfDue()
        }
    }

    /// The first `engine ready` starts the trial clock; later ones do nothing.
    func noteEngineReady() {
        let before = record
        record.noteEngineReady(now: Date())
        if record != before { store.save(record) }
        evaluate()
    }

    /// Re-read the record against the clock, save what moved, and say so.
    private func evaluate() {
        let now = Date()
        let before = record
        record.observe(now: now)
        if record != before { store.save(record) }
        let allowed = entitlement.allowsTranscription
        onChange?()
        if wasAllowed, !allowed {
            err("license: \(describe(entitlement))")
            onBlocked?()
        } else if !wasAllowed, allowed {
            onUnblocked?()
        }
        wasAllowed = allowed
        reverifyIfDue()
    }

    // MARK: activation

    enum ActivationResult {
        case notAKey
        case licensed(email: String?)
        /// Gumroad's definitive no. The record is unchanged.
        case revoked(Revocation)
        case invalid(message: String?)
        /// Gumroad could not be reached, and the key is good for 72 hours.
        case provisional(until: Date)
        /// Gumroad could not be reached, and a verified key is already on
        /// file, which the unverified one does not replace.
        case unreachable(Error)
    }

    /// A key the user typed. Calls back on the main thread.
    func activate(_ text: String, completion: @escaping (ActivationResult) -> Void) {
        guard let key = LicenseKey(parsing: text) else {
            completion(.notAKey)
            return
        }
        verifier.verify(key, incrementUses: true) { [weak self] result in
            guard let self else { return }
            let now = Date()
            switch result {
            case .answered(let outcome):
                self.record.activate(key, outcome: outcome, now: now)
                self.store.save(self.record)
                self.evaluate()
                switch outcome {
                case .valid(let email, _, _): completion(.licensed(email: email))
                case .revoked(let why): completion(.revoked(why))
                case .invalid(let message): completion(.invalid(message: message))
                case .malformed: completion(.invalid(message: nil))   // the verifier never passes this
                }
            case .unreachable(let error):
                if self.record.acceptProvisionally(key, now: now) {
                    self.store.save(self.record)
                    self.evaluate()
                    if case .provisional(let until) = self.entitlement {
                        completion(.provisional(until: until))
                    } else {
                        completion(.unreachable(error))
                    }
                } else {
                    completion(.unreachable(error))
                }
            }
        }
    }

    /// Forget the key on file. For the window's "Remove key", and for
    /// nothing else.
    func removeKey() {
        record.removeKey()
        store.save(record)
        evaluate()
    }

    // MARK: the monthly check

    /// The silent check: a verified key every thirty days, a provisional one
    /// at every tick until Gumroad answers. `increment_uses_count=false`, so
    /// it counts for nothing on the dashboard. No answer changes nothing,
    /// and the next tick tries again.
    private func reverifyIfDue(force: Bool = false, then: (() -> Void)? = nil) {
        guard !checking, let key = record.key, force || record.reverifyDue(now: Date()) else {
            then?()
            return
        }
        checking = true
        verifier.verify(key, incrementUses: false) { [weak self] result in
            guard let self else { return }
            self.checking = false
            switch result {
            case .answered(let outcome):
                self.record.reverify(outcome: outcome, now: Date())
                self.store.save(self.record)
                err("license: checked — \(self.describe(self.entitlement))")
                self.evaluate()
            case .unreachable(let error):
                err("license: check postponed — \(error.localizedDescription)")
            }
            then?()
        }
    }

    /// Ask now, ignoring the schedule: the window's Check Now for a
    /// provisional key.
    func recheck(then: @escaping () -> Void) {
        reverifyIfDue(force: true, then: then)
    }

    // MARK: the window

    /// The site's /buy and /key, which redirect to the store and to where it
    /// shows a buyer their key — so a change of store, or a help page for the
    /// second, is one line on the site and not a release.
    static let buyURL = URL(string: "https://subtitles-live.com/buy")!
    static let libraryURL = URL(string: "https://subtitles-live.com/key")!

    /// Open the licence window: the form, or the page for the key on file.
    func present() {
        if entitlement.isLicensed {
            showLicensed(justActivated: false)
        } else {
            showForm(key: window.typedKey, outcome: .none)
        }
    }

    private func showForm(key: String, outcome: LicenseWindow.Outcome) {
        window.show(.enter(
            entitlement: entitlement, key: key, outcome: outcome,
            activate: { [weak self] text in self?.tryKey(text) },
            buy: { NSWorkspace.shared.open(Self.buyURL) },
            findKey: { NSWorkspace.shared.open(Self.libraryURL) },
            close: { [weak self] in self?.window.close() }))
    }

    private func showLicensed(justActivated: Bool) {
        let provisional: Bool
        if case .provisional = entitlement { provisional = true } else { provisional = false }
        window.show(.licensed(
            entitlement: entitlement, justActivated: justActivated,
            enterAnother: { [weak self] in self?.showForm(key: "", outcome: .none) },
            checkNow: provisional ? { [weak self] in self?.checkNow() } : nil,
            done: { [weak self] in self?.window.close() }))
    }

    private func tryKey(_ text: String) {
        guard !activating else { return }
        guard LicenseKey(parsing: text) != nil else {
            showForm(key: text, outcome: .notAKey)
            return
        }
        activating = true
        showForm(key: text, outcome: .checking)
        activate(text) { [weak self] result in
            guard let self else { return }
            self.activating = false
            switch result {
            case .notAKey: self.showForm(key: text, outcome: .notAKey)
            case .licensed: self.showLicensed(justActivated: true)
            case .provisional: self.showLicensed(justActivated: false)
            case .revoked(let why): self.showForm(key: text, outcome: .revoked(why))
            case .invalid(let message): self.showForm(key: text, outcome: .invalid(message))
            case .unreachable(let error):
                self.showForm(key: text, outcome: .unreachable(error.localizedDescription))
            }
        }
    }

    /// The provisional page's Check Now: ask, and show whatever came of it.
    private func checkNow() {
        recheck { [weak self] in
            guard let self else { return }
            if self.entitlement.isLicensed {
                self.showLicensed(justActivated: false)
            } else {
                self.showForm(key: self.record.key?.formatted ?? "", outcome: .none)
            }
        }
    }

    private func describe(_ e: Entitlement) -> String {
        switch e {
        case .trial(let days, let started): return started ? "trial, \(days) days left" : "trial, not started"
        case .expired: return "trial ended"
        case .licensed(let email): return "licensed" + (email.map { " to \($0)" } ?? "")
        case .provisional(let until): return "provisional until \(until)"
        case .revoked(let why): return "revoked (\(why.phrase))"
        case .grandfathered: return "grandfathered"
        }
    }
}
