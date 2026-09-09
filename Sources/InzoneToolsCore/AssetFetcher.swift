import Foundation
import FoundationNetworking
import Glibc
import InzoneCore

@_silgen_name("renameat2")
private func fetchRenameAt2(
    _ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>,
    _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32
) -> Int32

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
    static let managedPayloadManifestName = ".inzone-managed-payload.json"

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
        try Self.rejectVendorUpdaterExecutable(path)
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
        let version = try runVerifiedDecompiler(path, arguments: ["--version"], timeout: 30)
        guard version.components(separatedBy: .newlines).contains(where: {
            $0.trimmingCharacters(in: .whitespaces) == "ilspycmd: \(Self.decompilerVersion)"
        }) else {
            throw InzoneError.message("Expected ilspycmd \(Self.decompilerVersion): \(path.path)")
        }
        return path
    }

    func prepare(installer: URL, metadata: InstallerMetadata, sevenZip: URL, decompiler: URL) throws {
        try Self.rejectVendorUpdaterExecutable(sevenZip)
        try Self.rejectVendorUpdaterExecutable(decompiler)
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
        for target in AssetExport.managedSourceTargets {
            let type = target.typeName
            print("Extracting " + (type.split(separator: ".").last.map(String.init) ?? type) + "...")
            let content = try runVerifiedDecompiler(
                decompiler,
                arguments: ["--disable-updatecheck", "-t", type,
                            payload.appendingPathComponent("inzonehub.dll").path],
                timeout: 180
            )
            try Data(content.utf8).write(to: decompiled.appendingPathComponent(type + ".decompiled.cs"))
        }
        let assets = stage.appendingPathComponent("assets")
        try FilterBank.export(payload: payload, destination: assets)
        try AssetExport.equalizerTables(payload: payload, decompiled: decompiled, destination: assets)
        try AssetExport.presets(payload: payload, decompiled: decompiled, destination: assets)
        let inventory = stage.appendingPathComponent("reverse-engineering-inventory.json")
        try AssetExport.reverseEngineeringInventory(
            payload: payload, decompiled: decompiled,
            decompilerVersion: Self.decompilerVersion, destination: inventory
        )

        // Publication starts only after all extraction and transformation steps succeed.
        try Self.publishManagedPayload(
            sourceDirectory: payload, destinationDirectory: analysis.appendingPathComponent("payload"),
            names: Array(metadata.payload.keys)
        )
        for source in try manager.contentsOfDirectory(at: decompiled, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            try Self.publishFile(source, destination: analysis.appendingPathComponent("decompiled/" + source.lastPathComponent))
        }
        try Self.publishFile(inventory, destination: analysis.appendingPathComponent("reverse-engineering-inventory.json"))
        try Self.publishGeneratedDirectory(assets, destination: options.repository.appendingPathComponent("assets"))
        print("Ready: analysis/payload, analysis/decompiled, analysis/reverse-engineering-inventory.json, assets (all ignored by Git).")
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

    static func publishGeneratedDirectory(_ staged: URL, destination: URL) throws {
        try validateGeneratedDirectory(staged)
        let sourceParent = staged.deletingLastPathComponent()
        let destinationParent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        let sourceDescriptor = Glibc.open(sourceParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw InzoneError.message("Cannot open generated asset parent directory: \(sourceParent.path)")
        }
        defer { Glibc.close(sourceDescriptor) }
        let destinationDescriptor = Glibc.open(
            destinationParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard destinationDescriptor >= 0 else {
            throw InzoneError.message("Cannot open asset destination parent directory: \(destinationParent.path)")
        }
        defer { Glibc.close(destinationDescriptor) }

        var destinationStatus = stat()
        let destinationResult = Glibc.fstatat(
            destinationDescriptor, destination.lastPathComponent, &destinationStatus, AT_SYMLINK_NOFOLLOW
        )
        let exchanged = destinationResult == 0
        if exchanged {
            guard (destinationStatus.st_mode & S_IFMT) == S_IFDIR else {
                throw InzoneError.message("Asset destination must be a regular directory: \(destination.path)")
            }
            let result = staged.lastPathComponent.withCString { sourceName in
                destination.lastPathComponent.withCString { destinationName in
                    fetchRenameAt2(sourceDescriptor, sourceName, destinationDescriptor, destinationName, 2)
                }
            }
            guard result == 0 else {
                throw InzoneError.message("Cannot atomically exchange generated assets: \(String(cString: strerror(errno))).")
            }
        } else {
            guard errno == ENOENT else {
                throw InzoneError.message("Cannot inspect asset destination: \(String(cString: strerror(errno))).")
            }
            let result = staged.lastPathComponent.withCString { sourceName in
                destination.lastPathComponent.withCString { destinationName in
                    Glibc.renameat(sourceDescriptor, sourceName, destinationDescriptor, destinationName)
                }
            }
            guard result == 0 else {
                throw InzoneError.message("Cannot publish generated assets: \(String(cString: strerror(errno))).")
            }
        }
        guard Glibc.fsync(destinationDescriptor) == 0 else {
            let synchronizeError = String(cString: strerror(errno))
            let rollbackResult: Int32
            if exchanged {
                rollbackResult = destination.lastPathComponent.withCString { destinationName in
                    staged.lastPathComponent.withCString { sourceName in
                        fetchRenameAt2(destinationDescriptor, destinationName, sourceDescriptor, sourceName, 2)
                    }
                }
            } else {
                rollbackResult = destination.lastPathComponent.withCString { destinationName in
                    staged.lastPathComponent.withCString { sourceName in
                        Glibc.renameat(destinationDescriptor, destinationName, sourceDescriptor, sourceName)
                    }
                }
            }
            guard rollbackResult == 0 else {
                throw InzoneError.message(
                    "Cannot synchronize or roll back generated asset publication: \(synchronizeError)."
                )
            }
            throw InzoneError.message("Cannot synchronize generated asset publication: \(synchronizeError).")
        }
    }

    private static func validateGeneratedDirectory(_ directory: URL) throws {
        var rootStatus = stat()
        guard Glibc.lstat(directory.path, &rootStatus) == 0, (rootStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw InzoneError.message("Generated assets must be a regular directory: \(directory.path)")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            throw InzoneError.message("Cannot enumerate generated assets: \(directory.path)")
        }
        for case let entry as URL in enumerator {
            let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else {
                throw InzoneError.message("Generated assets contain a link or special file: \(entry.path)")
            }
        }
    }

    static func publishManagedPayload(sourceDirectory: URL, destinationDirectory: URL, names: [String]) throws {
        let manager = FileManager.default
        let publishableNames = publishablePayloadNames(names)
        for name in publishableNames {
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                  !name.contains("\\"), !name.contains("\0") else {
                throw InzoneError.message("Invalid managed payload filename: \(name)")
            }
            let source = sourceDirectory.appendingPathComponent(name)
            let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw InzoneError.message("Expected a regular managed payload file: \(name)")
            }
        }
        let destinationParent = destinationDirectory.deletingLastPathComponent()
        try manager.createDirectory(at: destinationParent, withIntermediateDirectories: true)
        var destinationStatus = stat()
        let destinationResult = Glibc.lstat(destinationDirectory.path, &destinationStatus)
        if destinationResult == 0 {
            guard (destinationStatus.st_mode & S_IFMT) == S_IFDIR else {
                throw InzoneError.message("Managed payload destination must be a regular directory: \(destinationDirectory.path)")
            }
        } else if errno != ENOENT {
            throw InzoneError.message("Cannot inspect managed payload destination: \(destinationDirectory.path)")
        }
        let previousManagedNames = destinationResult == 0
            ? try managedPayloadNames(in: destinationDirectory) : []
        let staged = destinationParent.appendingPathComponent(".payload-publish-" + UUID().uuidString.lowercased())
        try manager.createDirectory(
            at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        defer { try? manager.removeItem(at: staged) }
        if destinationResult == 0 {
            let replacedNames = Set(publishableNames).union(previousManagedNames)
            for name in try manager.contentsOfDirectory(atPath: destinationDirectory.path).sorted()
                where name != managedPayloadManifestName
                    && !replacedNames.contains(name)
                    && !AssetExport.isKnownVendorFirmwareArtifact(name)
            {
                try manager.copyItem(
                    at: destinationDirectory.appendingPathComponent(name),
                    to: staged.appendingPathComponent(name)
                )
            }
        }
        for name in publishableNames {
            try publishFile(
                sourceDirectory.appendingPathComponent(name), destination: staged.appendingPathComponent(name)
            )
        }
        let manifest = ManagedPayloadManifest(schemaVersion: 1, files: publishableNames)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(
            encoder.encode(manifest) + Data([0x0A]),
            to: staged.appendingPathComponent(managedPayloadManifestName), permissions: 0o644
        )
        try publishGeneratedDirectory(staged, destination: destinationDirectory)
    }

    static func removeStaleFirmwareArtifacts(from directory: URL) throws {
        let descriptor = Glibc.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InzoneError.message("Cannot open managed payload directory: \(directory.path)")
        }
        defer { Glibc.close(descriptor) }
        try removeStaleFirmwareArtifacts(fromDirectoryDescriptor: descriptor, directory: directory)
    }

    private static func removeStaleFirmwareArtifacts(fromDirectoryDescriptor descriptor: Int32, directory: URL) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            where AssetExport.isKnownVendorFirmwareArtifact(name)
        {
            var status = stat()
            guard Glibc.fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                throw InzoneError.message("Cannot inspect stale firmware artifact: \(name)")
            }
            let fileType = status.st_mode & S_IFMT
            guard fileType == S_IFREG || fileType == S_IFLNK else { continue }
            guard Glibc.unlinkat(descriptor, name, 0) == 0 || errno == ENOENT else {
                throw InzoneError.message("Cannot remove stale firmware artifact: \(name)")
            }
        }
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
            if let executable = arguments.first {
                try Self.rejectVendorUpdaterExecutable(URL(fileURLWithPath: executable))
            }
            return try runner.run(arguments, input: nil, timeout: timeout)
        } catch let error as CommandError {
            let detail = error.output.trimmingCharacters(in: .whitespacesAndNewlines).suffix(3000)
            let reason = error.timedOut ? "timed out" : "failed"
            throw InzoneError.message("\(URL(fileURLWithPath: arguments[0]).lastPathComponent) \(reason): \(detail)")
        }
    }

    private func runVerifiedDecompiler(
        _ executable: URL, arguments: [String], timeout: TimeInterval
    ) throws -> String {
        try Self.rejectVendorUpdaterExecutable(executable)
        let handle = try Self.openValidatedDecompilerExecutable(executable)
        defer { try? handle.close() }
        let descriptorPath = "/proc/\(Glibc.getpid())/fd/\(handle.fileDescriptor)"
        return try runTool([descriptorPath] + arguments, timeout: timeout)
    }

    static func openValidatedDecompilerExecutable(_ executable: URL) throws -> FileHandle {
        let descriptor = Glibc.open(executable.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InzoneError.message("Cannot open ilspycmd as a regular file: \(executable.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            var status = stat()
            guard Glibc.fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
                  status.st_size > 0, status.st_size <= 64 * 1024 * 1024,
                  status.st_mode & 0o111 != 0 else {
                throw InzoneError.message("ilspycmd must be an executable regular file no larger than 64 MiB.")
            }
            let data = try handle.readToEnd() ?? Data()
            let bytes = [UInt8](data)
            if bytes.count >= 2, bytes[0] == 0x4D, bytes[1] == 0x5A {
                throw InzoneError.message("PE executables cannot be used as ilspycmd.")
            }
            func unsigned16(_ offset: Int) -> UInt16 {
                UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
            }
            func unsigned32(_ offset: Int) -> UInt32 {
                UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                    | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            }
            func unsigned64(_ offset: Int) -> UInt64 {
                (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << UInt64($1 * 8) }
            }
            #if arch(x86_64)
            let expectedMachine: UInt16 = 62
            let architecture = "x86_64"
            #elseif arch(arm64)
            let expectedMachine: UInt16 = 183
            let architecture = "arm64"
            #else
            #error("AssetFetcher supports ilspycmd only on x86_64 and arm64 hosts.")
            #endif
            guard bytes.count >= 64, Array(bytes[0..<4]) == [0x7F, 0x45, 0x4C, 0x46],
                  bytes[4] == 2, bytes[5] == 1, bytes[6] == 1,
                  unsigned16(18) == expectedMachine else {
                throw InzoneError.message("ilspycmd must be an ELF64 little-endian \(architecture) executable.")
            }
            let programOffset = unsigned64(32)
            let programEntrySize = UInt64(unsigned16(54))
            let programCount = UInt64(unsigned16(56))
            let (programBytes, programOverflow) = programEntrySize.multipliedReportingOverflow(by: programCount)
            let (programEnd, endOverflow) = programOffset.addingReportingOverflow(programBytes)
            guard !programOverflow, !endOverflow, programEntrySize >= 56, programCount > 0,
                  programEnd <= UInt64(bytes.count) else {
                throw InzoneError.message("ilspycmd contains an invalid ELF program-header table.")
            }
            let executableLoad = (0..<Int(programCount)).contains { index in
                let offset = Int(programOffset + UInt64(index) * programEntrySize)
                return unsigned32(offset) == 1 && unsigned32(offset + 4) & 1 != 0
            }
            guard executableLoad else {
                throw InzoneError.message("ilspycmd ELF does not contain an executable PT_LOAD segment.")
            }
            return handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func rejectVendorUpdaterExecutable(_ executable: URL) throws {
        let resolvedExecutable = executable.standardizedFileURL.resolvingSymlinksInPath()
        let name = resolvedExecutable.lastPathComponent.lowercased()
        let updater = name.contains("firmware") || name.contains("fwupdate")
            || name == "blhost.exe" || name == "glhubupdatetoolcli.exe"
            || (name.hasPrefix("update") && name.hasSuffix(".bat"))
        guard !updater else {
            throw InzoneError.message("Firmware updater artifacts are static-catalog-only and cannot be executed: \(resolvedExecutable.lastPathComponent)")
        }
    }

    static func publishablePayloadNames(_ names: [String]) -> [String] {
        names.filter { !AssetExport.isKnownVendorFirmwareArtifact($0) }.sorted()
    }

    private static func managedPayloadNames(in directory: URL) throws -> Set<String> {
        let manifest = directory.appendingPathComponent(managedPayloadManifestName)
        let descriptor = Glibc.open(manifest.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return [] }
            throw InzoneError.message("Cannot inspect managed payload manifest: \(manifest.path)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var status = stat()
        guard Glibc.fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
            throw InzoneError.message("Managed payload manifest must be a regular file: \(manifest.path)")
        }
        let value = try JSONDecoder().decode(ManagedPayloadManifest.self, from: handle.readToEnd() ?? Data())
        guard value.schemaVersion == 1, value.files == value.files.sorted(),
              Set(value.files).count == value.files.count,
              value.files.allSatisfy({ name in
                  !name.isEmpty && name != "." && name != ".." && !name.contains("/")
                      && !name.contains("\\") && !name.contains("\0")
              }) else {
            throw InzoneError.message("Invalid managed payload manifest: \(manifest.path)")
        }
        return Set(value.files)
    }
}

private struct ManagedPayloadManifest: Codable {
    let schemaVersion: Int
    let files: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case files
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
