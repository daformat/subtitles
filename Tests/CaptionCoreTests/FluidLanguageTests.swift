// The language table.
//
// Nothing here is clever, which is the point: these are the facts every other
// part of the app trusts without checking. A wrong FLEURS code seeds the decoder
// with the wrong prompt and quietly costs accuracy, a wrong pack answer sends
// someone a 583 MB download that cannot decode the language they picked, and a
// miscount goes straight into a menu subtitle. All three have a way of drifting
// when a language is added, and none of them fails loudly.

import XCTest
@testable import CaptionCore

final class FluidLanguageTests: XCTestCase {
    private var real: [FluidLanguage] { FluidLanguage.allCases.filter { $0 != .auto } }

    /// The menu describes the multilingual variant as carrying sixteen languages.
    /// That number is written out in `FluidVariant.note`, and the repository has
    /// already shipped it wrong once ("Say eight languages, not nine"). Adding a
    /// language should fail here and send you to the string.
    func testSixteenLanguagesAreOffered() {
        XCTAssertEqual(real.count, 16)
    }

    /// `auto` is a detection mode over the languages, not one of them.
    func testAutoIsNotALanguage() {
        XCTAssertEqual(FluidLanguage.auto.code, "auto")
        XCTAssertFalse(real.contains(.auto))
    }

    // MARK: prompt codes

    /// The decoder is prompted by this code. Two languages sharing one would
    /// prompt for the wrong language with no error anywhere.
    func testEveryCodeIsDistinct() {
        let codes = FluidLanguage.allCases.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
    }

    func testCodesAreFleursShaped() {
        for language in real {
            let parts = language.code.split(separator: "-")
            XCTAssertEqual(parts.count, 2, "\(language.rawValue) has code '\(language.code)'")
            XCTAssertEqual(String(parts[0]), language.rawValue,
                           "the code should lead with the language's own subtag")
        }
    }

    // MARK: matching what the recogniser reports

    /// The multilingual checkpoint reports the language it heard as a FLEURS
    /// code, and the translator is pointed at whatever comes back.
    func testEveryLanguageIsFoundByItsOwnCode() {
        for language in real {
            XCTAssertEqual(FluidLanguage.matching(code: language.code), language)
        }
    }

    /// A locale the table does not list should still resolve on its language
    /// subtag rather than turning translation off.
    func testAnUnlistedRegionFallsBackToTheLanguage() {
        XCTAssertEqual(FluidLanguage.matching(code: "en-GB"), .en)
        XCTAssertEqual(FluidLanguage.matching(code: "pt-PT"), .pt)
        XCTAssertEqual(FluidLanguage.matching(code: "fr-CA"), .fr)
    }

    func testABareSubtagResolves() {
        XCTAssertEqual(FluidLanguage.matching(code: "de"), .de)
    }

    func testAnUnknownLanguageIsNotGuessed() {
        XCTAssertNil(FluidLanguage.matching(code: "xx-XX"))
        XCTAssertNil(FluidLanguage.matching(code: ""))
    }

    // MARK: which pack gets downloaded

    /// The pruned 2828-token pack was built for six named languages and covers
    /// nothing past them, so this list is not "the Latin-script ones" however much
    /// the name suggests it. Dutch, Turkish and Vietnamese are Latin-script and
    /// still need the full vocabulary.
    func testTheLatinPackIsExactlyItsSixLanguages() {
        let latin = FluidLanguage.allCases.filter(\.usesLatinPack)
        XCTAssertEqual(Set(latin), Set([.en, .es, .fr, .it, .pt, .de]))
    }

    func testAutoTakesTheFullVocabulary() {
        // Auto-detect has to be able to decode anything, so it cannot use the
        // pruned pack.
        XCTAssertFalse(FluidLanguage.auto.usesLatinPack)
    }

    func testLatinScriptLanguagesThatStillNeedTheFullPack() {
        for language in [FluidLanguage.nl, .tr, .vi] {
            XCTAssertFalse(language.usesLatinPack,
                           "\(language.rawValue) is Latin-script but not in the pruned pack")
        }
    }

    // MARK: menu text

    func testEveryLanguageHasItsOwnDisplayName() {
        let names = FluidLanguage.allCases.map(\.displayName)
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertFalse(names.contains(where: \.isEmpty))
    }
}
