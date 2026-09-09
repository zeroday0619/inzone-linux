import Foundation
import Glibc
import InzoneCore

public struct InstallCoordinatorOptions: Sendable {
    public let repository: URL
    public let home: URL
    public let binary: URL
    public let payload: URL?

    public init(repository: URL, home: URL, binary: URL, payload: URL? = nil) {
        self.repository = repository
        self.home = home
        self.binary = binary
        self.payload = payload
    }
}

public struct InstallCoordinator {
    struct SealedInstallSources {
        let plugin: SealedFile
        let pluginDigest: String
        let udevRule: SealedFile
        let udevRuleDigest: String
    }

    public let options: InstallCoordinatorOptions
    private let runner: any CommandRunning
    private let effectiveUserIDProvider: () -> uid_t
    private let sourceProvider: (URL) throws -> SealedInstallSources
    private let userInstaller: (InstallOptions) throws -> Void
    private let sealedExecutableProvider: () throws -> SealedExecutable

    public init(options: InstallCoordinatorOptions) {
        self.init(options: options, runner: DirectCommandRunner())
    }

    public init(options: InstallCoordinatorOptions, runner: any CommandRunning) {
        self.options = options
        self.runner = runner
        self.effectiveUserIDProvider = { Glibc.geteuid() }
        self.sourceProvider = { try Self.prepareSources(repository: $0) }
        self.userInstaller = { try Installer(options: $0).run() }
        self.sealedExecutableProvider = { try SealedExecutable.snapshotCurrentProcess() }
    }

    init(
        options: InstallCoordinatorOptions,
        runner: any CommandRunning,
        effectiveUserIDProvider: @escaping () -> uid_t,
        sourceProvider: @escaping (URL) throws -> SealedInstallSources,
        userInstaller: @escaping (InstallOptions) throws -> Void,
        sealedExecutableProvider: @escaping () throws -> SealedExecutable
    ) {
        self.options = options
        self.runner = runner
        self.effectiveUserIDProvider = effectiveUserIDProvider
        self.sourceProvider = sourceProvider
        self.userInstaller = userInstaller
        self.sealedExecutableProvider = sealedExecutableProvider
    }

    @discardableResult
    public func run() throws -> String {
        guard effectiveUserIDProvider() != 0 else {
            throw InzoneError.message("The coordinated installation must not run as root.")
        }
        let sealedExecutable = try sealedExecutableProvider()
        let sources = try sourceProvider(options.repository)
        try userInstaller(InstallOptions(
            repository: options.repository,
            home: options.home,
            binary: options.binary,
            payload: options.payload,
            expectedPluginSHA256: sources.pluginDigest
        ))

        let arguments = [
            "/usr/bin/sudo", "--", sealedExecutable.procFDPath, "install-system",
            "--plugin-procfd", sources.plugin.procFDPath,
            "--udev-rule-procfd", sources.udevRule.procFDPath,
            "--expected-plugin-sha256", sources.pluginDigest,
            "--expected-udev-rule-sha256", sources.udevRuleDigest,
        ]
        do {
            return try withExtendedLifetime((sealedExecutable, sources.plugin, sources.udevRule)) {
                try runner.run(arguments, timeout: .infinity)
            }
        } catch {
            let detail = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw InzoneError.message(
                "The user installation completed, but the system installation failed and may be incomplete. \(detail)"
            )
        }
    }

    private static func prepareSources(repository: URL) throws -> SealedInstallSources {
        let repository = try AnchoredDirectory(
            root: repository.standardizedFileURL.resolvingSymlinksInPath()
        )
        let pluginData = try repository.read(
            ["native", "inzone_dsp.so"], maximumSize: 128 * 1024 * 1024
        )
        let plugin = try SealedFile.snapshot(data: pluginData, name: "inzone-plugin")
        let pluginDigest = Digests.sha256(pluginData)
        let udevRuleData = try repository.read(
            ["configs", "udev", "70-inzone-h9-ii.rules"], maximumSize: 1024 * 1024
        )
        let udevRule = try SealedFile.snapshot(data: udevRuleData, name: "inzone-udev-rule")
        return SealedInstallSources(
            plugin: plugin,
            pluginDigest: pluginDigest,
            udevRule: udevRule,
            udevRuleDigest: Digests.sha256(udevRuleData)
        )
    }
}
