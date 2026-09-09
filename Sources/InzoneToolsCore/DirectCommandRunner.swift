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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let terminationDeadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        guard !timedOut, process.terminationStatus == 0 else {
            throw CommandError(
                arguments: arguments, status: process.terminationStatus, output: "", timedOut: timedOut
            )
        }
        return ""
    }
}
