import Foundation
import FoundationNetworking
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class AssetFetcherTests: XCTestCase, @unchecked Sendable {
    private static func writeExecutableELF(to path: URL, machine: UInt16 = nativeELFMachine) throws {
        var bytes = [UInt8](repeating: 0, count: 120)
        bytes.replaceSubrange(0..<7, with: [0x7F, 0x45, 0x4C, 0x46, 2, 1, 1])
        func write16(_ value: UInt16, at offset: Int) {
            bytes[offset] = UInt8(truncatingIfNeeded: value)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        }
        func write32(_ value: UInt32, at offset: Int) {
            for index in 0..<4 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        func write64(_ value: UInt64, at offset: Int) {
            for index in 0..<8 { bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (index * 8)) }
        }
        write16(2, at: 16)
        write16(machine, at: 18)
        write32(1, at: 20)
        write64(64, at: 32)
        write16(64, at: 52)
        write16(56, at: 54)
        write16(1, at: 56)
        write32(1, at: 64)
        write32(5, at: 68)
        try Data(bytes).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
    }

    #if arch(x86_64)
    private static let nativeELFMachine: UInt16 = 62
    private static let foreignELFMachine: UInt16 = 183
    #elseif arch(arm64)
    private static let nativeELFMachine: UInt16 = 183
    private static let foreignELFMachine: UInt16 = 62
    #endif

    func testFetchSuccessMessagesEscapeTerminalControls() {
        let unsafe = "name\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\nvalue"
        let escaped = "name\\u{001B}\\u{007F}\\u{0085}\\u{202E}\\u{2028}\\u{2029}\\u{000A}value"

        XCTAssertEqual(
            AssetFetcher.cachedInstallerMessage(URL(fileURLWithPath: "/downloads/\(unsafe)")),
            "Verified cached installer: \(escaped)"
        )
        XCTAssertEqual(
            AssetFetcher.downloadMessage(version: unsafe),
            "Downloading INZONE Hub \(escaped) from Sony..."
        )
    }

    func testVerifiedHTTPSDownloadPublishesOnlyCompletedCacheEntry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = Data("pinned installer fixture".utf8)
        let url = StubProtocol.register(.init(body: body))
        let target = fixture.directory.appendingPathComponent("installer.exe")

        try await AssetFetcher.download(url, target: target, expected: Digests.sha256(body),
                                        size: Int64(body.count), configuration: Self.configuration())

        XCTAssertEqual(try Data(contentsOf: target), body)
        XCTAssertEqual(try fixture.contents(), ["installer.exe"])
    }

    func testVerifiedDownloadReplacesLeafLinkWithoutChangingItsTarget() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = Data("pinned installer fixture".utf8)
        let url = StubProtocol.register(.init(body: body))
        let target = fixture.directory.appendingPathComponent("installer.exe")
        let sentinel = fixture.directory.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: sentinel)

        try await AssetFetcher.download(url, target: target, expected: Digests.sha256(body),
                                        size: Int64(body.count), configuration: Self.configuration())

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: target), body)
        let sentinelAttributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual((sentinelAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(targetAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((targetAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPinnedDownloadKeepsCreatedInodeAfterTemporaryPathReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = Data("pinned installer fixture".utf8)
        let url = StubProtocol.register(.init(body: body))
        let target = fixture.directory.appendingPathComponent("installer.exe")
        let sentinel = fixture.directory.appendingPathComponent("sentinel")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sentinel.path)
        let stagedDownload = try AtomicFile.stage(for: target)
        let temporaryName = try XCTUnwrap(try fixture.contents().first { $0 != "sentinel" })
        let temporary = fixture.directory.appendingPathComponent(temporaryName)
        try FileManager.default.removeItem(at: temporary)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: sentinel)
        let transfer = PinnedDownload(
            url: url, output: stagedDownload.fileHandle, size: Int64(body.count), configuration: Self.configuration()
        )

        try await transfer.receive()
        try AssetFetcher.verify(
            stagedDownload.fileHandle, name: target.lastPathComponent,
            expected: Digests.sha256(body), size: Int64(body.count)
        )
        XCTAssertThrowsError(try stagedDownload.publish())

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testInvalidDownloadsPreserveExistingCacheAndRemoveTemporaryFiles() async throws {
        let expected = Data("expected installer".utf8)
        for received in [Data(expected.dropLast()), expected + Data("extra".utf8), Data(repeating: 0, count: expected.count)] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let target = fixture.directory.appendingPathComponent("installer.exe")
            let previous = Data("existing cache".utf8)
            try previous.write(to: target)
            let url = StubProtocol.register(.init(body: received, advertiseLength: false))

            do {
                try await AssetFetcher.download(url, target: target, expected: Digests.sha256(expected),
                                                size: Int64(expected.count), configuration: Self.configuration())
                XCTFail("Invalid download was accepted")
            } catch {}

            XCTAssertEqual(try Data(contentsOf: target), previous)
            XCTAssertEqual(try fixture.contents(), ["installer.exe"])
        }
    }

    func testHTTPDownloadIsRejectedBeforeCreatingCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.directory.appendingPathComponent("installer.exe")

        do {
            try await AssetFetcher.download(URL(string: "http://fixture.invalid/installer.exe")!, target: target,
                                            expected: Digests.sha256(Data()), size: 0, configuration: Self.configuration())
            XCTFail("HTTP download was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
        }

        XCTAssertEqual(try fixture.contents(), [])
    }

    func testHTTPSRedirectPolicyRejectsDowngrades() throws {
        XCTAssertNoThrow(try HTTPSDownloadPolicy.validate(URL(string: "https://other.invalid/installer.exe")!, redirect: true))
        for destination in ["http://other.invalid/installer.exe", "file:///tmp/installer.exe", "https:///installer.exe"] {
            XCTAssertThrowsError(try HTTPSDownloadPolicy.validate(URL(string: destination)!, redirect: true)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Download redirect must use HTTPS"))
            }
        }
    }

    func testRedirectDelegateRefusesDowngradeAndAllowsHTTPS() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let temporary = fixture.directory.appendingPathComponent("download.tmp")
        try Data().write(to: temporary)
        let original = URL(string: "https://fixture.invalid/installer.exe")!
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        let transfer = PinnedDownload(url: original, output: output, size: 0, configuration: Self.configuration())
        let session = URLSession(configuration: Self.configuration())
        defer { session.invalidateAndCancel() }
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        for scheme in ["https", "http"] {
            let task = session.dataTask(with: original)
            let request = URLRequest(url: URL(string: "\(scheme)://other.invalid/installer.exe")!)
            let result = RedirectResult()

            transfer.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                result.record($0)
            }

            XCTAssertTrue(result.called)
            XCTAssertEqual(result.request, scheme == "https" ? request : nil)
            task.cancel()
        }
    }

    func testDowngradedResponseCannotBypassHTTPSPolicy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = Data("fixture".utf8)
        let url = StubProtocol.register(.init(body: body, responseURL: URL(string: "http://other.invalid/installer.exe")))
        let target = fixture.directory.appendingPathComponent("installer.exe")

        do {
            try await AssetFetcher.download(url, target: target, expected: Digests.sha256(body),
                                            size: Int64(body.count), configuration: Self.configuration())
            XCTFail("Downgraded response was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("HTTPS"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try fixture.contents(), [])
    }

    func testHTTPFailurePreservesExistingCache() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let body = Data("fixture".utf8)
        let target = fixture.directory.appendingPathComponent("installer.exe")
        try body.write(to: target)
        let url = StubProtocol.register(.init(body: Data(), status: 503))

        do {
            try await AssetFetcher.download(url, target: target, expected: Digests.sha256(body),
                                            size: Int64(body.count), configuration: Self.configuration())
            XCTFail("HTTP failure was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("unsuccessful HTTP response"))
        }

        XCTAssertEqual(try Data(contentsOf: target), body)
        XCTAssertEqual(try fixture.contents(), ["installer.exe"])
    }

    func testDownloadOnlyOfflineVerifiesCacheWithoutRunningTools() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let metadata = try fixture.writeMetadata()
        let installer = fixture.directory.appendingPathComponent("downloads/installer.exe")
        try FileManager.default.createDirectory(at: installer.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixture.installer.write(to: installer)
        let runner = ScriptedRunner { _, _ in
            XCTFail("Download-only mode must not invoke extraction tools")
            return ""
        }

        try await AssetFetcher(options: .init(repository: fixture.directory, offline: true, downloadOnly: true),
                               runner: runner, configuration: Self.configuration(), environment: ["PATH": ""])
            .run()

        XCTAssertEqual(metadata.size, Int64(fixture.installer.count))
        XCTAssertEqual(runner.count, 0)
        XCTAssertEqual(try Data(contentsOf: installer), fixture.installer)
    }

    func testOfflineMissingInstallerDoesNotDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeMetadata()

        do {
            try await AssetFetcher(options: .init(repository: fixture.directory, offline: true, downloadOnly: true),
                                   runner: ScriptedRunner.unused(), configuration: Self.configuration(), environment: ["PATH": ""])
                .run()
            XCTFail("Offline mode accepted a missing installer")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Installer not found"))
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("downloads").path))
    }

    func testExplicitMissingInstallerDoesNotFallBackToDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeMetadata()

        do {
            try await AssetFetcher(options: .init(repository: fixture.directory,
                                                  installer: fixture.directory.appendingPathComponent("missing.exe"), downloadOnly: true),
                                   runner: ScriptedRunner.unused(), configuration: Self.configuration(), environment: ["PATH": ""])
                .run()
            XCTFail("Missing explicit installer triggered a successful fetch")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Installer not found"))
        }
    }

    func testCachedInstallerMismatchIsReportedWithoutReplacingIt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.writeMetadata()
        let installer = fixture.directory.appendingPathComponent("existing.exe")
        let previous = Data(repeating: 0, count: fixture.installer.count)
        try previous.write(to: installer)

        do {
            try await AssetFetcher(options: .init(repository: fixture.directory, installer: installer, downloadOnly: true),
                                   runner: ScriptedRunner.unused(), configuration: Self.configuration(), environment: ["PATH": ""])
                .run()
            XCTFail("Cached installer hash mismatch was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("SHA-256 mismatch"))
        }

        XCTAssertEqual(try Data(contentsOf: installer), previous)
    }

    func testEmbeddedMSIExtractionStopsAtPinnedBoundary() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installer = fixture.directory.appendingPathComponent("installer.exe")
        let destination = fixture.directory.appendingPathComponent("embedded.msi")
        try fixture.installer.write(to: installer)

        try AssetFetcher.extractMSI(installer: installer, destination: destination, offset: 6,
                                    size: Int64(fixture.msi.count))

        XCTAssertEqual(try Data(contentsOf: destination), fixture.msi)
        XCTAssertThrowsError(try AssetFetcher.extractMSI(installer: installer, destination: destination,
                                                         offset: UInt64(fixture.installer.count - 1), size: 2)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Truncated embedded MSI"))
        }
    }

    func testMetadataRejectsEscapingPayloadPathsAndOutOfBoundsMSI() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let metadata = try fixture.writeMetadata()
        for name in ["../report.json", "nested/payload.dll", "nested\\payload.dll", ".", ".."] {
            let invalid = InstallerMetadata(url: metadata.url, size: metadata.size, sha256: metadata.sha256,
                                            version: metadata.version, msi: metadata.msi,
                                            payload: [name: .init(size: 0, sha256: Digests.sha256(Data()))])
            XCTAssertThrowsError(try invalid.validate())
        }
        let invalid = InstallerMetadata(url: metadata.url, size: metadata.size, sha256: metadata.sha256,
                                        version: metadata.version,
                                        msi: .init(offset: UInt64(metadata.size), size: 1, sha256: metadata.msi.sha256),
                                        payload: metadata.payload)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testAtomicPublicationPreservesReportsAndCleansTemporaryFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("source")
        let destination = fixture.directory.appendingPathComponent("assets/runtime.json")
        let report = fixture.directory.appendingPathComponent("assets/report.json")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        try Data("old".utf8).write(to: destination)
        try Data("report".utf8).write(to: report)

        try AssetFetcher.publishFile(source, destination: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: report), Data("report".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path).sorted(),
                       ["report.json", "runtime.json"])
        XCTAssertThrowsError(try AssetFetcher.publishFile(fixture.directory.appendingPathComponent("missing"), destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
    }

    func testGeneratedAssetDirectoryPublishesNestedDownmixAsCompleteGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = fixture.directory.appendingPathComponent("stage/assets")
        let downmix = staged.appendingPathComponent("downmix")
        let destination = fixture.directory.appendingPathComponent("repository/assets")
        try FileManager.default.createDirectory(at: downmix, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new manifest".utf8).write(to: staged.appendingPathComponent("manifest.json"))
        try Data("new downmix".utf8).write(to: downmix.appendingPathComponent("fir-bank.bin"))
        try Data("old manifest".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        try Data("stale generation".utf8).write(to: destination.appendingPathComponent("stale.bin"))

        try AssetFetcher.publishGeneratedDirectory(staged, destination: destination)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")),
                       Data("new manifest".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("downmix/fir-bank.bin")),
                       Data("new downmix".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("stale.bin").path))
        XCTAssertEqual(try Data(contentsOf: staged.appendingPathComponent("manifest.json")),
                       Data("old manifest".utf8))
    }

    func testGeneratedAssetDirectoryRejectsLinksWithoutChangingCurrentGeneration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let staged = fixture.directory.appendingPathComponent("stage/assets")
        let destination = fixture.directory.appendingPathComponent("repository/assets")
        let outside = fixture.directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside)
        try Data("current".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        try FileManager.default.createSymbolicLink(
            at: staged.appendingPathComponent("downmix"), withDestinationURL: outside
        )

        XCTAssertThrowsError(try AssetFetcher.publishGeneratedDirectory(staged, destination: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")),
                       Data("current".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testAssetPublicationReplacesLeafLinkWithoutChangingItsTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("source")
        let destination = fixture.directory.appendingPathComponent("assets/runtime.json")
        let sentinel = fixture.directory.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("new".utf8).write(to: source)
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sentinel)

        try AssetFetcher.publishFile(source, destination: destination)

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("sentinel".utf8))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        let sentinelAttributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((sentinelAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(destinationAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((destinationAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testDecompilerFailurePreservesWorkingAssetSetAndReports() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let metadata = try fixture.writeMetadata()
        let installer = fixture.directory.appendingPathComponent("installer.exe")
        try fixture.installer.write(to: installer)
        let currentAsset = fixture.directory.appendingPathComponent("assets/current.json")
        let report = fixture.directory.appendingPathComponent("analysis/reviewed-report.json")
        try FileManager.default.createDirectory(at: currentAsset.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current asset".utf8).write(to: currentAsset)
        try Data("reviewed report".utf8).write(to: report)
        let archiveTool = fixture.directory.appendingPathComponent("7zz")
        let decompiler = fixture.directory.appendingPathComponent("ilspycmd")
        try Self.writeExecutableELF(to: decompiler)
        let runner = ScriptedRunner { arguments, timeout in
            if arguments.first == archiveTool.path {
                XCTAssertEqual(timeout, 120)
                XCTAssertEqual(Array(arguments[1...3]), ["x", "-y", "-bd"])
                let output = URL(fileURLWithPath: String(arguments[4].dropFirst(2)))
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                if arguments.last == "Data1.cab" {
                    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: arguments[5])), fixture.msi)
                    try Data("cabinet".utf8).write(to: output.appendingPathComponent("Data1.cab"))
                } else {
                    try fixture.assembly.write(to: output.appendingPathComponent("inzonehub.dll"))
                }
                return ""
            }
            XCTAssertTrue(arguments[0].hasPrefix("/proc/"))
            XCTAssertTrue(arguments[0].contains("/fd/"))
            XCTAssertEqual(Array(arguments[1...3]), ["--disable-updatecheck", "-t", AssetExport.managedSourceTargets[0].typeName])
            XCTAssertEqual(timeout, 180)
            throw CommandError(arguments: arguments, status: 1, output: "simulated decompiler failure")
        }
        let fetcher = AssetFetcher(options: .init(repository: fixture.directory), runner: runner)

        XCTAssertThrowsError(try fetcher.prepare(installer: installer, metadata: metadata,
                                                sevenZip: archiveTool, decompiler: decompiler)) { error in
            XCTAssertTrue(error.localizedDescription.contains("simulated decompiler failure"))
        }

        XCTAssertEqual(runner.count, 3)
        XCTAssertEqual(try Data(contentsOf: currentAsset), Data("current asset".utf8))
        XCTAssertEqual(try Data(contentsOf: report), Data("reviewed report".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: report.deletingLastPathComponent().path), ["reviewed-report.json"])
    }

    func testOfflineDecompilerRequiresExistingPinnedTool() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = fixture.directory.appendingPathComponent("ilspycmd")
        let runner = ScriptedRunner { arguments, timeout in
            XCTAssertTrue(arguments[0].hasPrefix("/proc/"))
            XCTAssertTrue(arguments[0].contains("/fd/"))
            XCTAssertEqual(Array(arguments.dropFirst()), ["--version"])
            XCTAssertEqual(timeout, 30)
            return "ilspycmd: 11.0.0.93750\n"
        }
        let fetcher = AssetFetcher(options: .init(repository: fixture.directory, offline: true), runner: runner)
        XCTAssertThrowsError(try fetcher.prepareDecompiler(tool)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Offline mode requires"))
        }
        XCTAssertEqual(runner.count, 0)
        try Self.writeExecutableELF(to: tool)
        XCTAssertThrowsError(try fetcher.prepareDecompiler(tool)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Expected ilspycmd 11.0.0.9375"))
        }
        XCTAssertEqual(runner.count, 1)
    }

    func testVendorUpdaterBasenamesCannotBeUsedAsExecutableTools() throws {
        for name in [
            "blhost.exe", "earbudsfwupdate.dll", "FirmwareUpdateViewModel.exe",
            "fwupdate_headset.dll", "glhubupdatetoolcli.exe", "update.bat", "updatehub.bat",
        ] {
            XCTAssertThrowsError(try AssetFetcher.rejectVendorUpdaterExecutable(URL(fileURLWithPath: "/payload/" + name))) { error in
                XCTAssertTrue(error.localizedDescription.contains("static-catalog-only"))
            }
        }
        for name in ["7zz", "dotnet", "ilspycmd", "installer.exe"] {
            XCTAssertNoThrow(try AssetFetcher.rejectVendorUpdaterExecutable(URL(fileURLWithPath: "/tools/" + name)))
        }

        let fixture = try Fixture()
        defer { fixture.remove() }
        let updater = fixture.directory.appendingPathComponent("fwupdate_headset.dll")
        try Data().write(to: updater)
        let fetcher = AssetFetcher(
            options: .init(repository: fixture.directory, offline: true), runner: ScriptedRunner.unused()
        )
        XCTAssertThrowsError(try fetcher.prepareDecompiler(updater)) { error in
            XCTAssertTrue(error.localizedDescription.contains("static-catalog-only"))
        }
    }

    func testRenamedVendorPEIsRejectedBeforeRunnerInvocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = fixture.directory.appendingPathComponent("ilspycmd")
        try Data([0x4D, 0x5A] + Array(repeating: 0, count: 126)).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let runner = ScriptedRunner.unused()
        let fetcher = AssetFetcher(
            options: .init(repository: fixture.directory, offline: true), runner: runner
        )

        XCTAssertThrowsError(try fetcher.prepareDecompiler(tool)) { error in
            XCTAssertTrue(error.localizedDescription.contains("PE executables cannot"))
        }
        XCTAssertEqual(runner.count, 0)
    }

    func testForeignArchitectureELFIsRejectedBeforeRunnerInvocation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = fixture.directory.appendingPathComponent("ilspycmd")
        try Self.writeExecutableELF(to: tool, machine: Self.foreignELFMachine)
        let runner = ScriptedRunner.unused()
        let fetcher = AssetFetcher(
            options: .init(repository: fixture.directory, offline: true), runner: runner
        )

        XCTAssertThrowsError(try fetcher.prepareDecompiler(tool)) { error in
            XCTAssertTrue(error.localizedDescription.contains("ELF64 little-endian"))
        }
        XCTAssertEqual(runner.count, 0)
    }

    func testFirmwareArtifactsAreExcludedFromPublishedPayloadNames() {
        XCTAssertEqual(AssetFetcher.publishablePayloadNames([
            "inzonehub.dll", "updatehub.bat", "glhubupdatetoolcli.exe", "control.yaml",
            "fwupdate_headset.dll", "wf_g700n_param.bin", "glflash_v1.39.fl", "firmware-notes.txt",
            "custom.fl", "personal_param.bin",
        ]), ["control.yaml", "custom.fl", "firmware-notes.txt", "inzonehub.dll", "personal_param.bin"])
    }

    func testManagedPayloadPublicationReconcilesStaleFirmwareAndPreservesUserFilesAcrossReruns() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("source")
        let destination = fixture.directory.appendingPathComponent("analysis/payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("first managed value".utf8).write(to: source.appendingPathComponent("control.yaml"))
        try Data("first assembly".utf8).write(to: source.appendingPathComponent("inzonehub.dll"))
        try Data("stale updater".utf8).write(to: destination.appendingPathComponent("fwupdate_headset.dll"))
        try Data("user evidence".utf8).write(to: destination.appendingPathComponent("user-evidence.bin"))
        try Data("user firmware notes".utf8).write(to: destination.appendingPathComponent("firmware-notes.txt"))
        try Data("user flash data".utf8).write(to: destination.appendingPathComponent("custom.fl"))
        try Data("user parameters".utf8).write(to: destination.appendingPathComponent("personal_param.bin"))
        let sentinel = fixture.directory.appendingPathComponent("sentinel")
        try Data("outside payload".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: destination.appendingPathComponent("updatehub.bat"), withDestinationURL: sentinel
        )

        try AssetFetcher.publishManagedPayload(
            sourceDirectory: source, destinationDirectory: destination,
            names: ["control.yaml", "fwupdate_headset.dll", "inzonehub.dll"]
        )

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("control.yaml")),
                       Data("first managed value".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("fwupdate_headset.dll").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("updatehub.bat").path))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("outside payload".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("user-evidence.bin")),
                       Data("user evidence".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("firmware-notes.txt")),
                       Data("user firmware notes".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("custom.fl")),
                       Data("user flash data".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("personal_param.bin")),
                       Data("user parameters".utf8))

        try Data("second managed value".utf8).write(to: source.appendingPathComponent("control.yaml"))
        try Data("stale flash image".utf8).write(to: destination.appendingPathComponent("glflash_v1.39.fl"))
        try AssetFetcher.publishManagedPayload(
            sourceDirectory: source, destinationDirectory: destination, names: ["control.yaml"]
        )

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("control.yaml")),
                       Data("second managed value".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("glflash_v1.39.fl").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("inzonehub.dll").path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("user-evidence.bin")),
                       Data("user evidence".utf8))
    }

    func testManagedPayloadPreflightFailurePreservesExistingDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("source")
        let destination = fixture.directory.appendingPathComponent("analysis/payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("current managed value".utf8).write(to: destination.appendingPathComponent("control.yaml"))
        try Data("stale updater".utf8).write(to: destination.appendingPathComponent("fwupdate_headset.dll"))

        XCTAssertThrowsError(try AssetFetcher.publishManagedPayload(
            sourceDirectory: source, destinationDirectory: destination, names: ["control.yaml"]
        ))

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("control.yaml")),
                       Data("current managed value".utf8))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("fwupdate_headset.dll")),
                       Data("stale updater".utf8))
    }

    func testManagedPayloadPublicationRejectsLinkedDestinationDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("source")
        let outside = fixture.directory.appendingPathComponent("outside")
        let destination = fixture.directory.appendingPathComponent("analysis/payload")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        try Data("managed value".utf8).write(to: source.appendingPathComponent("control.yaml"))

        XCTAssertThrowsError(try AssetFetcher.publishManagedPayload(
            sourceDirectory: source, destinationDirectory: destination, names: ["control.yaml"]
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testDecompilerInstallPinsVersionSourceAndTelemetryEnvironment() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let tool = fixture.directory.appendingPathComponent("tools/ilspycmd")
        let dotnet = fixture.directory.appendingPathComponent("dotnet")
        try Data().write(to: dotnet)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dotnet.path)
        let runner = ScriptedRunner { arguments, timeout in
            if arguments.first == "env" {
                XCTAssertEqual(arguments, [
                    "env", "DOTNET_CLI_TELEMETRY_OPTOUT=1", "DOTNET_NOLOGO=1", dotnet.path,
                    "tool", "install", "ilspycmd", "--tool-path", tool.deletingLastPathComponent().path,
                    "--version", "11.0.0.9375", "--source", "https://api.nuget.org/v3/index.json",
                ])
                XCTAssertEqual(timeout, 240)
                try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.writeExecutableELF(to: tool)
                return ""
            }
            XCTAssertTrue(arguments[0].hasPrefix("/proc/"))
            XCTAssertTrue(arguments[0].contains("/fd/"))
            XCTAssertEqual(Array(arguments.dropFirst()), ["--version"])
            XCTAssertEqual(timeout, 30)
            return "ilspycmd: 11.0.0.9375\nICSharpCode.Decompiler: 11.0.0.9375\n"
        }
        let fetcher = AssetFetcher(options: .init(repository: fixture.directory), runner: runner,
                                   configuration: Self.configuration(), environment: ["PATH": fixture.directory.path])

        XCTAssertEqual(try fetcher.prepareDecompiler(tool), tool)
        XCTAssertEqual(runner.count, 2)
    }

    private static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return configuration
    }

    private struct Fixture: Sendable {
        let directory: URL
        let msi = Data("embedded MSI".utf8)
        let assembly = Data("managed assembly".utf8)
        var installer: Data { Data("prefix".utf8) + msi + Data("suffix".utf8) }

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-fetch-tests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }

        func writeMetadata() throws -> InstallerMetadata {
            let path = directory.appendingPathComponent("evidence/installer.json")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            let value: [String: Any] = [
                "url": "https://fixture.invalid/installer.exe", "version": "fixture", "size": installer.count,
                "sha256": Digests.sha256(installer),
                "msi": ["offset": 6, "size": msi.count, "sha256": Digests.sha256(msi)],
                "payload": ["inzonehub.dll": ["size": assembly.count, "sha256": Digests.sha256(assembly)]],
            ]
            try JSONSerialization.data(withJSONObject: value).write(to: path)
            return try InstallerMetadata.load(path)
        }

        func contents() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
    }

    private final class ScriptedRunner: CommandRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private let handler: @Sendable ([String], TimeInterval) throws -> String
        var count: Int { lock.withLock { calls } }

        init(_ handler: @escaping @Sendable ([String], TimeInterval) throws -> String) { self.handler = handler }

        static func unused() -> ScriptedRunner {
            ScriptedRunner { arguments, _ in
                XCTFail("Unexpected command: \(arguments)")
                throw InzoneError.message("Unexpected test command")
            }
        }

        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            XCTAssertNil(input)
            lock.withLock { calls += 1 }
            return try handler(arguments, timeout)
        }
    }

    private final class RedirectResult: @unchecked Sendable {
        private let lock = NSLock()
        private var didCall = false
        private var redirectedRequest: URLRequest?
        var called: Bool { lock.withLock { didCall } }
        var request: URLRequest? { lock.withLock { redirectedRequest } }

        func record(_ request: URLRequest?) {
            lock.withLock {
                didCall = true
                redirectedRequest = request
            }
        }
    }

    private final class StubProtocol: URLProtocol {
        struct Response: Sendable {
            let body: Data
            var status = 200
            var responseURL: URL?
            var advertiseLength = true
        }

        private final class Registry: @unchecked Sendable {
            let lock = NSLock()
            var responses: [URL: Response] = [:]
        }

        private static let registry = Registry()

        static func register(_ response: Response) -> URL {
            let url = URL(string: "https://fixture.invalid/\(UUID().uuidString)/installer.exe")!
            registry.lock.withLock { registry.responses[url] = response }
            return url
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url,
                  let response = Self.registry.lock.withLock({ Self.registry.responses.removeValue(forKey: url) }) else {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
                return
            }
            let headers = response.advertiseLength ? ["Content-Length": String(response.body.count)] : [:]
            let result = HTTPURLResponse(url: response.responseURL ?? url, statusCode: response.status,
                                         httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: result, cacheStoragePolicy: .notAllowed)
            for offset in stride(from: 0, to: response.body.count, by: 3) {
                client?.urlProtocol(self, didLoad: response.body.subdata(in: offset..<min(offset + 3, response.body.count)))
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
