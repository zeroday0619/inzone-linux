import Foundation
import Glibc
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class InstallationTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Fixture {
        let directory: URL
        let staging: URL
        let home: URL
        let binary: URL
    }

    private func fixture(_ body: (Fixture) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-install-\(UUID().uuidString)")
        let staging = directory.appendingPathComponent("staging")
        let home = staging.appendingPathComponent("desktop user's home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(Fixture(directory: directory, staging: staging, home: home, binary: directory.appendingPathComponent("build's executable")))
    }

    private struct StagingRunner: CommandRunning {
        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            throw InzoneError.message("Staged installation attempted to run a host command: \(arguments)")
        }
    }

    private final class InvocationRunner: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var storedInvocations: [[String]] = []

        var invocations: [[String]] { lock.withLock { storedInvocations } }

        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            lock.withLock { storedInvocations.append(arguments) }
            return ""
        }
    }

    private final class MutableEffectiveUserID: @unchecked Sendable {
        private let lock = NSLock()
        private var storedValue: uid_t
        private var storedCallCount = 0

        init(_ value: uid_t) { storedValue = value }

        var callCount: Int { lock.withLock { storedCallCount } }

        func set(_ value: uid_t) {
            lock.withLock { storedValue = value }
        }

        func read() -> uid_t {
            lock.withLock {
                storedCallCount += 1
                return storedValue
            }
        }
    }

    private func requireAssets() throws {
        for path in [
            "native/inzone_dsp.so", "assets/sony-eq-tables.json", "assets/sony-presets.json",
            "analysis/payload/inzonevirtualizer.dll", "analysis/payload/shp_for_game_v2.0_512tap.hki",
            "analysis/payload/downmix.hki", "analysis/payload/wh_g910n_standard.ba",
        ] where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            throw XCTSkip("Prepare native DSP and pinned installer assets with make build; missing \(path).")
        }
    }

    private func run(_ executable: URL, _ arguments: [String], fixture: Fixture) throws -> (status: Int32, output: String) {
        try runProcess(
            executable, arguments, currentDirectory: fixture.directory,
            environment: ["HOME": fixture.home.path, "PATH": fixture.directory.appendingPathComponent("missing").path, "LANG": "C.UTF-8"]
        )
    }

    private func runProcess(
        _ executable: URL, _ arguments: [String], currentDirectory: URL,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func installUser(_ fixture: Fixture) throws {
        try Installer(
            options: InstallOptions(
                repository: root, home: fixture.home, binary: fixture.binary,
                expectedPluginSHA256: try pluginDigest()
            ),
            effectiveUserIDProvider: { Glibc.geteuid() }, runtimeHomeProvider: { fixture.home }
        ).run()
    }

    private func installSystem(_ fixture: Fixture, staging: URL? = nil) throws {
        try SystemInstaller(options: SystemInstallOptions(
            repository: root, stagingRoot: staging ?? fixture.staging,
            expectedPluginSHA256: try pluginDigest(), expectedUdevRuleSHA256: try udevRuleDigest()
        ), runner: StagingRunner()).run()
    }

    private func install(_ fixture: Fixture) throws {
        try installUser(fixture)
        try installSystem(fixture)
    }

    private func write(_ text: String, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func profileConfiguration(_ file: URL) throws -> (header: String, config: [String: Any]) {
        let text = try String(contentsOf: file, encoding: .utf8)
        let lines = text.components(separatedBy: .newlines)
        let json = lines.filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        return (lines.first ?? "", try XCTUnwrap(JSONSupport.decode(Data(json.utf8)) as? [String: Any]))
    }

    private func softwareDSPGraph(_ config: [String: Any]) throws -> [String: Any] {
        let modules = try XCTUnwrap(config["context.modules"] as? [[String: Any]])
        let filter = try XCTUnwrap(modules.first { $0["name"] as? String == "libpipewire-module-filter-chain" })
        return try XCTUnwrap(filter["args"] as? [String: Any])
    }

    private func pluginDigest() throws -> String {
        try Digests.sha256(file: root.appendingPathComponent("native/inzone_dsp.so"))
    }

    private func udevRuleDigest() throws -> String {
        try Digests.sha256(file: root.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules"))
    }

    private func requireDigestInputs() throws {
        for path in ["native/inzone_dsp.so", "configs/udev/70-inzone-h9-ii.rules"]
        where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            throw XCTSkip("Prepare the native DSP and repository udev rule; missing \(path).")
        }
    }

    private func toolsExecutable() throws -> URL {
        let testDirectory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            ProcessInfo.processInfo.environment["INZONE_TEST_TOOLS_BINARY"].map(URL.init(fileURLWithPath:)),
            testDirectory.appendingPathComponent("inzone-tools"),
            root.appendingPathComponent(".build/debug/inzone-tools"),
            root.appendingPathComponent(".build/release/inzone-tools"),
        ].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw XCTSkip("Run swift build, or set INZONE_TEST_TOOLS_BINARY to the built inzone-tools executable.")
        }
        return executable
    }

    private func installFixtureExecutable(_ fixture: Fixture) throws {
        // A system ELF fixture verifies deployment without requiring an application build.
        guard let path = ["/usr/bin/printf", "/bin/printf"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("The installation fixture requires a printf executable.")
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: fixture.binary)
    }

    func testMissingOrNonExecutableBinaryDoesNotModifyHome() throws {
        try fixture { fixture in
            let sentinel = fixture.home.appendingPathComponent("settings.json")
            try write("preserved\n", to: sentinel)
            for mode in ["missing", "non-executable"] {
                if mode == "non-executable" {
                    try write("invalid executable\n", to: fixture.binary)
                    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.binary.path)
                }
                XCTAssertThrowsError(try installUser(fixture)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Run: make swift-build"), error.localizedDescription)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), ["settings.json"])
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserved\n")
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("usr").path))
            }
        }
    }

    func testPEAndFirmwareUpdaterBinariesCannotBeInstalled() throws {
        try fixture { fixture in
            let sentinel = fixture.home.appendingPathComponent("settings.json")
            try write("preserved\n", to: sentinel)

            let portableExecutable = fixture.directory.appendingPathComponent("ordinary-tool")
            try Data([0x4d, 0x5a] + Array(repeating: 0, count: 62)).write(to: portableExecutable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: portableExecutable.path)

            let updater = fixture.directory.appendingPathComponent("glhubupdatetoolcli.exe")
            guard let nativeExecutable = ["/usr/bin/printf", "/bin/printf"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                throw XCTSkip("The installation fixture requires a native executable for this host.")
            }
            try FileManager.default.copyItem(at: URL(fileURLWithPath: nativeExecutable), to: updater)

            let wrongArchitecture = fixture.directory.appendingPathComponent("wrong-architecture")
            var wrongArchitectureData = try Data(contentsOf: URL(fileURLWithPath: nativeExecutable))
            #if arch(x86_64)
            wrongArchitectureData[18] = 0xb7
            wrongArchitectureData[19] = 0
            #elseif arch(arm64)
            wrongArchitectureData[18] = 0x3e
            wrongArchitectureData[19] = 0
            #endif
            try wrongArchitectureData.write(to: wrongArchitecture)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: wrongArchitecture.path
            )

            for (candidate, errorFragment) in [
                (portableExecutable, "cannot be installed"),
                (updater, "cannot be installed"),
                (wrongArchitecture, "native ELF64 executable for this host architecture"),
            ] {
                let installer = Installer(
                    options: InstallOptions(
                        repository: root, home: fixture.home, binary: candidate,
                        expectedPluginSHA256: String(repeating: "0", count: 64)
                    ),
                    effectiveUserIDProvider: { Glibc.geteuid() }, runtimeHomeProvider: { fixture.home }
                )
                XCTAssertThrowsError(try installer.run()) { error in
                    XCTAssertTrue(
                        error.localizedDescription.contains(errorFragment),
                        error.localizedDescription
                    )
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), ["settings.json"])
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserved\n")
                XCTAssertFalse(FileManager.default.fileExists(
                    atPath: fixture.home.appendingPathComponent(".local/bin/inzone-profile").path
                ))
            }
        }
    }

    func testSystemStagingRejectsInvalidRootAndEscapingSystemPaths() throws {
        try fixture { fixture in
            for invalidRoot in [URL(fileURLWithPath: "/"), fixture.directory.appendingPathComponent("missing")] {
                XCTAssertThrowsError(try installSystem(fixture, staging: invalidRoot)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("existing non-root directory"), error.localizedDescription)
                }
            }
            let outside = fixture.directory.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let missing = fixture.directory.appendingPathComponent("missing outside")
            for component in ["usr", "etc"] {
                let link = fixture.staging.appendingPathComponent(component)
                for target in [outside.path, missing.path, component] {
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: target)
                XCTAssertThrowsError(try installSystem(fixture)) { error in
                    XCTAssertTrue(error.localizedDescription.contains("anchored directory"), error.localizedDescription)
                }
                    try FileManager.default.removeItem(at: link)
                }
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("usr").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("etc").path))
        }
    }

    func testSystemPhasesRequireOnlyTheirIntendedPrivilege() throws {
        try fixture { fixture in
            let live = SystemInstaller(
                options: SystemInstallOptions(
                    repository: root, expectedPluginSHA256: String(repeating: "0", count: 64),
                    expectedUdevRuleSHA256: String(repeating: "0", count: 64)
                ), runner: StagingRunner(), effectiveUserID: 1000
            )
            XCTAssertThrowsError(try live.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("must run as root"), error.localizedDescription)
            }
            let staged = SystemInstaller(
                options: SystemInstallOptions(
                    repository: root, stagingRoot: fixture.staging,
                    expectedPluginSHA256: String(repeating: "0", count: 64),
                    expectedUdevRuleSHA256: String(repeating: "0", count: 64)
                ),
                runner: StagingRunner(), effectiveUserID: 0
            )
            XCTAssertThrowsError(try staged.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("must not run as root"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.staging.path), ["desktop user's home"])
        }
    }

    func testInstallOptionsDoNotResolvePathsDuringInitialization() throws {
        try fixture { fixture in
            let target = fixture.directory.appendingPathComponent("resolved target")
            let repositoryTarget = target.appendingPathComponent("repository")
            let binaryTarget = target.appendingPathComponent("binary")
            let payloadTarget = target.appendingPathComponent("payload")
            let stagingTarget = target.appendingPathComponent("staging")
            for directory in [repositoryTarget, payloadTarget, stagingTarget] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try write("binary", to: binaryTarget)

            let repository = fixture.directory.appendingPathComponent("repository link")
            let binary = fixture.directory.appendingPathComponent("binary link")
            let payload = fixture.directory.appendingPathComponent("payload link")
            let staging = fixture.directory.appendingPathComponent("staging link")
            for (link, destination) in [
                (repository, repositoryTarget), (binary, binaryTarget),
                (payload, payloadTarget), (staging, stagingTarget),
            ] {
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
                XCTAssertNotEqual(link.resolvingSymlinksInPath(), link)
            }

            let userOptions = InstallOptions(
                repository: repository, home: fixture.home, binary: binary, payload: payload,
                expectedPluginSHA256: String(repeating: "0", count: 64)
            )
            XCTAssertEqual(userOptions.repository, repository)
            XCTAssertEqual(userOptions.binary, binary)
            XCTAssertEqual(userOptions.payload, payload)

            let systemOptions = SystemInstallOptions(
                repository: repository, stagingRoot: staging,
                expectedPluginSHA256: String(repeating: "0", count: 64),
                expectedUdevRuleSHA256: String(repeating: "0", count: 64)
            )
            XCTAssertEqual(systemOptions.repository, repository)
            XCTAssertEqual(systemOptions.stagingRoot, staging)
        }
    }

    func testInstallersEvaluateEffectiveUserIDForEveryRun() throws {
        try fixture { fixture in
            let userCredential = MutableEffectiveUserID(0)
            let userInstaller = Installer(
                options: InstallOptions(
                    repository: root, home: fixture.home, binary: fixture.binary,
                    expectedPluginSHA256: String(repeating: "0", count: 64)
                ),
                effectiveUserIDProvider: { userCredential.read() },
                runtimeHomeProvider: { fixture.home }
            )
            XCTAssertEqual(userCredential.callCount, 0)
            XCTAssertThrowsError(try userInstaller.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("must not run as root"), error.localizedDescription)
            }
            userCredential.set(uid_t.max)
            XCTAssertThrowsError(try userInstaller.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("owned by the current user"), error.localizedDescription)
            }
            XCTAssertEqual(userCredential.callCount, 2)

            let systemCredential = MutableEffectiveUserID(0)
            let systemInstaller = SystemInstaller(
                options: SystemInstallOptions(
                    repository: root, stagingRoot: URL(fileURLWithPath: "/"),
                    expectedPluginSHA256: String(repeating: "0", count: 64),
                    expectedUdevRuleSHA256: String(repeating: "0", count: 64)
                ),
                runner: StagingRunner(), effectiveUserIDProvider: { systemCredential.read() }
            )
            XCTAssertEqual(systemCredential.callCount, 0)
            XCTAssertThrowsError(try systemInstaller.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("must not run as root"), error.localizedDescription)
            }
            systemCredential.set(1000)
            XCTAssertThrowsError(try systemInstaller.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("existing non-root directory"), error.localizedDescription)
            }
            XCTAssertEqual(systemCredential.callCount, 2)

            let liveCredential = MutableEffectiveUserID(1000)
            let liveInstaller = SystemInstaller(
                options: SystemInstallOptions(
                    repository: fixture.directory,
                    expectedPluginSHA256: String(repeating: "0", count: 64),
                    expectedUdevRuleSHA256: String(repeating: "0", count: 64)
                ),
                runner: StagingRunner(), effectiveUserIDProvider: { liveCredential.read() },
                currentExecutableSealValidator: {}
            )
            XCTAssertEqual(liveCredential.callCount, 0)
            XCTAssertThrowsError(try liveInstaller.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("must run as root"), error.localizedDescription)
            }
            liveCredential.set(0)
            XCTAssertThrowsError(try liveInstaller.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("rejects a repository path"), error.localizedDescription)
            }
            XCTAssertEqual(liveCredential.callCount, 2)
        }
    }

    func testLiveSystemInstallationReadsOnlySealedSourcesAndUsesAbsoluteUdevadm() throws {
        try fixture { fixture in
            let pluginData = Data("sealed live plugin".utf8)
            let udevRuleData = Data("SUBSYSTEM==\"hidraw\"\n".utf8)
            let plugin = try SealedFile.snapshot(data: pluginData, name: "live-plugin")
            let udevRule = try SealedFile.snapshot(data: udevRuleData, name: "live-udev-rule")
            let runner = InvocationRunner()
            let installer = SystemInstaller(
                options: SystemInstallOptions(
                    pluginSource: URL(fileURLWithPath: plugin.procFDPath),
                    udevRuleSource: URL(fileURLWithPath: udevRule.procFDPath),
                    expectedPluginSHA256: Digests.sha256(pluginData),
                    expectedUdevRuleSHA256: Digests.sha256(udevRuleData)
                ),
                runner: runner,
                effectiveUserID: 0,
                currentExecutableSealValidator: {},
                liveSystemRoot: fixture.staging
            )

            try installer.run()

            XCTAssertEqual(runner.invocations, [["/usr/bin/udevadm", "control", "--reload-rules"]])
            XCTAssertEqual(
                try Data(contentsOf: fixture.staging.appendingPathComponent("etc/udev/rules.d/70-inzone-h9-ii.rules")),
                udevRuleData
            )
            let digest = Digests.sha256(pluginData)
            XCTAssertEqual(
                try Data(contentsOf: fixture.staging.appendingPathComponent(
                    "usr/lib/ladspa/inzone_dsp_\(digest.prefix(16)).so"
                )),
                pluginData
            )
        }
    }

    func testSystemInstallationRejectsSourcesFromTheWrongPrivilegeMode() throws {
        try fixture { fixture in
            let data = Data("sealed source".utf8)
            let plugin = try SealedFile.snapshot(data: data, name: "mode-plugin")
            let udevRule = try SealedFile.snapshot(data: data, name: "mode-rule")
            let digest = Digests.sha256(data)

            let liveRepository = SystemInstaller(
                options: SystemInstallOptions(
                    repository: fixture.directory,
                    expectedPluginSHA256: digest,
                    expectedUdevRuleSHA256: digest
                ),
                runner: InvocationRunner(), effectiveUserID: 0,
                currentExecutableSealValidator: {}, liveSystemRoot: fixture.staging
            )
            XCTAssertThrowsError(try liveRepository.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("rejects a repository path"), error.localizedDescription)
            }

            let stagedProcFD = SystemInstaller(
                options: SystemInstallOptions(
                    repository: root, stagingRoot: fixture.staging,
                    pluginSource: URL(fileURLWithPath: plugin.procFDPath),
                    udevRuleSource: URL(fileURLWithPath: udevRule.procFDPath),
                    expectedPluginSHA256: digest,
                    expectedUdevRuleSHA256: digest
                ),
                runner: InvocationRunner(), effectiveUserID: 1000
            )
            XCTAssertThrowsError(try stagedProcFD.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("rejects live sealed source paths"), error.localizedDescription)
            }
        }
    }

    func testStagedSystemInstallationSupportsSymlinkedTopLevelDirectories() throws {
        try fixture { fixture in
            let repository = fixture.directory.appendingPathComponent("actual repository")
            let rule = repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules")
            let native = repository.appendingPathComponent("native/inzone_dsp.so")
            try write("SUBSYSTEM==\"hidraw\"\n", to: rule)
            try write("plugin", to: native)
            let repositoryLink = fixture.directory.appendingPathComponent("repository link")
            let stagingLink = fixture.directory.appendingPathComponent("staging link")
            try FileManager.default.createSymbolicLink(at: repositoryLink, withDestinationURL: repository)
            try FileManager.default.createSymbolicLink(at: stagingLink, withDestinationURL: fixture.staging)

            let installer = SystemInstaller(
                options: SystemInstallOptions(
                    repository: repositoryLink, stagingRoot: stagingLink,
                    expectedPluginSHA256: try Digests.sha256(file: native),
                    expectedUdevRuleSHA256: try Digests.sha256(file: rule)
                ),
                runner: StagingRunner(), effectiveUserID: 1000
            )
            try installer.run()

            XCTAssertEqual(
                try Data(contentsOf: fixture.staging.appendingPathComponent("etc/udev/rules.d/70-inzone-h9-ii.rules")),
                try Data(contentsOf: rule)
            )
            let digest = try Digests.sha256(file: native)
            XCTAssertEqual(
                try Data(contentsOf: fixture.staging.appendingPathComponent("usr/lib/ladspa/inzone_dsp_\(digest.prefix(16)).so")),
                try Data(contentsOf: native)
            )
        }
    }

    func testSystemPhaseRejectsSymlinkedRepositoryFiles() throws {
        try fixture { fixture in
            let repository = fixture.directory.appendingPathComponent("repository")
            let rule = repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules")
            let plugin = repository.appendingPathComponent("native/inzone_dsp.so")
            let sentinel = fixture.directory.appendingPathComponent("sentinel")
            try write("sentinel", to: sentinel)
            try FileManager.default.createDirectory(at: rule.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plugin.deletingLastPathComponent(), withIntermediateDirectories: true)

            for target in [rule, plugin] {
                if target != rule { try write("SUBSYSTEM==\"hidraw\"\n", to: rule) }
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)
                let installer = SystemInstaller(
                    options: SystemInstallOptions(
                        repository: repository, stagingRoot: fixture.staging,
                        expectedPluginSHA256: String(repeating: "0", count: 64),
                        expectedUdevRuleSHA256: target == rule
                            ? String(repeating: "0", count: 64) : try Digests.sha256(file: rule)
                    ),
                    runner: StagingRunner()
                )
                XCTAssertThrowsError(try installer.run()) { error in
                    XCTAssertTrue(error.localizedDescription.contains("Open repository file"), error.localizedDescription)
                }
                try FileManager.default.removeItem(at: target)
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("etc").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("usr").path))
            }
        }
    }

    func testUserPhaseRejectsRootBeforeInspectingHome() throws {
        try fixture { fixture in
            let options = InstallOptions(
                repository: root, home: fixture.home, binary: fixture.binary,
                expectedPluginSHA256: String(repeating: "0", count: 64)
            )
            let installer = Installer(options: options, effectiveUserID: 0)
            XCTAssertThrowsError(try installer.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("must not run as root"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), [])
        }
    }

    func testUserPhaseRejectsHomeOwnedByAnotherUserBeforeWriting() throws {
        let options = InstallOptions(repository: root, home: URL(fileURLWithPath: "/"),
                                     binary: root.appendingPathComponent("missing executable"),
                                     expectedPluginSHA256: String(repeating: "0", count: 64))
        let installer = Installer(options: options, effectiveUserID: uid_t.max)
        XCTAssertThrowsError(try installer.run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("owned by the current user"), error.localizedDescription)
        }
    }

    func testUserPhaseRejectsWrongOrMutatedPluginDigestBeforeWriting() throws {
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            let repository = fixture.directory.appendingPathComponent("repository")
            let native = repository.appendingPathComponent("native/inzone_dsp.so")
            try write("prepared plugin", to: native)
            let preparedDigest = try Digests.sha256(file: native)
            let sentinel = fixture.home.appendingPathComponent("settings.json")
            try write("preserved\n", to: sentinel)

            for expectedDigest in [String(repeating: "0", count: 64), preparedDigest] {
                if expectedDigest == preparedDigest { try write("mutated plugin", to: native) }
                let installer = Installer(
                    options: InstallOptions(
                        repository: repository, home: fixture.home, binary: fixture.binary,
                        expectedPluginSHA256: expectedDigest
                    ),
                    effectiveUserIDProvider: { Glibc.geteuid() }, runtimeHomeProvider: { fixture.home }
                )
                XCTAssertThrowsError(try installer.run()) { error in
                    XCTAssertTrue(error.localizedDescription.contains("changed after installation preparation"), error.localizedDescription)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), ["settings.json"])
                XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "preserved\n")
            }
        }
    }

    func testStagedSystemPhaseRejectsWrongOrMutatedPluginDigestBeforeWriting() throws {
        try fixture { fixture in
            let repository = fixture.directory.appendingPathComponent("repository")
            let rule = repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules")
            let native = repository.appendingPathComponent("native/inzone_dsp.so")
            try write("SUBSYSTEM==\"hidraw\"\n", to: rule)
            try write("prepared plugin", to: native)
            let preparedDigest = try Digests.sha256(file: native)

            for expectedDigest in [String(repeating: "0", count: 64), preparedDigest] {
                if expectedDigest == preparedDigest { try write("mutated plugin", to: native) }
                let installer = SystemInstaller(
                    options: SystemInstallOptions(
                        repository: repository, stagingRoot: fixture.staging,
                        expectedPluginSHA256: expectedDigest,
                        expectedUdevRuleSHA256: try Digests.sha256(file: rule)
                    ),
                    runner: StagingRunner()
                )
                XCTAssertThrowsError(try installer.run()) { error in
                    XCTAssertTrue(error.localizedDescription.contains("changed after installation preparation"), error.localizedDescription)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("etc").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("usr").path))
            }
        }
    }

    func testStagedSystemPhaseRejectsWrongOrMutatedUdevRuleDigestBeforeWriting() throws {
        try fixture { fixture in
            let repository = fixture.directory.appendingPathComponent("repository")
            let rule = repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules")
            let native = repository.appendingPathComponent("native/inzone_dsp.so")
            try write("SUBSYSTEM==\"hidraw\"\n", to: rule)
            try write("prepared plugin", to: native)
            let preparedDigest = try Digests.sha256(file: rule)

            for expectedDigest in [String(repeating: "0", count: 64), preparedDigest] {
                if expectedDigest == preparedDigest { try write("mutated udev rule\n", to: rule) }
                let installer = SystemInstaller(
                    options: SystemInstallOptions(
                        repository: repository, stagingRoot: fixture.staging,
                        expectedPluginSHA256: try Digests.sha256(file: native),
                        expectedUdevRuleSHA256: expectedDigest
                    ),
                    runner: StagingRunner()
                )
                XCTAssertThrowsError(try installer.run()) { error in
                    XCTAssertTrue(error.localizedDescription.contains("udev rule changed after installation preparation"), error.localizedDescription)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("etc").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("usr").path))
            }
        }
    }

    func testToolsCLIRequiresDigestOptionsAndPrintsPreparedDigests() throws {
        try requireDigestInputs()
        try fixture { fixture in
            let executable = try toolsExecutable()
            let digest = try pluginDigest()
            let printed = try runProcess(
                executable, ["plugin-digest", "--repository", root.path], currentDirectory: fixture.directory
            )
            XCTAssertEqual(printed.status, 0, printed.output)
            XCTAssertEqual(printed.output, digest + "\n")
            let ruleDigest = try udevRuleDigest()
            let printedRule = try runProcess(
                executable, ["udev-rule-digest", "--repository", root.path], currentDirectory: fixture.directory
            )
            XCTAssertEqual(printedRule.status, 0, printedRule.output)
            XCTAssertEqual(printedRule.output, ruleDigest + "\n")

            let user = try runProcess(
                executable,
                ["install", "--repository", root.path, "--home", fixture.home.path, "--binary", fixture.binary.path],
                currentDirectory: fixture.directory
            )
            XCTAssertEqual(user.status, 1, user.output)
            XCTAssertTrue(user.output.contains("install requires --expected-plugin-sha256 from plugin-digest"), user.output)

            let system = try runProcess(
                executable,
                ["install-system", "--repository", root.path, "--staging-root", fixture.staging.path],
                currentDirectory: fixture.directory
            )
            XCTAssertEqual(system.status, 1, system.output)
            XCTAssertTrue(system.output.contains("install-system requires --expected-plugin-sha256 from plugin-digest"), system.output)
            let systemWithoutRuleDigest = try runProcess(
                executable,
                [
                    "install-system", "--repository", root.path, "--staging-root", fixture.staging.path,
                    "--expected-plugin-sha256", digest,
                ],
                currentDirectory: fixture.directory
            )
            XCTAssertEqual(systemWithoutRuleDigest.status, 1, systemWithoutRuleDigest.output)
            XCTAssertTrue(
                systemWithoutRuleDigest.output.contains("install-system requires --expected-udev-rule-sha256 from udev-rule-digest"),
                systemWithoutRuleDigest.output
            )
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("etc").path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.staging.appendingPathComponent("usr").path))

            let successfulSystem = try runProcess(
                executable,
                [
                    "install-system", "--repository", root.path, "--staging-root", fixture.staging.path,
                    "--expected-plugin-sha256", digest, "--expected-udev-rule-sha256", ruleDigest,
                ],
                currentDirectory: fixture.directory
            )
            XCTAssertEqual(successfulSystem.status, 0, successfulSystem.output)
            XCTAssertEqual(successfulSystem.output, "Installed the INZONE system udev rule and LADSPA plugin.\n")
            XCTAssertEqual(
                try Data(contentsOf: fixture.staging.appendingPathComponent("etc/udev/rules.d/70-inzone-h9-ii.rules")),
                try Data(contentsOf: root.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules"))
            )
            XCTAssertEqual(
                try Data(contentsOf: fixture.staging.appendingPathComponent("usr/lib/ladspa/inzone_dsp_\(digest.prefix(16)).so")),
                try Data(contentsOf: root.appendingPathComponent("native/inzone_dsp.so"))
            )
        }
    }

    func testToolsCLISuccessPathsEscapeTerminalControls() throws {
        try requireAssets()
        for path in [
            "analysis/payload/inzonehub.dll", "analysis/payload/control.yaml",
            "analysis/decompiled/PCWidget.ViewModel.ApoFileCommunication.decompiled.cs",
            "analysis/decompiled/PCWidget.ViewModel.SoundQualitySettingsViewModel.decompiled.cs",
        ] where !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) {
            throw XCTSkip("Prepare pinned installer assets with make build; missing \(path).")
        }
        try fixture { fixture in
            let executable = try toolsExecutable()
            let unsafeComponent = "output\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\nleaf"
            let destination = fixture.directory.appendingPathComponent(unsafeComponent)
            let escapedDestination = TerminalOutput.escaped(destination.path, preservingNewlines: false)

            for (command, description) in [("export-eq", "equalizer tables"), ("export-presets", "Sony presets")] {
                let result = try runProcess(
                    executable,
                    [
                        command, "--repository", root.path,
                        "--payload", root.appendingPathComponent("analysis/payload").path,
                        "--decompiled", root.appendingPathComponent("analysis/decompiled").path,
                        "--output", destination.path,
                    ],
                    currentDirectory: fixture.directory
                )
                XCTAssertEqual(result.status, 0, result.output)
                XCTAssertEqual(result.output, "Exported \(description) to \(escapedDestination).\n")
            }

            let unsafeHome = fixture.directory.appendingPathComponent("home-" + unsafeComponent)
            try FileManager.default.createDirectory(at: unsafeHome, withIntermediateDirectories: true)
            try installFixtureExecutable(fixture)
            let result = try runProcess(
                executable,
                [
                    "install", "--repository", root.path, "--home", unsafeHome.path,
                    "--binary", fixture.binary.path, "--expected-plugin-sha256", try pluginDigest(),
                ],
                currentDirectory: fixture.directory,
                environment: [
                    "HOME": unsafeHome.path,
                    "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
                    "LANG": "C.UTF-8",
                ]
            )
            let escapedHome = TerminalOutput.escaped(unsafeHome.path, preservingNewlines: false)
            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertEqual(
                result.output,
                "Installed inzone-profile for \(escapedHome).\n"
                    + "In the desktop user session, reconnect the USB dongle and run: inzone-profile surround\n"
            )
        }
    }

    func testMakeInstallInvokesSingleCoordinatorCommand() throws {
        try fixture { fixture in
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/make") else {
                throw XCTSkip("The Make coordinator test requires GNU Make at /usr/bin/make.")
            }
            let tool = fixture.directory.appendingPathComponent("fake-inzone-tools")
            let log = fixture.directory.appendingPathComponent("make-install-arguments.log")
            try write(
                """
                #!/bin/sh
                printf '%s\\0' "$0" "$@" >> "$INZONE_INSTALL_LOG"
                test "$#" -eq 7 || exit 64
                test "$1" = "install-all" || exit 64
                test "$2" = "--home" && test "$3" = "$INZONE_HOME" || exit 64
                test "$4" = "--repository" && test "$5" = "$INZONE_REPOSITORY" || exit 64
                test "$6" = "--binary" && test "$7" = "$INZONE_BINARY" || exit 64
                test "$INZONE_FAIL_INSTALL_ALL" != "yes" || exit 73
                """ + "\n",
                to: tool
            )
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            var environment = ProcessInfo.processInfo.environment
            environment["INZONE_INSTALL_LOG"] = log.path
            environment["INZONE_REPOSITORY"] = root.path
            environment["INZONE_HOME"] = fixture.home.path
            environment["INZONE_BINARY"] = fixture.binary.path
            let makeArguments = [
                "-o", "build", "install", "SWIFT_TOOLS_BINARY=\(tool.path)",
                "SWIFT_BINARY=\(fixture.binary.path)", "INSTALL_HOME=\(fixture.home.path)",
            ]
            let result = try runProcess(
                URL(fileURLWithPath: "/usr/bin/make"), makeArguments,
                currentDirectory: root, environment: environment
            )
            XCTAssertEqual(result.status, 0, result.output)
            let arguments = try Data(contentsOf: log).split(separator: 0).map {
                String(decoding: $0, as: UTF8.self)
            }
            XCTAssertEqual(arguments, [
                tool.path, "install-all", "--home", fixture.home.path,
                "--repository", root.path, "--binary", fixture.binary.path,
            ])

            try write("", to: log)
            environment["INZONE_FAIL_INSTALL_ALL"] = "yes"
            let failed = try runProcess(
                URL(fileURLWithPath: "/usr/bin/make"), makeArguments,
                currentDirectory: root, environment: environment
            )
            XCTAssertEqual(failed.status, 2, failed.output)
            let failedArguments = try Data(contentsOf: log).split(separator: 0).map {
                String(decoding: $0, as: UTF8.self)
            }
            XCTAssertEqual(failedArguments, arguments)
        }
    }

    func testUserInstallationSupportsSymlinkedDotfileDirectory() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            let externalConfiguration = fixture.directory.appendingPathComponent("dotfiles/config")
            try FileManager.default.createDirectory(at: externalConfiguration, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: fixture.home.appendingPathComponent(".config"),
                withDestinationURL: externalConfiguration
            )
            try install(fixture)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: externalConfiguration.appendingPathComponent("inzone-h9-ii/balanced.conf").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: externalConfiguration.appendingPathComponent("wireplumber/wireplumber.conf.d/52-inzone-game-chat.conf").path
            ))
        }
    }

    func testMpvMigrationReplacesSymlinkSafelyAndPreservesRestrictiveRegularMode() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            let legacyDevice = "alsa_output.usb-Sony_INZONE_H9_II-00.iec958-stereo"
            let currentDevice = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
            let sentinel = fixture.directory.appendingPathComponent("mpv-target-sentinel.conf")
            let original = "audio-device=\(legacyDevice)\n"
            try write(original, to: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)

            let mpv = fixture.home.appendingPathComponent(".config/mpv/mpv.conf")
            try FileManager.default.createDirectory(at: mpv.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: mpv, withDestinationURL: sentinel)
            XCTAssertEqual(
                (try FileManager.default.attributesOfItem(atPath: mpv.path)[.posixPermissions] as? NSNumber)?.intValue,
                0o777
            )

            try installUser(fixture)

            let migrated = "audio-device=\(currentDevice)\n"
            let values = try mpv.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            XCTAssertEqual(values.isRegularFile, true)
            XCTAssertEqual(values.isSymbolicLink, false)
            XCTAssertEqual(try String(contentsOf: mpv, encoding: .utf8), migrated)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), original)
            XCTAssertEqual(
                (try FileManager.default.attributesOfItem(atPath: mpv.path)[.posixPermissions] as? NSNumber)?.intValue,
                0o600
            )

            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: mpv.path)
            try installUser(fixture)
            XCTAssertEqual(try String(contentsOf: mpv, encoding: .utf8), migrated)
            XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), original)
            XCTAssertEqual(
                (try FileManager.default.attributesOfItem(atPath: mpv.path)[.posixPermissions] as? NSNumber)?.intValue,
                0o400
            )
        }
    }

    func testRegularDataReadBindsBytesAndPermissionsAcrossSymlinkSwap() throws {
        try fixture { fixture in
            let original = try Data(contentsOf: root.appendingPathComponent(
                "configs/systemd/inzone-profile-auto.service"
            ))
            let restrictiveTarget = fixture.directory.appendingPathComponent("restrictive-unit.service")
            let permissiveTarget = fixture.directory.appendingPathComponent("permissive-unit.service")
            try original.write(to: restrictiveTarget)
            try Data("replacement unit\n".utf8).write(to: permissiveTarget)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: restrictiveTarget.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: permissiveTarget.path)

            let sourceUnit = fixture.directory.appendingPathComponent("inzone-profile-auto.service")
            try FileManager.default.createSymbolicLink(
                at: sourceUnit, withDestinationURL: restrictiveTarget
            )
            let sourceMode = try FileManager.default.attributesOfItem(atPath: sourceUnit.path)[.posixPermissions]
                as? NSNumber
            XCTAssertEqual(sourceMode?.intValue, 0o777)
            let installer = Installer(options: InstallOptions(
                repository: root, home: fixture.home, binary: fixture.binary,
                expectedPluginSHA256: String(repeating: "0", count: 64)
            ))
            let sourceFile = try installer.readDataAndSafeRegularFilePermissions(from: sourceUnit) {
                try FileManager.default.removeItem(at: sourceUnit)
                try FileManager.default.createSymbolicLink(at: sourceUnit, withDestinationURL: permissiveTarget)
            }
            XCTAssertEqual(sourceFile.data, original)
            XCTAssertEqual(sourceFile.permissions, 0o600)

            let cappedFile = try installer.readDataAndSafeRegularFilePermissions(from: permissiveTarget)
            XCTAssertEqual(cappedFile.data, Data("replacement unit\n".utf8))
            XCTAssertEqual(cappedFile.permissions, 0o644)
        }
    }

    func testStagedInstallationDeploysAllConfigsAssetsAndExecutable() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            let unrelated = fixture.home.appendingPathComponent(".config/unrelated/nested/settings.conf")
            try write("unrelated user configuration\n", to: unrelated)
            try installSystem(fixture)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.home.path), [".config"])
            let systemRule = fixture.staging.appendingPathComponent("etc/udev/rules.d/70-inzone-h9-ii.rules")
            let digest = try Digests.sha256(file: root.appendingPathComponent("native/inzone_dsp.so"))
            let systemPlugin = fixture.staging.appendingPathComponent("usr/lib/ladspa/inzone_dsp_\(digest.prefix(16)).so")
            let ruleIdentifier = try FileManager.default.attributesOfItem(atPath: systemRule.path)[.systemFileNumber] as? NSNumber
            let pluginIdentifier = try FileManager.default.attributesOfItem(atPath: systemPlugin.path)[.systemFileNumber] as? NSNumber
            try installUser(fixture)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: systemRule.path)[.systemFileNumber] as? NSNumber, ruleIdentifier)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: systemPlugin.path)[.systemFileNumber] as? NSNumber, pluginIdentifier)
            let data = fixture.home.appendingPathComponent(".config/inzone-h9-ii")
            let assets = fixture.home.appendingPathComponent(".local/share/inzone-linux/assets")
            for name in ["fps", "music", "voice", "balanced", "original"] {
                XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("\(name).conf")), try Data(contentsOf: root.appendingPathComponent("configs/\(name).conf")))
            }
            let mappings = [
                "52-inzone-game-chat.conf": fixture.home.appendingPathComponent(".config/wireplumber/wireplumber.conf.d/52-inzone-game-chat.conf"),
                "systemd/inzone-profile-auto.service": fixture.home.appendingPathComponent(".config/systemd/user/inzone-profile-auto.service"),
                "udev/70-inzone-h9-ii.rules": systemRule,
            ]
            for (source, destination) in mappings {
                XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: root.appendingPathComponent("configs/\(source)")))
            }
            let active = try profileConfiguration(fixture.home.appendingPathComponent(
                ".config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf"
            ))
            XCTAssertEqual(active.header, "# INZONE profile: balanced")
            let activeGraph = try softwareDSPGraph(active.config)
            let activeNodes = try XCTUnwrap((activeGraph["filter.graph"] as? [String: Any])?["nodes"] as? [[String: Any]])
            XCTAssertTrue(activeNodes.contains { $0["label"] as? String == "inzone_fir_downmix" })
            let graph = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: data.appendingPathComponent("sony-surround.json"))) as? [String: Any])
            XCTAssertEqual((graph["capture.props"] as? [String: Any])?["audio.channels"] as? Int, 8)
            let surround = try String(contentsOf: data.appendingPathComponent("surround.conf"), encoding: .utf8)
            XCTAssertFalse(surround.contains("node.software-dsp.rules"))
            XCTAssertFalse(surround.contains("context.modules"))
            let plugin = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: assets.appendingPathComponent("plugin.json"))) as? [String: String])
            let pluginName = try XCTUnwrap(plugin["name"])
            let native = try Data(contentsOf: root.appendingPathComponent("native/inzone_dsp.so"))
            XCTAssertEqual(try Data(contentsOf: systemPlugin), native)
            XCTAssertEqual(systemPlugin.lastPathComponent, pluginName + ".so")
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: systemRule.path)[.posixPermissions] as? NSNumber)?.intValue, 0o644)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: systemPlugin.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
            XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent(".local/lib/ladspa/inzone_dsp.so")), native)
            for name in ["sony-eq-tables.json", "sony-presets.json"] {
                XCTAssertEqual(try Data(contentsOf: assets.appendingPathComponent(name)), try Data(contentsOf: root.appendingPathComponent("assets/\(name)")))
            }
            XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent(".local/share/inzone-linux/decoder/inzonevirtualizer.dll")), try Data(contentsOf: root.appendingPathComponent("analysis/payload/inzonevirtualizer.dll")))
            let executable = fixture.home.appendingPathComponent(".local/bin/inzone-profile")
            XCTAssertEqual(try Data(contentsOf: executable), try Data(contentsOf: fixture.binary))
            let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
            for name in ["python", "venv"] {
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".local/share/inzone-linux/\(name)").path))
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: executable.deletingLastPathComponent().path), ["inzone-profile"])
            XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "unrelated user configuration\n")
            let homeOwner = try FileManager.default.attributesOfItem(atPath: fixture.home.path)[.ownerAccountID] as? NSNumber
            let executableOwner = attributes[.ownerAccountID] as? NSNumber
            XCTAssertEqual(executableOwner, homeOwner)
        }
    }

    func testInvalidVendorAssetsDoNotReplaceInstalledFiles() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let executable = fixture.home.appendingPathComponent(".local/bin/inzone-profile")
            let active = fixture.home.appendingPathComponent(".config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf")
            let previousBinary = try Data(contentsOf: executable)
            let previousProfile = try Data(contentsOf: active)
            let payload = fixture.directory.appendingPathComponent("invalid payload")
            for name in [
                "inzonevirtualizer.dll", "shp_for_game_v2.0_512tap.hki",
                "downmix.hki", "wh_g910n_standard.ba",
            ] {
                try write("unrecognized vendor file", to: payload.appendingPathComponent(name))
            }
            let installer = Installer(
                options: InstallOptions(
                    repository: root, home: fixture.home, binary: fixture.binary,
                    payload: payload, expectedPluginSHA256: try pluginDigest()
                ),
                effectiveUserIDProvider: { Glibc.geteuid() }, runtimeHomeProvider: { fixture.home }
            )
            XCTAssertThrowsError(try installer.run()) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unsupported DLL"), error.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: executable), previousBinary)
            XCTAssertEqual(try Data(contentsOf: active), previousProfile)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".local/state/inzone-linux/backups").path))
        }
    }

    func testInstalledExecutablePreservesArgumentsWithoutBuildDirectoryOrPATH() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            try FileManager.default.removeItem(at: fixture.binary)
            let arguments = ["a user's settings.json", "", "$(exit 99)", "line one\nline two"]
            let result = try run(fixture.home.appendingPathComponent(".local/bin/inzone-profile"), ["%s\n"] + arguments, fixture: fixture)
            XCTAssertEqual(result.status, 0)
            XCTAssertEqual(result.output, arguments.joined(separator: "\n") + "\n")
        }
    }

    func testReinstallRefreshesTemplatesAndPreservesStateAndLegacyRuntime() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let data = fixture.home.appendingPathComponent(".config/inzone-h9-ii")
            let preserved = [
                ".config/inzone-h9-ii/original.conf": "saved restore profile\n",
                ".config/inzone-h9-ii/profile-settings.json": "{\"music\":{\"drc\":2}}\n",
                ".config/inzone-h9-ii/auto-profiles.json": "{\"enabled\":false,\"bindings\":[]}\n",
                ".local/share/inzone-linux/python/inzone-profile.py": "legacy source\n",
                ".local/share/inzone-linux/venv/bin/python": "legacy interpreter\n",
            ]
            for (path, contents) in preserved { try write(contents, to: fixture.home.appendingPathComponent(path)) }
            let active = fixture.home.appendingPathComponent(
                ".config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf"
            )
            try write("# INZONE profile: music\n{}\n", to: active)
            let launcher = "#!/bin/sh\nexec /previous/venv/bin/python /previous/inzone-profile.py \"$@\"\n"
            try write(launcher, to: fixture.home.appendingPathComponent(".local/bin/inzone-profile"))
            for name in ["fps", "music", "voice", "balanced"] {
                try write("old \(name) profile\n", to: data.appendingPathComponent("\(name).conf"))
            }
            try install(fixture)
            for (path, contents) in preserved {
                XCTAssertEqual(try String(contentsOf: fixture.home.appendingPathComponent(path), encoding: .utf8), contents)
            }
            for name in ["fps", "music", "voice", "balanced"] {
                XCTAssertEqual(try Data(contentsOf: data.appendingPathComponent("\(name).conf")), try Data(contentsOf: root.appendingPathComponent("configs/\(name).conf")))
            }
            let refreshed = try profileConfiguration(active)
            XCTAssertEqual(refreshed.header, "# INZONE profile: music")
            let graph = try softwareDSPGraph(refreshed.config)
            let nodes = try XCTUnwrap((graph["filter.graph"] as? [String: Any])?["nodes"] as? [[String: Any]])
            XCTAssertTrue(nodes.contains { $0["label"] as? String == "inzone_fir_downmix" })
            let backups = try FileManager.default.contentsOfDirectory(at: fixture.home.appendingPathComponent(".local/state/inzone-linux/backups"), includingPropertiesForKeys: nil)
            XCTAssertEqual(backups.count, 1)
            let backup = try XCTUnwrap(backups.first)
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent(".local/bin/inzone-profile"), encoding: .utf8), launcher)
            XCTAssertEqual(try String(contentsOf: backup.appendingPathComponent(".config/inzone-h9-ii/fps.conf"), encoding: .utf8), "old fps profile\n")
            XCTAssertEqual(try Data(contentsOf: fixture.home.appendingPathComponent(".local/bin/inzone-profile")), try Data(contentsOf: fixture.binary))
        }
    }

    func testReinstallRefreshesCustomActiveProfileWithoutChangingCollection() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let paths = InzonePaths(home: fixture.home)
            let custom = try ProfileController(paths: paths).createProfile(
                name: "Custom Music", basedOn: "music"
            )
            let collection = paths.configDirectory.appendingPathComponent("sound-profiles.json")
            let previousCollection = try Data(contentsOf: collection)
            try write("# INZONE profile: \(custom.identifier)\n{}\n", to: paths.activeProfile)

            try install(fixture)

            XCTAssertEqual(try Data(contentsOf: collection), previousCollection)
            let refreshed = try profileConfiguration(paths.activeProfile)
            XCTAssertEqual(refreshed.header, "# INZONE profile: \(custom.identifier)")
            let graph = try softwareDSPGraph(refreshed.config)
            let nodes = try XCTUnwrap((graph["filter.graph"] as? [String: Any])?["nodes"] as? [[String: Any]])
            XCTAssertTrue(nodes.contains { $0["label"] as? String == "inzone_fir_downmix" })
        }
    }

    func testReinstallPreservesOriginalActiveConfiguration() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let paths = InzonePaths(home: fixture.home)
            let original = "{\"user-owned\":true}\n"
            try write(original, to: paths.configDirectory.appendingPathComponent("original.conf"))
            try write(original, to: paths.activeProfile)

            try install(fixture)

            XCTAssertEqual(try String(contentsOf: paths.activeProfile, encoding: .utf8), original)
            XCTAssertEqual(
                try String(contentsOf: paths.configDirectory.appendingPathComponent("original.conf"), encoding: .utf8),
                original
            )
        }
    }

    func testReinstallAtomicallyExchangesAssetBankForHeldDirectoryReaders() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let assets = InzonePaths(home: fixture.home).assetsDirectory
            let oldManifest = assets.appendingPathComponent("manifest.json")
            let oldManifestIdentifier = try FileManager.default.attributesOfItem(atPath: oldManifest.path)[.systemFileNumber]
                as? NSNumber
            let descriptor = Glibc.open(assets.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { if descriptor >= 0 { Glibc.close(descriptor) } }

            try install(fixture)

            let heldManifest = Glibc.openat(descriptor, "manifest.json", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(heldManifest, 0)
            defer { if heldManifest >= 0 { Glibc.close(heldManifest) } }
            var heldStatus = stat()
            XCTAssertEqual(Glibc.fstat(heldManifest, &heldStatus), 0)
            XCTAssertEqual(NSNumber(value: heldStatus.st_ino), oldManifestIdentifier)
            let newManifestIdentifier = try FileManager.default.attributesOfItem(atPath: oldManifest.path)[.systemFileNumber]
                as? NSNumber
            XCTAssertNotEqual(newManifestIdentifier, oldManifestIdentifier)
            for path in GraphRenderer.channels.map({ $0 + ".wav" })
                + GraphRenderer.channels.map({ "downmix/" + $0 + ".wav" })
                + [
                    "fir-bank.bin", "downmix/fir-bank.bin", "manifest.json", "h9-ii-biquads.json",
                    "sony-eq-tables.json", "sony-presets.json", "plugin.json",
                ] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: assets.appendingPathComponent(path).path), path)
            }
            let hidden = try FileManager.default.contentsOfDirectory(atPath: assets.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(".assets-stage-") }
            XCTAssertTrue(hidden.isEmpty, "Stale asset banks remain: \(hidden)")
            let retired = try FileManager.default.contentsOfDirectory(atPath: assets.deletingLastPathComponent().path)
                .filter { $0.hasPrefix(".assets-retired-") }
            XCTAssertTrue(retired.isEmpty)
            let backups = try FileManager.default.contentsOfDirectory(
                at: fixture.home.appendingPathComponent(".local/state/inzone-linux/backups"),
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(backups.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: backups[0].appendingPathComponent(".local/share/inzone-linux/assets/manifest.json").path
            ))
        }
    }

    func testReinstallRestoresPreviousAssetBankWhenLaterPublicationFails() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let paths = InzonePaths(home: fixture.home)
            let assetsIdentifier = try FileManager.default.attributesOfItem(atPath: paths.assetsDirectory.path)[.systemFileNumber]
                as? NSNumber
            let manifest = try Data(contentsOf: paths.assetsDirectory.appendingPathComponent("manifest.json"))
            let previousPlugin = Data("previous plugin".utf8)
            try previousPlugin.write(to: paths.pluginURL)
            let previousBalanced = Data("previous balanced\n".utf8)
            try previousBalanced.write(to: paths.configDirectory.appendingPathComponent("balanced.conf"))
            let installedDocumentation = paths.configDirectory.appendingPathComponent("docs")
            try FileManager.default.removeItem(at: installedDocumentation)
            try write("blocks directory replacement\n", to: installedDocumentation)

            XCTAssertThrowsError(try installUser(fixture))

            let restoredIdentifier = try FileManager.default.attributesOfItem(atPath: paths.assetsDirectory.path)[.systemFileNumber]
                as? NSNumber
            XCTAssertEqual(restoredIdentifier, assetsIdentifier)
            XCTAssertEqual(
                try Data(contentsOf: paths.assetsDirectory.appendingPathComponent("manifest.json")), manifest
            )
            XCTAssertEqual(try Data(contentsOf: paths.pluginURL), previousPlugin)
            XCTAssertEqual(
                try Data(contentsOf: paths.configDirectory.appendingPathComponent("balanced.conf")), previousBalanced
            )
            let hidden = try FileManager.default.contentsOfDirectory(atPath: paths.shareDirectory.path)
                .filter { $0.hasPrefix(".assets-stage-") }
            XCTAssertTrue(hidden.isEmpty, "Stale rollback banks remain: \(hidden)")
        }
    }

    func testUnknownManagedActiveProfileRejectsReinstallBeforePublication() throws {
        try requireAssets()
        try fixture { fixture in
            try installFixtureExecutable(fixture)
            try install(fixture)
            let paths = InzonePaths(home: fixture.home)
            try write("# INZONE profile: missing-profile\n{}\n", to: paths.activeProfile)
            let assetsIdentifier = try FileManager.default.attributesOfItem(atPath: paths.assetsDirectory.path)[.systemFileNumber]
                as? NSNumber
            let plugin = try Data(contentsOf: paths.pluginURL)

            XCTAssertThrowsError(try installUser(fixture)) { error in
                XCTAssertTrue(error.localizedDescription.contains("missing-profile"), error.localizedDescription)
            }

            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: paths.assetsDirectory.path)[.systemFileNumber]
                    as? NSNumber,
                assetsIdentifier
            )
            XCTAssertEqual(try Data(contentsOf: paths.pluginURL), plugin)
            XCTAssertEqual(
                try String(contentsOf: paths.activeProfile, encoding: .utf8),
                "# INZONE profile: missing-profile\n{}\n"
            )
        }
    }

    func testBuiltSwiftExecutableRunsFromStagedInstallation() throws {
        try requireAssets()
        let path = ProcessInfo.processInfo.environment["INZONE_TEST_BINARY"] ?? root.appendingPathComponent(".build/release/inzone-profile").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("Run make swift-build, or set INZONE_TEST_BINARY to the built Swift executable.")
        }
        try fixture { fixture in
            try FileManager.default.copyItem(at: URL(fileURLWithPath: path), to: fixture.binary)
            try install(fixture)
            try FileManager.default.removeItem(at: fixture.binary)
            let executable = fixture.home.appendingPathComponent(".local/bin/inzone-profile")
            let help = try run(executable, ["--help"], fixture: fixture)
            XCTAssertEqual(help.status, 0, help.output)
            XCTAssertTrue(help.output.contains("Usage: inzone-profile"), help.output)
            let profiles = try run(executable, ["--list"], fixture: fixture)
            XCTAssertEqual(profiles.status, 0, profiles.output)
            for name in ["fps", "music", "voice", "balanced", "surround", "restore"] {
                XCTAssertTrue(profiles.output.contains(name), profiles.output)
            }
        }
    }

}
