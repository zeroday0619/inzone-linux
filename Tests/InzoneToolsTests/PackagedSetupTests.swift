import Foundation
import Glibc
import XCTest
import InzoneCore
@testable import InzoneToolsCore

@MainActor
final class PackagedSetupTests: XCTestCase {
    private let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-package-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try await body(home)
    }

    private func setup(home: URL, assetsFrom: URL?, download: Bool = false, userID: uid_t? = nil) -> PackagedSetup {
        PackagedSetup(
            options: PackagedSetupOptions(
                resources: repository, binary: URL(fileURLWithPath: "/usr/bin/printf"),
                home: home, assetsFrom: assetsFrom, download: download
            ),
            environment: [:], effectiveUserIDProvider: { userID ?? Glibc.geteuid() },
            runtimeHomeProvider: { home }
        )
    }

    private func requireAssets() throws {
        for path in [
            "native/inzone_dsp.so", "assets/sony-eq-tables.json", "assets/sony-presets.json",
            "analysis/payload/inzonevirtualizer.dll", "analysis/payload/shp_for_game_v2.0_512tap.hki",
            "analysis/payload/downmix.hki", "analysis/payload/wh_g910n_standard.ba",
        ] where !FileManager.default.fileExists(atPath: repository.appendingPathComponent(path).path) {
            throw XCTSkip("Prepared installer assets are required: \(path)")
        }
    }

    func testResourceDirectoryFollowsExecutablePrefix() {
        let resources = PackagedSetupOptions.resourceDirectory(executable: URL(fileURLWithPath: "/opt/inzone/bin/inzone-tools"))
        XCTAssertEqual(resources.path, "/opt/inzone/share/inzone-linux/setup")
    }

    func testSetupRequiresExplicitAssetSourceWithoutWritingHome() async throws {
        try await fixture { home in
            for (assets, download) in [(nil as URL?, false), (repository, true)] {
                do {
                    try await setup(home: home, assetsFrom: assets, download: download).run()
                    XCTFail("Ambiguous setup mode was accepted")
                } catch {
                    XCTAssertTrue(error.localizedDescription.contains("Specify exactly one"), error.localizedDescription)
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
            }
        }
    }

    func testSetupRejectsRootBeforeDownloadsOrUserChanges() async throws {
        try await fixture { home in
            do {
                try await setup(home: home, assetsFrom: nil, download: true, userID: 0).run()
                XCTFail("Root setup was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("without sudo"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        }
    }

    func testSetupRejectsMismatchedHomeBeforeDownloads() async throws {
        try await fixture { home in
            let operation = PackagedSetup(
                options: PackagedSetupOptions(
                    resources: repository, binary: URL(fileURLWithPath: "/usr/bin/printf"),
                    home: home, download: true
                ),
                environment: [:], effectiveUserIDProvider: { Glibc.geteuid() },
                runtimeHomeProvider: { home.appendingPathComponent("different") }
            )
            do {
                try await operation.run()
                XCTFail("Mismatched home was accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("runtime HOME"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        }
    }

    func testAutomationUnitUsesPackagePathWithoutExpansion() throws {
        let template = "[Service]\nExecStart=old --auto-watch\nRestart=on-failure\n"
        let result = try Installer.packagedAutomationUnit(
            template, executable: URL(fileURLWithPath: "/opt/package %h/$PATH/quote\"/inzone-profile")
        )
        XCTAssertEqual(
            result,
            "[Service]\nExecStart=:\"/opt/package %%h/$PATH/quote\\\"/inzone-profile\" --auto-watch\nRestart=on-failure\n"
        )
        XCTAssertThrowsError(try Installer.packagedAutomationUnit("[Service]\n", executable: URL(fileURLWithPath: "/usr/bin/inzone-profile")))
        XCTAssertThrowsError(try Installer.packagedAutomationUnit(template, executable: URL(fileURLWithPath: "/opt/line\nbreak")))
    }

    func testPreparedSetupInstallsAudioResourcesWithoutCreatingLocalExecutable() async throws {
        try requireAssets()
        try await fixture { home in
            try await setup(home: home, assetsFrom: repository).run()
            let paths = InzonePaths(home: home)
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent(".local/bin/inzone-profile").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.assetsDirectory.appendingPathComponent("fir-bank.bin").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.activeDSPProfile.path))
            XCTAssertEqual(try ProfileController(paths: paths).status(), "balanced")
            let manifest = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: paths.assetsDirectory.appendingPathComponent("plugin.json"))) as? [String: String])
            XCTAssertEqual(manifest["name"], "inzone_dsp")
            XCTAssertEqual(manifest["sha256"], try Digests.sha256(file: repository.appendingPathComponent("native/inzone_dsp.so")))
            let unit = try String(contentsOf: home.appendingPathComponent(".config/systemd/user/inzone-profile-auto.service"), encoding: .utf8)
            XCTAssertTrue(unit.contains("ExecStart=:\"/usr/bin/printf\" --auto-watch"), unit)
        }
    }

    func testPreparedSetupPreservesLocalExecutableAndProfileStateAcrossRefresh() async throws {
        try requireAssets()
        try await fixture { home in
            let executable = home.appendingPathComponent(".local/bin/inzone-profile")
            try AtomicFile.write(Data("user-managed executable\n".utf8), to: executable, permissions: 0o751)
            try await setup(home: home, assetsFrom: repository).run()
            let paths = InzonePaths(home: home)
            try AtomicFile.write(Data("# INZONE profile: music\n{}\n".utf8), to: paths.activeProfile)
            let settings = SettingsStore(paths: paths)
            let saved = try settings.encode(settings.load())
            try AtomicFile.write(Data(saved.utf8), to: paths.configDirectory.appendingPathComponent("profile-settings.json"))
            try await setup(home: home, assetsFrom: repository).run()
            XCTAssertEqual(try Data(contentsOf: executable), Data("user-managed executable\n".utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o751)
            XCTAssertEqual(try ProfileController(paths: paths).status(), "music")
            XCTAssertEqual(try String(contentsOf: paths.configDirectory.appendingPathComponent("profile-settings.json"), encoding: .utf8), saved)
            let backup = home.appendingPathComponent(".local/state/inzone-linux/backups")
            if let enumerator = FileManager.default.enumerator(at: backup, includingPropertiesForKeys: nil) {
                let files = enumerator.allObjects.compactMap { $0 as? URL }
                XCTAssertFalse(files.contains { $0.path.hasSuffix("/.local/bin/inzone-profile") })
            }
        }
    }

    func testMissingPreparedAssetsDoesNotModifyHome() async throws {
        try await fixture { home in
            do {
                try await setup(home: home, assetsFrom: home).run()
                XCTFail("Missing prepared assets were accepted")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Prepared assets are missing"), error.localizedDescription)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.path), [])
        }
    }
}
