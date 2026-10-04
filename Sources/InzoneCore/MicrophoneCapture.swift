import Foundation
import Glibc

public protocol MicrophoneCapturing: Sendable {
    func whileActive(source: String, operation: () throws -> Void) throws
}

public struct SystemMicrophoneCapture: MicrophoneCapturing {
    public init() {}

    public func whileActive(source: String, operation: () throws -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "pw-cat", "-r", "--raw", "--format", "f32", "--rate", "48000", "--channels", "1",
            "--target", source, "/dev/null",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        Thread.sleep(forTimeInterval: 0.4)
        guard process.isRunning else {
            throw InzoneError.message("The microphone capture stream exited before DSP verification.")
        }
        try operation()
    }
}
