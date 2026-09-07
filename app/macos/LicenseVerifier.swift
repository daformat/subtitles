// The one request the licence ever makes: a key, to Gumroad, for an answer.
//
// At activation, with the uses counter incremented, so the dashboard counts
// activations; every thirty days after that with it held, so it goes on
// counting activations and not months (PLAN.md §24). Both requests carry
// the product id and the key and nothing else — no email, no machine name,
// nothing about what was transcribed. The privacy page and the licence window
// both say so, and this file is what makes it true.
//
// The reading of the answer is LicenseCore's (VerifyResponse); this is the
// transport. No answer — no network, a timeout, a 5xx page that is not JSON —
// is reported as `unreachable`, and the caller treats every kind alike: the
// record does not change.

import Foundation
import LicenseCore

final class LicenseVerifier {
    /// Gumroad's id for the product. Public — it is in every buy link — and
    /// compiled in, since there is nothing to configure.
    static let productID = "4RhCAM7ZoPS_lX9n_xXZ9g=="
    static let endpoint = URL(string: "https://api.gumroad.com/v2/licenses/verify")!

    enum Result {
        case answered(VerifyOutcome)
        case unreachable(Error)
    }

    /// Where the request goes; the real endpoint unless a test says otherwise.
    var endpoint: URL = LicenseVerifier.endpoint

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        // Short. A person is looking at a window that says "Checking…", and
        // twenty seconds of that is a long time; the provisional path exists
        // for exactly the network that does not answer.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    /// Asks, and calls back on the main thread.
    func verify(_ key: LicenseKey, incrementUses: Bool, completion: @escaping (Result) -> Void) {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(VerifyResponse.requestBody(
            productID: Self.productID, key: key, incrementUses: incrementUses).utf8)
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result
            if let error {
                result = .unreachable(error)
            } else if let data {
                switch VerifyResponse.parse(data) {
                case .malformed:
                    // Bytes came back and were not Gumroad's: a captive
                    // portal, a proxy's error page. That is no answer.
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    result = .unreachable(NSError(
                        domain: "LicenseVerifier", code: code,
                        userInfo: [NSLocalizedDescriptionKey: "Gumroad gave an answer that could not be read (HTTP \(code))."]))
                case let outcome:
                    result = .answered(outcome)
                }
            } else {
                result = .unreachable(NSError(
                    domain: "LicenseVerifier", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "Gumroad sent no answer."]))
            }
            DispatchQueue.main.async { completion(result) }
        }
        task.resume()
    }
}
