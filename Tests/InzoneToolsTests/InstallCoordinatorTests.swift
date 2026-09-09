import Foundation
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class InstallCoordinatorTests: XCTestCase {
    private final class RecordingRunner: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private let failureMessage: String?
        private var storedArguments: [String] = []
        private var storedTimeout: TimeInterval = 0
        private var storedExecutableWasAvailable = false
        private var storedPluginData: Data?
        private var storedUdevRuleData: Data?

        init(failureMessage: String? = nil) {
            self.failureMessage = failureMessage
        }

        var arguments: [String] { lock.withLock { storedArguments } }
        var timeout: TimeInterval { lock.withLock { storedTimeout } }
        var executableWasAvailable: Bool { lock.withLock { storedExecutableWasAvailable } }
        var pluginData: Data? { lock.withLock { storedPluginData } }
        var udevRuleData: Data? { lock.withLock { storedUdevRuleData } }

        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            let pluginIndex = arguments.firstIndex(of: "--plugin-procfd")
            let udevRuleIndex = arguments.firstIndex(of: "--udev-rule-procfd")
            let pluginData = try pluginIndex.map {
                try SealedFile.readAndValidateSealedProcFD(path: arguments[$0 + 1], maximumSize: 1024 * 1024)
            }
            let udevRuleData = try udevRuleIndex.map {
                try SealedFile.readAndValidateSealedProcFD(path: arguments[$0 + 1], maximumSize: 1024 * 1024)
            }
            lock.withLock {
                storedArguments = arguments
                storedTimeout = timeout
                storedExecutableWasAvailable = arguments.count > 2
                    && FileManager.default.isExecutableFile(atPath: arguments[2])
                storedPluginData = pluginData
                storedUdevRuleData = udevRuleData
            }
            if let failureMessage {
                throw InzoneError.message(failureMessage)
            }
            return "system installation complete\n"
        }
    }

    private func fixture() throws -> (
        directory: URL, repository: URL, home: URL, binary: URL, payload: URL,
        plugin: URL, udevRule: URL
    ) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "inzone-coordinator-\(UUID().uuidString)"
        )
        let repository = directory.appendingPathComponent("repository")
        let plugin = repository.appendingPathComponent("native/inzone_dsp.so")
        let udevRule = repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules")
        try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: udevRule.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (
            directory, repository, directory.appendingPathComponent("home"),
            directory.appendingPathComponent("inzone-profile"), directory.appendingPathComponent("payload"),
            plugin, udevRule
        )
    }

    func testCoordinatorBindsThreeSealedFilesAndInvokesAbsoluteSudo() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let pluginData = Data("original plugin bytes".utf8)
        let udevRuleData = Data("original udev rule bytes".utf8)
        try pluginData.write(to: fixture.plugin)
        try udevRuleData.write(to: fixture.udevRule)
        let pluginDigest = Digests.sha256(pluginData)
        let udevRuleDigest = Digests.sha256(udevRuleData)
        let runner = RecordingRunner()
        var operations: [String] = []
        var receivedInstallOptions: InstallOptions?

        let coordinator = InstallCoordinator(
            options: InstallCoordinatorOptions(
                repository: fixture.repository, home: fixture.home,
                binary: fixture.binary, payload: fixture.payload
            ),
            runner: runner,
            effectiveUserIDProvider: { 1000 },
            sourceProvider: { repository in
                operations.append("source-snapshots")
                let plugin = try Data(contentsOf: repository.appendingPathComponent("native/inzone_dsp.so"))
                let udevRule = try Data(contentsOf: repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules"))
                return try InstallCoordinator.SealedInstallSources(
                    plugin: SealedFile.snapshot(data: plugin, name: "test-plugin"),
                    pluginDigest: Digests.sha256(plugin),
                    udevRule: SealedFile.snapshot(data: udevRule, name: "test-udev-rule"),
                    udevRuleDigest: Digests.sha256(udevRule)
                )
            },
            userInstaller: { options in
                operations.append("user-install")
                receivedInstallOptions = options
                try Data("replacement plugin".utf8).write(to: fixture.plugin)
                try Data("replacement rule".utf8).write(to: fixture.udevRule)
            },
            sealedExecutableProvider: {
                operations.append("seal-executable")
                return try SealedExecutable.snapshotCurrentProcess()
            }
        )

        XCTAssertEqual(try coordinator.run(), "system installation complete\n")
        XCTAssertEqual(operations, ["seal-executable", "source-snapshots", "user-install"])
        XCTAssertEqual(receivedInstallOptions?.repository, fixture.repository)
        XCTAssertEqual(receivedInstallOptions?.home, fixture.home)
        XCTAssertEqual(receivedInstallOptions?.binary, fixture.binary)
        XCTAssertEqual(receivedInstallOptions?.payload, fixture.payload)
        XCTAssertEqual(receivedInstallOptions?.expectedPluginSHA256, pluginDigest)
        XCTAssertEqual(runner.timeout, .infinity)
        XCTAssertTrue(runner.executableWasAvailable)
        XCTAssertEqual(runner.pluginData, pluginData)
        XCTAssertEqual(runner.udevRuleData, udevRuleData)
        XCTAssertEqual(runner.arguments.count, 12)
        guard runner.arguments.count == 12 else { return }
        XCTAssertEqual(Array(runner.arguments.prefix(2)), ["/usr/bin/sudo", "--"])
        XCTAssertNotNil(
            runner.arguments[2].range(of: #"^/proc/[0-9]+/fd/[0-9]+$"#, options: .regularExpression),
            runner.arguments[2]
        )
        XCTAssertEqual(runner.arguments[3], "install-system")
        XCTAssertEqual(runner.arguments[4], "--plugin-procfd")
        XCTAssertEqual(runner.arguments[6], "--udev-rule-procfd")
        XCTAssertEqual(Array(runner.arguments.suffix(4)), [
            "--expected-plugin-sha256", pluginDigest,
            "--expected-udev-rule-sha256", udevRuleDigest,
        ])
    }

    func testCoordinatorReportsPartialStateWhenSystemPhaseFails() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let runner = RecordingRunner(failureMessage: "sudo was denied")
        var userInstallerRan = false
        let coordinator = InstallCoordinator(
            options: InstallCoordinatorOptions(
                repository: fixture.repository, home: fixture.home, binary: fixture.binary
            ),
            runner: runner,
            effectiveUserIDProvider: { 1000 },
            sourceProvider: { _ in
                try InstallCoordinator.SealedInstallSources(
                    plugin: SealedFile.snapshot(data: Data("plugin".utf8), name: "test-plugin"),
                    pluginDigest: Digests.sha256(Data("plugin".utf8)),
                    udevRule: SealedFile.snapshot(data: Data("rule".utf8), name: "test-rule"),
                    udevRuleDigest: Digests.sha256(Data("rule".utf8))
                )
            },
            userInstaller: { _ in userInstallerRan = true },
            sealedExecutableProvider: { try SealedExecutable.snapshotCurrentProcess() }
        )

        XCTAssertThrowsError(try coordinator.run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("user installation completed"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("system installation failed"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("sudo was denied"), error.localizedDescription)
        }
        XCTAssertTrue(userInstallerRan)
        XCTAssertFalse(runner.arguments.isEmpty)
    }

    func testCoordinatorRejectsRootBeforePreparingPrivilegeBoundary() throws {
        let runner = RecordingRunner()
        var providerWasCalled = false
        let coordinator = InstallCoordinator(
            options: InstallCoordinatorOptions(
                repository: URL(fileURLWithPath: "/missing"),
                home: URL(fileURLWithPath: "/missing-home"),
                binary: URL(fileURLWithPath: "/missing-binary")
            ),
            runner: runner,
            effectiveUserIDProvider: { 0 },
            sourceProvider: { _ in
                providerWasCalled = true
                throw InzoneError.message("unexpected source preparation")
            },
            userInstaller: { _ in providerWasCalled = true },
            sealedExecutableProvider: {
                providerWasCalled = true
                return try SealedExecutable.snapshotCurrentProcess()
            }
        )

        XCTAssertThrowsError(try coordinator.run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("must not run as root"), error.localizedDescription)
        }
        XCTAssertFalse(providerWasCalled)
        XCTAssertEqual(runner.arguments, [])
    }

    func testCoordinatorSealFailurePrecedesUserWritesAndIsNotReportedAsPartial() throws {
        let runner = RecordingRunner()
        var sourceProviderWasCalled = false
        var userInstallerRan = false
        let coordinator = InstallCoordinator(
            options: InstallCoordinatorOptions(
                repository: URL(fileURLWithPath: "/missing"),
                home: URL(fileURLWithPath: "/missing-home"),
                binary: URL(fileURLWithPath: "/missing-binary")
            ),
            runner: runner,
            effectiveUserIDProvider: { 1000 },
            sourceProvider: { _ in
                sourceProviderWasCalled = true
                throw InzoneError.message("unexpected source preparation")
            },
            userInstaller: { _ in userInstallerRan = true },
            sealedExecutableProvider: {
                throw InzoneError.message("sealed executable unavailable")
            }
        )

        XCTAssertThrowsError(try coordinator.run()) { error in
            XCTAssertEqual(error.localizedDescription, "sealed executable unavailable")
            XCTAssertFalse(error.localizedDescription.contains("user installation completed"))
        }
        XCTAssertFalse(sourceProviderWasCalled)
        XCTAssertFalse(userInstallerRan)
        XCTAssertEqual(runner.arguments, [])
    }
}
