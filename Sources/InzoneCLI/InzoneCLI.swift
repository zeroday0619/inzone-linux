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
    --status                            Print the active profile
    --list, --help, -h                   Print this help
    --settings                          Print saved DSP settings
    --set PROFILE KEY JSON_VALUE        Change and apply one DSP option
    --export FILE.json                  Export DSP settings
    --import FILE.json                  Import and apply DSP settings
    --preset [PROFILE PRESET]           List or apply Sony EQ presets
    --windows-list FILE.json            List Windows SoundProfile entries
    --windows-import PROFILE FILE INDEX Import a Windows entry (1-based index)
    --windows-export PROFILE FILE.json  Export a compatible Windows profile
    --personalize-import FILE.hki YY2987.ba
                                       Validate and import personalized filters
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
        let command = arguments.first ?? "--tui"
        let paths = InzonePaths()
        let controller = ProfileController(paths: paths)
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
            guard profile.surround == (arguments[1] == "surround") else {
                throw InzoneError.message("Windows Surround must match the destination profile's spatial processing.")
            }
            try controller.changeOptions(arguments[1], updates: profile.options)
            print("Imported Windows profile \(index).")
        case "--windows-export":
            try count(arguments, [3], usage: "--windows-export PROFILE FILE.json")
            try presets.exportWindows(profile: arguments[1], to: file(arguments[2]))
            print("Exported Windows profile.")
        case "--personalize-import":
            try count(arguments, [3], usage: "--personalize-import FILE.hki YY2987.ba")
            let destination = try Personalization.importFiles(
                paths: paths, hki: file(arguments[1]), ba: file(arguments[2])
            ).path
            print(TerminalOutput.escaped(destination, preservingNewlines: false))
        case "--device-status":
            try count(arguments, [1], usage: command)
            let device = try InzoneDevice()
            defer { device.close() }
            print(try JSONSupport.encode(device.snapshot()))
        case "--device-set":
            try count(arguments, [3], usage: "--device-set FIELD VALUE")
            guard let value = Int(arguments[2]) else { throw InzoneError.message("Device values must be integers.") }
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
        default:
            guard (SettingsStore.profiles + ["restore"]).contains(command) else {
                throw InzoneError.message("Unknown command or profile: \(command). Use --help.")
            }
            try count(arguments, [1], usage: command)
            try controller.activate(command)
            print("Applied profile: \(command).")
        }
    }
}
