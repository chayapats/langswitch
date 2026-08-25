import Foundation
import Darwin

struct HIDKeyMapping: Codable, Equatable {
    let source: UInt64
    let destination: UInt64

    enum CodingKeys: String, CodingKey {
        case source = "HIDKeyboardModifierMappingSrc"
        case destination = "HIDKeyboardModifierMappingDst"
    }
}

struct HIDPropertyPayload: Codable, Equatable {
    let mappings: [HIDKeyMapping]

    enum CodingKeys: String, CodingKey {
        case mappings = "UserKeyMapping"
    }
}

enum HIDMappingPolicy {
    static let capsLockUsage: UInt64 = 0x700000039
    static let f18Usage: UInt64 = 0x70000006D

    /// Temporarily replaces any Caps Lock source mapping while preserving every other map.
    static func activeMappings(from baseline: [HIDKeyMapping]) -> [HIDKeyMapping] {
        baseline.filter { $0.source != capsLockUsage } + [
            HIDKeyMapping(source: capsLockUsage, destination: f18Usage),
        ]
    }
}

enum HIDUtilCompatibility {
    /// macOS 27+ `hidutil property --get/--set` prints a per-device table instead of one
    /// OpenStep value. Scope both operations to keyboards so we do not dump every HID service.
    static let perDeviceTableMajorVersion = 27

    static func usesPerDevicePropertyTable(
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Bool {
        version.majorVersion >= perDeviceTableMajorVersion
    }

    static func propertyArguments(
        getting key: String,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [String] {
        if usesPerDevicePropertyTable(version: version) {
            return ["property", "--matching", "keyboard", "--get", key]
        }
        return ["property", "--get", key]
    }

    static func propertyArguments(
        setting payload: String,
        version: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> [String] {
        if usesPerDevicePropertyTable(version: version) {
            return ["property", "--matching", "keyboard", "--set", payload]
        }
        return ["property", "--set", payload]
    }
}

enum HIDMappingCodec {
    static func decodeHIDUtilOutput(_ data: Data) throws -> [HIDKeyMapping] {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isEmptyMappingText(text) {
            return []
        }

        // Detect by shape, not only by OS version: the table format is what actually
        // breaks the classic plist decoder, and hidutil may emit it independently of
        // the marketing version string.
        if looksLikeRegistryTable(text) {
            return try decodeRegistryTable(text)
        }

        return try decodeSingleValue(text)
    }

    static func encodeSetPayload(_ mappings: [HIDKeyMapping]) throws -> String {
        let data = try JSONEncoder().encode(HIDPropertyPayload(mappings: mappings))
        guard let json = String(data: data, encoding: .utf8) else {
            throw HIDMappingError.invalidOutput("Could not encode keyboard mappings")
        }
        return json
    }

    private static func isEmptyMappingText(_ text: String) -> Bool {
        text.isEmpty || text == "(null)" || text == "null"
    }

    private static func looksLikeRegistryTable(_ text: String) -> Bool {
        guard let firstLine = text.split(whereSeparator: \.isNewline).first else {
            return false
        }
        return firstLine.contains("RegistryID")
            && firstLine.contains("Key")
            && firstLine.contains("Value")
    }

    private static func decodeRegistryTable(_ text: String) throws -> [HIDKeyMapping] {
        let regex = try NSRegularExpression(
            pattern: #"^(?:0x)?[0-9a-fA-F]+[ \t]+UserKeyMapping[ \t]+"#,
            options: .anchorsMatchLines
        )
        let nsText = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: nsText.length)
        )
        guard !matches.isEmpty else { return [] }

        var devices: [[HIDKeyMapping]] = []
        devices.reserveCapacity(matches.count)
        for (index, match) in matches.enumerated() {
            let start = match.range.upperBound
            let end = index + 1 < matches.count
                ? matches[index + 1].range.lowerBound
                : nsText.length
            let value = nsText.substring(with: NSRange(location: start, length: end - start))
            devices.append(try decodeSingleValue(value))
        }
        return mergeDeviceMappings(devices)
    }

    private static func mergeDeviceMappings(_ devices: [[HIDKeyMapping]]) -> [HIDKeyMapping] {
        var seen: Set<UInt64> = []
        var merged: [HIDKeyMapping] = []
        for mappings in devices {
            for mapping in mappings {
                if seen.insert(mapping.source).inserted {
                    merged.append(mapping)
                }
            }
        }
        return merged
    }

    private static func decodeSingleValue(_ text: String) throws -> [HIDKeyMapping] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isEmptyMappingText(trimmed) {
            return []
        }

        let data = Data(trimmed.utf8)
        if let payload = try? JSONDecoder().decode(HIDPropertyPayload.self, from: data) {
            return payload.mappings
        }
        if let mappings = try? JSONDecoder().decode([HIDKeyMapping].self, from: data) {
            return mappings
        }

        return try decodePropertyListMappings(data)
    }

    private static func decodePropertyListMappings(_ data: Data) throws -> [HIDKeyMapping] {
        let propertyList: Any
        do {
            var format = PropertyListSerialization.PropertyListFormat.openStep
            propertyList = try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: &format
            )
        } catch {
            throw HIDMappingError.invalidOutput("Unexpected hidutil property-list shape")
        }

        let rawMappings: [Any]
        if let array = propertyList as? [Any] {
            rawMappings = array
        } else if let dictionary = propertyList as? [String: Any],
                  let array = dictionary["UserKeyMapping"] as? [Any] {
            rawMappings = array
        } else {
            throw HIDMappingError.invalidOutput("Unexpected hidutil property-list shape")
        }

        return try rawMappings.map { item in
            guard let dictionary = item as? [String: Any],
                  let source = uint64(dictionary["HIDKeyboardModifierMappingSrc"]),
                  let destination = uint64(dictionary["HIDKeyboardModifierMappingDst"])
            else {
                throw HIDMappingError.invalidOutput("Invalid keyboard mapping entry")
            }
            return HIDKeyMapping(source: source, destination: destination)
        }
    }

    private static func uint64(_ value: Any?) -> UInt64? {
        if let number = value as? NSNumber {
            guard number.int64Value >= 0 else { return nil }
            return number.uint64Value
        }
        if let string = value as? String {
            return UInt64(string)
        }
        return nil
    }
}

enum HIDMappingError: LocalizedError {
    case commandFailed(exitCode: Int32, message: String)
    case invalidOutput(String)
    case watchdogLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(exitCode, message):
            return "hidutil failed (exit \(exitCode)): \(message)"
        case let .invalidOutput(message):
            return "Could not safely preserve the current keyboard mapping: \(message)"
        case let .watchdogLaunchFailed(message):
            return "Could not start the Caps Lock restore watchdog: \(message)"
        }
    }
}

/// Owns the temporary mapping and a child watchdog. The watchdog is the same signed
/// executable in a non-GUI mode; it restores the baseline if the GUI process disappears.
public final class HIDMappingManager {
    private static let hidutilURL = URL(fileURLWithPath: "/usr/bin/hidutil")
    private static let watchdogFlag = "--restore-hid-mapping-watchdog"

    private var baseline: [HIDKeyMapping]?
    private var watchdog: Process?
    private var watchdogInput: Pipe?
    private var isApplied = false

    public init() {}

    public func activate() throws {
        guard !isApplied else { return }

        // Preserve every mapping exactly, even if the user already maps Caps Lock to F18.
        // Guessing that such a mapping is stale could destroy intentional user state.
        let original = try Self.readMappings()
        let active = HIDMappingPolicy.activeMappings(from: original)

        // Start the watchdog before mutating global state so there is no crash window
        // in which Caps Lock can be left remapped without an independent restorer.
        let (child, childInput) = try Self.launchWatchdog(restoring: original)

        do {
            try Self.setMappings(active)
        } catch {
            if (try? Self.setMappings(original)) != nil {
                child.terminate()
                try? childInput.fileHandleForWriting.close()
            }
            throw error
        }

        baseline = original
        watchdog = child
        watchdogInput = childInput
        isApplied = true
    }

    @discardableResult
    public func restoreOriginal() -> Bool {
        guard let baseline else { return true }

        do {
            try Self.setMappings(baseline)
            isApplied = false
            self.baseline = nil
            watchdog?.terminate()
            try? watchdogInput?.fileHandleForWriting.close()
            watchdog = nil
            watchdogInput = nil
            return true
        } catch {
            // Keep the watchdog alive. Once this process exits it retries the restore
            // independently for ten seconds.
            return false
        }
    }

    private static func readMappings() throws -> [HIDKeyMapping] {
        let result = try runHIDUtil(
            HIDUtilCompatibility.propertyArguments(getting: "UserKeyMapping")
        )
        return try HIDMappingCodec.decodeHIDUtilOutput(result)
    }

    private static func setMappings(_ mappings: [HIDKeyMapping]) throws {
        let payload = try HIDMappingCodec.encodeSetPayload(mappings)
        _ = try runHIDUtil(HIDUtilCompatibility.propertyArguments(setting: payload))
    }

    private static func runHIDUtil(_ arguments: [String]) throws -> Data {
        let process = Process()
        let combinedOutput = Pipe()

        process.executableURL = hidutilURL
        process.arguments = arguments
        process.standardOutput = combinedOutput
        process.standardError = combinedOutput

        try process.run()
        // Drain while hidutil is running so an unexpectedly large result cannot fill a
        // pipe buffer and deadlock this process before waitUntilExit().
        let output = combinedOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HIDMappingError.commandFailed(
                exitCode: process.terminationStatus,
                message: message.isEmpty ? "unknown error" : message
            )
        }

        return output
    }

    private static func launchWatchdog(
        restoring mappings: [HIDKeyMapping]
    ) throws -> (process: Process, input: Pipe) {
        guard let executableURL = Bundle.main.executableURL else {
            throw HIDMappingError.watchdogLaunchFailed("missing executable URL")
        }

        let encodedMappings: String
        do {
            encodedMappings = try JSONEncoder().encode(mappings).base64EncodedString()
        } catch {
            throw HIDMappingError.watchdogLaunchFailed(error.localizedDescription)
        }

        let process = Process()
        let input = Pipe()
        process.executableURL = executableURL
        process.arguments = [watchdogFlag, encodedMappings]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw HIDMappingError.watchdogLaunchFailed(error.localizedDescription)
        }

        return (process, input)
    }

    /// Returns nil for normal GUI launches. Watchdog launches block on a pipe whose writer
    /// belongs only to the GUI. A crash or force-quit closes it in the kernel, triggering
    /// restoration without relying on a reusable process ID.
    public static func watchdogExitCodeIfRequested(
        arguments: [String] = CommandLine.arguments
    ) -> Int32? {
        guard arguments.count == 3, arguments[1] == watchdogFlag else { return nil }
        guard let mappingData = Data(base64Encoded: arguments[2]),
              let mappings = try? JSONDecoder().decode([HIDKeyMapping].self, from: mappingData)
        else {
            return 2
        }

        _ = FileHandle.standardInput.readDataToEndOfFile()

        for _ in 0..<40 {
            if (try? setMappings(mappings)) != nil {
                return 0
            }
            usleep(250_000)
        }

        return 1
    }
}
