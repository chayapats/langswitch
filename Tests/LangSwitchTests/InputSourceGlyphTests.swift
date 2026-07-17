import XCTest
@testable import LangSwitchCore

final class InputSourceGlyphTests: XCTestCase {
    func testThaiMapsToThaiGlyph() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: "th", localizedName: "Thai — Kedmanee"),
            "ก"
        )
    }

    func testEnglishMapsToLatinAa() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: "en", localizedName: "ABC"),
            "Aa"
        )
    }

    func testUnmappedCodeUppercasesPrimarySubtag() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: "de", localizedName: "German"),
            "DE"
        )
    }

    func testBCP47CodeUsesPrimarySubtag() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: "zh-Hans", localizedName: "Pinyin"),
            "ZH"
        )
    }

    func testMapLookupIsCaseInsensitive() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: "TH", localizedName: "Thai"),
            "ก"
        )
    }

    func testMissingCodeUsesFirstCharacterOfName() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: nil, localizedName: "Pinyin"),
            "P"
        )
    }

    func testEmptyCodeBehavesLikeMissingCode() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: "", localizedName: "Pinyin"),
            "P"
        )
    }

    func testMissingCodeAndEmptyNameFallsBackToQuestionMark() {
        XCTAssertEqual(
            indicatorGlyph(languageCode: nil, localizedName: ""),
            "?"
        )
    }
}
