// Where the licence record lives (PLAN.md §24).
//
// Two places, on purpose. The whole record is JSON in the app's defaults,
// which is what every launch reads. The two facts a reinstall must not lose
// — the key, and the day the trial started — are also generic-password items
// in the login Keychain, which outlives the app, its defaults and a "reset
// everything" alike. LicenseRecord.restore is the merge; this file only
// fetches and stores.
//
// The Keychain's access control is per signing identity. An ad-hoc build has
// a different identity from the Developer ID build — and from the previous
// ad-hoc build, since ad-hoc means the cdhash — so an item one made prompts
// when the other reads it. A second service string keeps the two apart;
// nothing depends on the answer to a prompt, because the defaults carry
// everything and a Keychain that refuses is a Keychain with nothing in it.
//
// Honour system, as the record itself says: `defaults delete` and `security
// delete-generic-password` together restart the trial, and that is by design
// the amount of effort it takes.

import Foundation
import LicenseCore
import Security

final class LicenseStore {
    /// The Keychain service, and the defaults key holding the record.
    let service: String
    static let recordKey = "license.record"
    /// The two items' account names, the only other thing that identifies them.
    static let keyAccount = "key"
    static let trialStartAccount = "trial-start"

    private let defaults: UserDefaults
    /// What the Keychain held at the last read, so a save only writes what
    /// changed — every write is a chance for a prompt on the wrong build.
    private var keychainKey: LicenseKey?
    private var keychainTrialStart: Date?

    init(defaults: UserDefaults = .standard, service: String? = nil) {
        self.defaults = defaults
        self.service = service ?? (Self.isAdHocSigned
            ? "dev.mat.subtitles.license.dev" : "dev.mat.subtitles.license")
    }

    // MARK: reading

    func load(now: Date) -> LicenseRecord {
        var stored: LicenseRecord?
        if let json = defaults.string(forKey: Self.recordKey) {
            stored = try? Self.decoder.decode(LicenseRecord.self, from: Data(json.utf8))
        }
        keychainKey = read(Self.keyAccount).flatMap { LicenseKey(parsing: $0) }
        // Whole seconds since 1970, as text: the one format `security
        // find-generic-password -w` prints and `add-generic-password -w`
        // takes, so a trial can be moved by hand while testing.
        keychainTrialStart = read(Self.trialStartAccount)
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { Date(timeIntervalSince1970: $0) }
        let record = LicenseRecord.restore(defaults: stored, keychainKey: keychainKey,
                                           keychainTrialStart: keychainTrialStart, now: now)
        // One line for the log, because "why does it say my trial ended" is
        // the question this file will be asked, and the answer is which of
        // the two copies of the start date it took.
        let f = ISO8601DateFormatter()
        Self.log("trial start: defaults \(stored?.trialStart.map(f.string) ?? "none"), "
            + "keychain \(keychainTrialStart.map(f.string) ?? "none") → "
            + "\(record.trialStart.map(f.string) ?? "none")"
            + (keychainKey == nil ? "" : "; key in keychain"))
        return record
    }

    /// Whether any build before this one left preferences behind: the
    /// evidence grandfathering rests on. The licence's own key is not
    /// evidence of anything, and is the one excluded.
    var hasExistingPreferences: Bool {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let domain = defaults.persistentDomain(forName: bundleID) else { return false }
        return domain.keys.contains { !$0.hasPrefix("license.") }
    }

    // MARK: writing

    func save(_ record: LicenseRecord) {
        if let data = try? Self.encoder.encode(record), let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: Self.recordKey)
        }
        if record.key != keychainKey {
            write(Self.keyAccount, record.key?.formatted)
            keychainKey = record.key
        }
        // Compared at whole seconds, which is all the Keychain copy keeps.
        let start = record.trialStart.map { Date(timeIntervalSince1970: $0.timeIntervalSince1970.rounded(.down)) }
        if start != keychainTrialStart {
            write(Self.trialStartAccount, start.map { String(Int($0.timeIntervalSince1970)) })
            keychainTrialStart = start
        }
    }

    /// The record as a JSON string with ISO 8601 dates, rather than plist
    /// data: `defaults read` shows it, and `defaults write` can move a trial
    /// start back a week to see what the seventh day looks like.
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: the Keychain

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else {
            if status != errSecItemNotFound { Self.log("read \(account): \(status)") }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Nil removes the item.
    private func write(_ account: String, _ value: String?) {
        guard let value else {
            let status = SecItemDelete(query(account) as CFDictionary)
            if status != errSecSuccess, status != errSecItemNotFound { Self.log("delete \(account): \(status)") }
            return
        }
        let data = Data(value.utf8)
        let update = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query(account) as CFDictionary, update)
        if status == errSecItemNotFound {
            var q = query(account)
            q[kSecValueData as String] = data
            q[kSecAttrLabel as String] = "Subtitles license"
            status = SecItemAdd(q as CFDictionary, nil)
        }
        if status != errSecSuccess { Self.log("write \(account): \(status)") }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write("license store: \(message)\n".data(using: .utf8)!)
    }

    /// True when the running code carries no team identifier — an ad-hoc
    /// signature, or none. Asked of the code itself rather than of a build
    /// flag, so the answer is the one the Keychain will be using.
    static var isAdHocSigned: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return true }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return true }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return true }
        return dict[kSecCodeInfoTeamIdentifier as String] == nil
    }
}
