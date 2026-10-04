import Foundation
import Glibc
import InzoneCore

public struct PackagedSetupOptions: Sendable {
    public let resources: URL
    public let binary: URL
    public let home: URL
    public let assetsFrom: URL?
    public let download: Bool

    public init(resources: URL, binary: URL, home: URL, assetsFrom: URL? = nil, download: Bool = false) {
        self.resources = resources
        self.binary = binary
        self.home = home
        self.assetsFrom = assetsFrom
        self.download = download
    }

    public static func resourceDirectory(executable: URL) -> URL {
        executable.standardizedFileURL.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("share/inzone-linux/setup", isDirectory: true)
    }
}

/// Prepares desktop-user state while the package manager retains ownership of executables.
public struct PackagedSetup: Sendable {
    public let options: PackagedSetupOptions
    private let environment: [String: String]
    private let effectiveUserIDProvider: @Sendable () -> uid_t
    private let runtimeHomeProvider: @Sendable () -> URL

    public init(options: PackagedSetupOptions) {
        self.init(
            options: options, environment: ProcessInfo.processInfo.environment,
            effectiveUserIDProvider: { Glibc.geteuid() }, runtimeHomeProvider: { InzonePaths().home }
        )
    }

    init(
        options: PackagedSetupOptions, environment: [String: String],
        effectiveUserIDProvider: @escaping @Sendable () -> uid_t,
        runtimeHomeProvider: @escaping @Sendable () -> URL
    ) {
        self.options = options
        self.environment = environment
        self.effectiveUserIDProvider = effectiveUserIDProvider
        self.runtimeHomeProvider = runtimeHomeProvider
    }

    public func run() async throws {
        let effectiveUserID = effectiveUserIDProvider()
        guard effectiveUserID != 0 else {
            throw InzoneError.message("Package setup must run as the desktop user, without sudo.")
        }
        guard (options.assetsFrom != nil) != options.download else {
            throw InzoneError.message("Specify exactly one of --assets-from DIRECTORY or --download. Setup never downloads assets implicitly.")
        }
        _ = try Installer.validatedHome(
            options.home, runtimeHome: runtimeHomeProvider(), effectiveUserID: effectiveUserID
        )
        let manager = FileManager.default
        let resources = options.resources.standardizedFileURL.resolvingSymlinksInPath()
        let binary = options.binary.standardizedFileURL.resolvingSymlinksInPath()
        guard manager.isExecutableFile(atPath: binary.path) else {
            throw InzoneError.message("The packaged inzone-profile executable is missing: \(binary.path)")
        }
        for name in ["configs", "docs", "README.md", "native/inzone_dsp.so"] {
            guard manager.fileExists(atPath: resources.appendingPathComponent(name).path) else {
                throw InzoneError.message("Package setup resources are missing: \(name)")
            }
        }
        let assetSource: URL
        if let supplied = options.assetsFrom {
            assetSource = supplied.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let configuredCache = environment["XDG_CACHE_HOME"].flatMap { value -> URL? in
                value.hasPrefix("/") ? URL(fileURLWithPath: value, isDirectory: true) : nil
            }
            let cache = (configuredCache ?? options.home.appendingPathComponent(".cache", isDirectory: true))
                .appendingPathComponent("inzone-linux/setup", isDirectory: true)
            let metadata = resources.appendingPathComponent("evidence/installer.json")
            _ = try InstallerMetadata.load(metadata)
            try AtomicFile.write(
                Data(contentsOf: metadata), to: cache.appendingPathComponent("evidence/installer.json")
            )
            // Network access occurs only for the explicit --download setup mode.
            try await AssetFetcher(options: AssetFetchOptions(repository: cache)).run()
            assetSource = cache
        }
        let staged = manager.temporaryDirectory.appendingPathComponent("inzone-package-setup-\(UUID().uuidString)")
        try manager.createDirectory(at: staged, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: staged) }
        for name in ["configs", "docs", "README.md"] {
            try manager.copyItem(at: resources.appendingPathComponent(name), to: staged.appendingPathComponent(name))
        }
        let plugin = try Data(contentsOf: resources.appendingPathComponent("native/inzone_dsp.so"))
        try AtomicFile.write(plugin, to: staged.appendingPathComponent("native/inzone_dsp.so"), permissions: 0o755)
        for name in ["sony-eq-tables.json", "sony-presets.json"] {
            let source = assetSource.appendingPathComponent("assets/" + name)
            guard manager.fileExists(atPath: source.path) else {
                throw InzoneError.message("Prepared assets are missing \(name). Supply a directory containing assets/ and analysis/payload/, or use --download.")
            }
            try AtomicFile.write(Data(contentsOf: source), to: staged.appendingPathComponent("assets/" + name))
        }
        try Installer(
            options: InstallOptions(
                repository: staged, home: options.home, binary: binary,
                payload: assetSource.appendingPathComponent("analysis/payload"),
                expectedPluginSHA256: Digests.sha256(plugin), installExecutable: false
            ),
            effectiveUserIDProvider: effectiveUserIDProvider, runtimeHomeProvider: runtimeHomeProvider
        ).run()
    }
}
