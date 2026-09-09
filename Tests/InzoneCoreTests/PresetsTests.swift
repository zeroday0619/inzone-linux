import Foundation
import XCTest
@testable import InzoneCore

final class PresetsTests: XCTestCase {
    private func withFixture(_ body: (URL, InzonePaths, SonyPresets) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inzone-presets-test-\(UUID().uuidString)")
        let paths = InzonePaths(home: directory)
        try FileManager.default.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = repository.appendingPathComponent("assets/sony-presets.json")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Run make assets for the shipped Sony preset bank.")
        }
        let bank = try Data(contentsOf: source)
        try bank.write(to: paths.assetsDirectory.appendingPathComponent("sony-presets.json"))
        try body(directory, paths, SonyPresets(paths: paths))
    }

    private func save(_ options: [String: Any], profile: String = "music", paths: InzonePaths) throws {
        let text = try JSONSupport.encode([profile: options])
        try Data(text.utf8).write(to: paths.configDirectory.appendingPathComponent("profile-settings.json"))
    }

    func testShippedPresetsLoadFromInstalledAssetDirectory() throws {
        try withFixture { _, paths, presets in
            XCTAssertEqual(SonyPresets.names.count, 7)
            XCTAssertEqual(Set(SonyPresets.names), Set(SonyPresets.labels.keys))
            for name in SonyPresets.names {
                _ = try SettingsStore(paths: paths).updated(ProfileOptions(), with: presets.preset(name))
            }
            XCTAssertEqual(try presets.preset("bass_boost")["eq"] as? [Int], [12, 12, 8, 0, 0, 0, 0, 0, 0, 0])
            XCTAssertEqual(try presets.preset("flat")["output_alc"] as? Bool, false)
            XCTAssertEqual(try presets.preset("immersion_flat")["sound_mode"] as? String, "immersive")
            XCTAssertThrowsError(try presets.preset("missing"))
        }
    }

    func testEveryPresetRoundTripsThroughWindows() throws {
        try withFixture { directory, paths, presets in
            let file = directory.appendingPathComponent("windows.json")
            let settings = SettingsStore(paths: paths)
            for name in SonyPresets.names {
                var options = try presets.preset(name)
                options["drc"] = 2
                try save(options, paths: paths)
                try presets.exportWindows(profile: "music", to: file)
                let result = try XCTUnwrap(presets.readWindows(file).first)
                XCTAssertEqual(result.name, "music")
                XCTAssertFalse(result.surround)
                XCTAssertEqual(
                    try settings.updated(ProfileOptions(), with: result.options),
                    try settings.updated(ProfileOptions(), with: options), name
                )
                let data = try Data(contentsOf: file)
                let exported = try XCTUnwrap(JSONSupport.decode(data) as? [[String: Any]])
                XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(exported[0]["ProfileID"] as? String)))
                XCTAssertEqual(data.last, 0x0A)
            }
            try save(presets.preset("immersion_flat"), profile: "surround", paths: paths)
            try presets.exportWindows(profile: "surround", to: file)
            XCTAssertTrue(try XCTUnwrap(presets.readWindows(file).first).surround)
        }
    }

    func testWindowsJSONCWithBOMPreservesStringsAndAcceptsCaseInsensitiveFields() throws {
        try withFixture { directory, _, presets in
            let file = directory.appendingPathComponent("windows.json")
            let text = #"""
            [/* opening comment */ {
                "pRoFiLeNaMe": "a,//x /* untouched */,} \"quoted\"",
                "eQpReSeT": "4", // numeric enum
                "SuRrOuNd": true,
                "DyNaMiCrAnGeCoMpReSsIoN": "hIgH",
            },]
            """#
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(text.utf8))
            try data.write(to: file)
            let result = try XCTUnwrap(presets.readWindows(file).first)
            XCTAssertEqual(result.name, #"a,//x /* untouched */,} "quoted""#)
            XCTAssertTrue(result.surround)
            XCTAssertEqual(result.options["drc"] as? Int, 2)
            XCTAssertEqual(result.options["eq"] as? [Int], try presets.preset("fps1")["eq"] as? [Int])
        }
    }

    func testCustomWindowsEqualizerAcceptsIntegerStringsAndIntegralNumbers() throws {
        try withFixture { directory, _, presets in
            let file = directory.appendingPathComponent("windows.json")
            let text = #"[{"EQPreset":0,"EQAxis":"1","EQGain_31_5Hz":"-12","EQGain_1kHz":12.0,"DynamicRangeCompression":1}]"#
            try Data(text.utf8).write(to: file)
            let result = try XCTUnwrap(presets.readWindows(file).first)
            XCTAssertEqual(result.name, "Windows profile")
            XCTAssertFalse(result.surround)
            XCTAssertEqual(result.options["eq"] as? [Int], [-12, 0, 0, 0, 0, 12, 0, 0, 0, 0])
            XCTAssertEqual(result.options["sound_mode"] as? String, "immersive")
            XCTAssertEqual(result.options["output_alc"] as? Bool, true)
            XCTAssertEqual(result.options["eq_enable"] as? Bool, true)
            XCTAssertEqual(result.options["base_eq"] as? Bool, false)
            XCTAssertEqual(result.options["drc"] as? Int, 1)
        }
    }

    func testWindowsRejectsInvalidEnumsBooleanTypesNamesAndGains() throws {
        try withFixture { directory, _, presets in
            let file = directory.appendingPathComponent("windows.json")
            let invalid: [[String: Any]] = [
                ["EQPreset": 88], ["EQPreset": true], ["EQPreset": 4.5], ["EQPreset": NSNull()],
                ["EQPreset": "unknown"], ["EQPreset": "-1"], ["Surround": 1], ["Surround": "true"],
                ["Surround": NSNull()], ["ProfileName": false], ["ProfileName": String(repeating: "a", count: 257)],
                ["EQPreset": "CUSTOM", "EQAxis": true], ["DynamicRangeCompression": true],
                ["DynamicRangeCompression": 3],
                ["EQPreset": "CUSTOM", "EQGain_1kHz": true],
                ["EQPreset": "CUSTOM", "EQGain_1kHz": 50],
                ["EQPreset": "CUSTOM", "EQGain_1kHz": -13],
                ["EQPreset": "CUSTOM", "EQGain_1kHz": 1.5],
                ["EQPreset": "CUSTOM", "EQGain_1kHz": "1.5"],
                ["EQPreset": "CUSTOM", "EQGain_1kHz": NSNull()],
            ]
            for item in invalid {
                try Data(JSONSupport.encode([item]).utf8).write(to: file)
                XCTAssertThrowsError(try presets.readWindows(file), "\(item)")
            }
        }
    }

    func testWindowsImportEnforcesArrayFileAndEncodingLimits() throws {
        try withFixture { directory, _, presets in
            let file = directory.appendingPathComponent("windows.json")
            for text in ["[]", "{}", "[null]", "[[]]", "[1]", "[{}] /* unclosed", "[{}] extra"] {
                try Data(text.utf8).write(to: file)
                XCTAssertThrowsError(try presets.readWindows(file), text)
            }
            try Data(JSONSupport.encode(Array(repeating: [:] as [String: Any], count: 257)).utf8).write(to: file)
            XCTAssertThrowsError(try presets.readWindows(file))
            try Data(JSONSupport.encode(Array(repeating: [:] as [String: Any], count: 256)).utf8).write(to: file)
            XCTAssertEqual(try presets.readWindows(file).count, 256)
            var data = Data("[{}]".utf8)
            data.append(Data(repeating: 0x20, count: 1024 * 1024 - data.count))
            try data.write(to: file)
            XCTAssertEqual(try presets.readWindows(file).count, 1)
            data.append(0x20)
            try data.write(to: file)
            XCTAssertThrowsError(try presets.readWindows(file))
            try Data([0xFF]).write(to: file)
            XCTAssertThrowsError(try presets.readWindows(file))
            XCTAssertThrowsError(try presets.readWindows(directory))
        }
    }

    func testExportRejectsLossyOptionsBeforeWriting() throws {
        try withFixture { directory, paths, presets in
            let file = directory.appendingPathComponent("windows.json")
            let invalid: [(String, [String: Any])] = [
                ("music", ["mic_agc": true]), ("music", ["hrtf": "personal"]),
                ("music", ["output_alc": true]), ("music", ["eq_enable": true]),
                ("music", ["sound_mode": "immersive"]), ("fps", [:]), ("voice", [:]),
            ]
            for (profile, options) in invalid {
                try save(options, profile: profile, paths: paths)
                XCTAssertThrowsError(try presets.exportWindows(profile: profile, to: file), "\(profile): \(options)")
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
            XCTAssertThrowsError(try presets.exportWindows(profile: "direct", to: file))
        }
    }

    func testMalformedAssetBankIsRejected() throws {
        try withFixture { _, paths, presets in
            let file = paths.assetsDirectory.appendingPathComponent("sony-presets.json")
            for bank: [String: Any] in [[:], ["presets": ["flat": ["output_alc": 1]]]] {
                try Data(JSONSupport.encode(bank).utf8).write(to: file)
                XCTAssertThrowsError(try presets.preset("flat"))
            }
        }
    }
}
