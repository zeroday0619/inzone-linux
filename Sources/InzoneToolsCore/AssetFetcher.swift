import Foundation
import FoundationNetworking
import Glibc
import InzoneCore

public struct AssetFetchOptions: Sendable {
    public let repository: URL
    public let installer: URL?
    public let offline: Bool
    public let downloadOnly: Bool
    public let decompiler: URL?

    public init(repository: URL, installer: URL? = nil, offline: Bool = false,
                downloadOnly: Bool = false, decompiler: URL? = nil) {
        self.repository = repository.standardizedFileURL
        self.installer = installer
        self.offline = offline
        self.downloadOnly = downloadOnly
        self.decompiler = decompiler
    }
}

public struct AssetFetcher: Sendable {
    public static let decompilerVersion = "11.0.0.9375"
    static let blockSize = 1024 * 1024

    public let options: AssetFetchOptions
    public let runner: any CommandRunning
    private let configuration: URLSessionConfiguration
    private let environment: [String: String]

    public init(options: AssetFetchOptions, runner: any CommandRunning = SystemCommandRunner()) {
        self.init(options: options, runner: runner, configuration: .ephemeral,
                  environment: ProcessInfo.processInfo.environment)
    }

    init(options: AssetFetchOptions, runner: any CommandRunning,
         configuration: URLSessionConfiguration, environment: [String: String]) {
        self.options = options
        self.runner = runner
        self.configuration = configuration
        self.environment = environment
    }

    public func run() async throws {
        let metadata = try InstallerMetadata.load(options.repository.appendingPathComponent("evidence/installer.json"))
        let installer = (options.installer ?? options.repository.appendingPathComponent("downloads")
            .appendingPathComponent(metadata.url.lastPathComponent)).standardizedFileURL.resolvingSymlinksInPath()
        var sevenZip: URL?
        var decompiler: URL?
        if !options.downloadOnly {
            guard let archiveTool = executable("7zz") ?? executable("7z") else {
                throw InzoneError.message("Install 7-Zip (7zz or 7z) before extracting assets.")
            }
            sevenZip = archiveTool
            decompiler = try prepareDecompiler(options.decompiler ?? options.repository.appendingPathComponent("tools/ilspycmd"))
        }
        if FileManager.default.fileExists(atPath: installer.path) {
            try Self.verify(installer, expected: metadata.sha256, size: metadata.size)
            print(Self.cachedInstallerMessage(installer))
        } else {
            guard options.installer == nil, !options.offline else {
                throw InzoneError.message("Installer not found: \(installer.path)")
            }
            print(Self.downloadMessage(version: metadata.version))
            try await Self.download(metadata.url, target: installer, expected: metadata.sha256,
                                    size: metadata.size, configuration: configuration)
            print("Installer SHA-256 verified.")
        }
        if let sevenZip, let decompiler {
            try prepare(installer: installer, metadata: metadata, sevenZip: sevenZip, decompiler: decompiler)
        }
    }

    static func cachedInstallerMessage(_ installer: URL) -> String {
        "Verified cached installer: "
            + TerminalOutput.escaped(installer.lastPathComponent, preservingNewlines: false)
    }

    static func downloadMessage(version: String) -> String {
        "Downloading INZONE Hub "
            + TerminalOutput.escaped(version, preservingNewlines: false)
            + " from Sony..."
    }

    static func verify(_ file: URL, expected: String, size: Int64? = nil) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw InzoneError.message("Expected a regular file: \(file.lastPathComponent)")
        }
        if let size, Int64(values.fileSize ?? -1) != size {
            throw InzoneError.message("Unexpected file size: \(file.lastPathComponent)")
        }
        guard try Digests.sha256(file: file) == expected else {
            throw InzoneError.message("SHA-256 mismatch: \(file.lastPathComponent)")
        }
    }

    static func verify(_ fileHandle: FileHandle, name: String, expected: String, size: Int64? = nil) throws {
        var status = stat()
        guard Glibc.fstat(fileHandle.fileDescriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw InzoneError.message("Expected a regular file: \(name)")
        }
        if let size, status.st_size != off_t(size) {
            throw InzoneError.message("Unexpected file size: \(name)")
        }
        guard try Digests.sha256(fileHandle: fileHandle) == expected else {
            throw InzoneError.message("SHA-256 mismatch: \(name)")
        }
    }

    static func download(_ url: URL, target: URL, expected: String, size: Int64,
                         configuration: URLSessionConfiguration = .ephemeral) async throws {
        try HTTPSDownloadPolicy.validate(url)
        guard size >= 0 else { throw InzoneError.message("Pinned download size cannot be negative.") }
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stagedDownload = try AtomicFile.stage(for: target)
        let transfer = PinnedDownload(
            url: url, output: stagedDownload.fileHandle, size: size, configuration: configuration
        )
        try await transfer.receive()
        try Task.checkCancellation()
        try verify(stagedDownload.fileHandle, name: target.lastPathComponent, expected: expected, size: size)
        try Task.checkCancellation()
        try stagedDownload.publish()
    }

    func prepareDecompiler(_ path: URL) throws -> URL {
        let path = path.standardizedFileURL.resolvingSymlinksInPath()
        if !FileManager.default.fileExists(atPath: path.path) {
            guard !options.offline else {
                throw InzoneError.message("Offline mode requires an installed ilspycmd; use --ilspycmd PATH.")
            }
            guard let dotnet = executable("dotnet") else {
                throw InzoneError.message("Install the .NET 10 SDK to obtain ilspycmd.")
            }
            print("Installing ilspycmd \(Self.decompilerVersion) from NuGet...")
            _ = try runTool([
                "env", "DOTNET_CLI_TELEMETRY_OPTOUT=1", "DOTNET_NOLOGO=1", dotnet.path,
                "tool", "install", "ilspycmd", "--tool-path", path.deletingLastPathComponent().path,
                "--version", Self.decompilerVersion, "--source", "https://api.nuget.org/v3/index.json",
            ], timeout: 240)
        }
        let version = try runTool([path.path, "--version"], timeout: 30)
        guard version.components(separatedBy: .newlines).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "ilspycmd: \(Self.decompilerVersion)"
        }) else {
            throw InzoneError.message("Expected ilspycmd \(Self.decompilerVersion): \(path.path)")
        }
        return path
    }

    func prepare(installer: URL, metadata: InstallerMetadata, sevenZip: URL, decompiler: URL) throws {
        let manager = FileManager.default
        let analysis = options.repository.appendingPathComponent("analysis")
        try manager.createDirectory(at: analysis, withIntermediateDirectories: true)
        let stage = analysis.appendingPathComponent(".fetch-assets-\(UUID().uuidString)")
        try manager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: stage) }
        let msi = stage.appendingPathComponent("INZONEHub.msi")
        try Self.extractMSI(installer: installer, destination: msi, offset: metadata.msi.offset, size: metadata.msi.size)
        try Self.verify(msi, expected: metadata.msi.sha256, size: metadata.msi.size)
        print("Extracting MSI and CAB without running Windows code...")
        let extractedMSI = stage.appendingPathComponent("msi")
        _ = try runTool([sevenZip.path, "x", "-y", "-bd", "-o" + extractedMSI.path, msi.path, "Data1.cab"], timeout: 120)
        let payload = stage.appendingPathComponent("payload")
        _ = try runTool([sevenZip.path, "x", "-y", "-bd", "-o" + payload.path,
                         extractedMSI.appendingPathComponent("Data1.cab").path], timeout: 120)
        for (name, pin) in metadata.payload {
            try Self.verify(payload.appendingPathComponent(name), expected: pin.sha256, size: pin.size)
        }
        let decompiled = stage.appendingPathComponent("decompiled")
        try manager.createDirectory(at: decompiled, withIntermediateDirectories: false)
        for type in [AssetExport.equalizerSourceType, AssetExport.presetSourceType] {
            print("Extracting " + (type.split(separator: ".").last.map(String.init) ?? type) + "...")
            let content = try runTool([decompiler.path, "--disable-updatecheck", "-t", type,
                                       payload.appendingPathComponent("inzonehub.dll").path], timeout: 180)
            try Data(content.utf8).write(to: decompiled.appendingPathComponent(type + ".decompiled.cs"))
        }
        let assets = stage.appendingPathComponent("assets")
        try FilterBank.export(payload: payload, destination: assets)
        try AssetExport.equalizerTables(payload: payload, decompiled: decompiled, destination: assets)
        try AssetExport.presets(payload: payload, decompiled: decompiled, destination: assets)

        // Publication starts only after all extraction and transformation steps succeed.
        for name in metadata.payload.keys.sorted() {
            try Self.publishFile(payload.appendingPathComponent(name), destination: analysis.appendingPathComponent("payload/" + name))
        }
        for source in try manager.contentsOfDirectory(at: decompiled, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Self.publishFile(source, destination: analysis.appendingPathComponent("decompiled/" + source.lastPathComponent))
        }
        for source in try manager.contentsOfDirectory(at: assets, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Self.publishFile(source, destination: options.repository.appendingPathComponent("assets/" + source.lastPathComponent))
        }
        print("Ready: analysis/payload, analysis/decompiled, assets (all ignored by Git).")
    }

    static func extractMSI(installer: URL, destination: URL, offset: UInt64, size: Int64) throws {
        guard size >= 0 else { throw InzoneError.message("Embedded MSI size cannot be negative.") }
        let source = try FileHandle(forReadingFrom: installer)
        defer { try? source.close() }
        let stagedOutput = try AtomicFile.stage(for: destination)
        let output = stagedOutput.fileHandle
        try source.seek(toOffset: offset)
        var remaining = size
        while remaining > 0 {
            let block = try source.read(upToCount: Int(min(Int64(blockSize), remaining))) ?? Data()
            guard !block.isEmpty else { throw InzoneError.message("Truncated embedded MSI.") }
            try output.write(contentsOf: block)
            remaining -= Int64(block.count)
        }
        try output.synchronize()
        try stagedOutput.publish()
    }

    static func publishFile(_ source: URL, destination: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let stagedOutput = try AtomicFile.stage(for: destination, permissions: 0o644)
        while let block = try input.read(upToCount: blockSize), !block.isEmpty {
            try stagedOutput.fileHandle.write(contentsOf: block)
        }
        try stagedOutput.publish()
    }

    private func executable(_ name: String) -> URL? {
        for directory in (environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin").split(separator: ":", omittingEmptySubsequences: false) {
            let url = URL(fileURLWithPath: directory.isEmpty ? "." : String(directory), isDirectory: true).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    private func runTool(_ arguments: [String], timeout: TimeInterval) throws -> String {
        do {
            return try runner.run(arguments, input: nil, timeout: timeout)
        } catch let error as CommandError {
            let detail = error.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(3000)
            let reason = error.timedOut ? "timed out" : "failed"
            throw InzoneError.message("\(URL(fileURLWithPath: arguments[0]).lastPathComponent) \(reason): \(detail)")
        }
    }
}

struct InstallerMetadata: Decodable, Sendable {
    struct FilePin: Decodable, Sendable {
        let size: Int64
        let sha256: String
    }
    struct EmbeddedMSI: Decodable, Sendable {
        let offset: UInt64
        let size: Int64
        let sha256: String
    }
    let url: URL
    let size: Int64
    let sha256: String
    let version: String
    let msi: EmbeddedMSI
    let payload: [String: FilePin]

    static func load(_ path: URL) throws -> InstallerMetadata {
        let metadata = try JSONDecoder().decode(Self.self, from: Data(contentsOf: path))
        try metadata.validate()
        return metadata
    }

    func validate() throws {
        try HTTPSDownloadPolicy.validate(url)
        guard size >= 0, !url.lastPathComponent.isEmpty, msi.size >= 0,
              msi.offset <= UInt64(size), UInt64(msi.size) <= UInt64(size) - msi.offset,
              Self.validDigest(sha256), Self.validDigest(msi.sha256), !payload.isEmpty else {
            throw InzoneError.message("Invalid pinned installer metadata.")
        }
        for (name, pin) in payload {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"),
                  !name.contains("\0"), pin.size >= 0, Self.validDigest(pin.sha256) else {
                throw InzoneError.message("Invalid pinned payload entry: \(name)")
            }
        }
    }

    private static func validDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

enum HTTPSDownloadPolicy {
    static func validate(_ url: URL, redirect: Bool = false) throws {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else {
            throw InzoneError.message(redirect ? "Download redirect must use HTTPS." : "Download must use HTTPS.")
        }
    }
}

/// The lock serializes cancellation with URLSession callbacks and file writes.
final class PinnedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let output: FileHandle
    private let size: Int64
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var total: Int64 = 0
    private var failure: (any Error)?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false

    init(url: URL, output: FileHandle, size: Int64, configuration: URLSessionConfiguration) {
        self.url = url
        self.output = output
        self.size = size
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.timeoutIntervalForRequest = 60
        self.configuration.timeoutIntervalForResource = 60 * 60
    }

    func receive() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.withLock {
                    guard !cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    let queue = OperationQueue()
                    queue.maxConcurrentOperationCount = 1
                    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
                    self.session = session
                    let task = session.dataTask(with: url)
                    self.task = task
                    task.resume()
                }
            }
        } onCancel: {
            self.lock.withLock {
                self.cancelled = true
                self.failure = CancellationError()
                self.task?.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        do {
            guard let url = request.url else { throw InzoneError.message("Download redirect URL is missing.") }
            try HTTPSDownloadPolicy.validate(url, redirect: true)
            completionHandler(request)
        } catch {
            lock.withLock { if failure == nil { failure = error } }
            completionHandler(nil)
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        do {
            guard let url = response.url else { throw InzoneError.message("Download response URL is missing.") }
            try HTTPSDownloadPolicy.validate(url)
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                throw InzoneError.message("Installer download returned an unsuccessful HTTP response.")
            }
            guard response.expectedContentLength <= size else {
                throw InzoneError.message("Download exceeds pinned file size.")
            }
            completionHandler(.allow)
        } catch {
            lock.withLock { if failure == nil { failure = error } }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock {
            guard failure == nil else { return }
            do {
                guard Int64(data.count) <= size - total else {
                    throw InzoneError.message("Download exceeds pinned file size.")
                }
                try output.write(contentsOf: data)
                total += Int64(data.count)
            } catch {
                failure = error
                dataTask.cancel()
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let outcome: (CheckedContinuation<Void, any Error>?, (any Error)?) = lock.withLock {
            var finalError = failure ?? error
            do { try output.synchronize() }
            catch { if finalError == nil { finalError = error } }
            let pending = continuation
            continuation = nil
            self.task = nil
            self.session = nil
            return (pending, finalError)
        }
        session.finishTasksAndInvalidate()
        if let error = outcome.1 { outcome.0?.resume(throwing: error) }
        else { outcome.0?.resume() }
    }
}
