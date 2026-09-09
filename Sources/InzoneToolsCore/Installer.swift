import Foundation
import Glibc
import InzoneCore

@_silgen_name("renameat2")
private func renameAt2(
    _ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>,
    _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32
) -> Int32

public struct InstallOptions: Sendable {
    public let repository: URL
    public let home: URL
    public let binary: URL
    public let payload: URL?
    public let expectedPluginSHA256: String

    public init(repository: URL, home: URL, binary: URL, payload: URL? = nil, expectedPluginSHA256: String) {
        self.repository = repository
        self.home = home
        self.binary = binary
        self.payload = payload
        self.expectedPluginSHA256 = expectedPluginSHA256
    }
}

public struct SystemInstallOptions: Sendable {
    public let repository: URL?
    public let stagingRoot: URL?
    public let pluginSource: URL?
    public let udevRuleSource: URL?
    public let expectedPluginSHA256: String
    public let expectedUdevRuleSHA256: String

    public init(
        repository: URL? = nil, stagingRoot: URL? = nil,
        pluginSource: URL? = nil, udevRuleSource: URL? = nil,
        expectedPluginSHA256: String, expectedUdevRuleSHA256: String
    ) {
        self.repository = repository
        self.stagingRoot = stagingRoot
        self.pluginSource = pluginSource
        self.udevRuleSource = udevRuleSource
        self.expectedPluginSHA256 = expectedPluginSHA256
        self.expectedUdevRuleSHA256 = expectedUdevRuleSHA256
    }
}

public struct Installer {
    public let options: InstallOptions
    private let manager = FileManager.default
    private let effectiveUserIDProvider: @Sendable () -> uid_t
    private let runtimeHomeProvider: @Sendable () -> URL

    public init(options: InstallOptions) {
        self.options = options
        self.effectiveUserIDProvider = { Glibc.geteuid() }
        self.runtimeHomeProvider = { InzonePaths().home }
    }

    init(
        options: InstallOptions,
        effectiveUserIDProvider: @escaping @Sendable () -> uid_t,
        runtimeHomeProvider: @escaping @Sendable () -> URL
    ) {
        self.options = options
        self.effectiveUserIDProvider = effectiveUserIDProvider
        self.runtimeHomeProvider = runtimeHomeProvider
    }

    init(options: InstallOptions, effectiveUserID: uid_t) {
        self.init(
            options: options, effectiveUserIDProvider: { effectiveUserID },
            runtimeHomeProvider: { options.home }
        )
    }

    public func run() throws {
        let effectiveUserID = effectiveUserIDProvider()
        guard effectiveUserID != 0 else {
            throw InzoneError.message("The user installation phase must not run as root.")
        }
        let home = try validatedHome(effectiveUserID: effectiveUserID)
        let binary = options.binary.standardizedFileURL.resolvingSymlinksInPath()
        guard isFile(binary), manager.isExecutableFile(atPath: binary.path) else {
            throw InzoneError.message("The Swift executable is missing or not executable. Run: make swift-build")
        }
        let binaryFile = try readDataAndSafeRegularFilePermissions(from: binary)
        try validateInstallExecutable(binaryFile.data, name: binary.lastPathComponent)
        let repository = options.repository.standardizedFileURL.resolvingSymlinksInPath()
        let native = repository.appendingPathComponent("native/inzone_dsp.so")
        guard isFile(native) else {
            throw InzoneError.message("The native DSP plugin is missing. Run: make native-build")
        }
        let nativeData = try Data(contentsOf: native)
        let digest = Digests.sha256(nativeData)
        try requireExpectedPluginDigest(options.expectedPluginSHA256, actual: digest)
        let payload = options.payload?.standardizedFileURL.resolvingSymlinksInPath()
            ?? repository.appendingPathComponent("analysis/payload")
        var required = [
            "inzonevirtualizer.dll", "shp_for_game_v2.0_512tap.hki",
            "downmix.hki", "wh_g910n_standard.ba",
        ].map { payload.appendingPathComponent($0) }
        required += ["sony-eq-tables.json", "sony-presets.json"].map { repository.appendingPathComponent("assets/\($0)") }
        guard required.allSatisfy(isFile) else { throw InzoneError.message("Assets are missing. Run: make assets") }
        let templates = ["fps", "music", "voice", "balanced", "original"]
        let configFiles = templates.map { $0 + ".conf" } + ["52-inzone-game-chat.conf", "systemd/inzone-profile-auto.service"]
        for path in configFiles where !isFile(repository.appendingPathComponent("configs/\(path)")) {
            throw InzoneError.message("Missing repository configuration: \(path)")
        }
        guard isFile(repository.appendingPathComponent("README.md")), isDirectory(repository.appendingPathComponent("docs")) else {
            throw InzoneError.message("Repository README.md and docs are required for installation.")
        }
        let balancedText = try String(contentsOf: repository.appendingPathComponent("configs/balanced.conf"), encoding: .utf8)
        let balancedJSON = balancedText.components(separatedBy: .newlines).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        guard let surroundTemplate = try JSONSupport.decode(Data(balancedJSON.utf8)) as? [String: Any] else {
            throw InzoneError.message("The balanced profile must contain a JSON object.")
        }
        let pluginName = "inzone_dsp_" + String(digest.prefix(16))

        // Decode and validate the complete asset bank before replacing installed files.
        let preparedAssets = manager.temporaryDirectory.appendingPathComponent("inzone-install-assets-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: preparedAssets) }
        try FilterBank.export(payload: payload, destination: preparedAssets)
        for name in ["sony-eq-tables.json", "sony-presets.json"] {
            try copy(repository.appendingPathComponent("assets/\(name)"), to: preparedAssets.appendingPathComponent(name))
        }
        try writeJSON(["name": pluginName, "sha256": digest], to: preparedAssets.appendingPathComponent("plugin.json"))
        let paths = InzonePaths(home: home)
        let data = paths.configDirectory
        let assets = paths.assetsDirectory
        let dataExistedBeforeLock = manager.fileExists(atPath: data.path)
        let switchLock = try FileLock(url: data.appendingPathComponent("switch.lock"))
        defer { withExtendedLifetime(switchLock) {} }
        let activeExisted = manager.fileExists(atPath: paths.activeProfile.path)
        let existingActiveProfile = activeExisted ? try managedProfileIdentifier(in: paths.activeProfile) : "balanced"
        if let identifier = existingActiveProfile,
           try SettingsStore(paths: paths).profileIfAvailable(identifier) == nil {
            throw InzoneError.message("The active sound profile is not present in the installed profile collection: \(identifier)")
        }
        let wireplumber = home.appendingPathComponent(".config/wireplumber/wireplumber.conf.d")
        let executable = home.appendingPathComponent(".local/bin/inzone-profile")
        let unit = home.appendingPathComponent(".config/systemd/user/inzone-profile-auto.service")
        let decoder = paths.shareDirectory.appendingPathComponent("decoder")
        let backup = home.appendingPathComponent(".local/state/inzone-linux/backups/\(backupStamp())")
        let backupPaths = [
            ".config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf", ".local/lib/ladspa/inzone_dsp.so",
            ".local/share/inzone-linux/python", ".config/inzone-h9-ii", ".local/bin/inzone-profile",
            ".config/wireplumber/wireplumber.conf.d/52-inzone-game-chat.conf", ".config/mpv/mpv.conf",
            ".config/systemd/user/inzone-profile-auto.service",
        ]
        for path in backupPaths {
            if path == ".config/inzone-h9-ii", !dataExistedBeforeLock { continue }
            let source = home.appendingPathComponent(path)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = backup.appendingPathComponent(path)
            try createDirectory(destination.deletingLastPathComponent())
            try manager.copyItem(at: source, to: destination)
        }
        let original = data.appendingPathComponent("original.conf")
        let rollbackRoot = backup.appendingPathComponent(".installation-rollback-" + UUID().uuidString.lowercased())
        let rollbackTargets = [
            decoder.appendingPathComponent("inzonevirtualizer.dll"),
            data.appendingPathComponent("fps.conf"), data.appendingPathComponent("music.conf"),
            data.appendingPathComponent("voice.conf"), data.appendingPathComponent("balanced.conf"), original,
            paths.pluginURL, data.appendingPathComponent("sony-surround.json"),
            data.appendingPathComponent("surround.conf"),
            wireplumber.appendingPathComponent("52-inzone-game-chat.conf"), paths.activeProfile,
            data.appendingPathComponent("README.md"), data.appendingPathComponent("docs"),
            executable, unit, home.appendingPathComponent(".config/mpv/mpv.conf"),
        ]
        let rollbackSnapshots = try snapshotInstallationTargets(rollbackTargets, into: rollbackRoot)
        let stagedAssets = paths.shareDirectory.appendingPathComponent(".assets-stage-\(UUID().uuidString)")
        var removeStagedAssets = true
        defer { if removeStagedAssets { try? manager.removeItem(at: stagedAssets) } }
        try mergeDirectory(preparedAssets, into: stagedAssets)
        var assetPublication: AssetBankPublication?
        do {
            try copy(payload.appendingPathComponent("inzonevirtualizer.dll"), to: decoder.appendingPathComponent("inzonevirtualizer.dll"))
            for name in ["fps", "music", "voice", "balanced"] {
                try copy(repository.appendingPathComponent("configs/\(name).conf"), to: data.appendingPathComponent("\(name).conf"))
            }
            if !manager.fileExists(atPath: original.path) {
                try copy(repository.appendingPathComponent("configs/original.conf"), to: original)
            }
            assetPublication = try publishAssetBank(staged: stagedAssets, active: assets)
            removeStagedAssets = false
            try write(nativeData, to: paths.pluginURL, permissions: 0o755)
            let graph = try GraphRenderer(paths: paths).buildSurround(assets: assets, plugin: paths.pluginURL)
            try writeJSON(graph, to: data.appendingPathComponent("sony-surround.json"))
            try write(
                Data(("# INZONE profile: surround\n" + JSONSupport.encode(surroundTemplate) + "\n").utf8),
                to: data.appendingPathComponent("surround.conf"), permissions: 0o644
            )
            try copy(repository.appendingPathComponent("configs/52-inzone-game-chat.conf"), to: wireplumber.appendingPathComponent("52-inzone-game-chat.conf"))
            if let identifier = existingActiveProfile,
               let profile = try SettingsStore(paths: paths).profileIfAvailable(identifier) {
                let template = try String(
                    contentsOf: data.appendingPathComponent(profile.templateProfile + ".conf"), encoding: .utf8
                )
                let rendered = try GraphRenderer(paths: paths).render(profile: identifier, template: template)
                try write(Data(rendered.utf8), to: paths.activeProfile, permissions: 0o644)
            }
            try copy(repository.appendingPathComponent("README.md"), to: data.appendingPathComponent("README.md"))
            try mergeDirectory(repository.appendingPathComponent("docs"), into: data.appendingPathComponent("docs"))
            // Install the validated snapshot so the source cannot change between validation and publication.
            try write(binaryFile.data, to: executable, permissions: 0o755)
            try copy(repository.appendingPathComponent("configs/systemd/inzone-profile-auto.service"), to: unit)
            let mpv = home.appendingPathComponent(".config/mpv/mpv.conf")
            if manager.fileExists(atPath: mpv.path) {
                let previousFile = try readDataAndSafeRegularFilePermissions(from: mpv)
                guard let previous = String(data: previousFile.data, encoding: .utf8) else {
                    throw InzoneError.message("The mpv configuration must be UTF-8.")
                }
                let updated = previous.replacingOccurrences(
                    of: "alsa_output.usb-Sony_INZONE_H9_II-00.iec958-stereo",
                    with: "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
                )
                try write(Data(updated.utf8), to: mpv, permissions: previousFile.permissions)
            }
            if let publication = assetPublication, publication.exchanged {
                let retainedAssets = backup.appendingPathComponent(".local/share/inzone-linux/assets")
                try createDirectory(retainedAssets.deletingLastPathComponent())
                guard Glibc.rename(publication.previous.path, retainedAssets.path) == 0 else {
                    throw InzoneError.message(
                        "Cannot retain the previous asset bank for active readers: \(String(cString: strerror(errno)))."
                    )
                }
            }
            assetPublication = nil
            try? manager.removeItem(at: rollbackRoot)
            removeEmptyBackupContainers(backup)
        } catch {
            let installationError = error
            var restorationFailures = [String]()
            if let publication = assetPublication {
                do { try rollbackAssetBank(publication) }
                catch { restorationFailures.append(error.localizedDescription) }
            }
            do {
                try restoreInstallationSnapshots(rollbackSnapshots)
                try? manager.removeItem(at: rollbackRoot)
                removeEmptyBackupContainers(backup)
            } catch { restorationFailures.append(error.localizedDescription) }
            if restorationFailures.isEmpty { throw installationError }
            throw InzoneError.message(
                "User installation failed: \(installationError.localizedDescription) Rollback failed: "
                    + restorationFailures.joined(separator: " | ")
            )
        }
    }

    private func isFile(_ path: URL) -> Bool {
        (try? path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isDirectory(_ path: URL) -> Bool {
        (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func validateInstallExecutable(_ data: Data, name: String) throws {
        let normalizedName = name.lowercased()
        let updaterName = normalizedName.contains("firmware")
            || normalizedName.contains("fwupdate")
            || normalizedName.contains("updatetool")
            || normalizedName == "blhost.exe"
            || (normalizedName.hasPrefix("update") && normalizedName.hasSuffix(".bat"))
        guard !updaterName else {
            throw InzoneError.message("Known firmware updater artifact names cannot be installed.")
        }

        let bytes = [UInt8](data)
        if bytes.count >= 2, bytes[0] == 0x4d, bytes[1] == 0x5a {
            throw InzoneError.message("Windows PE binaries, including firmware updaters, cannot be installed.")
        }
        #if arch(x86_64)
        let hostMachine: UInt16 = 62
        #elseif arch(arm64)
        let hostMachine: UInt16 = 183
        #else
        throw InzoneError.message("This Linux architecture is not supported by the installer.")
        #endif
        guard bytes.count >= 64,
              Array(bytes[0..<4]) == [0x7f, 0x45, 0x4c, 0x46],
              bytes[4] == 2, bytes[5] == 1, bytes[6] == 1,
              unsigned16(bytes, at: 16).map({ $0 == 2 || $0 == 3 }) == true,
              unsigned16(bytes, at: 18) == hostMachine,
              unsigned32(bytes, at: 20) == 1,
              unsigned64(bytes, at: 24).map({ $0 != 0 }) == true,
              unsigned16(bytes, at: 52) == 64,
              unsigned16(bytes, at: 54) == 56,
              let programHeaderOffset = unsigned64(bytes, at: 32),
              let programHeaderCount = unsigned16(bytes, at: 56), programHeaderCount > 0,
              programHeaderOffset <= UInt64(bytes.count) else {
            throw InzoneError.message("The install binary must be a native ELF64 executable for this host architecture.")
        }

        let headerOffset = Int(programHeaderOffset)
        let headerCount = Int(programHeaderCount)
        guard headerCount <= (bytes.count - headerOffset) / 56 else {
            throw InzoneError.message("The install binary must have a bounded ELF program header table.")
        }
        var hasExecutableLoadSegment = false
        for index in 0..<headerCount {
            let offset = headerOffset + index * 56
            guard let segmentType = unsigned32(bytes, at: offset),
                  let segmentFlags = unsigned32(bytes, at: offset + 4),
                  let fileOffset = unsigned64(bytes, at: offset + 8),
                  let fileSize = unsigned64(bytes, at: offset + 32),
                  fileOffset <= UInt64(bytes.count), fileSize <= UInt64(bytes.count) - fileOffset else {
                throw InzoneError.message("The install binary contains an invalid ELF program segment.")
            }
            if segmentType == 1, segmentFlags & 1 != 0 {
                hasExecutableLoadSegment = true
            }
        }
        guard hasExecutableLoadSegment else {
            throw InzoneError.message("The install binary must contain an executable ELF load segment.")
        }
    }

    private func unsigned16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= bytes.count, 2 <= bytes.count - offset else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private func unsigned32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= bytes.count, 4 <= bytes.count - offset else { return nil }
        return (0..<4).reduce(UInt32(0)) { result, index in
            result | UInt32(bytes[offset + index]) << (index * 8)
        }
    }

    private func unsigned64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= bytes.count, 8 <= bytes.count - offset else { return nil }
        return (0..<8).reduce(UInt64(0)) { result, index in
            result | UInt64(bytes[offset + index]) << (index * 8)
        }
    }

    private func managedProfileIdentifier(in activeProfile: URL) throws -> String? {
        let activeFile = try readDataAndSafeRegularFilePermissions(from: activeProfile)
        guard let text = String(data: activeFile.data, encoding: .utf8) else {
            throw InzoneError.message("The active WirePlumber profile must be UTF-8.")
        }
        let prefix = "# INZONE profile: "
        guard let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first,
              firstLine.hasPrefix(prefix) else { return nil }
        let identifier = String(firstLine.dropFirst(prefix.count))
        guard !identifier.isEmpty, !["original", "restore"].contains(identifier) else { return nil }
        return identifier
    }

    private struct AssetBankPublication {
        let active: URL
        let previous: URL
        let exchanged: Bool
    }

    private struct InstallationSnapshot {
        let target: URL
        let stored: URL?
    }

    private func snapshotInstallationTargets(
        _ targets: [URL], into directory: URL
    ) throws -> [InstallationSnapshot] {
        try createDirectory(directory)
        return try targets.enumerated().map { index, target in
            var status = stat()
            if Glibc.lstat(target.path, &status) != 0 {
                guard errno == ENOENT else {
                    throw InzoneError.message("Cannot inspect rollback target \(target.path): \(String(cString: strerror(errno))).")
                }
                return InstallationSnapshot(target: target, stored: nil)
            }
            let fileType = status.st_mode & S_IFMT
            guard fileType == S_IFREG || fileType == S_IFDIR || fileType == S_IFLNK else {
                throw InzoneError.message("Rollback target must be a regular file, directory, or symbolic link: \(target.path)")
            }
            let stored = directory.appendingPathComponent(String(index))
            try manager.copyItem(at: target, to: stored)
            return InstallationSnapshot(target: target, stored: stored)
        }
    }

    private func restoreInstallationSnapshots(_ snapshots: [InstallationSnapshot]) throws {
        var failures = [String]()
        for snapshot in snapshots.reversed() {
            do {
                var status = stat()
                if Glibc.lstat(snapshot.target.path, &status) == 0 {
                    try manager.removeItem(at: snapshot.target)
                } else if errno != ENOENT {
                    throw InzoneError.message("Cannot inspect rollback destination: \(snapshot.target.path)")
                }
                if let stored = snapshot.stored {
                    try createDirectory(snapshot.target.deletingLastPathComponent())
                    try manager.copyItem(at: stored, to: snapshot.target)
                }
            } catch {
                failures.append("\(snapshot.target.path): \(error.localizedDescription)")
            }
        }
        guard failures.isEmpty else {
            throw InzoneError.message("Cannot restore installation snapshot: " + failures.joined(separator: " | "))
        }
    }

    private func removeEmptyBackupContainers(_ backup: URL) {
        for directory in [backup, backup.deletingLastPathComponent()] {
            guard (try? manager.contentsOfDirectory(atPath: directory.path).isEmpty) == true else {
                continue
            }
            try? manager.removeItem(at: directory)
        }
    }

    private func publishAssetBank(staged: URL, active: URL) throws -> AssetBankPublication {
        try createDirectory(active.deletingLastPathComponent())
        var activeStatus = stat()
        if Glibc.lstat(active.path, &activeStatus) == 0 {
            let result = staged.path.withCString { stagedPath in
                active.path.withCString { activePath in
                    renameAt2(AT_FDCWD, stagedPath, AT_FDCWD, activePath, 2)
                }
            }
            guard result == 0 else {
                throw InzoneError.message("Cannot atomically exchange the installed asset bank: \(String(cString: strerror(errno))).")
            }
            return AssetBankPublication(active: active, previous: staged, exchanged: true)
        }
        guard errno == ENOENT else {
            throw InzoneError.message("Cannot inspect the installed asset bank: \(String(cString: strerror(errno))).")
        }
        guard Glibc.rename(staged.path, active.path) == 0 else {
            throw InzoneError.message("Cannot publish the installed asset bank: \(String(cString: strerror(errno))).")
        }
        return AssetBankPublication(active: active, previous: staged, exchanged: false)
    }

    private func rollbackAssetBank(_ publication: AssetBankPublication) throws {
        if publication.exchanged {
            let result = publication.active.path.withCString { activePath in
                publication.previous.path.withCString { previousPath in
                    renameAt2(AT_FDCWD, activePath, AT_FDCWD, previousPath, 2)
                }
            }
            guard result == 0 else {
                throw InzoneError.message("Cannot restore the previous asset bank: \(String(cString: strerror(errno))).")
            }
            try manager.removeItem(at: publication.previous)
        } else if manager.fileExists(atPath: publication.active.path) {
            guard Glibc.rename(publication.active.path, publication.previous.path) == 0 else {
                throw InzoneError.message("Cannot withdraw the new asset bank: \(String(cString: strerror(errno))).")
            }
            try manager.removeItem(at: publication.previous)
        }
    }

    private func createDirectory(_ directory: URL) throws {
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func readDataAndSafeRegularFilePermissions(
        from file: URL, afterOpeningFile: () throws -> Void = {}
    ) throws -> (data: Data, permissions: Int) {
        let descriptor = Glibc.open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InzoneError.message("Cannot open source file \(file.path): \(String(cString: strerror(errno))).")
        }
        return try readDataAndSafeRegularFilePermissions(
            descriptor: descriptor, path: file.path, afterOpeningFile: afterOpeningFile
        )
    }

    private func readDataAndSafeRegularFilePermissions(
        descriptor: Int32, path: String, afterOpeningFile: () throws -> Void = {}
    ) throws -> (data: Data, permissions: Int) {
        defer { Glibc.close(descriptor) }
        try afterOpeningFile()

        var status = stat()
        guard Glibc.fstat(descriptor, &status) == 0 else {
            throw InzoneError.message("Cannot inspect source file \(path): \(String(cString: strerror(errno))).")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw InzoneError.message("The installation source must be a regular file: \(path).")
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw InzoneError.message("Cannot read source file \(path): \(String(cString: strerror(errno))).")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return (data, Int(status.st_mode) & 0o644)
    }

    private func copy(_ source: URL, to destination: URL, permissions: Int? = nil) throws {
        let sourceFile = try readDataAndSafeRegularFilePermissions(from: source)
        try write(
            sourceFile.data, to: destination,
            permissions: permissions ?? sourceFile.permissions
        )
    }

    private func write(_ data: Data, to destination: URL, permissions: Int = 0o644) throws {
        try AtomicFile.write(data, to: destination, permissions: permissions)
    }

    private func writeJSON(_ value: Any, to destination: URL) throws {
        try write(Data((JSONSupport.encode(value) + "\n").utf8), to: destination)
    }

    private func mergeDirectory(_ source: URL, into destination: URL) throws {
        try createDirectory(destination)
        for file in try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isDirectoryKey]) {
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if isDirectory(file) { try mergeDirectory(file, into: target) }
            else { try copy(file, to: target) }
        }
    }

    private func backupStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS"
        return formatter.string(from: Date()) + "-" + UUID().uuidString
    }

    private func validatedHome(effectiveUserID: uid_t) throws -> URL {
        let canonicalHome = options.home.standardizedFileURL.resolvingSymlinksInPath()
        let runtimeHome = runtimeHomeProvider().standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalHome == runtimeHome else {
            throw InzoneError.message(
                "INSTALL_HOME must match the desktop user's runtime HOME so the FIR plugin loads the validated asset bank."
            )
        }
        var canonicalStatus = stat()
        guard Glibc.lstat(canonicalHome.path, &canonicalStatus) == 0,
              (canonicalStatus.st_mode & S_IFMT) == S_IFDIR else {
            throw InzoneError.message("The desktop user home directory must already exist.")
        }
        guard canonicalStatus.st_uid == effectiveUserID else {
            throw InzoneError.message("The desktop user home directory must be owned by the current user.")
        }
        return canonicalHome
    }
}

public struct SystemInstaller {
    public let options: SystemInstallOptions
    private let runner: any CommandRunning
    private let effectiveUserIDProvider: @Sendable () -> uid_t
    private let currentExecutableSealValidator: () throws -> Void
    private let liveSystemRoot: URL

    public init(options: SystemInstallOptions) {
        self.init(options: options, runner: DirectCommandRunner())
    }

    public init(options: SystemInstallOptions, runner: any CommandRunning) {
        self.options = options
        self.runner = runner
        self.effectiveUserIDProvider = { Glibc.geteuid() }
        self.currentExecutableSealValidator = { try SealedExecutable.requireCurrentProcessSealed() }
        self.liveSystemRoot = URL(fileURLWithPath: "/")
    }

    init(
        options: SystemInstallOptions, runner: any CommandRunning,
        effectiveUserIDProvider: @escaping @Sendable () -> uid_t,
        currentExecutableSealValidator: @escaping () throws -> Void = {
            try SealedExecutable.requireCurrentProcessSealed()
        },
        liveSystemRoot: URL = URL(fileURLWithPath: "/")
    ) {
        self.options = options
        self.runner = runner
        self.effectiveUserIDProvider = effectiveUserIDProvider
        self.currentExecutableSealValidator = currentExecutableSealValidator
        self.liveSystemRoot = liveSystemRoot
    }

    init(
        options: SystemInstallOptions, runner: any CommandRunning, effectiveUserID: uid_t,
        currentExecutableSealValidator: @escaping () throws -> Void = {
            try SealedExecutable.requireCurrentProcessSealed()
        },
        liveSystemRoot: URL = URL(fileURLWithPath: "/")
    ) {
        self.init(
            options: options,
            runner: runner,
            effectiveUserIDProvider: { effectiveUserID },
            currentExecutableSealValidator: currentExecutableSealValidator,
            liveSystemRoot: liveSystemRoot
        )
    }

    public func run() throws {
        let effectiveUserID = effectiveUserIDProvider()
        if options.stagingRoot == nil {
            guard effectiveUserID == 0 else {
                throw InzoneError.message("The live system installation phase must run as root.")
            }
            try currentExecutableSealValidator()
        } else {
            guard effectiveUserID != 0 else {
                throw InzoneError.message("The staged system installation phase must not run as root.")
            }
        }
        let stagingRoot = options.stagingRoot?.standardizedFileURL.resolvingSymlinksInPath()
        if let stagingRoot {
            guard stagingRoot.path != "/",
                  (try? stagingRoot.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw InzoneError.message("The staging root must be an existing non-root directory.")
            }
        }
        let rule: Data
        let native: Data
        if stagingRoot != nil {
            guard let repositoryURL = options.repository,
                  options.pluginSource == nil, options.udevRuleSource == nil else {
                throw InzoneError.message(
                    "Staged system installation requires a repository and rejects live sealed source paths."
                )
            }
            let repository = try AnchoredDirectory(
                root: repositoryURL.standardizedFileURL.resolvingSymlinksInPath()
            )
            rule = try repository.read(
                ["configs", "udev", "70-inzone-h9-ii.rules"], maximumSize: 1024 * 1024
            )
            native = try repository.read(["native", "inzone_dsp.so"], maximumSize: 128 * 1024 * 1024)
        } else {
            guard options.repository == nil,
                  let pluginSource = options.pluginSource,
                  let udevRuleSource = options.udevRuleSource else {
                throw InzoneError.message(
                    "Live system installation requires sealed plugin and udev rule procfd sources and rejects a repository path."
                )
            }
            rule = try SealedFile.readAndValidateSealedProcFD(
                path: udevRuleSource.path, maximumSize: 1024 * 1024
            )
            native = try SealedFile.readAndValidateSealedProcFD(
                path: pluginSource.path, maximumSize: 128 * 1024 * 1024
            )
        }
        try requireExpectedUdevRuleDigest(options.expectedUdevRuleSHA256, actual: Digests.sha256(rule))
        let digest = Digests.sha256(native)
        try requireExpectedPluginDigest(options.expectedPluginSHA256, actual: digest)
        let system = try AnchoredDirectory(root: stagingRoot ?? liveSystemRoot)
        try system.validate(["etc", "udev", "rules.d"])
        try system.validate(["usr", "lib", "ladspa"])
        try system.write(rule, ["etc", "udev", "rules.d", "70-inzone-h9-ii.rules"], permissions: 0o644)
        try system.write(
            native, ["usr", "lib", "ladspa", "inzone_dsp_\(digest.prefix(16)).so"], permissions: 0o755
        )
        if options.stagingRoot == nil {
            _ = try runner.run(["/usr/bin/udevadm", "control", "--reload-rules"])
        }
    }
}

private func requireExpectedPluginDigest(_ expected: String, actual: String) throws {
    let valid = expected.utf8.count == 64 && expected.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
    guard valid, expected == actual else {
        throw InzoneError.message("The DSP plugin changed after installation preparation. Rebuild and retry.")
    }
}

private func requireExpectedUdevRuleDigest(_ expected: String, actual: String) throws {
    let valid = expected.utf8.count == 64 && expected.utf8.allSatisfy {
        (48...57).contains($0) || (97...102).contains($0)
    }
    guard valid, expected == actual else {
        throw InzoneError.message("The udev rule changed after installation preparation. Retry the installation.")
    }
}

final class AnchoredDirectory {
    private let rootDescriptor: Int32

    init(root: URL) throws {
        rootDescriptor = Glibc.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw InzoneError.message("Cannot open anchored directory \(root.path): \(String(cString: strerror(errno))).")
        }
    }

    deinit { Glibc.close(rootDescriptor) }

    func read(_ components: [String], maximumSize: Int) throws -> Data {
        guard maximumSize >= 0, let name = components.last else {
            throw InzoneError.message("A bounded repository file path is required.")
        }
        let directory = try openDirectory(Array(components.dropLast()), create: false)
        defer { Glibc.close(directory) }
        let descriptor = Glibc.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw pathError("Open repository file", component: name) }
        defer { Glibc.close(descriptor) }
        var status = stat()
        guard Glibc.fstat(descriptor, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0, status.st_size <= off_t(maximumSize) else {
            throw InzoneError.message("Repository file is not a bounded regular file: \(name).")
        }
        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw pathError("Read repository file", component: name)
            }
            if count == 0 { break }
            guard result.count <= maximumSize - count else {
                throw InzoneError.message("Repository file exceeds its size limit: \(name).")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }

    func write(_ data: Data, _ components: [String], permissions: Int) throws {
        guard let name = components.last else { throw InzoneError.message("A system file path is required.") }
        let directory = try openDirectory(Array(components.dropLast()), create: true)
        defer { Glibc.close(directory) }
        try AtomicFile.write(data, inDirectoryDescriptor: directory, name: name, permissions: permissions)
    }

    func validate(_ components: [String]) throws {
        var current = Glibc.openat(rootDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw pathError("Duplicate anchored directory", component: ".") }
        defer { Glibc.close(current) }
        for component in components {
            try validate(component)
            let next = Glibc.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT { return }
            guard next >= 0 else { throw pathError("Open anchored directory", component: component) }
            Glibc.close(current)
            current = next
        }
    }

    private func openDirectory(_ components: [String], create: Bool) throws -> Int32 {
        var current = Glibc.openat(rootDescriptor, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw pathError("Duplicate anchored directory", component: ".") }
        do {
            for component in components {
                try validate(component)
                if create, Glibc.mkdirat(current, component, mode_t(0o755)) != 0, errno != EEXIST {
                    throw pathError("Create anchored directory", component: component)
                }
                let next = Glibc.openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw pathError("Open anchored directory", component: component) }
                Glibc.close(current)
                current = next
            }
            return current
        } catch {
            Glibc.close(current)
            throw error
        }
    }

    private func validate(_ component: String) throws {
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/"), !component.contains("\0") else {
            throw InzoneError.message("Invalid anchored path component: \(component).")
        }
    }

    private func pathError(_ operation: String, component: String) -> InzoneError {
        .message("\(operation) \(component): \(String(cString: strerror(errno))).")
    }
}
