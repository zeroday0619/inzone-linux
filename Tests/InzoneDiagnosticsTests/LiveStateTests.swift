import Foundation
import Glibc
import XCTest
import InzoneCore
@testable import InzoneDiagnostics

final class LiveStateTests: XCTestCase {
    private final class Runner: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [[String]] = []
        let failRestart: Bool
        let mute: String

        init(failRestart: Bool = false, mute: String = "Mute: yes\n") {
            self.failRestart = failRestart
            self.mute = mute
        }

        var commands: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(arguments)
            switch arguments {
            case ["pactl", "get-default-sink"]: return "initial-sink\n"
            case ["pactl", "get-sink-mute", ProfileController.game]: return mute
            case ["systemctl", "--user", "restart", "wireplumber.service"] where failRestart:
                throw InzoneError.message("Injected restart failure")
            default: return ""
            }
        }
    }

    private func fixture(optionalFiles: Bool = true, _ body: (InzonePaths) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-live-state-test-\(UUID().uuidString)")
        let paths = InzonePaths(home: directory)
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.activeProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("# INZONE profile: balanced\n{\"custom-preserved-value\":1}\n".utf8).write(to: paths.activeProfile)
        if optionalFiles {
            try Data("{\"balanced\":{\"drc\":1}}\n".utf8).write(to: paths.configDirectory.appendingPathComponent("profile-settings.json"))
            try Data("original-manual-token".utf8).write(to: paths.configDirectory.appendingPathComponent("manual-switch"))
            try Data("[{\"app\":\"saved-game\",\"profile\":\"music\",\"priority\":2}]\n".utf8)
                .write(to: AutomationStore(paths: paths).fileURL)
        }
        try body(paths)
    }

    private func files(_ paths: InzonePaths) -> [URL] {
        [paths.activeProfile, paths.configDirectory.appendingPathComponent("profile-settings.json"),
         paths.configDirectory.appendingPathComponent("manual-switch"), AutomationStore(paths: paths).fileURL]
    }

    private func mutate(_ paths: InzonePaths) throws {
        try Data("# INZONE profile: voice\n{}\n".utf8).write(to: paths.activeProfile)
        try Data("{}\n".utf8).write(to: paths.configDirectory.appendingPathComponent("profile-settings.json"))
        try Data("diagnostic-manual-token".utf8).write(to: paths.configDirectory.appendingPathComponent("manual-switch"))
        try Data("[]\n".utf8).write(to: AutomationStore(paths: paths).fileURL)
    }

    func testFailedDiagnosticRestoresExactBytesModesAndManualOwnership() throws {
        try fixture { paths in
            let originalFiles = files(paths)
            let originalBytes = try originalFiles.map { try Data(contentsOf: $0) }
            for file in originalFiles {
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
            }
            let runner = Runner()
            let state = try LiveSessionState(paths: paths, runner: runner)
            XCTAssertEqual(state.initialProfile, "balanced")
            XCTAssertThrowsError(try state.withRestoration {
                try mutate(paths)
                throw InzoneError.message("Injected verification failure")
            }) { error in
                XCTAssertEqual(error.localizedDescription, "Injected verification failure")
            }
            for (file, data) in zip(originalFiles, originalBytes) {
                XCTAssertEqual(try Data(contentsOf: file), data)
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            }
            XCTAssertTrue(runner.commands.contains(["systemctl", "--user", "restart", "wireplumber.service"]))
            XCTAssertTrue(runner.commands.contains(["pactl", "set-default-sink", "initial-sink"]))
            XCTAssertTrue(runner.commands.contains(["pactl", "set-sink-mute", ProfileController.game, "1"]))
        }
    }

    func testSuccessfulDiagnosticRestoresAbsenceOfOptionalState() throws {
        try fixture(optionalFiles: false) { paths in
            let active = try Data(contentsOf: paths.activeProfile)
            let runner = Runner(mute: "Mute: no\n")
            let state = try LiveSessionState(paths: paths, runner: runner)
            let result = try state.withRestoration {
                try mutate(paths)
                return "complete"
            }
            XCTAssertEqual(result, "complete")
            XCTAssertEqual(try Data(contentsOf: paths.activeProfile), active)
            for file in files(paths).dropFirst() {
                XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            }
            XCTAssertTrue(runner.commands.contains(["pactl", "set-sink-mute", ProfileController.game, "0"]))
        }
    }

    func testCleanupAttemptsAllRestorationsAfterRestartFailure() throws {
        try fixture { paths in
            let originalFiles = files(paths)
            let originalBytes = try originalFiles.map { try Data(contentsOf: $0) }
            let runner = Runner(failRestart: true)
            let state = try LiveSessionState(paths: paths, runner: runner)
            XCTAssertThrowsError(try state.withRestoration {
                try mutate(paths)
                throw InzoneError.message("Injected verification failure")
            }) { error in
                XCTAssertTrue(error.localizedDescription.contains("Injected verification failure"))
                XCTAssertTrue(error.localizedDescription.contains("Injected restart failure"))
                XCTAssertTrue(error.localizedDescription.contains("Restoration also failed"))
            }
            for (file, data) in zip(originalFiles, originalBytes) { XCTAssertEqual(try Data(contentsOf: file), data) }
            XCTAssertTrue(runner.commands.contains(["systemctl", "--user", "is-active", "wireplumber.service"]))
            XCTAssertTrue(runner.commands.contains(["pactl", "set-default-sink", "initial-sink"]))
            XCTAssertTrue(runner.commands.contains(["pactl", "set-sink-mute", ProfileController.game, "1"]))
        }
    }

    func testAmbiguousMuteOrProfilePreventsDiagnosticStateCapture() throws {
        try fixture { paths in
            XCTAssertThrowsError(try LiveSessionState(paths: paths, runner: Runner(mute: "unrecognized\n")))
            try Data("# INZONE profile: custom-unknown\n{}\n".utf8).write(to: paths.activeProfile)
            let runner = Runner()
            XCTAssertThrowsError(try LiveSessionState(paths: paths, runner: runner))
            XCTAssertTrue(runner.commands.isEmpty)
        }
    }

    func testRegisteredCustomProfileIsResolvedAndRestored() throws {
        try fixture { paths in
            let profile = try ProfileController(paths: paths).createProfile(
                name: "Live Custom", basedOn: "music"
            )
            let identifier = profile.identifier
            let active = Data("# INZONE profile: \(identifier.uppercased())\n{\"custom-preserved-value\":2}\n".utf8)
            try active.write(to: paths.activeProfile)

            let state = try LiveSessionState(paths: paths, runner: Runner())
            XCTAssertEqual(state.initialProfile, identifier)
            XCTAssertThrowsError(try state.withRestoration {
                try mutate(paths)
                throw InzoneError.message("Injected custom profile verification failure")
            })
            XCTAssertEqual(try Data(contentsOf: paths.activeProfile), active)
        }
    }

    func testRestoreProfileRemainsAccepted() throws {
        try fixture { paths in
            try Data("# INZONE profile: restore\n{}\n".utf8).write(to: paths.activeProfile)
            let state = try LiveSessionState(paths: paths, runner: Runner())
            XCTAssertEqual(state.initialProfile, "restore")
        }
    }

    func testStateSymlinksAreRejectedWithoutChangingTheirTargets() throws {
        try fixture(optionalFiles: false) { paths in
            let target = paths.home.appendingPathComponent("preserved-target")
            let bytes = Data("unchanged".utf8)
            try bytes.write(to: target)
            let link = paths.configDirectory.appendingPathComponent("manual-switch")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            XCTAssertThrowsError(try LiveSessionState(paths: paths, runner: Runner()))
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        }
    }

    func testInterruptCancellationStillRestoresSavedState() throws {
        try fixture { paths in
            let cancellation = LiveDiagnosticCancellation()
            defer { withExtendedLifetime(cancellation) {} }
            let originalFiles = files(paths)
            let originalBytes = try originalFiles.map { try Data(contentsOf: $0) }
            let state = try LiveSessionState(paths: paths, runner: Runner())
            XCTAssertThrowsError(try state.withRestoration {
                try mutate(paths)
                XCTAssertEqual(Glibc.raise(SIGINT), 0)
                try LiveDiagnosticCancellation.check()
            }) { error in
                XCTAssertTrue(error.localizedDescription.contains("cancelled"))
            }
            for (file, bytes) in zip(originalFiles, originalBytes) {
                XCTAssertEqual(try Data(contentsOf: file), bytes)
            }
        }
    }
}
