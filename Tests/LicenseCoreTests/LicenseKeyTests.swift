// The shape of a Gumroad key, and what people paste instead of it.

import XCTest
@testable import LicenseCore

final class LicenseKeyTests: XCTestCase {
    private let canonical = "E7086052-3FEE43A0-97D4295D-6500E239"

    func testCanonicalKeyIsItself() {
        XCTAssertEqual(LicenseKey(parsing: canonical)?.formatted, canonical)
    }

    func testLowercaseAndWhitespaceAreFolded() {
        let pasted = "  e7086052-3fee43a0-97d4295d-6500e239\n"
        XCTAssertEqual(LicenseKey(parsing: pasted)?.formatted, canonical)
    }

    func testHyphensAreOptional() {
        XCTAssertEqual(LicenseKey(parsing: "E70860523FEE43A097D4295D6500E239")?.formatted, canonical)
        XCTAssertEqual(LicenseKey(parsing: "E7086052 3FEE43A0 97D4295D 6500E239")?.formatted, canonical)
    }

    func testWrongLengthIsRefused() {
        XCTAssertNil(LicenseKey(parsing: "E7086052-3FEE43A0-97D4295D-6500E23"))
        XCTAssertNil(LicenseKey(parsing: "E7086052-3FEE43A0-97D4295D-6500E2391"))
        XCTAssertNil(LicenseKey(parsing: ""))
    }

    func testNonHexIsRefused() {
        XCTAssertNil(LicenseKey(parsing: "G7086052-3FEE43A0-97D4295D-6500E239"))
        XCTAssertNil(LicenseKey(parsing: "E7086052_3FEE43A0_97D4295D_6500E239"))
        // Unicode digits are not ASCII hex, and a key is bytes on the wire.
        XCTAssertNil(LicenseKey(parsing: "Ｅ7086052-3FEE43A0-97D4295D-6500E239"))
    }

    func testJunkBetweenDigitsIsRefused() {
        XCTAssertNil(LicenseKey(parsing: "key: E7086052-3FEE43A0-97D4295D-6500E239"))
    }

    func testCouldBecomeKey() {
        XCTAssertTrue(LicenseKey.couldBecomeKey(""))
        XCTAssertTrue(LicenseKey.couldBecomeKey("e708"))
        XCTAssertTrue(LicenseKey.couldBecomeKey(canonical))
        XCTAssertFalse(LicenseKey.couldBecomeKey(canonical + "0"))
        XCTAssertFalse(LicenseKey.couldBecomeKey("e70x"))
    }
}
