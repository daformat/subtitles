// The shape of a Gumroad key, and what people paste instead of it.

import XCTest
@testable import LicenseCore

final class LicenseKeyTests: XCTestCase {
    private let canonical = "A1B2C3D4-E5F6A7B8-C9D0E1F2-A3B4C5D6"

    func testCanonicalKeyIsItself() {
        XCTAssertEqual(LicenseKey(parsing: canonical)?.formatted, canonical)
    }

    func testLowercaseAndWhitespaceAreFolded() {
        let pasted = "  a1b2c3d4-e5f6a7b8-c9d0e1f2-a3b4c5d6\n"
        XCTAssertEqual(LicenseKey(parsing: pasted)?.formatted, canonical)
    }

    func testHyphensAreOptional() {
        XCTAssertEqual(LicenseKey(parsing: "A1B2C3D4E5F6A7B8C9D0E1F2A3B4C5D6")?.formatted, canonical)
        XCTAssertEqual(LicenseKey(parsing: "A1B2C3D4 E5F6A7B8 C9D0E1F2 A3B4C5D6")?.formatted, canonical)
    }

    func testWrongLengthIsRefused() {
        XCTAssertNil(LicenseKey(parsing: "A1B2C3D4-E5F6A7B8-C9D0E1F2-A3B4C5D"))
        XCTAssertNil(LicenseKey(parsing: "A1B2C3D4-E5F6A7B8-C9D0E1F2-A3B4C5D61"))
        XCTAssertNil(LicenseKey(parsing: ""))
    }

    func testNonHexIsRefused() {
        XCTAssertNil(LicenseKey(parsing: "G1B2C3D4-E5F6A7B8-C9D0E1F2-A3B4C5D6"))
        XCTAssertNil(LicenseKey(parsing: "A1B2C3D4_E5F6A7B8_C9D0E1F2_A3B4C5D6"))
        // Unicode digits are not ASCII hex, and a key is bytes on the wire.
        XCTAssertNil(LicenseKey(parsing: "Ａ1B2C3D4-E5F6A7B8-C9D0E1F2-A3B4C5D6"))
    }

    func testJunkBetweenDigitsIsRefused() {
        XCTAssertNil(LicenseKey(parsing: "key: A1B2C3D4-E5F6A7B8-C9D0E1F2-A3B4C5D6"))
    }

    func testCouldBecomeKey() {
        XCTAssertTrue(LicenseKey.couldBecomeKey(""))
        XCTAssertTrue(LicenseKey.couldBecomeKey("e708"))
        XCTAssertTrue(LicenseKey.couldBecomeKey(canonical))
        XCTAssertFalse(LicenseKey.couldBecomeKey(canonical + "0"))
        XCTAssertFalse(LicenseKey.couldBecomeKey("e70x"))
    }
}
