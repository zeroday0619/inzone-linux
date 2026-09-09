import Foundation
import XCTest
@testable import InzoneCore

final class ProfileControllerTests: XCTestCase {
    private let restart = ["systemctl", "--user", "restart", "wireplumber.service"]
    private let active = ["systemctl", "--user", "is-active", "wireplumber.service"]
    private let previousSink = "previous-output"

    func testConnectedFPSVerifiesLatencyPrerollAndEQBeforeMarkingManual() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink + "\n"),
            .output(restart), .output(active, "active\n"),
            .output(["pw-dump"], try nodes(latency: 128)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
            .silence(target: ProfileController.game),
            .output(["pw-cli", "enum-params", "11", "Props"], "eq0: Gain"),
        ])
        let controller = ProfileController(paths: fixture.paths, runner: runner)

        try controller.activate("fps")

        XCTAssertEqual(try controller.status(), "fps")
        XCTAssertFalse(AutomationStore(paths: fixture.paths).manualToken().isEmpty)
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
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pw-dump"], try nodes(latency: 512)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
        ])

        try ProfileController(paths: fixture.paths, runner: runner).activate("music")

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
            .output(["pw-dump"], try nodes(latency: 128)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
            .silence(target: ProfileController.game, timedOut: true),
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
            .output(["pw-dump"], try nodes(latency: 128)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
            .silence(target: ProfileController.game),
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
        let runner = ScriptedRunner([
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "get-default-sink"], previousSink),
            .output(restart), .output(active),
            .output(["pw-dump"], try nodes(latency: 128)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
            .silence(target: ProfileController.game),
            .output(["pw-cli", "enum-params", "11", "Props"], "volume: 1.0"),
            .output(restart),
            .output(["pactl", "set-default-sink", previousSink]),
        ])

        XCTAssertThrowsError(try ProfileController(paths: fixture.paths, runner: runner).activate("fps")) { error in
            XCTAssertTrue(String(describing: error).contains("Base equalizer loading verification failed."))
        }

        XCTAssertEqual(try String(contentsOf: fixture.paths.activeProfile, encoding: .utf8), previous)
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
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
            .silence(target: ProfileController.game),
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
            .output(["pw-dump"], try nodes(latency: 256)),
            .output(["pactl", "set-default-sink", ProfileController.game]),
            .silence(target: ProfileController.game),
            .output(["pw-cli", "enum-params", "11", "Props"], "game_drc: Mode\noutput_alc: Enable"),
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

    private func surroundNodes(linkedToGame: Bool) throws -> String {
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
        return try JSONSupport.encode(values, pretty: false)
    }

    private struct Fixture {
        let paths: InzonePaths

        init() throws {
            paths = InzonePaths(home: FileManager.default.temporaryDirectory.appendingPathComponent("inzone-controller-\(UUID().uuidString)"))
            try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.activeProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
            for profile in ProfileController.profiles {
                let text = "# INZONE profile: \(profile)\n{\"monitor.alsa.rules\": [], \"node.filter-graph.rules\": []}\n"
                try Data(text.utf8).write(to: paths.configDirectory.appendingPathComponent(profile + ".conf"))
            }
            try Data("{}\n".utf8).write(to: paths.configDirectory.appendingPathComponent("original.conf"))
            try FileManager.default.copyItem(at: paths.configDirectory.appendingPathComponent("balanced.conf"), to: paths.activeProfile)
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
