// The state machine: every edge of the trial clock, every answer to a key.

import XCTest
@testable import LicenseCore

final class EntitlementTests: XCTestCase {
    private let key = LicenseKey(parsing: "E7086052-3FEE43A0-97D4295D-6500E239")!
    private let other = LicenseKey(parsing: "00000000-11111111-22222222-33333333")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private let hour: TimeInterval = 3_600
    private let valid = VerifyOutcome.valid(email: "buyer@example.com", test: false, uses: 1)

    private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

    // MARK: trial

    func testFreshRecordIsAnUnstartedTrial() {
        let r = LicenseRecord()
        XCTAssertEqual(r.entitlement(now: t0), .trial(daysLeft: 7, started: false))
        XCTAssertTrue(r.entitlement(now: t0).allowsTranscription)
        XCTAssertFalse(r.reverifyDue(now: t0))
    }

    func testClockStartsAtFirstEngineReadyOnly() {
        var r = LicenseRecord()
        r.observe(now: t0)                       // launch; still downloading
        XCTAssertEqual(r.entitlement(now: at(3 * day)), .trial(daysLeft: 7, started: false))
        r.noteEngineReady(now: at(3 * day))
        XCTAssertEqual(r.trialStart, at(3 * day))
        r.noteEngineReady(now: at(5 * day))      // a later launch does not move it
        XCTAssertEqual(r.trialStart, at(3 * day))
    }

    func testDaysLeftCountsWholeDaysRemaining() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        XCTAssertEqual(r.entitlement(now: t0), .trial(daysLeft: 7, started: true))
        XCTAssertEqual(r.entitlement(now: at(hour)), .trial(daysLeft: 7, started: true))
        XCTAssertEqual(r.entitlement(now: at(day)), .trial(daysLeft: 6, started: true))
        XCTAssertEqual(r.entitlement(now: at(6 * day + 1)), .trial(daysLeft: 1, started: true))
        XCTAssertEqual(r.entitlement(now: at(7 * day - 1)), .trial(daysLeft: 1, started: true))
    }

    func testExpiresAtSevenDays() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        XCTAssertEqual(r.entitlement(now: at(7 * day)), .expired)
        XCTAssertEqual(r.entitlement(now: at(40 * day)), .expired)
        XCTAssertFalse(r.entitlement(now: at(7 * day)).allowsTranscription)
    }

    func testClockSetBackCountsAsExpired() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        r.observe(now: at(3 * day))
        // Within the tolerance: time servers do this.
        XCTAssertEqual(r.entitlement(now: at(3 * day - 30 * 60)), .trial(daysLeft: 5, started: true))
        // Beyond it: the trial is over for as long as the clock stays there.
        XCTAssertEqual(r.entitlement(now: at(2 * day)), .expired)
        // Put right again, it is the trial it was.
        XCTAssertEqual(r.entitlement(now: at(3 * day + 1)), .trial(daysLeft: 4, started: true))
        XCTAssertEqual(r.lastSeen, at(3 * day))
    }

    func testObserveNeverMovesBack() {
        var r = LicenseRecord()
        r.observe(now: at(day))
        r.observe(now: t0)
        XCTAssertEqual(r.lastSeen, at(day))
    }

    func testClockBeforeTrialStartIsExpired() {
        var r = LicenseRecord()
        r.noteEngineReady(now: at(day))
        r.lastSeen = nil                          // as if nothing had been observed
        XCTAssertEqual(r.entitlement(now: t0), .expired)
    }

    // MARK: reinstall

    func testKeychainTrialStartSurvivesLostDefaults() {
        let restored = LicenseRecord.restore(defaults: nil, keychainKey: nil,
                                             keychainTrialStart: t0, now: at(8 * day))
        XCTAssertEqual(restored.entitlement(now: at(8 * day)), .expired)
    }

    func testEarlierTrialStartWins() {
        var defaults = LicenseRecord()
        defaults.trialStart = at(2 * day)
        let restored = LicenseRecord.restore(defaults: defaults, keychainKey: nil,
                                             keychainTrialStart: t0, now: at(3 * day))
        XCTAssertEqual(restored.trialStart, t0)
    }

    func testKeychainKeyComesBackProvisional() {
        let now = at(day)
        let restored = LicenseRecord.restore(defaults: nil, keychainKey: key,
                                             keychainTrialStart: nil, now: now)
        XCTAssertEqual(restored.entitlement(now: now),
                       .provisional(until: now.addingTimeInterval(72 * hour)))
        XCTAssertTrue(restored.reverifyDue(now: now))
        var r = restored
        r.reverify(outcome: valid, now: now)
        XCTAssertEqual(r.entitlement(now: now), .licensed(email: "buyer@example.com"))
    }

    func testDefaultsKeyIsNotReplacedByKeychainKey() {
        var defaults = LicenseRecord()
        defaults.activate(key, outcome: valid, now: t0)
        let restored = LicenseRecord.restore(defaults: defaults, keychainKey: other,
                                             keychainTrialStart: nil, now: at(day))
        XCTAssertEqual(restored.key, key)
        XCTAssertEqual(restored.entitlement(now: at(day)), .licensed(email: "buyer@example.com"))
    }

    // MARK: activation

    func testValidKeyLicenses() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        r.activate(key, outcome: valid, now: at(day))
        XCTAssertEqual(r.entitlement(now: at(day)), .licensed(email: "buyer@example.com"))
        XCTAssertEqual(r.entitlement(now: at(400 * day)), .licensed(email: "buyer@example.com"))
        XCTAssertEqual(r.key, key)
    }

    func testTestPurchaseLicenses() {
        var r = LicenseRecord()
        r.activate(key, outcome: .valid(email: "me@example.com", test: true, uses: 1), now: t0)
        XCTAssertEqual(r.entitlement(now: t0), .licensed(email: "me@example.com"))
    }

    func testRefundedKeyAtActivationChangesNothing() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        r.activate(key, outcome: .revoked(.refunded), now: at(day))
        XCTAssertNil(r.key)
        XCTAssertEqual(r.entitlement(now: at(day)), .trial(daysLeft: 6, started: true))
    }

    func testInvalidKeyAtActivationKeepsTheLicenceOnFile() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        r.activate(other, outcome: .invalid(message: "no"), now: at(day))
        XCTAssertEqual(r.key, key)
        XCTAssertEqual(r.entitlement(now: at(day)), .licensed(email: "buyer@example.com"))
    }

    func testANewValidKeyReplacesARevokedOne() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        r.reverify(outcome: .revoked(.refunded), now: at(31 * day))
        XCTAssertEqual(r.entitlement(now: at(31 * day)), .revoked(.refunded))
        r.activate(other, outcome: .valid(email: "new@example.com", test: false, uses: 1),
                   now: at(32 * day))
        XCTAssertEqual(r.entitlement(now: at(32 * day)), .licensed(email: "new@example.com"))
    }

    // MARK: the monthly check

    func testReverifyDueAfterThirtyDays() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        XCTAssertFalse(r.reverifyDue(now: at(29 * day)))
        XCTAssertTrue(r.reverifyDue(now: at(30 * day)))
        r.reverify(outcome: valid, now: at(30 * day))
        XCTAssertFalse(r.reverifyDue(now: at(31 * day)))
        XCTAssertEqual(r.verifiedAt, at(30 * day))
    }

    func testEachDefinitiveAnswerRevokes() {
        for why in Revocation.allCases {
            var r = LicenseRecord()
            r.activate(key, outcome: valid, now: t0)
            r.reverify(outcome: .revoked(why), now: at(30 * day))
            XCTAssertEqual(r.entitlement(now: at(30 * day)), .revoked(why))
            XCTAssertFalse(r.entitlement(now: at(30 * day)).allowsTranscription)
            XCTAssertFalse(r.reverifyDue(now: at(90 * day)))
        }
    }

    func testRevocationOutranksGrandfathering() {
        var r = LicenseRecord()
        r.migrate(existingPreferences: true)
        r.activate(key, outcome: valid, now: t0)
        r.reverify(outcome: .revoked(.chargebacked), now: at(30 * day))
        XCTAssertEqual(r.entitlement(now: at(30 * day)), .revoked(.chargebacked))
    }

    func testUnknownKeyOnReverifyIsNotDefinitive() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        r.reverify(outcome: .invalid(message: "does not exist"), now: at(30 * day))
        XCTAssertEqual(r.entitlement(now: at(30 * day)), .licensed(email: "buyer@example.com"))
        // Still due: nothing was renewed.
        XCTAssertTrue(r.reverifyDue(now: at(30 * day)))
    }

    func testMalformedAnswerChangesNothing() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        let before = r
        r.reverify(outcome: .malformed, now: at(30 * day))
        XCTAssertEqual(r.key, before.key)
        XCTAssertEqual(r.verifiedAt, before.verifiedAt)
        XCTAssertEqual(r.entitlement(now: at(30 * day)), .licensed(email: "buyer@example.com"))
    }

    func testReverifyWithoutAKeyIsANoOp() {
        var r = LicenseRecord()
        r.reverify(outcome: .revoked(.refunded), now: t0)
        XCTAssertEqual(r, LicenseRecord())
    }

    // MARK: offline

    func testOfflineKeyIsProvisionalForThreeDays() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        XCTAssertTrue(r.acceptProvisionally(key, now: at(6 * day)))
        let until = at(6 * day + 72 * hour)
        XCTAssertEqual(r.entitlement(now: at(6 * day)), .provisional(until: until))
        XCTAssertEqual(r.entitlement(now: at(6 * day + 71 * hour)), .provisional(until: until))
        XCTAssertTrue(r.entitlement(now: at(8 * day)).allowsTranscription)
        XCTAssertTrue(r.reverifyDue(now: at(6 * day)))
        // Lapses back to what the trial is, which by then is over — and the
        // key is still there to be checked.
        XCTAssertEqual(r.entitlement(now: at(6 * day + 72 * hour)), .expired)
        XCTAssertEqual(r.key, key)
        XCTAssertTrue(r.reverifyDue(now: at(10 * day)))
    }

    func testProvisionalConfirmedBecomesLicensed() {
        var r = LicenseRecord()
        r.acceptProvisionally(key, now: t0)
        r.reverify(outcome: valid, now: at(day))
        XCTAssertEqual(r.entitlement(now: at(day)), .licensed(email: "buyer@example.com"))
        XCTAssertNil(r.provisionalSince)
    }

    func testProvisionalRefusedIsCleared() {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        r.acceptProvisionally(key, now: t0)
        r.reverify(outcome: .invalid(message: "no"), now: at(day))
        XCTAssertNil(r.key)
        XCTAssertEqual(r.entitlement(now: at(day)), .trial(daysLeft: 6, started: true))
    }

    func testProvisionalRefundedIsRevoked() {
        var r = LicenseRecord()
        r.acceptProvisionally(key, now: t0)
        r.reverify(outcome: .revoked(.refunded), now: at(day))
        XCTAssertEqual(r.entitlement(now: at(day)), .revoked(.refunded))
    }

    func testProvisionalDoesNotReplaceAVerifiedKey() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        XCTAssertFalse(r.acceptProvisionally(other, now: at(day)))
        XCTAssertFalse(r.acceptProvisionally(key, now: at(day)))
        XCTAssertEqual(r.entitlement(now: at(day)), .licensed(email: "buyer@example.com"))
    }

    func testProvisionalMayReplaceARevokedKey() {
        var r = LicenseRecord()
        r.activate(key, outcome: valid, now: t0)
        r.reverify(outcome: .revoked(.refunded), now: at(30 * day))
        XCTAssertTrue(r.acceptProvisionally(other, now: at(31 * day)))
        XCTAssertEqual(r.entitlement(now: at(31 * day)),
                       .provisional(until: at(31 * day + 72 * hour)))
    }

    func testProvisionalLapsesWhenTheClockGoesBack() {
        var r = LicenseRecord()
        r.acceptProvisionally(key, now: at(day))
        r.observe(now: at(2 * day))
        // No trial start on file, so the lapse lands on the unstarted trial;
        // the key stays, and is checked when the clock is right again.
        XCTAssertEqual(r.entitlement(now: at(day) + hour), .trial(daysLeft: 7, started: false))
        XCTAssertEqual(r.entitlement(now: at(2 * day)),
                       .provisional(until: at(day + 72 * hour)))
    }

    // MARK: existing customers

    func testExistingPreferencesGrandfather() {
        var r = LicenseRecord()
        r.migrate(existingPreferences: true)
        XCTAssertEqual(r.entitlement(now: t0), .grandfathered)
        XCTAssertEqual(r.entitlement(now: at(400 * day)), .grandfathered)
        XCTAssertFalse(r.reverifyDue(now: at(400 * day)))
    }

    func testNoPreferencesMeansTrial() {
        var r = LicenseRecord()
        r.migrate(existingPreferences: false)
        XCTAssertEqual(r.entitlement(now: t0), .trial(daysLeft: 7, started: false))
        XCTAssertTrue(r.migrated)
    }

    func testMigrationRunsOnce() {
        var r = LicenseRecord()
        r.migrate(existingPreferences: false)
        r.migrate(existingPreferences: true)   // 1.6's own preferences, next launch
        XCTAssertFalse(r.grandfathered)
    }

    func testGrandfatheredWithAKeyIsLicensedToThatKey() {
        var r = LicenseRecord()
        r.migrate(existingPreferences: true)
        r.activate(key, outcome: valid, now: t0)
        XCTAssertEqual(r.entitlement(now: t0), .licensed(email: "buyer@example.com"))
        r.removeKey()
        XCTAssertEqual(r.entitlement(now: t0), .grandfathered)
    }

    // MARK: copy

    func testMenuTitles() {
        XCTAssertEqual(Entitlement.trial(daysLeft: 6, started: true).menuTitle, "Trial: 6 days left")
        XCTAssertEqual(Entitlement.trial(daysLeft: 1, started: true).menuTitle, "Trial: 1 day left")
        XCTAssertEqual(Entitlement.expired.menuTitle, "Enter License Key…")
        XCTAssertEqual(Entitlement.revoked(.refunded).menuTitle, "Enter License Key…")
        XCTAssertEqual(Entitlement.licensed(email: "a@b").menuTitle, "Licensed")
        XCTAssertEqual(Entitlement.provisional(until: t0).menuTitle, "Licensed")
        XCTAssertEqual(Entitlement.grandfathered.menuTitle, "Licensed")
    }

    func testAboutAndStatusLines() {
        XCTAssertEqual(Entitlement.licensed(email: "a@b").aboutLine, "Licensed to a@b")
        XCTAssertEqual(Entitlement.licensed(email: nil).aboutLine, "Licensed")
        XCTAssertEqual(Entitlement.trial(daysLeft: 7, started: false).aboutLine,
                       "Trial · starts when captions do")
        XCTAssertEqual(Entitlement.expired.blockedStatusLine,
                       "Trial ended. Resume to enter a license key")
        XCTAssertEqual(Entitlement.revoked(.refunded).blockedStatusLine,
                       "License refunded. Resume to enter another key")
        XCTAssertNil(Entitlement.grandfathered.blockedStatusLine)
    }

    func testRecordRoundTripsThroughJSON() throws {
        var r = LicenseRecord()
        r.noteEngineReady(now: t0)
        r.activate(key, outcome: valid, now: at(day))
        let data = try JSONEncoder().encode(r)
        XCTAssertEqual(try JSONDecoder().decode(LicenseRecord.self, from: data), r)
    }
}
