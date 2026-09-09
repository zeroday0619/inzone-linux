import Foundation
import Glibc
import InzoneCore
import InzoneToolsCore
import InzoneDiagnostics

@main
struct InzoneToolsCommand {
    static let help = """
    Usage: inzone-tools COMMAND [OPTIONS]

    fetch               Download, verify, extract, and decode the pinned Sony assets
      --installer FILE --offline --download-only --ilspycmd FILE
    export-filters PAYLOAD DESTINATION
                        Decode a local Sony HKI/BA filter bank
    export-eq           Extract the Sony 10-band equalizer coefficient tables
    export-presets      Extract Sony presets and immersive equalizer sections
      --payload DIRECTORY --decompiled DIRECTORY --output DIRECTORY
    plugin-digest       Print the built DSP plugin SHA-256 for a bound installation
    udev-rule-digest    Print the udev rule SHA-256 for a bound installation
    disassemble START END [--input FILE]
                        Print an existing disassembly between hexadecimal RVAs
    install-all         Install user files, then hand sealed executable and source snapshots to sudo
      --home DIRECTORY --binary FILE --payload DIRECTORY
    install             Install application files and configuration for the current user
      --home DIRECTORY --binary FILE --payload DIRECTORY --expected-plugin-sha256 SHA256
    install-system      Install the udev rule and system LADSPA plugin
      --staging-root DIRECTORY | --plugin-procfd PROC_FD --udev-rule-procfd PROC_FD
      --expected-plugin-sha256 SHA256 --expected-udev-rule-sha256 SHA256
    diagnose-impulse     Verify impulses through a private PipeWire instance
    diagnose-sfx        Compare DSP samples in a private PipeWire instance
      --indices 3,18,32
    diagnose-live-profiles
                        Verify profiles in the active desktop audio session
    diagnose-live-automation
                        Verify process association in the active desktop audio session

    Commands accept --repository DIRECTORY by default; live install-system rejects it.
    Live system installation requires root; staged system installation rejects root.
    Live diagnostics temporarily change audio profiles and restore previous state.
    """

    static func main() async {
        do { try await execute(Array(CommandLine.arguments.dropFirst())) }
        catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let escapedMessage = TerminalOutput.escaped(message, preservingNewlines: false)
            FileHandle.standardError.write(Data((escapedMessage + "\n").utf8))
            exit(1)
        }
    }

    static func execute(_ arguments: [String]) async throws {
        guard let command = arguments.first, !["--help", "-h", "help"].contains(command),
              !arguments.dropFirst().contains("--help"), !arguments.dropFirst().contains("-h") else {
            print(help)
            return
        }
        let options = try ToolArguments(Array(arguments.dropFirst()))
        let repository = options.url("repository") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = InzonePaths(home: options.url("home") ?? InzonePaths().home)
        let payload = options.url("payload") ?? repository.appendingPathComponent("analysis/payload")
        let decompiled = options.url("decompiled") ?? repository.appendingPathComponent("analysis/decompiled")
        let destination = options.url("output") ?? repository.appendingPathComponent("assets")

        switch command {
        case "fetch":
            try options.validate(values: ["repository", "installer", "ilspycmd"], switches: ["offline", "download-only"])
            try await AssetFetcher(options: AssetFetchOptions(
                repository: repository, installer: options.url("installer"),
                offline: options.switches.contains("offline"), downloadOnly: options.switches.contains("download-only"),
                decompiler: options.url("ilspycmd")
            )).run()
        case "export-filters":
            try options.validate(values: ["repository"], positionalCount: 2)
            try FilterBank.export(payload: ToolArguments.path(options.positional[0]),
                                  destination: ToolArguments.path(options.positional[1]))
        case "export-eq", "export-presets":
            try options.validate(values: ["repository", "payload", "decompiled", "output"])
            if command == "export-eq" {
                try AssetExport.equalizerTables(payload: payload, decompiled: decompiled, destination: destination)
            } else {
                try AssetExport.presets(payload: payload, decompiled: decompiled, destination: destination)
            }
            let escapedDestination = TerminalOutput.escaped(destination.path, preservingNewlines: false)
            print("Exported \(command == "export-eq" ? "equalizer tables" : "Sony presets") to \(escapedDestination).")
        case "disassemble":
            try options.validate(values: ["repository", "input"], positionalCount: 2)
            func address(_ text: String) throws -> UInt64 {
                let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
                guard let value = UInt64(digits, radix: 16) else { throw InzoneError.message("RVAs must be hexadecimal integers.") }
                return value
            }
            print(try AssetExport.disassemble(
                input: options.url("input") ?? repository.appendingPathComponent("analysis/virtualizer.asm"),
                start: address(options.positional[0]), end: address(options.positional[1])
            ), terminator: "")
        case "plugin-digest":
            try options.validate(values: ["repository"])
            print(try Digests.sha256(file: repository.appendingPathComponent("native/inzone_dsp.so")))
        case "udev-rule-digest":
            try options.validate(values: ["repository"])
            print(try Digests.sha256(file: repository.appendingPathComponent("configs/udev/70-inzone-h9-ii.rules")))
        case "install-all":
            try options.validate(values: ["repository", "home", "binary", "payload"])
            let output = try InstallCoordinator(options: InstallCoordinatorOptions(
                repository: repository,
                home: paths.home,
                binary: options.url("binary") ?? repository.appendingPathComponent(".build/release/inzone-profile"),
                payload: options.url("payload")
            )).run()
            let escapedHome = TerminalOutput.escaped(paths.home.path, preservingNewlines: false)
            print("Installed inzone-profile for \(escapedHome).")
            print("In the desktop user session, reconnect the USB dongle and run: inzone-profile surround")
            print(output, terminator: "")
        case "install":
            try options.validate(values: ["repository", "home", "binary", "payload", "expected-plugin-sha256"])
            guard let expectedPluginSHA256 = options.values["expected-plugin-sha256"] else {
                throw InzoneError.message("install requires --expected-plugin-sha256 from plugin-digest.")
            }
            guard Glibc.geteuid() != 0 else {
                throw InzoneError.message("The user installation phase must not run as root.")
            }
            try Installer(options: InstallOptions(
                repository: repository, home: paths.home,
                binary: options.url("binary") ?? repository.appendingPathComponent(".build/release/inzone-profile"),
                payload: options.url("payload"), expectedPluginSHA256: expectedPluginSHA256
            )).run()
            let escapedHome = TerminalOutput.escaped(paths.home.path, preservingNewlines: false)
            print("Installed inzone-profile for \(escapedHome).")
            print("In the desktop user session, reconnect the USB dongle and run: inzone-profile surround")
        case "install-system":
            try options.validate(values: [
                "repository", "staging-root", "plugin-procfd", "udev-rule-procfd",
                "expected-plugin-sha256", "expected-udev-rule-sha256",
            ])
            guard let expectedPluginSHA256 = options.values["expected-plugin-sha256"] else {
                throw InzoneError.message("install-system requires --expected-plugin-sha256 from plugin-digest.")
            }
            guard let expectedUdevRuleSHA256 = options.values["expected-udev-rule-sha256"] else {
                throw InzoneError.message("install-system requires --expected-udev-rule-sha256 from udev-rule-digest.")
            }
            let stagingRoot = options.url("staging-root")
            let effectiveUserID = Glibc.geteuid()
            let systemOptions: SystemInstallOptions
            if stagingRoot == nil {
                guard effectiveUserID == 0 else {
                    throw InzoneError.message("The live system installation phase must run as root.")
                }
                try SealedExecutable.requireCurrentProcessSealed()
                guard options.values["repository"] == nil,
                      let pluginProcFD = options.values["plugin-procfd"],
                      let udevRuleProcFD = options.values["udev-rule-procfd"] else {
                    throw InzoneError.message(
                        "Live install-system requires --plugin-procfd and --udev-rule-procfd and rejects --repository."
                    )
                }
                systemOptions = SystemInstallOptions(
                    pluginSource: URL(fileURLWithPath: pluginProcFD),
                    udevRuleSource: URL(fileURLWithPath: udevRuleProcFD),
                    expectedPluginSHA256: expectedPluginSHA256,
                    expectedUdevRuleSHA256: expectedUdevRuleSHA256
                )
            } else {
                guard effectiveUserID != 0 else {
                    throw InzoneError.message("The staged system installation phase must not run as root.")
                }
                guard options.values["plugin-procfd"] == nil, options.values["udev-rule-procfd"] == nil else {
                    throw InzoneError.message("Staged install-system rejects live procfd source options.")
                }
                systemOptions = SystemInstallOptions(
                    repository: repository, stagingRoot: stagingRoot,
                    expectedPluginSHA256: expectedPluginSHA256,
                    expectedUdevRuleSHA256: expectedUdevRuleSHA256
                )
            }
            try SystemInstaller(options: systemOptions).run()
            print("Installed the INZONE system udev rule and LADSPA plugin.")
        case "diagnose-impulse":
            try options.validate(values: ["repository"])
            try DiagnosticPrerequisites.requirePrograms(["pipewire", "pw-cli", "pw-cat", "pw-dump", "pw-link"])
            print(try JSONSupport.encode(PipeWireDiagnostics.runImpulse(repository: repository)))
        case "diagnose-sfx":
            try options.validate(values: ["repository", "home", "indices"])
            try DiagnosticPrerequisites.requirePrograms(["pipewire", "pw-cli", "pw-cat", "pw-dump", "pw-link"])
            let indices: [Int]
            if let selected = options.values["indices"] {
                let components = selected.split(separator: ",", omittingEmptySubsequences: false)
                indices = try components.map {
                    guard let value = Int($0), value >= 0 else { throw InzoneError.message("Indices must be comma-separated nonnegative integers.") }
                    return value
                }
            } else { indices = [3, 18, 32] }
            print(try JSONSupport.encode(PipeWireDiagnostics.runSFX(repository: repository, paths: paths, indices: indices)))
        case "diagnose-live-profiles":
            try options.validate(values: ["repository", "home"])
            try DiagnosticPrerequisites.requirePrograms(["systemctl", "pactl", "pw-cat", "pw-cli", "pw-dump"])
            try LiveProfiles.run(paths: paths, repository: repository)
        case "diagnose-live-automation":
            try options.validate(values: ["repository", "home"])
            try DiagnosticPrerequisites.requirePrograms(["systemctl", "pactl", "pw-dump"])
            try LiveAutomation.run(paths: paths, repository: repository)
        default:
            throw InzoneError.message("Unknown tools command: \(command). Use --help.")
        }
    }
}

struct ToolArguments {
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var positional: [String] = []

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                positional.append(contentsOf: arguments.dropFirst(index + 1))
                break
            }
            if argument.hasPrefix("--") {
                let parts = argument.dropFirst(2).split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(parts[0])
                guard values[key] == nil && !switches.contains(key) else {
                    throw InzoneError.message("Duplicate option: --\(key).")
                }
                if ["offline", "download-only"].contains(key), parts.count == 1 { switches.insert(key) }
                else if parts.count == 2 { values[key] = String(parts[1]) }
                else {
                    index += 1
                    guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                        throw InzoneError.message("Option --\(key) requires a value.")
                    }
                    values[key] = arguments[index]
                }
            } else { positional.append(argument) }
            index += 1
        }
    }

    static func path(_ text: String) -> URL { URL(fileURLWithPath: (text as NSString).expandingTildeInPath) }
    func url(_ key: String) -> URL? { values[key].map(Self.path) }

    func validate(values allowedValues: Set<String>, switches allowedSwitches: Set<String> = [], positionalCount: Int = 0) throws {
        guard Set(values.keys).isSubset(of: allowedValues), switches.isSubset(of: allowedSwitches), positional.count == positionalCount else {
            throw InzoneError.message("Invalid command arguments. Use inzone-tools --help.")
        }
    }
}
