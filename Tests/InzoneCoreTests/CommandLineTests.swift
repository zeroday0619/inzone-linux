import Foundation
import Glibc
import XCTest
@testable import InzoneCore

final class CommandLineTests: XCTestCase {
    private static var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private struct CommandResult {
        let status: Int32
        let output: String
        let error: String
    }

    private final class Fixture {
        let directory: URL
        let paths: InzonePaths
        let binary: URL
        var environment: [String: String]

        init(binary source: URL) throws {
            let manager = FileManager.default
            directory = manager.temporaryDirectory.appendingPathComponent("inzone-command-test-\(UUID().uuidString)")
            paths = InzonePaths(home: directory.appendingPathComponent("desktop user's home"))
            binary = directory.appendingPathComponent("inzone-profile")
            let commands = directory.appendingPathComponent("commands")
            environment = ["HOME": paths.home.path, "PATH": commands.path, "LANG": "C.UTF-8"]
            do {
                try manager.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
                try manager.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
                try manager.createDirectory(at: paths.activeProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.createDirectory(at: commands, withIntermediateDirectories: true)
                for name in ["fps", "music", "voice", "balanced", "original"] {
                    let data = try Data(contentsOf: CommandLineTests.repository.appendingPathComponent("configs/\(name).conf"))
                    try data.write(to: paths.configDirectory.appendingPathComponent("\(name).conf"))
                }
                try Data(contentsOf: paths.configDirectory.appendingPathComponent("balanced.conf")).write(to: paths.activeProfile)
                try manager.createDirectory(
                    at: paths.pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try Data().write(to: paths.pluginURL)
                let downmixChannels = Dictionary(uniqueKeysWithValues: FilterBank.channels.map {
                    ($0.name, [$0.azimuth, $0.polar])
                })
                try Data(JSONSupport.encode([
                    "rate": 48000, "taps": 512, "downmix_channels": downmixChannels,
                ]).utf8).write(to: paths.assetsDirectory.appendingPathComponent("manifest.json"))
                let downmix = paths.assetsDirectory.appendingPathComponent("downmix", isDirectory: true)
                try manager.createDirectory(at: downmix, withIntermediateDirectories: true)
                for channel in GraphRenderer.channels {
                    try Data().write(to: downmix.appendingPathComponent(channel + ".wav"))
                }
                let presets = CommandLineTests.repository.appendingPathComponent("assets/sony-presets.json")
                if manager.fileExists(atPath: presets.path) {
                    try Data(contentsOf: presets).write(
                        to: paths.assetsDirectory.appendingPathComponent("sony-presets.json")
                    )
                }
                // Copying bytes keeps each fixture independent of source symlinks and build artifacts.
                try Data(contentsOf: source).write(to: binary)
                try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
                for (name, command) in [
                    "pw-dump": "printf '[]\\n'", "pactl": "printf 'previous-sink\\n'", "systemctl": "exit 0",
                ] {
                    let script = commands.appendingPathComponent(name)
                    try Data(("#!/bin/sh\n" + command + "\n").utf8).write(to: script)
                    try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
                }
            } catch {
                try? manager.removeItem(at: directory)
                throw error
            }
        }

        deinit { try? FileManager.default.removeItem(at: directory) }

        @discardableResult
        func command(
            _ arguments: [String], success: Bool = true, file: StaticString = #filePath, line: UInt = #line
        ) throws -> CommandResult {
            let identifier = UUID().uuidString
            let outputURL = directory.appendingPathComponent("stdout-\(identifier)")
            let errorURL = directory.appendingPathComponent("stderr-\(identifier)")
            try Data().write(to: outputURL)
            try Data().write(to: errorURL)
            defer {
                try? FileManager.default.removeItem(at: outputURL)
                try? FileManager.default.removeItem(at: errorURL)
            }
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? error.close() }
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.environment = environment
            process.currentDirectoryURL = directory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error
            try process.run()
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            let timedOut = process.isRunning
            if timedOut {
                process.terminate()
                let deadline = ProcessInfo.processInfo.systemUptime + 0.5
                while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                    Thread.sleep(forTimeInterval: 0.01)
                }
                if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
            }
            process.waitUntilExit()
            let result = CommandResult(
                status: process.terminationStatus,
                output: String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
                error: String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            )
            if timedOut {
                throw InzoneError.message("CLI command timed out: \(arguments.joined(separator: " "))")
            }
            if success {
                XCTAssertEqual(result.status, 0, "\(arguments): \(result.error)", file: file, line: line)
                XCTAssertEqual(result.error, "", file: file, line: line)
            } else {
                XCTAssertNotEqual(result.status, 0, "\(arguments)", file: file, line: line)
            }
            return result
        }

        func settings() throws -> [String: [String: Any]] {
            let output = try command(["--settings"]).output
            return try XCTUnwrap(JSONSupport.decode(Data(output.utf8)) as? [String: [String: Any]])
        }
    }

    private func withFixture(_ body: (Fixture) throws -> Void) throws {
        let binary: URL
        if let override = ProcessInfo.processInfo.environment["INZONE_TEST_BINARY"], !override.isEmpty {
            binary = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: binary.path) else {
                throw InzoneError.message("INZONE_TEST_BINARY is not an executable file: \(binary.path)")
            }
        } else {
            let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("inzone-profile")
            let candidates = [sibling, Self.repository.appendingPathComponent(".build/debug/inzone-profile")]
            guard let available = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
                throw XCTSkip("Build the inzone-profile executable before running CLI integration tests.")
            }
            binary = available
        }
        try body(Fixture(binary: binary))
    }

    private func assertTerminalSafeError(
        _ output: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let scalars = Array(output.unicodeScalars)
        XCTAssertEqual(scalars.last?.value, 0x0A, file: file, line: line)
        XCTAssertEqual(scalars.filter { $0.value == 0x0A }.count, 1, file: file, line: line)
        let prohibitedScalars = scalars.dropLast().filter { scalar in
            let value = scalar.value
            let category = scalar.properties.generalCategory
            return value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .surrogate
        }
        XCTAssertTrue(prohibitedScalars.isEmpty, "Raw terminal controls: \(prohibitedScalars)", file: file, line: line)
    }

    private func assertTerminalSafeJSON(
        _ output: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let prohibitedScalars = output.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value == 0x0A { return false }
            let category = scalar.properties.generalCategory
            return value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .surrogate
        }
        XCTAssertTrue(prohibitedScalars.isEmpty, "Raw terminal controls: \(prohibitedScalars)", file: file, line: line)
        XCTAssertFalse(output.contains("\\u{"), "JSON contains nonstandard Unicode escapes.", file: file, line: line)
    }

    func testRelocatedBinaryReadsHelpSettingsStatusAndPresetNamesWithEmptyCommandPath() throws {
        try withFixture { fixture in
            fixture.environment["PATH"] = fixture.directory.appendingPathComponent("missing").path
            XCTAssertTrue(try fixture.command(["--help"]).output.contains("Usage: inzone-profile"))
            XCTAssertTrue(try fixture.settings().isEmpty)
            XCTAssertEqual(try fixture.command(["--status"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "balanced")
            let presets = try fixture.command(["--preset"]).output
            let labels = try XCTUnwrap(JSONSupport.decode(Data(presets.utf8)) as? [String: String])
            XCTAssertNotNil(labels["bass_boost"])
        }
    }

    func testOptionUpdateExportImportAndManualSwitchToken() throws {
        try withFixture { fixture in
            try fixture.command(["--set", "music", "drc", "2"])
            XCTAssertEqual(try fixture.command(["--status"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "music")
            XCTAssertEqual(try fixture.settings()["music"]?["drc"] as? Int, 2)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.configDirectory.appendingPathComponent("manual-switch").path))
            let destination = fixture.directory.appendingPathComponent("a user's settings.json")
            try fixture.command(["--export", destination.path])
            let exported = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: destination)) as? [String: [String: Any]])
            XCTAssertEqual(exported["music"]?["drc"] as? Int, 2)
            try Data(#"{"balanced":{"mic_agc":true}}"#.utf8).write(to: destination)
            try fixture.command(["--import", destination.path])
            XCTAssertEqual(try fixture.settings()["balanced"]?["mic_agc"] as? Bool, true)
            let settingsFile = fixture.paths.configDirectory.appendingPathComponent("profile-settings.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: settingsFile.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testInvalidOptionsPreserveSettingsAndActiveProfileBytes() throws {
        try withFixture { fixture in
            try fixture.command(["--set", "music", "drc", "1"])
            let settingsFile = fixture.paths.configDirectory.appendingPathComponent("profile-settings.json")
            let beforeSettings = try Data(contentsOf: settingsFile)
            let beforeProfile = try Data(contentsOf: fixture.paths.activeProfile)
            for (key, value) in [("drc", "true"), ("drc", "1.5"), ("mic_agc", "1"), ("eq", "[0]"), ("missing", "0")] {
                try fixture.command(["--set", "music", key, value], success: false)
                XCTAssertEqual(try Data(contentsOf: settingsFile), beforeSettings, "\(key)=\(value)")
                XCTAssertEqual(try Data(contentsOf: fixture.paths.activeProfile), beforeProfile, "\(key)=\(value)")
            }
        }
    }

    func testAutomationRuleRoundTripPreservesExecutableIdentity() throws {
        try withFixture { fixture in
            let identity = #"C:\a user's games\game.exe"#
            try fixture.command(["--auto-bind", identity, "fps", "20"])
            let firstOutput = try fixture.command(["--auto-config"]).output
            let first = try XCTUnwrap(JSONSupport.decode(Data(firstOutput.utf8)) as? [[String: Any]])
            XCTAssertEqual(first.count, 1)
            XCTAssertEqual(first.first?["app"] as? String, identity)
            XCTAssertEqual(first.first?["profile"] as? String, "fps")
            XCTAssertEqual(first.first?["priority"] as? Int, 20)
            try fixture.command(["--auto-bind", identity, "music", "-2"])
            let secondOutput = try fixture.command(["--auto-config"]).output
            let second = try XCTUnwrap(JSONSupport.decode(Data(secondOutput.utf8)) as? [[String: Any]])
            XCTAssertEqual(second.count, 1)
            XCTAssertEqual(second.first?["app"] as? String, identity)
            XCTAssertEqual(second.first?["profile"] as? String, "music")
            XCTAssertEqual(second.first?["priority"] as? Int, -2)
            try fixture.command(["--auto-remove", identity])
            let finalOutput = try fixture.command(["--auto-config"]).output
            XCTAssertTrue(try XCTUnwrap(JSONSupport.decode(Data(finalOutput.utf8)) as? [Any]).isEmpty)
        }
    }

    func testCustomProfileCLIUsesStableIdentifiersAndDeletionGuards() throws {
        try withFixture { fixture in
            let created = try fixture.command(["--profile-create", "Custom", "music"])
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertNotNil(UUID(uuidString: created))
            let clone = try fixture.command(["--profile-clone", created, "Clone"])
                .output.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertNotEqual(clone, created)
            try fixture.command(["--profile-rename", created, "Renamed"])

            let profiles = try XCTUnwrap(JSONSupport.decode(
                Data(try fixture.command(["--profiles"]).output.utf8)
            ) as? [[String: Any]])
            XCTAssertEqual(profiles.count, SettingsStore.profiles.count + 2)
            XCTAssertEqual(profiles.first { $0["id"] as? String == created }?["name"] as? String, "Renamed")

            try fixture.command(["--auto-bind", "game", created])
            try fixture.command(["--profile-delete", created], success: false)
            try fixture.command(["--auto-remove", "game"])
            try fixture.command(["--profile-delete", created])
            let remaining = try XCTUnwrap(JSONSupport.decode(
                Data(try fixture.command(["--profiles"]).output.utf8)
            ) as? [[String: Any]])
            XCTAssertNil(remaining.first { $0["id"] as? String == created })
            XCTAssertNotNil(remaining.first { $0["id"] as? String == clone })
        }
    }

    func testWindowsCollectionCLIAppendsFreshIDsAndExplicitReplacePreservesIDs() throws {
        try withFixture { fixture in
            let identifier = UUID().uuidString.uppercased()
            let source = fixture.directory.appendingPathComponent("collection.json")
            let destination = fixture.directory.appendingPathComponent("exported-collection.json")
            let input: [[String: Any]] = [[
                "ProfileID": identifier, "ProfileName": "Imported", "EQPreset": "FLAT",
                "Surround": false, "DynamicRangeCompression": "OFF",
                "Future": ["value": 7],
            ]]
            try Data(JSONSupport.encode(input).utf8).write(to: source)

            try fixture.command(["--windows-import-collection", source.path])
            try fixture.command(["--windows-export-collection", destination.path])

            let output = try XCTUnwrap(
                (JSONSupport.decode(Data(contentsOf: destination)) as? [[String: Any]])?.first
            )
            let appendedIdentifier = try XCTUnwrap(output["ProfileID"] as? String)
            XCTAssertNotNil(UUID(uuidString: appendedIdentifier))
            XCTAssertNotEqual(appendedIdentifier.lowercased(), identifier.lowercased())
            XCTAssertEqual(output["ProfileName"] as? String, "Imported")
            XCTAssertEqual((output["Future"] as? [String: Any])?["value"] as? Int, 7)

            try fixture.command(["--windows-replace-collection", source.path])
            let before = try Data(contentsOf: destination)
            try fixture.command(["--windows-export-collection", destination.path], success: false)
            XCTAssertEqual(try Data(contentsOf: destination), before)
            try fixture.command(["--windows-export-collection", destination.path, "--force"])
            let replaced = try XCTUnwrap(
                (JSONSupport.decode(Data(contentsOf: destination)) as? [[String: Any]])?.first
            )
            XCTAssertEqual(replaced["ProfileID"] as? String, identifier)
            XCTAssertEqual((replaced["Future"] as? [String: Any])?["value"] as? Int, 7)
        }
    }

    func testFirmwareMutationCommandsAndInvalidDeviceFieldsFailBeforeDeviceAccess() throws {
        try withFixture { fixture in
            for command in ["--firmware-update", "--update-firmware", "--flash-firmware", "--firmware-download"] {
                let result = try fixture.command([command], success: false)
                XCTAssertTrue(result.error.contains("intentionally not implemented"), command)
            }
            let invalid = try fixture.command(["--device-set", "firmware", "1"], success: false)
            XCTAssertTrue(invalid.error.contains("Unknown device field or out-of-range value: firmware"))
            XCTAssertFalse(invalid.error.contains("HID"))
            let h9IIMicrophoneSet = try fixture.command(
                ["--device-set", "headset_microphone_mute", "1"], success: false
            )
            XCTAssertTrue(h9IIMicrophoneSet.error.contains(
                "Unknown device field or out-of-range value: headset_microphone_mute"
            ))
            XCTAssertFalse(h9IIMicrophoneSet.error.contains("HID"))
            let invalidBalance = try fixture.command(
                ["--device-set", "game_chat", "51"], success: false
            )
            XCTAssertTrue(invalidBalance.error.contains(
                "Unknown device field or out-of-range value: game_chat"
            ))
            XCTAssertFalse(invalidBalance.error.contains("HID"))
        }
    }

    func testPersonalizationCleanupCommandsReportEmptyState() throws {
        try withFixture { fixture in
            let status = try fixture.command(["--personalize-cleanup-status"]).output
            XCTAssertEqual(try JSONSupport.decode(Data(status.utf8)) as? [String], [])
            XCTAssertEqual(
                try fixture.command(["--personalize-cleanup"]).output,
                "Retired personal filter banks were cleaned.\n"
            )
        }
    }

    func testAutomationOutputEscapesTerminalControlsWithoutChangingRuleIdentity() throws {
        try withFixture { fixture in
            let identity = "game-\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\u{E0001}.exe"
            try fixture.command(["--auto-bind", identity, "fps", "7"])

            let output = try fixture.command(["--auto-config"]).output

            let rules = try XCTUnwrap(JSONSupport.decode(Data(output.utf8)) as? [[String: Any]])
            XCTAssertEqual(rules.first?["app"] as? String, identity)
            XCTAssertEqual(rules.first?["profile"] as? String, "fps")
            XCTAssertEqual(rules.first?["priority"] as? Int, 7)
            assertTerminalSafeJSON(output)
        }
    }

    func testWindowsCustomImportAndExportWithSyntheticEqualizerTable() throws {
        try withFixture { fixture in
            let source = fixture.directory.appendingPathComponent("windows.json")
            try Data(#"[{"ProfileName":"Custom","EQPreset":"CUSTOM","EQGain_1kHz":3}]"#.utf8).write(to: source)
            XCTAssertTrue(try fixture.command(["--windows-list", source.path]).output.contains("Custom"))
            let bands = ["31_5", "63", "125", "250", "500", "1000", "2000", "4000", "8000", "16000"]
            let rows = Array(repeating: [0, 0, 1, 0, 0, 0, 0], count: 25)
            let table = ["tables": Dictionary(uniqueKeysWithValues: bands.map { ($0, rows) })]
            let tableFile = fixture.paths.assetsDirectory.appendingPathComponent("sony-eq-tables.json")
            try Data(JSONSupport.encode(table).utf8).write(to: tableFile)
            try fixture.command(["--windows-import", "music", source.path, "1"])
            let destination = fixture.directory.appendingPathComponent("exported.json")
            try fixture.command(["--windows-export", "music", destination.path])
            let profiles = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: destination)) as? [[String: Any]])
            XCTAssertEqual(profiles.count, 1)
            XCTAssertEqual(profiles.first?["EQPreset"] as? String, "CUSTOM")
            XCTAssertEqual(profiles.first?["EQGain_1kHz"] as? Int, 3)
        }
    }

    func testWindowsListRejectsTerminalControlsInProfileNamesSafely() throws {
        try withFixture { fixture in
            let name = "\u{C708}\u{B3C4}\u{C6B0}-\u{0001}\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\u{E0001}-\u{D504}\u{B85C}\u{D544}"
            let source = fixture.directory.appendingPathComponent("windows-terminal-controls.json")
            let input: [[String: Any]] = [["ProfileName": name, "EQPreset": "CUSTOM"]]
            try Data(JSONSupport.encode(input).utf8).write(to: source)

            let result = try fixture.command(["--windows-list", source.path], success: false)

            XCTAssertEqual(result.output, "")
            XCTAssertTrue(result.error.contains("no control or format characters"))
            assertTerminalSafeError(result.error)
        }
    }

    func testStatusEscapesTerminalControlsFromActiveProfileHeader() throws {
        try withFixture { fixture in
            let suffix = "custom-\u{0001}\u{001B}\u{007F}\u{0086}\u{202E}-profile"
            try Data(("# INZONE profile: \(suffix)\n{}").utf8).write(to: fixture.paths.activeProfile)

            let output = try fixture.command(["--status"]).output

            XCTAssertEqual(output, TerminalOutput.escaped(suffix, preservingNewlines: false) + "\n")
            assertTerminalSafeError(output)
        }
    }

    func testPersonalizationImportEscapesDestinationPath() throws {
        try withFixture { fixture in
            let payload = Self.repository.appendingPathComponent("analysis/payload")
            let library = payload.appendingPathComponent("inzonevirtualizer.dll")
            let hki = payload.appendingPathComponent("shp_for_game_v2.0_512tap.hki")
            let ba = payload.appendingPathComponent("wh_g910n_standard.ba")
            for input in [library, hki, ba] where !FileManager.default.fileExists(atPath: input.path) {
                throw XCTSkip("Locally acquired asset is absent: \(input.lastPathComponent)")
            }
            let unsafeHome = fixture.directory.appendingPathComponent(
                "home-\u{0001}\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}"
            )
            let paths = InzonePaths(home: unsafeHome)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            fixture.environment["HOME"] = unsafeHome.path

            let output = try fixture.command(["--personalize-import", hki.path, ba.path]).output

            let expected = TerminalOutput.escaped(
                paths.shareDirectory.appendingPathComponent("personal").path, preservingNewlines: false
            ) + "\n"
            XCTAssertEqual(output, expected)
            assertTerminalSafeError(output)
        }
    }

    func testWindowsEnumErrorsEscapeTerminalControlsAndPreserveUnicode() throws {
        try withFixture { fixture in
            let source = fixture.directory.appendingPathComponent("windows-invalid-enum.json")
            let cases: [(field: String, json: String)] = [
                (
                    "EQPreset",
                    #"[{"EQPreset":"\#u{C815}\#u{C0C1} Unicode\n\u001B[31m\u0007\u007F\u0085\u202E\u2028\u2029\#u{B05D}"}]"#
                ),
                (
                    "EQAxis",
                    #"[{"EQPreset":"CUSTOM","EQAxis":"\#u{C815}\#u{C0C1} Unicode\n\u001B[31m\u0007\u007F\u0085\u202E\u2028\u2029\#u{B05D}"}]"#
                ),
                (
                    "DynamicRangeCompression",
                    #"[{"EQPreset":"CUSTOM","DynamicRangeCompression":"\#u{C815}\#u{C0C1} Unicode\n\u001B[31m\u0007\u007F\u0085\u202E\u2028\u2029\#u{B05D}"}]"#
                ),
            ]
            let expected = #"Unknown Windows setting value: \#u{C815}\#u{C0C1} Unicode\u{000A}\u{001B}[31m\u{0007}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\#u{B05D}"# + "\n"

            for item in cases {
                try Data(item.json.utf8).write(to: source)
                let result = try fixture.command(["--windows-list", source.path], success: false)
                XCTAssertEqual(result.status, 1, item.field)
                XCTAssertEqual(result.output, "", item.field)
                XCTAssertEqual(result.error, expected, item.field)
                assertTerminalSafeError(result.error)
            }
        }
    }

    func testRestoreArgumentValidationAndNoninteractiveTerminalGuard() throws {
        try withFixture { fixture in
            try fixture.command(["restore"])
            XCTAssertEqual(try fixture.command(["--status"]).output.trimmingCharacters(in: .whitespacesAndNewlines), "original")
            for arguments in [["unknown"], ["--status", "extra"], ["--set"], ["--auto-bind", "app"]] {
                try fixture.command(arguments, success: false)
            }
            let terminal = try fixture.command(["--tui"], success: false)
            XCTAssertTrue(terminal.error.contains("requires an interactive terminal"))
        }
    }
}
