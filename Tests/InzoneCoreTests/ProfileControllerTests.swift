import Foundation
import XCTest
@testable import InzoneCore

final class ProfileControllerTests: XCTestCase {
    private let restart = [
        "systemctl", "--user", "restart", "pipewire.service", "wireplumber.service",
        "pipewire-pulse.service",
    ]
    private let active = [
        "systemctl", "--user", "is-active", "pipewire.service", "wireplumber.service",
        "pipewire-pulse.service",
    ]
    private let previousSink = "previous-output"

    func testConnectedFPSVerifiesLatencyPrerollAndEQBeforeMarkingManual() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let dspLog = fixture.paths.debugLog
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink + "\n"),
            .output([
                "systemctl", "--user", "set-environment", "INZONE_DSP_DEBUG_LOG=\(dspLog.path)",
            ]),
            .output(restart), .output(active, "active\n"),
            .output(["systemctl", "--user", "unset-environment", "INZONE_DSP_DEBUG_LOG"]),
            .output(["pw-dump"], try downmixNodes(latency: 128)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-cli", "enum-params", "11", "Props"], "eq0: Gain"),
            .output(["pw-dump"], try downmixNodes(latency: 128)),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner, dspDebugLog: dspLog)

        try controller.activate("fps")

        XCTAssertEqual(try controller.status(), "fps")
        XCTAssertFalse(AutomationStore(paths: fixture.paths).manualToken().isEmpty)
        let wirePlumber = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let pipeWire = try String(contentsOf: fixture.paths.activeDSPProfile, encoding: .utf8)
        XCTAssertFalse(wirePlumber.contains("context.modules"))
        XCTAssertTrue(pipeWire.contains("libpipewire-module-filter-chain"))
        XCTAssertTrue(pipeWire.contains(GraphRenderer.downmixSink))
        runner.assertFinished()
    }

    func testVoiceRoutesAndInspectsChat() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "set-default-sink", ProfileController.chat]),
            .silence(target: ProfileController.chat),
            .output(["pw-cli", "enum-params", "12", "Props"], "eq0: Gain"),
        ])

        try ProfileController(paths: fixture.paths, runner: runner).activate("voice")

        runner.assertFinished()
    }

    func testMusicWaitsUntilBothOutputLatenciesMatch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 256)),
            .output(["pw-dump"], try downmixNodes(latency: 512, linked: false)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-dump"], try downmixNodes(latency: 512)),
        ])

        let logger = RecordingDiagnosticLogger()
        try ProfileController(paths: fixture.paths, runner: runner, logger: logger).activate("music")

        runner.assertFinished()
        XCTAssertTrue(logger.messages.contains { message in
            message.contains("attempt 1/40") && message.contains("correct_latency=false")
        })
        XCTAssertTrue(logger.messages.contains { message in
            message.contains("attempt 2/40") && message.contains("correct_latency=true")
                && message.contains("family_available=true")
        })
    }

    func testDownmixWaitsUntilEveryLayoutSinkIsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 512, completeFamily: false)),
            .output(["pw-dump"], try downmixNodes(latency: 512)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-dump"], try downmixNodes(latency: 512)),
        ])

        try ProfileController(paths: fixture.paths, runner: runner).activate("music")

        runner.assertFinished()
    }

    func testDownmixLinkDisappearingAfterSelectionRollsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 512)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-dump"], try downmixNodes(latency: 512, linked: false)),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner).activate("music")) {
            XCTAssertTrue($0.localizedDescription.contains("Downmix output is not linked"))
        }

        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testDisconnectedActivationOnlyPersistsAndRestarts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        try controller.activate("music")

        XCTAssertEqual(try controller.status(), "music")
        runner.assertFinished()
    }

    func testManualTokenFailureRollsBackSuccessfulLiveActivation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.paths.configDirectory.appendingPathComponent("manual-switch"),
            withIntermediateDirectories: false
        )
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner).activate("music"))

        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testManualTokenFailureRollsBackOptionsAndSuccessfulLiveApply() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.paths.configDirectory.appendingPathComponent("manual-switch"),
            withIntermediateDirectories: false
        )
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(
            try ProfileController(paths: fixture.paths, runner: runner)
                .changeOptions("balanced", updates: ["drc": 2])
        )

        XCTAssertTrue(try SettingsStore(paths: fixture.paths).load().isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testManualTokenFailureRollsBackImportedSettingsAndSuccessfulLiveApply() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        try FileManager.default.createDirectory(
            at: fixture.paths.configDirectory.appendingPathComponent("manual-switch"),
            withIntermediateDirectories: false
        )
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(
            try ProfileController(paths: fixture.paths, runner: runner)
                .importSettings(Data(#"{"balanced":{"drc":2}}"#.utf8))
        )

        XCTAssertTrue(try SettingsStore(paths: fixture.paths).load().isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testConnectedRestoreUsesOriginalConfigAndDefaultDSPOptions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 128)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        try controller.activate("restore")

        XCTAssertEqual(try controller.status(), "original")
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), "{}\n")
        runner.assertFinished()
    }

    func testSurroundRequiresDirectLinkToGame() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let spatial = try surroundNodes(linkedToGame: true)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], spatial),
            .output(["pactl", "set-default-sink", ProfileController.surround]),
            .silence(target: ProfileController.surround),
            .output(["pw-dump"], spatial),
        ])

        try ProfileController(paths: fixture.paths, runner: runner).activate("surround")

        runner.assertFinished()
    }

    func testSurroundWaitsUntilEveryLayoutSinkIsAvailable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let complete = try surroundNodes(linkedToGame: true)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try surroundNodes(linkedToGame: true, completeFamily: false)),
            .output(["pw-dump"], complete),
            .output(["pactl", "set-default-sink", ProfileController.surround]),
            .silence(target: ProfileController.surround),
            .output(["pw-dump"], complete),
        ])

        try ProfileController(paths: fixture.paths, runner: runner).activate("surround")

        runner.assertFinished()
    }

    func testSurroundLinkedToAnotherDeviceRollsBack() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let spatial = try surroundNodes(linkedToGame: false)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], spatial),
            .output(["pactl", "set-default-sink", ProfileController.surround]),
            .silence(target: ProfileController.surround),
            .output(["pw-dump"], spatial),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner).activate("surround")) { error in
            XCTAssertTrue(error.localizedDescription.contains("not linked to the H9 II Game output"))
        }

        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testPrerollTimeoutRollsBackWithoutCheckingDSP() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 128)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink, timedOut: true),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        XCTAssertThrowsError(try controller.activate("fps")) { error in
            XCTAssertTrue((error as? CommandError)?.timedOut == true)
        }

        XCTAssertEqual(try controller.status(), "balanced")
        runner.assertFinished()
    }

    func testRollbackFailureRetainsOriginalActivationError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 128)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-cli", "enum-params", "11", "Props"], "volume: 1.0"),
            .failure(restart),
            .output(["systemctl", "--user", "show", "wireplumber.service", "-p", "Result", "--value"], "exit-code"),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        XCTAssertThrowsError(try controller.activate("fps")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Base equalizer loading verification failed"))
            XCTAssertTrue(error.localizedDescription.contains("Rollback also failed"))
            XCTAssertTrue(error.localizedDescription.contains("simulated command failure"))
        }

        XCTAssertEqual(try controller.status(), "balanced")
        runner.assertFinished()
    }

    func testStartLimitHitResetsFailureAndRetriesRestart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .failure(restart),
            .output(["systemctl", "--user", "show", "wireplumber.service", "-p", "Result", "--value"], "start-limit-hit\n"),
            .output(["systemctl", "--user", "reset-failed", "wireplumber.service"]),
            .output(restart), .output(active),
        ])

        try ProfileController(paths: fixture.paths, runner: runner).activate("balanced")

        runner.assertFinished()
    }

    func testOtherRestartFailureRollsBackWithoutResetFailed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .failure(restart),
            .output(["systemctl", "--user", "show", "wireplumber.service", "-p", "Result", "--value"], "exit-code\n"),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner).activate("fps"))

        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        XCTAssertEqual(AutomationStore(paths: fixture.paths).manualToken(), "")
        runner.assertFinished()
    }

    func testMissingBaseEQRestoresConfigAndPreviousSink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let previousDSP = try String(contentsOf: fixture.paths.activeDSPProfile, encoding: .utf8)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 128)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-cli", "enum-params", "11", "Props"], "volume: 1.0"),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner).activate("fps")) { error in
            XCTAssertTrue(String(describing: error).contains("Base equalizer loading verification failed."))
        }

        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeDSPProfile, encoding: .utf8), previousDSP)
        XCTAssertEqual(AutomationStore(paths: fixture.paths).manualToken(), "")
        runner.assertFinished()
    }

    func testFailedOptionsChangeRestoresSettingsConfigAndSink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = SettingsStore(paths: fixture.paths)
        let initial = try settings.decode(Data(#"{"music":{"mic_agc":true}}"#.utf8))
        try settings.save(initial)
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 256)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-cli", "enum-params", "11", "Props"], "volume: 1.0"),
            .output(restart),
            .failure(["pactl", "set-default-sink", previousSink]),
            .output(["pactl", "set-default-sink", previousSink]),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        XCTAssertThrowsError(try controller.changeOptions("balanced", updates: ["drc": 2]))

        XCTAssertEqual(try settings.load().keys.sorted(), ["music"])
        XCTAssertTrue(try settings.options("music").microphoneAGC)
        XCTAssertEqual(try settings.options("balanced").drc, 0)
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testSuccessfulOptionsChangeVerifiesAdditionalDSP() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodes(latency: 256)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-cli", "enum-params", "11", "Props"], "game_drc: Mode\noutput_alc: Enable"),
            .output(["pw-dump"], try downmixNodes(latency: 256)),
        ])

        try ProfileController(paths: fixture.paths, runner: runner)
            .changeOptions("balanced", updates: ["drc": 2, "output_alc": true])

        XCTAssertEqual(try SettingsStore(paths: fixture.paths).options("balanced").drc, 2)
        XCTAssertTrue(try SettingsStore(paths: fixture.paths).options("balanced").outputALC)
        runner.assertFinished()
    }

    func testFailedImportRestoresPreviousSettingsAndActiveConfig() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .failure(active),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner)
            .importSettings(Data(#"{"balanced":{"drc":2}}"#.utf8)))

        XCTAssertTrue(try SettingsStore(paths: fixture.paths).load().isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testImportWhileOriginalIsActiveDoesNotRestartOrMarkManual() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("{}\n".utf8).write(to: fixture.paths.activeProfile)
        let runner = ScriptedRunner([])

        try ProfileController(paths: fixture.paths, runner: runner)
            .importSettings(Data(#"{"balanced":{"drc":1}}"#.utf8))

        XCTAssertEqual(try SettingsStore(paths: fixture.paths).options("balanced").drc, 1)
        XCTAssertEqual(AutomationStore(paths: fixture.paths).manualToken(), "")
        runner.assertFinished()
    }

    func testAutomaticSwitchRechecksManualTokenBeforeAnyCommands() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("new-token".utf8).write(to: fixture.paths.configDirectory.appendingPathComponent("manual-switch"))
        let runner = ScriptedRunner([])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        XCTAssertThrowsError(try controller.activate("fps", automatic: true, autoToken: "old-token"))

        XCTAssertEqual(try controller.status(), "balanced")
        runner.assertFinished()
    }

    func testAutomaticSwitchDoesNotOverwriteMatchingManualToken() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try Data("same-token".utf8).write(to: fixture.paths.configDirectory.appendingPathComponent("manual-switch"))
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
        ])

        try ProfileController(paths: fixture.paths, runner: runner)
            .activate("music", automatic: true, autoToken: "same-token")

        XCTAssertEqual(AutomationStore(paths: fixture.paths).manualToken(), "same-token")
        runner.assertFinished()
    }

    func testCustomProfileCRUDRejectsActiveAndAutomationReferencedDeletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let profile = try controller.createProfile(name: "Custom", basedOn: "music")
        try controller.renameProfile(profile.identifier, to: "Renamed")
        XCTAssertEqual(try controller.availableProfiles().last?.name, "Renamed")

        let automation = AutomationStore(paths: fixture.paths)
        try automation.edit(app: "game", profile: profile.identifier)
        XCTAssertThrowsError(try controller.deleteProfile(profile.identifier))
        try automation.edit(app: "game", profile: nil)

        try Data(("# INZONE profile: \(profile.identifier)\n{}\n").utf8).write(to: fixture.paths.activeProfile)
        XCTAssertThrowsError(try controller.deleteProfile(profile.identifier))
        try Data("# INZONE profile: balanced\n{}\n".utf8).write(to: fixture.paths.activeProfile)
        try controller.deleteProfile(profile.identifier)
        XCTAssertNil(try SoundProfileStore(paths: fixture.paths).profile(profile.identifier))
    }

    func testOfflineDeleteAndEmptyImportDoNotRequireAnActiveConfigurationFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let deleted = try controller.createProfile(name: "Delete", basedOn: "music")
        _ = try controller.createProfile(name: "Clear", basedOn: "voice")
        try FileManager.default.removeItem(at: fixture.paths.activeProfile)

        try controller.deleteProfile(deleted.identifier)
        let empty = fixture.paths.home.appendingPathComponent("empty-SoundProfile.json")
        try Data("[]\n".utf8).write(to: empty)
        _ = try controller.importWindowsCollection(empty, mode: .replace)

        XCTAssertTrue(try SoundProfileStore(paths: fixture.paths).load().isEmpty)
    }

    func testDefaultCollectionImportAppendsWithFreshIdentifiers() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let existing = try controller.createProfile(name: "Existing", basedOn: "music")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(contentsOf: repository.appendingPathComponent("assets/sony-presets.json")).write(
            to: fixture.paths.assetsDirectory.appendingPathComponent("sony-presets.json")
        )
        let importedIdentifier = UUID().uuidString.lowercased()
        let source = fixture.paths.home.appendingPathComponent("append.json")
        let item: [[String: Any]] = [[
            "ProfileID": importedIdentifier, "ProfileName": "Appended",
            "EQPreset": "FLAT", "Surround": false,
            "DynamicRangeCompression": "OFF",
        ]]
        try Data(JSONSupport.encode(item).utf8).write(to: source)

        let outcome = try controller.importWindowsCollection(source)

        let profiles = try SoundProfileStore(paths: fixture.paths).load()
        XCTAssertEqual(outcome, SoundProfileImportOutcome(importedCount: 1, skippedCount: 0))
        XCTAssertEqual(profiles.map(\.identifier).first, existing.identifier)
        XCTAssertEqual(profiles.last?.name, "Appended")
        XCTAssertNotEqual(profiles.last?.identifier.lowercased(), importedIdentifier)
    }

    func testAppendCollectionStopsAtMaximumAndReportsSkippedProfiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = (0..<255).map { index in
            SoundProfileRecord(
                identifier: UUID().uuidString.lowercased(), name: "Existing \(index)",
                templateProfile: "balanced", options: ProfileOptions()
            )
        }
        try SoundProfileStore(paths: fixture.paths).save(existing)
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(contentsOf: repository.appendingPathComponent("assets/sony-presets.json")).write(
            to: fixture.paths.assetsDirectory.appendingPathComponent("sony-presets.json")
        )
        let source = fixture.paths.home.appendingPathComponent("overflow-append.json")
        let items: [[String: Any]] = ["First", "Second"].map { name in
            [
                "ProfileID": UUID().uuidString.lowercased(), "ProfileName": name,
                "EQPreset": "FLAT", "Surround": false,
                "DynamicRangeCompression": "OFF",
            ]
        }
        try Data(JSONSupport.encode(items).utf8).write(to: source)

        let outcome = try ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
            .importWindowsCollection(source)

        let profiles = try SoundProfileStore(paths: fixture.paths).load()
        XCTAssertEqual(outcome, SoundProfileImportOutcome(importedCount: 1, skippedCount: 1))
        XCTAssertEqual(profiles.count, 256)
        XCTAssertEqual(profiles.last?.name, "First")
    }

    func testCollectionExportRequiresAtomicOverwriteAuthorization() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let destination = fixture.paths.home.appendingPathComponent("existing-export.json")
        try Data("preserved\n".utf8).write(to: destination)
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))

        XCTAssertThrowsError(try controller.exportWindowsCollection(destination))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "preserved\n")
        try controller.exportWindowsCollection(destination, allowOverwrite: true)
        XCTAssertEqual(try SonyPresets(paths: fixture.paths).readWindows(destination).count, 0)
    }

    func testAutomationBaselineProtectsProfileFromDeleteAndCollectionReplacement() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let profile = try controller.createProfile(name: "Baseline", basedOn: "music")
        let automation = AutomationStore(paths: fixture.paths)
        try automation.saveOwnership(AutomationOwnership(
            baseline: profile.identifier, applied: "fps", pending: nil, token: "token"
        ))

        XCTAssertThrowsError(try controller.deleteProfile(profile.identifier))
        let empty = fixture.paths.home.appendingPathComponent("empty-SoundProfile.json")
        try Data("[]\n".utf8).write(to: empty)
        XCTAssertThrowsError(try controller.importWindowsCollection(empty, mode: .replace))
        XCTAssertNotNil(try SoundProfileStore(paths: fixture.paths).profile(profile.identifier))
    }

    func testRestoreAutomationBaselineDoesNotBlockClearingCustomCollection() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        _ = try controller.createProfile(name: "Disposable", basedOn: "music")
        try AutomationStore(paths: fixture.paths).saveOwnership(AutomationOwnership(
            baseline: "restore", applied: "fps", pending: nil, token: "token"
        ))
        let empty = fixture.paths.home.appendingPathComponent("empty-SoundProfile.json")
        try Data("[]\n".utf8).write(to: empty)

        _ = try controller.importWindowsCollection(empty, mode: .replace)

        XCTAssertTrue(try SoundProfileStore(paths: fixture.paths).load().isEmpty)
    }

    func testActiveCustomCollectionRoundTripPreservesVoiceRoutingTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let profile = try controller.createProfile(name: "Voice Custom", basedOn: "voice")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(contentsOf: repository.appendingPathComponent("assets/sony-presets.json")).write(
            to: fixture.paths.assetsDirectory.appendingPathComponent("sony-presets.json")
        )
        let source = fixture.paths.home.appendingPathComponent("voice-SoundProfile.json")
        let item: [[String: Any]] = [[
            "ProfileID": profile.identifier, "ProfileName": profile.name,
            "EQPreset": "FLAT", "Surround": false,
            "DynamicRangeCompression": "OFF",
            "x-inzone-linux-template-profile": "voice",
        ]]
        try Data(JSONSupport.encode(item).utf8).write(to: source)
        let template = "# INZONE profile: voice\n{\"voice-template-marker\":true,\"node.filter-graph.rules\":[]}\n"
        try Data(template.utf8).write(to: fixture.paths.configDirectory.appendingPathComponent("voice.conf"))
        try Data(("# INZONE profile: \(profile.identifier)\n{}\n").utf8).write(to: fixture.paths.activeProfile)
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
        ])

        _ = try ProfileController(paths: fixture.paths, runner: runner)
            .importWindowsCollection(source, mode: .replace)

        XCTAssertEqual(
            try SoundProfileStore(paths: fixture.paths).profile(profile.identifier)?.templateProfile,
            "voice"
        )
        XCTAssertTrue(
            try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
                .contains(#""voice-template-marker" : true"#)
        )
        runner.assertFinished()
    }

    func testSameInstallImportPreservesTemplateWhenHubStripsLinuxExtension() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let profile = try controller.createProfile(name: "Voice Custom", basedOn: "voice")
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try Data(contentsOf: repository.appendingPathComponent("assets/sony-presets.json")).write(
            to: fixture.paths.assetsDirectory.appendingPathComponent("sony-presets.json")
        )
        let source = fixture.paths.home.appendingPathComponent("hub-stripped.json")
        let item: [[String: Any]] = [[
            "ProfileID": profile.identifier.uppercased(), "ProfileName": profile.name,
            "EQPreset": "FLAT", "Surround": false,
            "DynamicRangeCompression": "OFF",
        ]]
        try Data(JSONSupport.encode(item).utf8).write(to: source)

        _ = try controller.importWindowsCollection(source, mode: .replace)

        XCTAssertEqual(
            try SoundProfileStore(paths: fixture.paths).profile(profile.identifier)?.templateProfile,
            "voice"
        )
    }

    func testCustomProfileActivationUsesStableIdentifierAndStoredTemplate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let template = "# INZONE profile: music\n{\"template-marker\":\"music\",\"node.filter-graph.rules\":[]}\n"
        try Data(template.utf8).write(to: fixture.paths.configDirectory.appendingPathComponent("music.conf"))
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)
        let profile = try controller.createProfile(name: "../../original.conf", basedOn: "music")

        try controller.activate(profile.identifier.uppercased())

        XCTAssertEqual(try controller.status(), profile.identifier)
        let rendered = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        XCTAssertTrue(rendered.hasPrefix("# INZONE profile: \(profile.identifier)\n"))
        XCTAssertTrue(rendered.contains(#""template-marker" : "music""#))
        runner.assertFinished()
    }

    func testMissingMicrophoneAGCVerificationRestoresProfileAndSettings() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let previous = try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8)
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try downmixNodesWithMicrophone(latency: 256)),
            .output(["pactl", "set-default-sink", GraphRenderer.downmixSink]),
            .silence(target: GraphRenderer.downmixSink),
            .output(["pw-dump"], try downmixNodesWithMicrophone(latency: 256)),
            .output(["pw-cli", "enum-params", "18", "Props"], "volume: 1.0"),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(
            try ProfileController(paths: fixture.paths, runner: runner)
                .changeOptions("balanced", updates: ["mic_agc": true])
        ) { error in
            XCTAssertTrue(String(describing: error).contains("Microphone AGC loading verification failed."))
        }
        XCTAssertTrue(try SettingsStore(paths: fixture.paths).load().isEmpty)
        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
        runner.assertFinished()
    }

    func testPersonalizationResetUpdatesCustomProfilesBeforeReapplyingActiveSurround() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let personal = fixture.paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try Data("personal".utf8).write(to: personal.appendingPathComponent("marker"))
        let store = SoundProfileStore(paths: fixture.paths)
        let profile = SoundProfileRecord(
            identifier: UUID().uuidString.lowercased(), name: "Personal",
            templateProfile: "surround", options: ProfileOptions(hrtf: "personal")
        )
        try store.save([profile])
        try Data(("# INZONE profile: \(profile.identifier)\n{}\n").utf8).write(to: fixture.paths.activeProfile)
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertTrue(
            try ProfileController(paths: fixture.paths, runner: runner)
                .resetPersonalizationResult().removed
        )

        XCTAssertEqual(try store.profile(profile.identifier)?.options.hrtf, "standard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: personal.path))
        XCTAssertEqual(try ProfileController(paths: fixture.paths).status(), profile.identifier)
        runner.assertFinished()
    }

    func testPersonalizationResetRejectsUnknownAndUnmanagedActiveConfigurationsBeforeMutation() throws {
        for active in ["# INZONE profile: missing\n{}\n", "{\"unmanaged\":true}\n"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let settings = SettingsStore(paths: fixture.paths)
            try settings.save(["surround": ProfileOptions(hrtf: "personal")])
            let settingsBefore = try Data(contentsOf: fixture.paths.configDirectory.appendingPathComponent("profile-settings.json"))
            let personal = fixture.paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
            try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
            try Data("personal".utf8).write(to: personal.appendingPathComponent("marker"))
            try Data(active.utf8).write(to: fixture.paths.activeProfile)

            XCTAssertThrowsError(
                try ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
                    .resetPersonalizationResult()
            )

            XCTAssertEqual(
                try Data(contentsOf: fixture.paths.configDirectory.appendingPathComponent("profile-settings.json")),
                settingsBefore
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: personal.appendingPathComponent("marker").path))
        }
    }

    func testPersonalizationResetAcceptsManagedLegacyRestoreHeader() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = SettingsStore(paths: fixture.paths)
        try settings.save(["surround": ProfileOptions(hrtf: "personal")])
        let personal = fixture.paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: true)
        try Data("personal".utf8).write(to: personal.appendingPathComponent("marker"))
        let original = try Data(contentsOf: fixture.paths.configDirectory.appendingPathComponent("original.conf"))
        var active = Data("# INZONE profile: restore\n".utf8)
        active.append(original)
        try active.write(to: fixture.paths.activeProfile)

        XCTAssertTrue(
            try ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
                .resetPersonalizationResult().removed
        )

        XCTAssertEqual(try settings.options("surround").hrtf, "standard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: personal.path))
    }

    func testPersonalizationResetCommitsStandardSettingsWhenRetiredCleanupIsPending() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let settings = SettingsStore(paths: fixture.paths)
        try settings.save(["surround": ProfileOptions(hrtf: "personal")])
        let personal = fixture.paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        let blocked = personal.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("held".utf8).write(to: blocked.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)

        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let outcome = try controller.resetPersonalizationResult()

        XCTAssertTrue(outcome.removed)
        XCTAssertFalse(outcome.cleanupPending.isEmpty)
        XCTAssertEqual(try settings.options("surround").hrtf, "standard")
        XCTAssertFalse(FileManager.default.fileExists(atPath: personal.path))
        XCTAssertEqual(try controller.personalizationCleanupPending(), outcome.cleanupPending)
        for path in outcome.cleanupPending {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: URL(fileURLWithPath: path).appendingPathComponent("blocked").path
            )
        }
        XCTAssertTrue(try controller.retryPersonalizationCleanup().isEmpty)
    }

    func testPersonalizationResetPrecommitFailureRestoresPersonalSettingsProfileAndSink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let personal = fixture.paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.copyItem(at: fixture.paths.assetsDirectory, to: personal)
        let manifestURL = personal.appendingPathComponent("manifest.json")
        var manifest = try XCTUnwrap(
            JSONSupport.decode(Data(contentsOf: manifestURL)) as? [String: Any]
        )
        manifest["kind"] = "personal"
        try Data((JSONSupport.encode(manifest) + "\n").utf8).write(to: manifestURL)
        try Data("invalid".utf8).write(
            to: fixture.paths.shareDirectory.appendingPathComponent(".personal-retired-invalid")
        )
        let profile = SoundProfileRecord(
            identifier: UUID().uuidString.lowercased(), name: "Personal",
            templateProfile: "surround", options: ProfileOptions(hrtf: "personal")
        )
        let store = SoundProfileStore(paths: fixture.paths)
        try store.save([profile])
        let previousConfiguration = Data(
            ("# INZONE profile: \(profile.identifier)\n{\"preserved\":true}\n").utf8
        )
        try previousConfiguration.write(to: fixture.paths.activeProfile)
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pactl", "set-default-sink", previousSink]),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(
            try ProfileController(paths: fixture.paths, runner: runner).resetPersonalizationResult()
        )

        XCTAssertEqual(try store.profile(profile.identifier)?.options.hrtf, "personal")
        XCTAssertTrue(FileManager.default.fileExists(atPath: personal.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try Data(contentsOf: fixture.paths.activeProfile), previousConfiguration)
        XCTAssertEqual(try ProfileController(paths: fixture.paths).status(), profile.identifier)
        runner.assertFinished()
    }

    func testPersonalizationImportCommitsNewBankWhenRetiredCleanupIsPending() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let payload = repository.appendingPathComponent("analysis/payload")
        let library = payload.appendingPathComponent("inzonevirtualizer.dll")
        let hki = payload.appendingPathComponent("shp_for_game_v2.0_512tap.hki")
        let ba = payload.appendingPathComponent("wh_g910n_standard.ba")
        for file in [library, hki, ba] where !FileManager.default.fileExists(atPath: file.path) {
            throw XCTSkip("Locally acquired personalization asset is absent: \(file.lastPathComponent)")
        }
        let installedLibrary = fixture.paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
        try FileManager.default.createDirectory(
            at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contentsOf: library).write(to: installedLibrary)
        let personal = fixture.paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        let blocked = personal.appendingPathComponent("blocked", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: blocked.appendingPathComponent("file"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)

        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
        let outcome = try controller.importPersonalizationResult(
            hki: hki, ba: ba, allowReplacing: true
        )

        XCTAssertEqual(outcome.destination, personal)
        XCTAssertFalse(outcome.cleanupPending.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: personal.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try controller.personalizationCleanupPending(), outcome.cleanupPending)
        for path in outcome.cleanupPending {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: URL(fileURLWithPath: path).appendingPathComponent("blocked").path
            )
        }
        XCTAssertTrue(try controller.retryPersonalizationCleanup().isEmpty)
    }

    func testPersonalizationImportFailureRestoresOldBankAndReappliesActiveProfile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let payload = repository.appendingPathComponent("analysis/payload")
        let library = payload.appendingPathComponent("inzonevirtualizer.dll")
        let hki = payload.appendingPathComponent("shp_for_game_v2.0_512tap.hki")
        let ba = payload.appendingPathComponent("wh_g910n_standard.ba")
        for file in [library, hki, ba] where !FileManager.default.fileExists(atPath: file.path) {
            throw XCTSkip("Locally acquired personalization asset is absent: \(file.lastPathComponent)")
        }
        let installedLibrary = fixture.paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
        try FileManager.default.createDirectory(
            at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contentsOf: library).write(to: installedLibrary)
        let personal = try Personalization.importFiles(
            paths: fixture.paths, hki: hki, ba: ba,
            allowReplacing: false, cleanupRetiredAfterActivation: false, activate: {}
        )
        let marker = personal.appendingPathComponent("old-bank-marker")
        try Data("old".utf8).write(to: marker)
        let profile = SoundProfileRecord(
            identifier: UUID().uuidString.lowercased(), name: "Personal",
            templateProfile: "surround", options: ProfileOptions(hrtf: "personal")
        )
        try SoundProfileStore(paths: fixture.paths).save([profile])
        let previousConfiguration = Data(
            ("# INZONE profile: \(profile.identifier)\n{\"preserved-import\":true}\n").utf8
        )
        try previousConfiguration.write(to: fixture.paths.activeProfile)
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .failure(active),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(
            try ProfileController(paths: fixture.paths, runner: runner)
                .importPersonalizationResult(hki: hki, ba: ba, allowReplacing: true)
        )

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "old")
        XCTAssertEqual(try Data(contentsOf: fixture.paths.activeProfile), previousConfiguration)
        XCTAssertEqual(try ProfileController(paths: fixture.paths).status(), profile.identifier)
        runner.assertFinished()
    }

    func testPersonalizationImportSuccessPreservesActiveProfileAndPreviousDefaultSink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.prepareSurround()
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let payload = repository.appendingPathComponent("analysis/payload")
        let library = payload.appendingPathComponent("inzonevirtualizer.dll")
        let hki = payload.appendingPathComponent("shp_for_game_v2.0_512tap.hki")
        let ba = payload.appendingPathComponent("wh_g910n_standard.ba")
        for file in [library, hki, ba] where !FileManager.default.fileExists(atPath: file.path) {
            throw XCTSkip("Locally acquired personalization asset is absent: \(file.lastPathComponent)")
        }
        let installedLibrary = fixture.paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
        try FileManager.default.createDirectory(
            at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contentsOf: library).write(to: installedLibrary)
        _ = try Personalization.importFiles(
            paths: fixture.paths, hki: hki, ba: ba,
            allowReplacing: false, cleanupRetiredAfterActivation: false, activate: {}
        )
        let profile = SoundProfileRecord(
            identifier: UUID().uuidString.lowercased(), name: "Personal",
            templateProfile: "surround", options: ProfileOptions(hrtf: "personal")
        )
        try SoundProfileStore(paths: fixture.paths).save([profile])
        try Data(("# INZONE profile: \(profile.identifier)\n{}\n").utf8).write(to: fixture.paths.activeProfile)
        XCTAssertThrowsError(
            try ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))
                .importPersonalizationResult(hki: hki, ba: ba)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("confirmation"))
        }
        let runner = ScriptedRunner([
            .output(["pw-dump"], "[]"),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        let outcome = try ProfileController(paths: fixture.paths, runner: runner)
            .importPersonalizationResult(hki: hki, ba: ba, allowReplacing: true)

        XCTAssertTrue(outcome.cleanupPending.isEmpty)
        XCTAssertEqual(try ProfileController(paths: fixture.paths).status(), profile.identifier)
        runner.assertFinished()
    }

    func testCompetingSwitchFailsWithoutCommandsOrConfigChanges() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lock = try FileLock(url: fixture.paths.configDirectory.appendingPathComponent("switch.lock"))
        let runner = ScriptedRunner([])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        try withExtendedLifetime(lock) {
            XCTAssertThrowsError(try controller.activate("music"))
        }

        XCTAssertEqual(try controller.status(), "balanced")
        runner.assertFinished()
    }

    func testPersonalizationCleanupRetryRequiresSwitchLock() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let retired = fixture.paths.shareDirectory.appendingPathComponent(
            ".personal-retired-held", isDirectory: true
        )
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        var lock: FileLock? = try FileLock(
            url: fixture.paths.configDirectory.appendingPathComponent("switch.lock")
        )
        let controller = ProfileController(paths: fixture.paths, runner: ScriptedRunner([]))

        try withExtendedLifetime(lock) {
            XCTAssertThrowsError(try controller.retryPersonalizationCleanup()) { error in
                XCTAssertTrue(error.localizedDescription.contains("Another operation holds switch.lock"))
            }
        }
        lock = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: retired.path))
        XCTAssertTrue(try controller.retryPersonalizationCleanup().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
    }

    private func nodes(latency: Int) throws -> String {
        let values: [[String: Any]] = [ProfileController.game, ProfileController.chat].enumerated().map { index, name in
            [
                "id": 11 + index,
                "type": "PipeWire:Interface:Node",
                "info": ["props": ["node.name": name, "node.latency": "\(latency)/48000"]],
            ]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }

    private func downmixNodes(
        latency: Int, linked: Bool = true, completeFamily: Bool = true
    ) throws -> String {
        var values = try JSONSupport.decode(Data(nodes(latency: latency).utf8)) as! [[String: Any]]
        values.append([
            "id": 13,
            "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": GraphRenderer.downmixSink]],
        ])
        values.append([
            "id": 14,
            "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": "inzone.sony-downmix.output"]],
        ])
        if linked {
            values.append([
                "id": 15,
                "type": "PipeWire:Interface:Link",
                "info": ["output-node-id": 14, "input-node-id": 11],
            ])
        }
        values.append([
            "id": 16,
            "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": GraphRenderer.downmixFivePointOneSink]],
        ])
        if completeFamily {
            values.append([
                "id": 17,
                "type": "PipeWire:Interface:Node",
                "info": ["props": ["node.name": GraphRenderer.downmixSevenPointOneSink]],
            ])
        }
        return try JSONSupport.encode(values, pretty: false)
    }

    private func downmixNodesWithMicrophone(latency: Int) throws -> String {
        var values = try JSONSupport.decode(Data(downmixNodes(latency: latency).utf8)) as! [[String: Any]]
        values.append([
            "id": 18,
            "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": "alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat"]],
        ])
        return try JSONSupport.encode(values, pretty: false)
    }

    private func surroundNodes(
        linkedToGame: Bool, completeFamily: Bool = true
    ) throws -> String {
        var values = try JSONSupport.decode(Data(nodes(latency: 256).utf8)) as! [[String: Any]]
        values.append([
            "id": 13, "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": ProfileController.surround]],
        ])
        values.append([
            "id": 14, "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": "inzone.sony-surround.output"]],
        ])
        values.append([
            "id": 99, "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": "another-device"]],
        ])
        values.append([
            "id": 15, "type": "PipeWire:Interface:Link",
            "info": ["output-node-id": 14, "input-node-id": linkedToGame ? 11 : 99],
        ])
        values.append([
            "id": 16, "type": "PipeWire:Interface:Node",
            "info": ["props": ["node.name": GraphRenderer.surroundStereoSink]],
        ])
        if completeFamily {
            values.append([
                "id": 17, "type": "PipeWire:Interface:Node",
                "info": ["props": ["node.name": GraphRenderer.surroundFivePointOneSink]],
            ])
        }
        return try JSONSupport.encode(values, pretty: false)
    }

    private struct Fixture {
        let paths: InzonePaths

        init() throws {
            paths = InzonePaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("inzone-controller-\(UUID().uuidString)"))
            try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.activeProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: paths.activeDSPProfile.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            for profile in ProfileController.profiles {
                let text = "# INZONE profile: \(profile)\n{\"monitor.alsa.rules\": [], \"node.filter-graph.rules\": []}\n"
                try Data(text.utf8).write(to: paths.configDirectory.appendingPathComponent(profile + ".conf"))
            }
            try Data("{}\n".utf8).write(to: paths.configDirectory.appendingPathComponent("original.conf"))
            try FileManager.default.copyItem(at: paths.configDirectory.appendingPathComponent("balanced.conf"), to: paths.activeProfile)
            try Data("{}\n".utf8).write(to: paths.activeDSPProfile)
            try FileManager.default.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
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
            try FileManager.default.createDirectory(at: downmix, withIntermediateDirectories: true)
            for channel in GraphRenderer.channels {
                try Data().write(to: downmix.appendingPathComponent(channel + ".wav"))
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: paths.home)
        }

        func prepareSurround() throws {
            try FileManager.default.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: paths.pluginURL)
            try Data(#"{"rate":48000,"taps":512}"#.utf8).write(to: paths.assetsDirectory.appendingPathComponent("manifest.json"))
            let coefficients = Array(repeating: [1, 0, 0, 0, 0], count: 7)
            try JSONSerialization.data(withJSONObject: coefficients)
                .write(to: paths.assetsDirectory.appendingPathComponent("h9-ii-biquads.json"))
            // The mock PipeWire process owns loading, and graph rendering only needs existing paths.
            for channel in ["FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR"] {
                try Data().write(to: paths.assetsDirectory.appendingPathComponent(channel + ".wav"))
            }
        }
    }

    private struct Step {
        let arguments: [String]
        var output = ""
        var fails = false
        var timedOut = false
        var input: Data?
        var timeout: TimeInterval = 15

        static func output(_ arguments: [String], _ output: String = "") -> Step {
            Step(arguments: arguments, output: output)
        }

        static func failure(_ arguments: [String]) -> Step {
            Step(arguments: arguments, fails: true)
        }

        static func silence(target: String, timedOut: Bool = false) -> Step {
            Step(arguments: [
                "pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000",
                "--channels", "2", "--latency", "256", "--target", target, "-",
            ], fails: timedOut, timedOut: timedOut, input: Data(count: 4096 * 8), timeout: 8)
        }
    }

    /// Test calls are synchronous, and unexpected commands never reach the host session.
    private final class RecordingDiagnosticLogger: DiagnosticLogging, @unchecked Sendable {
        private let lock = NSLock()
        private var recordedMessages: [String] = []

        var messages: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedMessages
        }

        func log(_ message: String) {
            lock.lock()
            recordedMessages.append(message)
            lock.unlock()
        }
    }

    private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
        private var steps: [Step]

        init(_ steps: [Step]) { self.steps = steps }

        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            guard !steps.isEmpty else {
                XCTFail("Unexpected command: \(arguments)")
                throw InzoneError.message("Unexpected test command")
            }
            let step = steps.removeFirst()
            XCTAssertEqual(arguments, step.arguments)
            XCTAssertEqual(input, step.input)
            XCTAssertEqual(timeout, step.timeout)
            if step.fails {
                throw CommandError(arguments: arguments, status: 1, output: "simulated command failure", timedOut: step.timedOut)
            }
            return step.output
        }

        func assertFinished(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertTrue(steps.isEmpty, "Unexecuted commands: \(steps.map(\.arguments))", file: file, line: line)
        }
    }
}
