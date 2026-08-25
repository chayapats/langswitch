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

    func testOldMacOSUsesClassicHIDUtilArguments() {
        let version = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        XCTAssertEqual(
            HIDUtilCompatibility.propertyArguments(getting: "UserKeyMapping", version: version),
            ["property", "--get", "UserKeyMapping"]
        )
        XCTAssertEqual(
            HIDUtilCompatibility.propertyArguments(setting: "{\"UserKeyMapping\":[]}", version: version),
            ["property", "--set", "{\"UserKeyMapping\":[]}"]
        )
    }

    func testMacOS27UsesKeyboardMatchingHIDUtilArguments() {
        let version = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(
            HIDUtilCompatibility.propertyArguments(getting: "UserKeyMapping", version: version),
            ["property", "--matching", "keyboard", "--get", "UserKeyMapping"]
        )
        XCTAssertEqual(
            HIDUtilCompatibility.propertyArguments(setting: "{\"UserKeyMapping\":[]}", version: version),
            ["property", "--matching", "keyboard", "--set", "{\"UserKeyMapping\":[]}"]
        )
    }

    func testDecodesMacOS27NullRegistryTable() throws {
        let output = """
        RegistryID  Key                   Value
        10000556b   UserKeyMapping   (null)
        100000cdf   UserKeyMapping   (null)
        100001389   UserKeyMapping   (null)
        """

        XCTAssertEqual(try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8)), [])
    }

    func testDecodesMacOS27EmptyArrayRegistryTable() throws {
        let output = """
        RegistryID  Key                   Value
        10000556b   UserKeyMapping   (
        )
        100000cdf   UserKeyMapping   (
        )
        100001389   UserKeyMapping   (
        )
        """

        XCTAssertEqual(try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8)), [])
    }

    func testDecodesMacOS27MappedRegistryTableAndDeduplicatesDevices() throws {
        let output = """
        RegistryID  Key                   Value
        10000556b   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        100000cdf   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        100001389   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingDst = 30064771181;
                HIDKeyboardModifierMappingSrc = 30064771129;
            }
        )
        """

        XCTAssertEqual(
            try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8)),
            [HIDKeyMapping(source: 30064771129, destination: 30064771181)]
        )
    }

    func testMergesDistinctDeviceMappingsFromRegistryTable() throws {
        let output = """
        RegistryID  Key                   Value
        10000556b   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingSrc = 10;
                HIDKeyboardModifierMappingDst = 20;
            }
        )
        100000cdf   UserKeyMapping   (null)
        100001389   UserKeyMapping   (
                {
                HIDKeyboardModifierMappingSrc = 30;
                HIDKeyboardModifierMappingDst = 40;
            }
        )
        """

        XCTAssertEqual(
            try HIDMappingCodec.decodeHIDUtilOutput(Data(output.utf8)),
            [
                HIDKeyMapping(source: 10, destination: 20),
                HIDKeyMapping(source: 30, destination: 40),
            ]
        )
    }
}
