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

    func testWindowsCollectionPreservesStableIdentityKnownRepresentationsAndUnknownFields() throws {
        try withFixture { directory, paths, presets in
            let identifier = UUID().uuidString.uppercased()
            let source = directory.appendingPathComponent("collection.json")
            let input: [[String: Any]] = [[
                "pRoFiLeId": identifier,
                "pRoFiLeNaMe": "Imported",
                "eQpReSeT": "fps1",
                "EQAxis": "0",
                "EQGain_1kHz": "7",
                "Surround": false,
                "DynamicRangeCompression": "HIGH",
                "FutureSetting": ["enabled": true, "values": [1, 2, 3]],
            ]]
            try Data(JSONSupport.encode(input).utf8).write(to: source)

            let records = try presets.importWindowsCollection(source)
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].identifier, identifier)
            XCTAssertEqual(records[0].name, "Imported")
            try SoundProfileStore(paths: paths).replace(with: records)
            try SoundProfileStore(paths: paths).rename(identifier, to: "Renamed")

            let destination = directory.appendingPathComponent("exported.json")
            try presets.exportWindowsCollection(try SoundProfileStore(paths: paths).load(), to: destination)
            let output = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: destination)) as? [[String: Any]])
            let profile = try XCTUnwrap(output.first)
            XCTAssertEqual(profile["ProfileID"] as? String, identifier)
            XCTAssertEqual(profile["ProfileName"] as? String, "Renamed")
            XCTAssertEqual(profile["eQpReSeT"] as? String, "fps1")
            XCTAssertEqual(profile["EQAxis"] as? String, "0")
            XCTAssertEqual(profile["EQGain_1kHz"] as? String, "7")
            XCTAssertEqual(
                (profile["FutureSetting"] as? [String: Any])?["enabled"] as? Bool, true
            )
        }
    }

    func testWindowsCollectionCanonicalizesChangedKnownFieldsWithoutDroppingExtensions() throws {
        try withFixture { directory, paths, presets in
            let source = directory.appendingPathComponent("collection.json")
            let input: [[String: Any]] = [[
                "ProfileID": UUID().uuidString.lowercased(), "ProfileName": "Imported",
                "EQPreset": "FPS1", "Surround": false, "DynamicRangeCompression": "OFF",
                "Extension": ["value": "retained"],
            ]]
            try Data(JSONSupport.encode(input).utf8).write(to: source)
            var records = try presets.importWindowsCollection(source)
            records[0].options.drc = 2

            let destination = directory.appendingPathComponent("exported.json")
            try presets.exportWindowsCollection(records, to: destination)
            let profile = try XCTUnwrap(
                (JSONSupport.decode(Data(contentsOf: destination)) as? [[String: Any]])?.first
            )
            XCTAssertEqual(profile["ProfileID"] as? String, records[0].identifier)
            XCTAssertEqual(profile["ProfileName"] as? String, "Imported")
            XCTAssertEqual(profile["EQPreset"] as? String, "FPS1")
            XCTAssertEqual(profile["DynamicRangeCompression"] as? String, "HIGH")
            XCTAssertEqual((profile["Extension"] as? [String: Any])?["value"] as? String, "retained")
            XCTAssertEqual(try presets.readWindows(destination).first?.options["drc"] as? Int, 2)
        }
    }

    func testWindowsCollectionRoundTripsMaximumCountAndOrder() throws {
        try withFixture { directory, _, presets in
            let input = (0..<256).map { index in
                [
                    "ProfileID": UUID().uuidString.lowercased(),
                    "ProfileName": "Profile \(index)", "EQPreset": "FLAT",
                    "Surround": false, "DynamicRangeCompression": "OFF",
                ] as [String: Any]
            }
            let source = directory.appendingPathComponent("maximum-collection.json")
            let destination = directory.appendingPathComponent("maximum-export.json")
            try Data(JSONSupport.encode(input).utf8).write(to: source)

            let records = try presets.importWindowsCollection(source)
            try presets.exportWindowsCollection(records, to: destination)
            let output = try presets.readWindows(destination)

            XCTAssertEqual(output.count, 256)
            XCTAssertEqual(output.map(\.identifier), input.map { $0["ProfileID"] as? String })
            XCTAssertEqual(output.map(\.name), (0..<256).map { "Profile \($0)" })
        }
    }

    func testWindowsCollectionPreservesEveryLinuxRoutingTemplate() throws {
        try withFixture { directory, paths, presets in
            let flat = try SettingsStore(paths: paths).updated(
                ProfileOptions(), with: presets.preset("flat")
            )
            let templates = SettingsStore.profiles
            let records = templates.map { template in
                SoundProfileRecord(
                    identifier: UUID().uuidString.lowercased(), name: template,
                    templateProfile: template, options: flat
                )
            }
            let file = directory.appendingPathComponent("linux-templates.json")

            try presets.exportWindowsCollection(records, to: file)
            let imported = try presets.importWindowsCollection(file)

            XCTAssertEqual(imported.map(\.identifier), records.map(\.identifier))
            XCTAssertEqual(imported.map(\.templateProfile), templates)
            let raw = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: file)) as? [[String: Any]])
            XCTAssertEqual(
                raw.compactMap { $0["x-inzone-linux-template-profile"] as? String },
                templates
            )
        }
    }

    func testWindowsCollectionExportSizeMatchesImporterAndPreservesDestination() throws {
        try withFixture { directory, paths, presets in
            let flat = try SettingsStore(paths: paths).updated(
                ProfileOptions(), with: presets.preset("flat")
            )
            let sourceFields: [String: Any] = [
                "ProfileID": UUID().uuidString.lowercased(), "ProfileName": "Large",
                "EQPreset": "FLAT", "Surround": false,
                "DynamicRangeCompression": "OFF",
                "FuturePayload": String(repeating: "x", count: 15_000_000),
            ]
            let source = directory.appendingPathComponent("near-limit-input.json")
            try Data(JSONSupport.encode([sourceFields], pretty: false).utf8).write(to: source)
            let imported = try presets.importWindowsCollection(source)
            var record = try XCTUnwrap(imported.first)
            record = SoundProfileRecord(
                identifier: record.identifier, name: record.name,
                templateProfile: "music", options: flat, windowsSource: record.windowsSource
            )
            let readable = directory.appendingPathComponent("readable-large.json")
            try presets.exportWindowsCollection([record], to: readable)
            XCTAssertLessThanOrEqual(
                try Data(contentsOf: readable).count, SonyPresets.maximumWindowsCollectionSize
            )
            XCTAssertEqual(try presets.readWindows(readable).count, 1)

            try SoundProfileStore(paths: paths).save([record])
            let single = directory.appendingPathComponent("single-large.json")
            try presets.exportWindows(profile: record.identifier, to: single)
            XCTAssertLessThanOrEqual(
                try Data(contentsOf: single).count, SonyPresets.maximumWindowsCollectionSize
            )
            XCTAssertEqual(try presets.readWindows(single).count, 1)

            let destination = directory.appendingPathComponent("preserved.json")
            try Data("preserved\n".utf8).write(to: destination)
            var clone = record
            clone = SoundProfileRecord(
                identifier: UUID().uuidString.lowercased(), name: "Clone",
                templateProfile: clone.templateProfile, options: clone.options,
                windowsSource: clone.windowsSource
            )
            XCTAssertThrowsError(try presets.exportWindowsCollection([record, clone], to: destination))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "preserved\n")
        }
    }

    func testWindowsCollectionRejectsEveryRecognizedDuplicateField() throws {
        try withFixture { directory, _, presets in
            let recognized = [
                "ProfileID", "ProfileName", "EQPreset", "EQAxis", "Surround",
                "DynamicRangeCompression", "x-inzone-linux-template-profile",
                "EQGain_31_5Hz", "EQGain_63Hz", "EQGain_125Hz", "EQGain_250Hz",
                "EQGain_500Hz", "EQGain_1kHz", "EQGain_2kHz", "EQGain_4kHz",
                "EQGain_8kHz", "EQGain_16kHz",
            ]
            let source = directory.appendingPathComponent("duplicates.json")
            for field in recognized {
                let variant = field == field.lowercased() ? field.uppercased() : field.lowercased()
                for text in [
                    #"[{"# + field + #"":null,"# + field + #"":null}]"#,
                    #"[{"# + field + #"":null,"# + variant + #"":null}]"#,
                ] {
                    try Data(text.utf8).write(to: source)
                    XCTAssertThrowsError(try presets.readWindows(source), field)
                }
            }
            let escaped = #"[{"ProfileID":"one","Profile\u0049D":"two"}]"#
            try Data(escaped.utf8).write(to: source)
            XCTAssertThrowsError(try presets.readWindows(source))
        }
    }

    func testWindowsDuplicateScannerIgnoresNestedObjectsStringsAndComments() throws {
        try withFixture { directory, _, presets in
            let source = directory.appendingPathComponent("nested-keys.json")
            let text = #"""
            [{
                "ProfileName": "Valid 한국어",
                "EQPreset": "FLAT",
                "Future": {"ProfileID": "one", "profileid": "two"},
                "Text": "\"ProfileID\":\"not a key\"",
                /* "ProfileName": "comment" */
            }]
            """#
            try Data(text.utf8).write(to: source)
            XCTAssertEqual(try presets.readWindows(source).first?.name, "Valid 한국어")
        }
    }

    func testWindowsImportRestoresSameInstallTemplateByIdentifier() throws {
        try withFixture { directory, _, presets in
            let identifier = UUID().uuidString.lowercased()
            let existing = SoundProfileRecord(
                identifier: identifier.uppercased(), name: "Existing",
                templateProfile: "music", options: ProfileOptions()
            )
            let source = directory.appendingPathComponent("stripped-template.json")
            let fields: [[String: Any]] = [[
                "ProfileID": identifier, "ProfileName": "Imported",
                "EQPreset": "FLAT", "Surround": false,
                "DynamicRangeCompression": "OFF",
            ]]
            try Data(JSONSupport.encode(fields).utf8).write(to: source)

            XCTAssertEqual(
                try presets.importWindowsCollection(source, existingRecords: [existing]).first?.templateProfile,
                "music"
            )
            XCTAssertEqual(
                try presets.importWindowsCollection(source).first?.templateProfile,
                "balanced"
            )
            var surroundFields = fields
            surroundFields[0]["ProfileID"] = UUID().uuidString.lowercased()
            surroundFields[0]["Surround"] = true
            try Data(JSONSupport.encode(surroundFields).utf8).write(to: source)
            XCTAssertEqual(
                try presets.importWindowsCollection(source).first?.templateProfile,
                "surround"
            )
        }
    }

    func testWindowsProfileNamesRejectUnsafeUnicodeAndPreserveValidUnicode() throws {
        try withFixture { directory, _, presets in
            let source = directory.appendingPathComponent("name.json")
            for name in ["line\nfeed", "escape\u{1B}[31m", "bidi\u{202E}override", "join\u{200D}er",
                         "line\u{2028}separator", "paragraph\u{2029}separator"] {
                try Data(JSONSupport.encode([["ProfileName": name, "EQPreset": "FLAT"]]).utf8).write(to: source)
                XCTAssertThrowsError(try presets.readWindows(source), String(reflecting: name))
            }
            let valid = "한국어 العربية 😀"
            try Data(JSONSupport.encode([["ProfileName": valid, "EQPreset": "FLAT"]]).utf8).write(to: source)
            XCTAssertEqual(try presets.readWindows(source).first?.name, valid)
        }
    }

    func testWindowsExportOverwritePoliciesAreAtomic() throws {
        try withFixture { directory, _, presets in
            let destination = directory.appendingPathComponent("export.json")
            try Data("preserved\n".utf8).write(to: destination)
            XCTAssertThrowsError(
                try presets.exportWindowsCollection([], to: destination, allowOverwrite: false)
            )
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "preserved\n")

            let created = directory.appendingPathComponent("created.json")
            try presets.exportWindowsCollection([], to: created, allowOverwrite: false)
            XCTAssertEqual(try presets.readWindows(created).count, 0)

            try presets.exportWindowsCollection([], to: destination, allowOverwrite: true)
            XCTAssertEqual(try presets.readWindows(destination).count, 0)
            XCTAssertThrowsError(
                try presets.exportWindows(profile: "music", to: destination, allowOverwrite: false)
            )
            XCTAssertEqual(try presets.readWindows(destination).count, 0)
        }
    }

    func testWindowsCollectionGeneratesStableUniqueIdentifiers() throws {
        try withFixture { directory, _, presets in
            let duplicate = UUID().uuidString.uppercased()
            let input: [[String: Any]] = [
                ["ProfileName": "Missing", "EQPreset": "FLAT"],
                ["ProfileID": "not-a-uuid", "ProfileName": "Invalid", "EQPreset": "FLAT"],
                ["ProfileID": duplicate, "ProfileName": "First", "EQPreset": "FLAT"],
                ["ProfileID": duplicate.lowercased(), "ProfileName": "Duplicate", "EQPreset": "FLAT"],
                ["ProfileName": "Missing", "EQPreset": "FLAT"],
            ]
            let source = directory.appendingPathComponent("identifiers.json")
            try Data(JSONSupport.encode(input).utf8).write(to: source)

            let first = try presets.importWindowsCollection(source)
            let second = try presets.importWindowsCollection(source)
            XCTAssertEqual(first.map(\.identifier), second.map(\.identifier))
            XCTAssertNotEqual(first[2].identifier.lowercased(), duplicate.lowercased())
            XCTAssertEqual(Set(first.map { $0.identifier.lowercased() }).count, input.count)
            XCTAssertTrue(first.allSatisfy { UUID(uuidString: $0.identifier) != nil })

            let reordered: [[String: Any]] = [
                ["ProfileName": "Inserted", "EQPreset": "FLAT"], input[1], input[0],
            ]
            let reorderedSource = directory.appendingPathComponent("identifiers-reordered.json")
            try Data(JSONSupport.encode(reordered).utf8).write(to: reorderedSource)
            let reorderedProfiles = try presets.importWindowsCollection(reorderedSource)
            let originalByName = Dictionary(uniqueKeysWithValues: first.prefix(2).map { ($0.name, $0.identifier) })
            let reorderedByName = Dictionary(uniqueKeysWithValues: reorderedProfiles.map { ($0.name, $0.identifier) })
            XCTAssertEqual(reorderedByName["Missing"], originalByName["Missing"])
            XCTAssertEqual(reorderedByName["Invalid"], originalByName["Invalid"])

            let duplicateReorderedSource = directory.appendingPathComponent("duplicates-reordered.json")
            let duplicateReordered = [input[3], input[2], input[0], input[1], input[4]]
            try Data(JSONSupport.encode(duplicateReordered).utf8).write(to: duplicateReorderedSource)
            let duplicateReorderedProfiles = try presets.importWindowsCollection(duplicateReorderedSource)
            let firstDuplicateIDs = Dictionary(uniqueKeysWithValues: first[2...3].map { ($0.name, $0.identifier) })
            let reorderedDuplicateIDs = Dictionary(uniqueKeysWithValues:
                duplicateReorderedProfiles.prefix(2).map { ($0.name, $0.identifier) }
            )
            XCTAssertEqual(reorderedDuplicateIDs, firstDuplicateIDs)
        }
    }

    func testEmptyWindowsCollectionRoundTripsAndClearsStoredProfiles() throws {
        try withFixture { directory, paths, presets in
            let store = SoundProfileStore(paths: paths)
            try store.save([
                SoundProfileRecord(
                    identifier: UUID().uuidString.lowercased(), name: "Existing",
                    templateProfile: "balanced", options: ProfileOptions()
                ),
            ])
            let source = directory.appendingPathComponent("empty.json")
            let destination = directory.appendingPathComponent("empty-export.json")
            try Data("[]\n".utf8).write(to: source)

            let imported = try presets.importWindowsCollection(source)
            XCTAssertEqual(imported, [])
            try store.replace(with: imported)
            XCTAssertEqual(try store.load(), [])
            try presets.exportWindowsCollection(try store.load(), to: destination)
            XCTAssertEqual(try presets.readWindows(destination).count, 0)
        }
    }

    func testWindowsCollectionExportRejectsInvalidPublicRecordsBeforeWriting() throws {
        try withFixture { directory, _, presets in
            let destination = directory.appendingPathComponent("existing.json")
            try Data("preserved\n".utf8).write(to: destination)
            let invalid = SoundProfileRecord(
                identifier: UUID().uuidString.lowercased(), name: "Invalid",
                templateProfile: "balanced", options: ProfileOptions(drc: 99)
            )

            XCTAssertThrowsError(try presets.exportWindowsCollection([invalid], to: destination))
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "preserved\n")
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
            for text in ["{}", "[null]", "[[]]", "[1]", "[{}] /* unclosed", "[{}] extra"] {
                try Data(text.utf8).write(to: file)
                XCTAssertThrowsError(try presets.readWindows(file), text)
            }
            try Data(JSONSupport.encode(Array(repeating: [:] as [String: Any], count: 257)).utf8).write(to: file)
            XCTAssertThrowsError(try presets.readWindows(file))
            try Data(JSONSupport.encode(Array(repeating: [:] as [String: Any], count: 256)).utf8).write(to: file)
            XCTAssertEqual(try presets.readWindows(file).count, 256)
            var data = Data("[{}]".utf8)
            data.append(Data(repeating: 0x20, count: SonyPresets.maximumWindowsCollectionSize - data.count))
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
