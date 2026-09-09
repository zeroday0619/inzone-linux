import Foundation
import FoundationNetworking
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class AssetFetcherTests: XCTestCase, @unchecked Sendable {
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
            XCTAssertEqual(arguments.first, decompiler.path)
            XCTAssertEqual(Array(arguments[1...3]), ["--disable-updatecheck", "-t", AssetExport.equalizerSourceType])
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
            XCTAssertEqual(arguments, [tool.path, "--version"])
            XCTAssertEqual(timeout, 30)
            return "ilspycmd: 11.0.0.93750\n"
        }
        let fetcher = AssetFetcher(options: .init(repository: fixture.directory, offline: true), runner: runner)
        XCTAssertThrowsError(try fetcher.prepareDecompiler(tool)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Offline mode requires"))
        }
        XCTAssertEqual(runner.count, 0)
        try Data().write(to: tool)
        XCTAssertThrowsError(try fetcher.prepareDecompiler(tool)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Expected ilspycmd 11.0.0.9375"))
        }
        XCTAssertEqual(runner.count, 1)
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
                try Data().write(to: tool)
                return ""
            }
            XCTAssertEqual(arguments, [tool.path, "--version"])
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
