import Foundation
import Glibc
import InzoneCore

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

    public init(options: InstallOptions) {
        self.options = options
        self.effectiveUserIDProvider = { Glibc.geteuid() }
    }

    init(options: InstallOptions, effectiveUserIDProvider: @escaping @Sendable () -> uid_t) {
        self.options = options
        self.effectiveUserIDProvider = effectiveUserIDProvider
    }

    init(options: InstallOptions, effectiveUserID: uid_t) {
        self.init(options: options, effectiveUserIDProvider: { effectiveUserID })
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
        var required = ["inzonevirtualizer.dll", "shp_for_game_v2.0_512tap.hki", "wh_g910n_standard.ba"].map { payload.appendingPathComponent($0) }
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
        guard var surround = try JSONSupport.decode(Data(balancedJSON.utf8)) as? [String: Any] else {
            throw InzoneError.message("The balanced profile must contain a JSON object.")
        }
        let pluginName = "inzone_dsp_" + String(digest.prefix(16))

        // Decode and validate vendor data before replacing installed files.
        let preparedAssets = manager.temporaryDirectory.appendingPathComponent("inzone-install-assets-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: preparedAssets) }
        try FilterBank.export(payload: payload, destination: preparedAssets)
        let paths = InzonePaths(home: home)
        let data = paths.configDirectory
        let assets = paths.assetsDirectory
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
            let source = home.appendingPathComponent(path)
            guard manager.fileExists(atPath: source.path) else { continue }
            let destination = backup.appendingPathComponent(path)
            try createDirectory(destination.deletingLastPathComponent())
            try manager.copyItem(at: source, to: destination)
        }
        try write(nativeData, to: paths.pluginURL, permissions: 0o755)
        try copy(payload.appendingPathComponent("inzonevirtualizer.dll"), to: decoder.appendingPathComponent("inzonevirtualizer.dll"))
        try mergeDirectory(preparedAssets, into: assets)
        for name in ["sony-eq-tables.json", "sony-presets.json"] {
            try copy(repository.appendingPathComponent("assets/\(name)"), to: assets.appendingPathComponent(name))
        }
        try writeJSON(["name": pluginName, "sha256": digest], to: assets.appendingPathComponent("plugin.json"))
        for name in ["fps", "music", "voice", "balanced"] {
            try copy(repository.appendingPathComponent("configs/\(name).conf"), to: data.appendingPathComponent("\(name).conf"))
        }
        let original = data.appendingPathComponent("original.conf")
        if !manager.fileExists(atPath: original.path) {
            try copy(repository.appendingPathComponent("configs/original.conf"), to: original)
        }
        let graph = try GraphRenderer(paths: paths).buildSurround(assets: assets, plugin: paths.pluginURL)
        try writeJSON(graph, to: data.appendingPathComponent("sony-surround.json"))
        surround["wireplumber.profiles"] = ["main": ["node.software-dsp": "required"]]
        surround["node.software-dsp.rules"] = [[
            "matches": [["node.name": "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"]],
            "actions": ["create-filter": ["filter-graph": try JSONSupport.encode(graph, pretty: false), "hide-parent": false]],
        ]]
        try write(Data(("# INZONE profile: surround\n" + JSONSupport.encode(surround) + "\n").utf8), to: data.appendingPathComponent("surround.conf"), permissions: 0o644)
        try copy(repository.appendingPathComponent("configs/52-inzone-game-chat.conf"), to: wireplumber.appendingPathComponent("52-inzone-game-chat.conf"))
        if !manager.fileExists(atPath: paths.activeProfile.path) {
            try copy(data.appendingPathComponent("balanced.conf"), to: paths.activeProfile)
        }
        try copy(repository.appendingPathComponent("README.md"), to: data.appendingPathComponent("README.md"))
        try mergeDirectory(repository.appendingPathComponent("docs"), into: data.appendingPathComponent("docs"))
        try copy(binary, to: executable, permissions: 0o755)
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
    }

    private func isFile(_ path: URL) -> Bool {
        (try? path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func isDirectory(_ path: URL) -> Bool {
        (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
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
