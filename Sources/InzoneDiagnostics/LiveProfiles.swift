import Foundation
import Glibc
import InzoneCore

public enum LiveProfiles {
    public static func run(
        paths: InzonePaths, repository: URL, runner: any CommandRunning = SystemCommandRunner()
    ) throws {
        try LiveDiagnosticSupport.requireCommands(["pactl", "pw-cat", "pw-cli", "pw-dump", "systemctl"])
        try LiveDiagnosticSupport.requireInactiveAutomation(runner: runner)
        let diagnosticLock = try FileLock(url: paths.configDirectory.appendingPathComponent("live-diagnostics.lock"))
        let cancellation = LiveDiagnosticCancellation()
        defer { withExtendedLifetime(cancellation) {} }
        let watcherLock = try FileLock(url: paths.configDirectory.appendingPathComponent("auto-watch.lock"))
        defer { withExtendedLifetime((diagnosticLock, watcherLock)) {} }
        let controller = ProfileController(paths: paths, runner: runner)
        let profiles = ["surround", "fps", "music", "voice", "balanced", "restore"]
        try LiveDiagnosticSupport.requireNodes(
            [ProfileController.game, ProfileController.chat, LiveDiagnosticSupport.microphone], runner: runner
        )
        try LiveDiagnosticSupport.requireTemplates(profiles, paths: paths)
        let state = try LiveSessionState(paths: paths, runner: runner)
        let results: [[String: Any]] = try state.withRestoration {
            var results: [[String: Any]] = []
            try LiveDiagnosticCancellation.check()
            _ = try runner.run(["pactl", "set-sink-mute", ProfileController.game, "1"])
            for profile in profiles {
                try LiveDiagnosticCancellation.check()
                try controller.activate(profile)
                try LiveDiagnosticCancellation.check()
                results.append(["profile": profile, "result": "loaded and routed"])
            }
            let changes: [(String, [String: Any])] = [
                ("balanced", ["drc": 2, "output_alc": true]),
                ("voice", ["mic_agc": true]),
                ("surround", [
                    "drc": 1, "output_alc": true, "eq": [0, 0, 0, 0, 0, 1, 0, 0, 0, 0],
                    "sound_mode": "immersive", "base_eq": false,
                ]),
                ("fps", [
                    "drc": 1, "output_alc": true, "eq": [-6, -2, 2, 3, 2, 0, 2, 3, 1, -2],
                    "sound_mode": "standard", "base_eq": false,
                ]),
            ]
            for (profile, options) in changes {
                try LiveDiagnosticCancellation.check()
                print("Checking \(profile) \(try JSONSupport.encode(options, pretty: false))")
                try controller.changeOptions(profile, updates: options)
                try LiveDiagnosticCancellation.check()
                let target = profile == "surround" ? ProfileController.surround : ProfileController.game
                _ = try runner.run([
                    "pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000",
                    "--channels", "2", "--latency", "256", "--target", target, "-",
                ], input: Data(count: 4096 * 8), timeout: 8)
                try LiveDiagnosticCancellation.check()
                if profile == "voice" {
                    let recorder = try LiveDiagnosticProcess(
                        executable: LiveDiagnosticSupport.executable("pw-cat"),
                        arguments: [
                            "-r", "--raw", "--format", "f32", "--rate", "48000", "--channels", "1",
                            "--target", LiveDiagnosticSupport.microphone, "-",
                        ], environment: LiveDiagnosticSupport.environment(paths: paths), captureOutput: false
                    )
                    do {
                        try LiveDiagnosticCancellation.pause(0.4)
                        guard recorder.isRunning else {
                            throw InzoneError.message("The microphone verification stream exited unexpectedly: \(try recorder.output())")
                        }
                        let properties = try LiveDiagnosticSupport.properties(
                            node: LiveDiagnosticSupport.microphone, runner: runner
                        )
                        guard properties.contains("mic_agc:") else {
                            throw InzoneError.message("The microphone AGC control ports were not loaded.")
                        }
                    } catch {
                        do { try recorder.stop(timeout: 3) } catch let cleanup {
                            throw LiveDiagnosticSupport.combined(error, cleanup)
                        }
                        throw error
                    }
                    try recorder.stop(timeout: 3)
                } else {
                    let properties = try LiveDiagnosticSupport.properties(node: ProfileController.game, runner: runner)
                    guard properties.contains("output_alc:"), properties.contains("game_drc:") else {
                        throw InzoneError.message("The Game output ALC and DRC control ports were not loaded.")
                    }
                    let chat = try LiveDiagnosticSupport.properties(node: ProfileController.chat, runner: runner)
                    guard ["output_alc:", "game_drc:", "custom0:", "immersive0:"].allSatisfy({ !chat.contains($0) }) else {
                        throw InzoneError.message("Game output effects unexpectedly appeared on Chat: \(chat)")
                    }
                }
                results.append(["profile": profile, "settings": options, "result": "DSP ports verified"])
            }
            return results
        }
        try LiveDiagnosticCancellation.check()
        let report = repository.appendingPathComponent("analysis/live-profile-results.json")
        try AtomicFile.write(Data((try JSONSupport.encode(results) + "\n").utf8), to: report, permissions: 0o644)
        print("PASS \(results.count) live profile/DSP checks; restored \(state.initialProfile)")
    }
}

nonisolated(unsafe) private var liveDiagnosticCancelled: sig_atomic_t = 0
private func liveDiagnosticSignalHandler(_ signal: Int32) { liveDiagnosticCancelled = 1 }

final class LiveDiagnosticCancellation {
    private let previousInterrupt: sig_t?
    private let previousTermination: sig_t?

    init() {
        liveDiagnosticCancelled = 0
        previousInterrupt = Glibc.signal(SIGINT, liveDiagnosticSignalHandler)
        previousTermination = Glibc.signal(SIGTERM, liveDiagnosticSignalHandler)
    }

    deinit {
        _ = Glibc.signal(SIGINT, previousInterrupt)
        _ = Glibc.signal(SIGTERM, previousTermination)
    }

    static func check() throws {
        guard liveDiagnosticCancelled == 0 else { throw InzoneError.message("Live diagnostics were cancelled; saved state restoration was requested.") }
    }

    static func pause(_ duration: TimeInterval) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + duration
        while ProcessInfo.processInfo.systemUptime < deadline {
            try check()
            Thread.sleep(forTimeInterval: max(0, min(0.1, deadline - ProcessInfo.processInfo.systemUptime)))
        }
        try check()
    }
}

struct LiveSavedFile {
    let url: URL
    let data: Data?
    let permissions: Int

    init(_ url: URL, required: Bool = false) throws {
        self.url = url
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            guard !required else { throw error }
            data = nil
            permissions = 0o600
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw InzoneError.message("Live diagnostics require a regular state file without symlinks: \(url.path)")
        }
        data = try Data(contentsOf: url)
        permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    func restore() throws {
        if let data {
            try AtomicFile.write(data, to: url, permissions: permissions)
        } else if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw InzoneError.message("Refusing to remove an unexpected state object: \(url.path)")
            }
            try FileManager.default.removeItem(at: url)
        }
    }
}

final class LiveSessionState {
    let initialProfile: String
    private let paths: InzonePaths
    private let runner: any CommandRunning
    private let active: LiveSavedFile
    private let settings: LiveSavedFile
    private let manual: LiveSavedFile
    private let rules: LiveSavedFile
    private let defaultSink: String
    private let muted: Bool

    init(paths: InzonePaths, runner: any CommandRunning) throws {
        self.paths = paths
        self.runner = runner
        active = try LiveSavedFile(paths.activeProfile, required: true)
        settings = try LiveSavedFile(paths.configDirectory.appendingPathComponent("profile-settings.json"))
        manual = try LiveSavedFile(paths.configDirectory.appendingPathComponent("manual-switch"))
        rules = try LiveSavedFile(AutomationStore(paths: paths).fileURL)
        let settingsStore = SettingsStore(paths: paths)
        _ = try settingsStore.load()
        _ = try AutomationStore(paths: paths).load()
        let current = try ProfileController(paths: paths, runner: runner).status()
        if current == "original" || current == "restore" {
            initialProfile = "restore"
        } else if let profile = try settingsStore.profileIfAvailable(current) {
            initialProfile = profile.identifier
        } else {
            throw InzoneError.message("The initial profile cannot be identified safely: \(current)")
        }
        defaultSink = try runner.run(["pactl", "get-default-sink"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !defaultSink.isEmpty, !defaultSink.contains("\n"), !defaultSink.contains("\r") else {
            throw InzoneError.message("The initial default sink cannot be identified safely.")
        }
        let mute = try runner.run(["pactl", "get-sink-mute", ProfileController.game])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch mute {
        case "Mute: yes": muted = true
        case "Mute: no": muted = false
        default: throw InzoneError.message("Unrecognized Game sink mute state: \(mute). Run with LC_ALL=C.")
        }
    }

    func withRestoration<Result>(_ operation: () throws -> Result) throws -> Result {
        let result: Swift.Result<Result, Error>
        do { result = .success(try operation()) } catch { result = .failure(error) }
        do {
            try restore()
        } catch {
            if case .failure(let original) = result { throw LiveDiagnosticSupport.combined(original, error) }
            throw error
        }
        return try result.get()
    }

    private func restore() throws {
        let lock = try FileLock(url: paths.configDirectory.appendingPathComponent("switch.lock"))
        defer { withExtendedLifetime(lock) {} }
        var failures: [String] = []
        func attempt(_ description: String, _ operation: () throws -> Void) {
            do { try operation() } catch { failures.append("\(description): \(error.localizedDescription)") }
        }
        attempt("Restore DSP settings") { try settings.restore() }
        attempt("Restore automation rules") { try rules.restore() }
        attempt("Restore active profile") { try active.restore() }
        attempt("Restart WirePlumber") { _ = try runner.run(["systemctl", "--user", "restart", "wireplumber.service"]) }
        attempt("Verify WirePlumber") { _ = try runner.run(["systemctl", "--user", "is-active", "wireplumber.service"]) }
        attempt("Restore default sink") {
            try LiveDiagnosticSupport.retryRouting {
                _ = try runner.run(["pactl", "set-default-sink", defaultSink])
            }
        }
        attempt("Restore Game mute") {
            try LiveDiagnosticSupport.retryRouting {
                _ = try runner.run(["pactl", "set-sink-mute", ProfileController.game, muted ? "1" : "0"])
            }
        }
        // The original token retains manual ownership after diagnostic profile changes.
        attempt("Restore manual selection token") { try manual.restore() }
        if !failures.isEmpty {
            throw InzoneError.message("Live diagnostic restoration failed. " + failures.joined(separator: " "))
        }
    }
}

enum LiveDiagnosticSupport {
    static let microphone = "alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat"

    static func combined(_ original: any Error, _ cleanup: any Error) -> InzoneError {
        .message("\(original.localizedDescription) Restoration also failed: \(cleanup.localizedDescription)")
    }

    static func environment(paths: InzonePaths) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = paths.home.path
        environment["LC_ALL"] = "C"
        return environment
    }

    static func executable(_ name: String) throws -> URL {
        let candidates: [URL]
        if name.contains("/") {
            candidates = [URL(fileURLWithPath: name)]
        } else {
            candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).map {
                URL(fileURLWithPath: $0.isEmpty ? FileManager.default.currentDirectoryPath : String($0)).appendingPathComponent(name)
            }
        }
        guard let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw InzoneError.message("Required live diagnostic executable is unavailable: \(name)")
        }
        return candidate
    }

    static func requireCommands(_ names: [String]) throws {
        for name in names { _ = try executable(name) }
    }

    static func requireInactiveAutomation(runner: any CommandRunning) throws {
        do {
            _ = try runner.run(["systemctl", "--user", "is-active", "--quiet", AutomationStore.unit])
        } catch let error as CommandError where !error.timedOut && [3, 4].contains(error.status) {
            return
        }
        throw InzoneError.message("Stop the existing automation service before running live diagnostics.")
    }

    static func requireTemplates(_ profiles: [String], paths: InzonePaths) throws {
        for profile in profiles {
            let file = paths.configDirectory.appendingPathComponent((profile == "restore" ? "original" : profile) + ".conf")
            let template = try String(contentsOf: file, encoding: .utf8)
            _ = try GraphRenderer(paths: paths).render(profile: profile, template: template)
        }
    }

    static func nodeIdentifier(_ name: String, runner: any CommandRunning) throws -> String {
        let output = try runner.run(["pw-dump"])
        guard let objects = try JSONSupport.decode(Data(output.utf8)) as? [[String: Any]] else {
            throw InzoneError.message("PipeWire node discovery did not return an array.")
        }
        let matches = objects.filter { object in
            guard object["type"] as? String == "PipeWire:Interface:Node",
                  let information = object["info"] as? [String: Any],
                  let properties = information["props"] as? [String: Any] else { return false }
            return properties["node.name"] as? String == name
        }
        guard matches.count == 1, let identifier = matches.first?["id"] as? NSNumber else {
            throw InzoneError.message("Exactly one live PipeWire node is required for \(name); found \(matches.count).")
        }
        return identifier.stringValue
    }

    static func requireNodes(_ names: [String], runner: any CommandRunning) throws {
        for name in names { _ = try nodeIdentifier(name, runner: runner) }
    }

    static func properties(node: String, runner: any CommandRunning) throws -> String {
        try runner.run(["pw-cli", "enum-params", nodeIdentifier(node, runner: runner), "Props"])
    }

    static func retryRouting(_ operation: () throws -> Void) throws {
        for attempt in 0..<40 {
            do { try operation(); return } catch let error as CommandError where !error.timedOut {
                guard attempt < 39 else { throw error }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }
}

final class LiveDiagnosticProcess {
    private let process = Process()
    private let directory: URL
    private let log: URL
    private let logHandle: FileHandle

    var isRunning: Bool { process.isRunning }
    var status: Int32 { process.terminationStatus }

    init(executable: URL, arguments: [String], environment: [String: String], captureOutput: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-live-process-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        log = directory.appendingPathComponent("output")
        do {
            try Data().write(to: log)
            logHandle = try FileHandle(forWritingTo: log)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = captureOutput ? logHandle : FileHandle.nullDevice
        process.standardError = logHandle
        do { try process.run() } catch {
            try? logHandle.close()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    deinit {
        if process.isRunning {
            _ = Glibc.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        try? logHandle.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func output() throws -> String { String(decoding: try Data(contentsOf: log), as: UTF8.self) }

    func stop(timeout: TimeInterval, requireSuccessfulExit: Bool = false) throws {
        if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        guard !timedOut else { throw InzoneError.message("Live diagnostic subprocess did not stop within \(timeout) seconds: \(try output())") }
        if requireSuccessfulExit, process.terminationReason != .exit || process.terminationStatus != 0 {
            throw InzoneError.message("Live diagnostic subprocess exited with status \(process.terminationStatus): \(try output())")
        }
    }
}
