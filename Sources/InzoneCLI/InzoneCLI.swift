import Foundation
import Glibc
import InzoneCore
import InzoneTUI

@main
@MainActor
struct InzoneCommand {
    static let help = """
    Usage: inzone-profile [COMMAND]

    No arguments: open the SwiftTUI terminal interface.
    Profiles: fps | music | voice | balanced | surround | restore
    --tui, --gui                         Open the terminal interface
    --debug                             Enable command and DSP verification logging
    --status                            Print the active profile
    --list, --help, -h                   Print this help
    --settings                          Print saved DSP settings
    --profiles                          List built-in and custom sound profiles
    --profile-create NAME [BASE]        Create a custom profile
    --profile-clone PROFILE [NAME]      Clone a built-in or custom profile
    --profile-rename PROFILE NAME       Rename a custom profile
    --profile-delete PROFILE            Delete an inactive, unreferenced custom profile
    --set PROFILE KEY JSON_VALUE        Change and apply one DSP option
    --export FILE.json                  Export DSP settings
    --import FILE.json                  Import and apply DSP settings
    --preset [PROFILE PRESET]           List or apply Sony EQ presets
    --windows-list FILE.json            List Windows SoundProfile entries
    --windows-import PROFILE FILE INDEX Import a Windows entry (1-based index)
    --windows-export PROFILE FILE.json  Export a compatible Windows profile
    --windows-import-collection FILE.json
                                       Append Windows profiles with new identifiers
    --windows-replace-collection FILE.json
                                       Replace the custom collection and preserve identifiers
    --windows-export-collection FILE.json [--force]
                                       Export the complete collection; --force replaces an existing file
    --personalize-import FILE.hki YY2987.ba
                                       Validate and import personalized filters
    --personalize-reset                Reset all profiles to standard HRTF and remove personal filters
    --personalize-cleanup              Retry cleanup of retired personal filter banks
    --personalize-cleanup-status       List retired personal filter banks awaiting cleanup
    --device-status                     Read headset state
    --device-set FIELD VALUE            Set a headset field and verify readback
    --auto-config                       Print process association rules
    --auto-bind APP PROFILE [PRIORITY]   Add or replace a rule
    --auto-remove APP                   Remove a rule
    --auto-enable, --auto-disable       Enable or disable the user service
    --auto-watch                        Run the process association watcher

    DSP keys: drc (0..2), output_alc, mic_agc, hrtf, eq, eq_enable,
              sound_mode, base_eq. Boolean values use JSON true or false.
    EQ: ten integer gains from -12 to 12 dB, ordered from 31.5 Hz to 16 kHz.
    """

    static func main() {
        do {
            try execute(Array(CommandLine.arguments.dropFirst()))
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            let escapedMessage = TerminalOutput.escaped(message, preservingNewlines: false)
            FileHandle.standardError.write(Data((escapedMessage + "\n").utf8))
            exit(1)
        }
    }

    static func file(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static func count(_ arguments: [String], _ allowed: Set<Int>, usage: String) throws {
        guard allowed.contains(arguments.count) else { throw InzoneError.message("Usage: inzone-profile \(usage)") }
    }

    static func execute(_ arguments: [String]) throws {
        var arguments = arguments
        let debugFlagCount = arguments.filter { $0 == "--debug" }.count
        guard debugFlagCount <= 1 else {
            throw InzoneError.message("Specify --debug only once.")
        }
        arguments.removeAll { $0 == "--debug" }
        let command = arguments.first ?? "--tui"
        let paths = InzonePaths()
        let debugEnabled = debugFlagCount == 1 || ProcessInfo.processInfo.environment["INZONE_DEBUG"] == "1"
        let logger: any DiagnosticLogging = debugEnabled
            ? try DiagnosticLogger(
                file: paths.debugLog,
                echoToStandardError: command != "--tui" && command != "--gui"
            )
            : DisabledDiagnosticLogger()
        if debugEnabled { logger.log("debug mode enabled: command=\(command); log=\(paths.debugLog.path)") }
        let controller = ProfileController(
            paths: paths, runner: SystemCommandRunner(logger: logger), logger: logger,
            dspDebugLog: debugEnabled ? paths.debugLog : nil
        )
        let settings = SettingsStore(paths: paths)
        let automation = AutomationStore(paths: paths)
        let presets = SonyPresets(paths: paths)

        switch command {
        case "--help", "-h", "--list":
            try count(arguments, [1], usage: command)
            print(help)
        case "--tui", "--gui":
            try count(arguments, [0, 1], usage: "--tui")
            guard isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1 else {
                throw InzoneError.message("The TUI requires an interactive terminal. Use --help for CLI commands.")
            }
            InzoneTerminal.run(controller: controller)
        case "--status":
            try count(arguments, [1], usage: command)
            print(TerminalOutput.escaped(try controller.status(), preservingNewlines: false))
        case "--settings":
            try count(arguments, [1], usage: command)
            print(try settings.encode(settings.load()))
        case "--profiles":
            try count(arguments, [1], usage: command)
            let values = try controller.availableProfiles().map { profile in
                [
                    "id": profile.identifier, "name": profile.name,
                    "template": profile.templateProfile, "built_in": profile.isBuiltIn,
                ] as [String: Any]
            }
            print(TerminalOutput.escapedJSON(try JSONSupport.encode(values)))
        case "--profile-create":
            try count(arguments, [2, 3], usage: "--profile-create NAME [BASE]")
            let profile = try controller.createProfile(
                name: arguments[1], basedOn: arguments.count == 3 ? arguments[2] : "balanced"
            )
            print(TerminalOutput.escaped(profile.identifier, preservingNewlines: false))
        case "--profile-clone":
            try count(arguments, [2, 3], usage: "--profile-clone PROFILE [NAME]")
            let profile = try controller.cloneProfile(
                arguments[1], name: arguments.count == 3 ? arguments[2] : nil
            )
            print(TerminalOutput.escaped(profile.identifier, preservingNewlines: false))
        case "--profile-rename":
            try count(arguments, [3], usage: "--profile-rename PROFILE NAME")
            try controller.renameProfile(arguments[1], to: arguments[2])
        case "--profile-delete":
            try count(arguments, [2], usage: "--profile-delete PROFILE")
            try controller.deleteProfile(arguments[1])
        case "--set":
            try count(arguments, [4], usage: "--set PROFILE KEY JSON_VALUE")
            let value = try JSONSupport.decode(Data(arguments[3].utf8))
            try controller.changeOptions(arguments[1], updates: [arguments[2]: value])
            let profile = TerminalOutput.escaped(arguments[1], preservingNewlines: false)
            print("Applied DSP settings for \(profile).")
        case "--export":
            try count(arguments, [2], usage: "--export FILE.json")
            try AtomicFile.write(Data((try settings.encode(settings.load()) + "\n").utf8), to: file(arguments[1]))
        case "--import":
            try count(arguments, [2], usage: "--import FILE.json")
            try controller.importSettings(Data(contentsOf: file(arguments[1])))
            print("Imported DSP settings.")
        case "--preset":
            try count(arguments, [1, 3], usage: "--preset [PROFILE PRESET]")
            if arguments.count == 1 {
                print(try JSONSupport.encode(SonyPresets.labels))
            } else {
                try controller.changeOptions(arguments[1], updates: presets.preset(arguments[2]))
                let preset = TerminalOutput.escaped(arguments[2], preservingNewlines: false)
                print("Applied Sony preset \(preset).")
            }
        case "--windows-list":
            try count(arguments, [2], usage: "--windows-list FILE.json")
            for (index, profile) in try presets.readWindows(file(arguments[1])).enumerated() {
                let value: [String: Any] = ["name": profile.name, "surround": profile.surround, "options": profile.options]
                let json = try JSONSupport.encode(value, pretty: false)
                print("\(index + 1): \(TerminalOutput.escapedJSON(json))")
            }
        case "--windows-import":
            try count(arguments, [4], usage: "--windows-import PROFILE FILE.json INDEX")
            let profiles = try presets.readWindows(file(arguments[2]))
            guard let index = Int(arguments[3]), (1...profiles.count).contains(index) else {
                throw InzoneError.message("The Windows profile index is outside the available range.")
            }
            let profile = profiles[index - 1]
            guard profile.surround == (try settings.resolvedProfile(arguments[1])).isSurround else {
                throw InzoneError.message("Windows Surround must match the destination profile's spatial processing.")
            }
            try controller.changeOptions(arguments[1], updates: profile.options)
            print("Imported Windows profile \(index).")
        case "--windows-export":
            try count(arguments, [3], usage: "--windows-export PROFILE FILE.json")
            try presets.exportWindows(profile: arguments[1], to: file(arguments[2]))
            print("Exported Windows profile.")
        case "--windows-import-collection":
            try count(arguments, [2], usage: "--windows-import-collection FILE.json")
            let outcome = try controller.importWindowsCollection(file(arguments[1]), mode: .append)
            print("Imported \(outcome.importedCount) Windows sound profile(s).")
            reportSkippedProfiles(outcome.skippedCount)
        case "--windows-replace-collection":
            try count(arguments, [2], usage: "--windows-replace-collection FILE.json")
            let outcome = try controller.importWindowsCollection(file(arguments[1]), mode: .replace)
            print("Replaced the custom collection with \(outcome.importedCount) Windows sound profile(s).")
        case "--windows-export-collection":
            try count(arguments, [2, 3], usage: "--windows-export-collection FILE.json [--force]")
            guard arguments.count == 2 || arguments[2] == "--force" else {
                throw InzoneError.message("Usage: inzone-profile --windows-export-collection FILE.json [--force]")
            }
            try controller.exportWindowsCollection(
                file(arguments[1]), allowOverwrite: arguments.count == 3
            )
            print("Exported Windows sound profile collection.")
        case "--personalize-import":
            try count(arguments, [3], usage: "--personalize-import FILE.hki YY2987.ba")
            let outcome = try controller.importPersonalizationResult(
                hki: file(arguments[1]), ba: file(arguments[2])
            )
            print(TerminalOutput.escaped(outcome.destination.path, preservingNewlines: false))
            reportCleanupPending(outcome.cleanupPending)
        case "--personalize-reset":
            try count(arguments, [1], usage: command)
            let outcome = try controller.resetPersonalizationResult()
            print(outcome.removed ? "Removed personalized filters." : "No personalized filters were installed.")
            reportCleanupPending(outcome.cleanupPending)
        case "--personalize-cleanup":
            try count(arguments, [1], usage: command)
            let remaining = try controller.retryPersonalizationCleanup()
            print(remaining.isEmpty ? "Retired personal filter banks were cleaned." : "Personalization cleanup remains pending.")
            reportCleanupPending(remaining)
        case "--personalize-cleanup-status":
            try count(arguments, [1], usage: command)
            print(TerminalOutput.escapedJSON(try JSONSupport.encode(controller.personalizationCleanupPending())))
        case "--device-status":
            try count(arguments, [1], usage: command)
            let device = try InzoneDevice()
            defer { device.close() }
            print(try JSONSupport.encode(device.snapshot()))
        case "--device-set":
            try count(arguments, [3], usage: "--device-set FIELD VALUE")
            guard let value = Int(arguments[2]) else { throw InzoneError.message("Device values must be integers.") }
            guard let field = InzoneDevice.fields.first(where: { $0.name == arguments[1] }),
                  field.values.contains(value) else {
                throw InzoneError.message("Unknown device field or out-of-range value: \(arguments[1])")
            }
            let device = try InzoneDevice()
            defer { device.close() }
            try device.setField(arguments[1], value: value)
            print("Updated headset setting and verified readback.")
        case "--auto-config":
            try count(arguments, [1], usage: command)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: try encoder.encode(automation.load()), as: UTF8.self)
            print(TerminalOutput.escapedJSON(json))
        case "--auto-bind":
            try count(arguments, [3, 4], usage: "--auto-bind APP PROFILE [PRIORITY]")
            guard let priority = Int(arguments.count == 4 ? arguments[3] : "0") else {
                throw InzoneError.message("Automation priority must be an integer.")
            }
            try automation.edit(app: arguments[1], profile: arguments[2], priority: priority)
        case "--auto-remove":
            try count(arguments, [2], usage: "--auto-remove APP")
            try automation.edit(app: arguments[1], profile: nil)
        case "--auto-enable", "--auto-disable":
            try count(arguments, [1], usage: command)
            try automation.service(command == "--auto-enable" ? "enable" : "disable", runner: controller.runner)
        case "--auto-watch":
            try count(arguments, [1], usage: command)
            try automation.watch(controller: controller)
        case "--firmware-update", "--update-firmware", "--flash-firmware", "--firmware-download",
             "firmware-update", "update-firmware", "flash-firmware", "firmware-download":
            throw InzoneError.message(
                "Firmware update, flashing, and download operations are intentionally not implemented. Use --device-status to read the installed version."
            )
        default:
            let isKnownProfile = command == "restore" ? true : try settings.profileIfAvailable(command) != nil
            guard isKnownProfile else {
                throw InzoneError.message("Unknown command or profile: \(command). Use --help.")
            }
            try count(arguments, [1], usage: command)
            try controller.activate(command)
            print("Applied profile: \(command).")
        }
    }

    private static func reportCleanupPending(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let message = "Personalization cleanup remains pending for \(paths.count) retired bank(s). Retry with --personalize-cleanup."
        let escaped = TerminalOutput.escaped(message, preservingNewlines: false)
        try? FileHandle.standardError.write(contentsOf: Data((escaped + "\n").utf8))
    }

    private static func reportSkippedProfiles(_ count: Int) {
        guard count > 0 else { return }
        let message = "Skipped \(count) Windows sound profile(s) because the collection limit is 256."
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}
