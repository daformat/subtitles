// Gumroad's answers, as bytes, and what each one means.

import XCTest
@testable import LicenseCore

final class VerifyResponseTests: XCTestCase {
    private let key = LicenseKey(parsing: "E7086052-3FEE43A0-97D4295D-6500E239")!

    private func body(success: Bool = true, purchase: [String: Any] = [:], uses: Int? = 2,
                      message: String? = nil) -> Data {
        var json: [String: Any] = ["success": success]
        if success {
            var p: [String: Any] = ["email": "buyer@example.com", "refunded": false,
                                    "chargebacked": false, "disputed": false,
                                    "dispute_won": false, "test": false,
                                    "product_id": "4RhCAM7ZoPS_lX9n_xXZ9g==",
                                    "license_key": key.formatted]
            p.merge(purchase) { $1 }
            json["purchase"] = p
            if let uses { json["uses"] = uses }
        }
        if let message { json["message"] = message }
        return try! JSONSerialization.data(withJSONObject: json)
    }

    func testRequestBody() {
        let s = VerifyResponse.requestBody(productID: "4RhCAM7ZoPS_lX9n_xXZ9g==", key: key,
                                           incrementUses: false)
        XCTAssertEqual(s, "product_id=4RhCAM7ZoPS_lX9n_xXZ9g%3D%3D"
            + "&license_key=E7086052-3FEE43A0-97D4295D-6500E239&increment_uses_count=false")
        XCTAssertTrue(VerifyResponse.requestBody(productID: "x", key: key, incrementUses: true)
            .hasSuffix("increment_uses_count=true"))
        XCTAssertEqual(VerifyResponse.formEncoded("a b&c/é"), "a+b%26c%2F%C3%A9")
    }

    func testValid() {
        XCTAssertEqual(VerifyResponse.parse(body()),
                       .valid(email: "buyer@example.com", test: false, uses: 2))
    }

    func testTestPurchaseIsValid() {
        XCTAssertEqual(VerifyResponse.parse(body(purchase: ["test": true])),
                       .valid(email: "buyer@example.com", test: true, uses: 2))
    }

    func testMissingEmailAndUses() {
        XCTAssertEqual(VerifyResponse.parse(body(purchase: ["email": ""], uses: nil)),
                       .valid(email: nil, test: false, uses: nil))
    }

    func testRefunded() {
        XCTAssertEqual(VerifyResponse.parse(body(purchase: ["refunded": true])), .revoked(.refunded))
    }

    func testChargebacked() {
        XCTAssertEqual(VerifyResponse.parse(body(purchase: ["chargebacked": true])),
                       .revoked(.chargebacked))
    }

    func testDisputed() {
        XCTAssertEqual(VerifyResponse.parse(body(purchase: ["disputed": true])), .revoked(.disputed))
    }

    func testDisputeWonBySellerStands() {
        XCTAssertEqual(VerifyResponse.parse(body(purchase: ["disputed": true, "dispute_won": true])),
                       .valid(email: "buyer@example.com", test: false, uses: 2))
    }

    func testUnknownKey() {
        let msg = "That license does not exist for the provided product."
        XCTAssertEqual(VerifyResponse.parse(body(success: false, message: msg)),
                       .invalid(message: msg))
    }

    func testDisabledKey() {
        XCTAssertEqual(VerifyResponse.parse(body(success: false,
                                                 message: "This license key has been disabled.")),
                       .revoked(.disabled))
    }

    func testMalformed() {
        XCTAssertEqual(VerifyResponse.parse(Data("<html>502</html>".utf8)), .malformed)
        XCTAssertEqual(VerifyResponse.parse(Data("{\"success\": true}".utf8)), .malformed)
        XCTAssertEqual(VerifyResponse.parse(Data()), .malformed)
    }

    func testRevocationPhrases() {
        XCTAssertEqual(Revocation.chargebacked.phrase, "charged back")
        XCTAssertEqual(Revocation.allCases.count, 4)
    }
}
