import XCTest
@testable import LangSwitchCore

final class HIDMappingTests: XCTestCase {
    func testNullOutputMeansNoMappings() throws {
        XCTAssertEqual(
            try HIDMappingCodec.decodeHIDUtilOutput(Data("(null)\n".utf8)),
            []
        )
    }

    func testDecodesOpenStepOutputFromHIDUtil() throws {
        let output = """
        (
            {
                HIDKeyboardModifierMappingSrc = 30064771129;
                HIDKeyboardModifierMappingDst = 30064771181;
            }
        )
        """

        XCTAssertEqual(
            try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8)),
            [HIDKeyMapping(source: 30064771129, destination: 30064771181)]
        )
    }

    func testDecodesJSONPayload() throws {
        let output = """
        {"UserKeyMapping":[{"HIDKeyboardModifierMappingSrc":1,"HIDKeyboardModifierMappingDst":2}]}
        """

        XCTAssertEqual(
            try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8)),
            [HIDKeyMapping(source: 1, destination: 2)]
        )
    }

    func testRejectsNegativeOpenStepValues() {
        let output = """
        (
            {
                HIDKeyboardModifierMappingSrc = -1;
                HIDKeyboardModifierMappingDst = 2;
            }
        )
        """

        XCTAssertThrowsError(
            try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8))
        )
    }

    func testActiveMappingPreservesUnrelatedMappingsAndTemporarilyReplacesCapsLock() {
        let unrelated = HIDKeyMapping(source: 10, destination: 20)
        let customCaps = HIDKeyMapping(source: HIDMappingPolicy.capsLockUsage, destination: 123)

        XCTAssertEqual(
            HIDMappingPolicy.activeMappings(from: [unrelated, customCaps]),
            [
                unrelated,
                HIDKeyMapping(
                    source: HIDMappingPolicy.capsLockUsage,
                    destination: HIDMappingPolicy.f18Usage
                ),
            ]
        )
    }

    func testSetPayloadRoundTripsWithoutShellEscaping() throws {
        let mappings = [HIDKeyMapping(source: 10, destination: 20)]
        let payload = try HIDMappingCodec.encodeSetPayload(mappings)

        XCTAssertEqual(
            try HIDMappingCodec.decodeHIDUtilOutput(Data(payload.utf8)),
            mappings
        )
    }
}
