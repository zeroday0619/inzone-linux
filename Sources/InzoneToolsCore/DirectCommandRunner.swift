import Foundation
import Glibc
import InzoneCore

struct DirectCommandRunner: CommandRunning {
    func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
        guard let command = arguments.first, command.hasPrefix("/"), timeout > 0 else {
            throw InzoneError.message("An absolute command path and positive timeout are required.")
        }
        guard input == nil else {
            throw InzoneError.message("Direct privileged commands do not accept buffered input.")
        }

        let terminal = try ForegroundTerminal()
        defer { try? terminal?.restore() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        do {
            try terminal?.transfer(to: process.processIdentifier)
        } catch {
            stop(process)
            process.waitUntilExit()
            throw error
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut { stop(process) }
        process.waitUntilExit()
        try terminal?.restore()
        guard !timedOut, process.terminationStatus == 0 else {
            throw CommandError(
                arguments: arguments, status: process.terminationStatus, output: "", timedOut: timedOut
            )
        }
        return ""
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        let group = getpgid(process.processIdentifier) == process.processIdentifier
        let target = group ? -process.processIdentifier : process.processIdentifier
        _ = Glibc.kill(target, SIGTERM)
        // Stopped terminal readers must resume before they can handle termination.
        _ = Glibc.kill(target, SIGCONT)
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { _ = Glibc.kill(target, SIGKILL) }
    }
}
