// Whether this copy may transcribe, and why (PLAN.md §24).
//
// The app is a free download with a seven-day trial, and the key is the
// product. This file is the whole of the rule: a record of what has happened
// — when captions first appeared, which key was entered, what Gumroad said
// about it and when — and the reading of that record into one of six states.
// Nothing here touches the Keychain, the network or a window; the app hands
// in a record and a clock and gets an answer, which is what lets every edge
// of it be tested.
//
// Honour system, by construction. The source is public, so anyone can build a
// copy without this file; anyone with `defaults write` can forge the
// grandfathering below; anyone willing to set their clock back an hour a day
// can stretch the trial. None of that is worth defending against for a $9
// app, and the checks here are sized to what they are for: keeping an honest
// person honest by accident — a reinstall that would otherwise restart the
// trial, a clock set wrong — and no more.

import Foundation

/// What the record says right now.
public enum Entitlement: Equatable {
    /// The trial, with whole days remaining. `started` is false until the
    /// first `engine ready`: the first launch is a 633 MB download, and the
    /// clock does not run on it.
    case trial(daysLeft: Int, started: Bool)
    /// The trial is over. The app runs, and does not transcribe.
    case expired
    /// A key Gumroad confirmed. `email` is the buyer's, when Gumroad gave one.
    case licensed(email: String?)
    /// A well-formed key entered while Gumroad was unreachable, good until
    /// `until` and checked again as soon as the network is back.
    case provisional(until: Date)
    /// The key stood once and Gumroad has since given a definitive answer
    /// that it does not. Runs, and does not transcribe, like expired.
    case revoked(Revocation)
    /// Preferences from a build older than 1.6 were found on its first
    /// launch. Every copy before 1.6 came from Gumroad or from source, so
    /// that is evidence enough of a purchase, and no key is asked for.
    case grandfathered

    /// The one thing the pipeline asks.
    public var allowsTranscription: Bool {
        switch self {
        case .trial, .licensed, .provisional, .grandfathered: return true
        case .expired, .revoked: return false
        }
    }

    /// True while a key is on file and standing — the states where the
    /// menu says "Licensed" rather than offering to enter one.
    public var isLicensed: Bool {
        switch self {
        case .licensed, .provisional, .grandfathered: return true
        case .trial, .expired, .revoked: return false
        }
    }

    /// The menu item near Settings.
    public var menuTitle: String {
        switch self {
        case .trial(let days, _):
            return "Trial: \(days) \(days == 1 ? "day" : "days") left"
        case .expired, .revoked:
            return "Enter License Key…"
        case .licensed, .provisional, .grandfathered:
            return "Licensed"
        }
    }

    /// The line under the version in About, or nil when there is nothing to
    /// say — a trial in progress says so in the menu, not there.
    public var aboutLine: String? {
        switch self {
        case .licensed(let email?): return "Licensed to \(email)"
        case .licensed(nil), .grandfathered: return "Licensed"
        case .provisional: return "Licensed · to be confirmed"
        case .revoked(let why): return "License \(why.phrase)"
        case .trial(let days, true): return "Trial · \(days) \(days == 1 ? "day" : "days") left"
        case .trial(_, false): return "Trial · starts when captions do"
        case .expired: return "Trial ended"
        }
    }

    /// What the status line at the top of the menu says while transcription
    /// is refused; nil in every state where it is not.
    public var blockedStatusLine: String? {
        switch self {
        case .expired: return "Trial ended — Resume to enter a license key"
        case .revoked(let why): return "License \(why.phrase) — Resume to enter another key"
        default: return nil
        }
    }
}

/// Everything the app has learned about this copy's entitlement. Stored by
/// the app (the key and the trial start in the Keychain as well as the
/// defaults, so a reinstall changes nothing; the rest in the defaults) and
/// read here.
public struct LicenseRecord: Codable, Equatable {
    /// The first `engine ready` on this Mac. Nil until then.
    public var trialStart: Date?
    /// The latest moment this record has been evaluated at. A clock now
    /// behind it by more than `clockTolerance` has been set back, and the
    /// trial is treated as over for as long as it stays there.
    public var lastSeen: Date?
    /// The key on file, verified or provisional.
    public var key: LicenseKey?
    /// The buyer's email from the last good verification, for display.
    public var email: String?
    /// When Gumroad last confirmed `key`. Nil while the key is provisional.
    public var verifiedAt: Date?
    /// When `key` was accepted without an answer from Gumroad.
    public var provisionalSince: Date?
    /// Gumroad's definitive answer that `key` no longer stands.
    public var revocation: Revocation?
    /// Set once, on 1.6's first launch, if the app already had preferences.
    public var grandfathered: Bool = false
    /// True once that first-launch check has run, so it never runs again —
    /// a later launch has the app's own 1.6 preferences to be fooled by.
    public var migrated: Bool = false

    public static let trialLength: TimeInterval = 7 * 86_400
    public static let provisionalLength: TimeInterval = 72 * 3_600
    public static let reverifyInterval: TimeInterval = 30 * 86_400
    /// How far the clock may step backwards before it counts as having been
    /// set back. An hour: time servers correct by seconds, and no time zone
    /// or daylight change moves absolute time at all.
    public static let clockTolerance: TimeInterval = 3_600

    public init() {}

    // MARK: reading

    public func entitlement(now: Date) -> Entitlement {
        // A definitive answer outranks everything, grandfathering included:
        // it is the one fact here that did not come from this machine.
        if key != nil, let revocation { return .revoked(revocation) }
        if key != nil, verifiedAt != nil, revocation == nil { return .licensed(email: email) }
        if key != nil, let since = provisionalSince {
            let until = since.addingTimeInterval(Self.provisionalLength)
            if now >= since, now < until, !clockWentBackwards(now: now) {
                return .provisional(until: until)
            }
            // Past 72 h with no answer, or a clock that went back: the key
            // stays on file to be checked, and the trial is what is left.
        }
        if grandfathered { return .grandfathered }
        guard let trialStart else { return .trial(daysLeft: Self.trialDays, started: false) }
        if clockWentBackwards(now: now) || now < trialStart { return .expired }
        let left = trialStart.addingTimeInterval(Self.trialLength).timeIntervalSince(now)
        guard left > 0 else { return .expired }
        return .trial(daysLeft: Int((left / 86_400).rounded(.up)), started: true)
    }

    public static var trialDays: Int { Int(trialLength / 86_400) }

    /// True when `now` is behind the latest time this record has seen by
    /// more than the tolerance. Not sticky: a clock put right again is a
    /// trial running again, with the days it had.
    public func clockWentBackwards(now: Date) -> Bool {
        guard let lastSeen else { return false }
        return now < lastSeen.addingTimeInterval(-Self.clockTolerance)
    }

    /// Whether the monthly check should run, given a network to run it on.
    /// A provisional key is always due — it has never been answered — and a
    /// verified one every thirty days. Nothing about a trial is ever sent.
    public func reverifyDue(now: Date) -> Bool {
        guard key != nil, revocation == nil else { return false }
        guard let verifiedAt else { return provisionalSince != nil }
        return now.timeIntervalSince(verifiedAt) >= Self.reverifyInterval
    }

    // MARK: the clock

    /// The trial clock starts on the first `engine ready`, whenever that is:
    /// a launch that spends its whole time downloading starts nothing.
    public mutating func noteEngineReady(now: Date) {
        if trialStart == nil { trialStart = now }
        observe(now: now)
    }

    /// Records that `now` has happened. Called at every evaluation, so
    /// `lastSeen` is the high-water mark of the clock; it never moves back.
    public mutating func observe(now: Date) {
        if let lastSeen, lastSeen >= now { return }
        lastSeen = now
    }

    // MARK: existing customers

    /// 1.6's first launch. If the app already had preferences — any key of
    /// its own in the defaults, written by a build that was only ever sold —
    /// this copy is licensed without a key. Runs once; forgeable with
    /// `defaults write`, and that is fine (see the top of this file).
    public mutating func migrate(existingPreferences: Bool) {
        guard !migrated else { return }
        migrated = true
        if existingPreferences { grandfathered = true }
    }

    // MARK: keys

    /// Gumroad's answer to a key the user just entered. A good answer
    /// replaces whatever key was on file; any other leaves the record as it
    /// was, so a licensed user mistyping a second key loses nothing, and a
    /// trial user trying a refunded one keeps their trial. The window shows
    /// the outcome either way.
    public mutating func activate(_ key: LicenseKey, outcome: VerifyOutcome, now: Date) {
        guard case .valid(let email, _, _) = outcome else { return }
        self.key = key
        self.email = email
        verifiedAt = now
        provisionalSince = nil
        revocation = nil
        observe(now: now)
    }

    /// A well-formed key entered while Gumroad could not be reached. Accepted
    /// for 72 hours and checked as soon as it can be — unless a verified key
    /// is already on file, which is not to be traded for an unverified one.
    /// Returns whether the key was taken.
    @discardableResult
    public mutating func acceptProvisionally(_ key: LicenseKey, now: Date) -> Bool {
        if self.key != nil, verifiedAt != nil, revocation == nil { return false }
        self.key = key
        email = nil
        verifiedAt = nil
        provisionalSince = now
        revocation = nil
        observe(now: now)
        return true
    }

    /// The monthly check, or the first answer for a provisional key. Only
    /// the definitive answers change anything: a good one renews the date,
    /// a revocation records itself. A key Gumroad no longer knows is ignored
    /// for a verified key — that is not one of the four — and clears a
    /// provisional one, whose activation it is the first answer to.
    public mutating func reverify(outcome: VerifyOutcome, now: Date) {
        guard key != nil else { return }
        switch outcome {
        case .valid(let email, _, _):
            self.email = email
            verifiedAt = now
            provisionalSince = nil
            revocation = nil
        case .revoked(let why):
            revocation = why
        case .invalid:
            if verifiedAt == nil { removeKey() }
        case .malformed:
            break
        }
        observe(now: now)
    }

    /// Forget the key. Nothing else: the trial clock is what it was.
    public mutating func removeKey() {
        key = nil
        email = nil
        verifiedAt = nil
        provisionalSince = nil
        revocation = nil
    }

    // MARK: storage

    /// The record the defaults held, if any, completed from the two Keychain
    /// items. The Keychain outlives the defaults — a reinstall, a reset — and
    /// wins where the two disagree about the trial start, since the earlier
    /// date is the true one. A key found only in the Keychain comes back
    /// provisional: its verification went with the defaults, and the next
    /// check confirms it.
    public static func restore(defaults: LicenseRecord?, keychainKey: LicenseKey?,
                               keychainTrialStart: Date?, now: Date) -> LicenseRecord {
        var record = defaults ?? LicenseRecord()
        switch (record.trialStart, keychainTrialStart) {
        case (nil, let stored?): record.trialStart = stored
        case (let own?, let stored?): record.trialStart = min(own, stored)
        default: break
        }
        if record.key == nil, let keychainKey {
            record.key = keychainKey
            record.provisionalSince = now
            record.verifiedAt = nil
            record.revocation = nil
        }
        return record
    }
}
