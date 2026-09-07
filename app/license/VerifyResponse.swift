// Gumroad's licence verification, as data: the request body the app sends,
// and what its answer means.
//
// The endpoint is `POST https://api.gumroad.com/v2/licenses/verify`, checked
// 2026-09-07. It takes `product_id` and `license_key`, needs no token, and
// answers with the purchase record — whether it was refunded, charged back or
// disputed, the buyer's email, a `test` flag for the seller's own test
// purchases — plus a `uses` counter it increments on every call unless told
// `increment_uses_count=false`. A key it does not know, or one the seller has
// disabled, comes back as a 404 with `success: false` and a message.
//
// Nothing here talks to the network. The app does that (LicenseVerifier, in
// the app target) and hands the bytes in; every reading of them is here, where
// a test can hand in the same bytes.

import Foundation

/// A definitive answer that a key no longer stands. These are the only four
/// that ever revoke a licence: anything else Gumroad says, or fails to say,
/// leaves the record alone (PLAN.md §24).
public enum Revocation: String, Codable, Equatable, CaseIterable {
    case refunded
    case chargebacked
    case disputed
    case disabled

    /// The word for the window: "This key was refunded."
    public var phrase: String {
        switch self {
        case .refunded: return "refunded"
        case .chargebacked: return "charged back"
        case .disputed: return "disputed"
        case .disabled: return "disabled"
        }
    }
}

public enum VerifyOutcome: Equatable {
    /// The key is good. `email` is the buyer's, for the licensed-to line;
    /// `test` marks the seller's own test purchase, which counts as good.
    case valid(email: String?, test: Bool, uses: Int?)
    /// The purchase stood once and no longer does.
    case revoked(Revocation)
    /// Gumroad does not know this key for this product. Definitive at
    /// activation; not at re-verification, where it is ignored.
    case invalid(message: String?)
    /// The bytes were not a verify answer at all: a proxy's error page, a
    /// half-received body. Treated exactly like no answer.
    case malformed
}

public enum VerifyResponse {
    /// The form body for a verify call. `incrementUses` false is what the
    /// monthly check sends, so the dashboard's activation count stays a count
    /// of activations and not of months.
    public static func requestBody(productID: String, key: LicenseKey, incrementUses: Bool) -> String {
        let fields = [
            ("product_id", productID),
            ("license_key", key.formatted),
            ("increment_uses_count", incrementUses ? "true" : "false"),
        ]
        return fields.map { "\($0)=\(formEncoded($1))" }.joined(separator: "&")
    }

    /// application/x-www-form-urlencoded: unreserved characters as they are,
    /// space as +, everything else percent-encoded. Gumroad's product ids end
    // in `==`, which is the case that matters here.
    static func formEncoded(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "*"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out.append(String(format: "%%%02X", byte))
            }
        }
        return out
    }

    /// What Gumroad's body means. The status code is not consulted: Gumroad
    /// says `success: false` in the body of every refusal, and a 200 whose
    /// body says the purchase was refunded is a refund.
    public static func parse(_ data: Data) -> VerifyOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any],
              let success = json["success"] as? Bool else { return .malformed }
        guard success else {
            let message = json["message"] as? String
            // "This license key has been disabled." is the seller's own doing
            // — the one refusal that is a decision about this key rather than
            // a key Gumroad has never seen.
            if let message, message.lowercased().contains("disabled") {
                return .revoked(.disabled)
            }
            return .invalid(message: message)
        }
        guard let purchase = json["purchase"] as? [String: Any] else { return .malformed }
        if purchase["refunded"] as? Bool == true { return .revoked(.refunded) }
        if purchase["chargebacked"] as? Bool == true { return .revoked(.chargebacked) }
        // A dispute the seller won is a purchase that stands: the buyer's bank
        // asked and was told no. Only an open or lost dispute counts.
        if purchase["disputed"] as? Bool == true, purchase["dispute_won"] as? Bool != true {
            return .revoked(.disputed)
        }
        let email = (purchase["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return .valid(email: email,
                      test: purchase["test"] as? Bool == true,
                      uses: json["uses"] as? Int)
    }
}
