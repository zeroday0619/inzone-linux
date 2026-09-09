import Foundation
import InzoneCore

public enum LiveAutomation {
    public static func run(
        paths: InzonePaths, repository: URL, runner: any CommandRunning = SystemCommandRunner()
    ) throws {
        try LiveDiagnosticSupport.requireCommands(["pactl", "pw-cat", "pw-cli", "pw-dump", "systemctl"])
        try LiveDiagnosticSupport.requireInactiveAutomation(runner: runner)
        let diagnosticLock = try FileLock(url: paths.configDirectory.appendingPathComponent("live-diagnostics.lock"))
        defer { withExtendedLifetime(diagnosticLock) {} }
        let cancellation = LiveDiagnosticCancellation()
        defer { withExtendedLifetime(cancellation) {} }
        // An independently started watcher must also be absent when the service is inactive.
        do {
            let watcherLock = try FileLock(url: paths.configDirectory.appendingPathComponent("auto-watch.lock"))
            withExtendedLifetime(watcherLock) {}
        }
        try LiveDiagnosticSupport.requireNodes([ProfileController.game, ProfileController.chat], runner: runner)
        try LiveDiagnosticSupport.requireTemplates(["music", "balanced", "voice"], paths: paths)
        let binary = try profileExecutable(paths: paths, repository: repository)
        let sleep = try LiveDiagnosticSupport.executable("/usr/bin/sleep")
        let state = try LiveSessionState(paths: paths, runner: runner)
        let controller = ProfileController(paths: paths, runner: runner)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-auto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("inzone-test-game")
        try Data(contentsOf: sleep).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let environment = LiveDiagnosticSupport.environment(paths: paths)
        let results: [String] = try state.withRestoration {
            var watcher: LiveDiagnosticProcess?
            var game: LiveDiagnosticProcess?
            do {
                var results: [String] = []
                try LiveDiagnosticCancellation.check()
                _ = try runner.run(["pactl", "set-sink-mute", ProfileController.game, "1"])
                try controller.activate("music")
                try LiveDiagnosticCancellation.check()
                try AutomationStore(paths: paths).save([
                    AutomationRule(app: executable.path, profile: "balanced", priority: 10),
                ])
                watcher = try LiveDiagnosticProcess(executable: binary, arguments: ["--auto-watch"], environment: environment)
                try LiveDiagnosticCancellation.pause(1)
                try requireWatcher(watcher)
                game = try LiveDiagnosticProcess(executable: executable, arguments: ["180"], environment: environment)
                try waitForProfile("balanced", controller: controller, watcher: watcher)
                results.append("game start selects balanced")
                try game?.stop(timeout: 5)
                game = nil
                try waitForProfile("music", controller: controller, watcher: watcher)
                results.append("game exit restores music")
                game = try LiveDiagnosticProcess(executable: executable, arguments: ["180"], environment: environment)
                try waitForProfile("balanced", controller: controller, watcher: watcher)
                try controller.activate("voice")
                try LiveDiagnosticCancellation.pause(4)
                try requireWatcher(watcher)
                try requireProfile("voice", controller: controller)
                results.append("manual choice remains while game runs")
                try game?.stop(timeout: 5)
                game = nil
                try LiveDiagnosticCancellation.pause(4)
                try requireWatcher(watcher)
                try requireProfile("voice", controller: controller)
                results.append("manual baseline survives game exit")
                try watcher?.stop(timeout: 50, requireSuccessfulExit: true)
                watcher = nil
                try requireProfile("voice", controller: controller)
                results.append("watcher shutdown preserves manual choice")
                return results
            } catch {
                var failures: [String] = []
                if let game {
                    do { try game.stop(timeout: 5) } catch { failures.append("Stop test game: \(error.localizedDescription)") }
                }
                if let watcher {
                    do { try watcher.stop(timeout: 50) } catch { failures.append("Stop test watcher: \(error.localizedDescription)") }
                }
                if !failures.isEmpty {
                    throw LiveDiagnosticSupport.combined(error, InzoneError.message(failures.joined(separator: " ")))
                }
                throw error
            }
        }
        try LiveDiagnosticCancellation.check()
        let report: [String: Any] = ["checks": results, "restored_profile": state.initialProfile]
        try AtomicFile.write(
            Data((try JSONSupport.encode(report) + "\n").utf8),
            to: repository.appendingPathComponent("analysis/live-automation-results.json"), permissions: 0o644
        )
        print("PASS: \(results.count) live automation checks; restored \(state.initialProfile)")
    }

    private static func profileExecutable(paths: InzonePaths, repository: URL) throws -> URL {
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("inzone-profile")
        let candidates = [
            sibling, repository.appendingPathComponent(".build/release/inzone-profile"),
            repository.appendingPathComponent(".build/debug/inzone-profile"),
            paths.home.appendingPathComponent(".local/bin/inzone-profile"),
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            let file = try FileHandle(forReadingFrom: candidate)
            defer { try? file.close() }
            if try file.read(upToCount: 4) == Data([0x7F, 0x45, 0x4C, 0x46]) { return candidate }
        }
        throw InzoneError.message("Build or install the native Swift inzone-profile executable before testing live automation.")
    }

    private static func requireWatcher(_ watcher: LiveDiagnosticProcess?) throws {
        guard let watcher, watcher.isRunning else {
            throw InzoneError.message("The automation watcher exited unexpectedly: \(try watcher?.output() ?? "not started")")
        }
    }

    private static func requireProfile(_ expected: String, controller: ProfileController) throws {
        let actual = try controller.status()
        guard actual == expected else {
            throw InzoneError.message("Expected active profile \(expected), found \(actual).")
        }
    }

    private static func waitForProfile(
        _ expected: String, controller: ProfileController, watcher: LiveDiagnosticProcess?
    ) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        var lastLockError: String?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try LiveDiagnosticCancellation.check()
            try requireWatcher(watcher)
            if try controller.status() == expected {
                do {
                    let lock = try FileLock(url: controller.paths.configDirectory.appendingPathComponent("switch.lock"))
                    defer { withExtendedLifetime(lock) {} }
                    // The active file is replaced before the restart and routing checks finish.
                    if try controller.status() == expected { return }
                } catch { lastLockError = error.localizedDescription }
            }
            try LiveDiagnosticCancellation.pause(0.25)
        }
        throw InzoneError.message(
            "Timed out waiting for \(expected); actual=\(try controller.status())."
                + (lastLockError.map { " Last switch-lock error: \($0)" } ?? "")
        )
    }
}
