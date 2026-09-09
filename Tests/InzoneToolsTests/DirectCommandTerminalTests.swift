import Foundation
import Glibc
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class DirectCommandTerminalTests: XCTestCase {
    private static let fixtureKey = "INZONE_DIRECT_TERMINAL_FIXTURE"
    private static let inputMarker = "inzone-test-only-input"

    func testInteractiveInputAndTerminalRestoration() throws {
        for mode in ["success", "failure", "timeout", "interrupt"] {
            try runTerminalFixture(mode: mode)
        }
    }

    func testFixture() throws {
        guard let mode = ProcessInfo.processInfo.environment[Self.fixtureKey] else { return }
        let descriptor = Glibc.open("/dev/tty", O_RDWR | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { _ = Glibc.close(descriptor) }
        var original = termios()
        XCTAssertEqual(Glibc.tcgetattr(descriptor, &original), 0)
        XCTAssertEqual(Glibc.tcgetpgrp(descriptor), Glibc.getpgrp())

        let command: String
        if mode == "timeout" || mode == "interrupt" {
            command = "stty -echo </dev/tty; printf 'AUTH_READY\\n'; exec /bin/sleep 10"
        } else {
            let status = mode == "failure" ? 7 : 0
            command = "stty -echo </dev/tty; printf 'AUTH_READY\\n'; "
                + "IFS= read -r value </dev/tty; stty echo </dev/tty; "
                + "test \"$value\" = '\(Self.inputMarker)' || exit 8; exit \(status)"
        }
        do {
            _ = try DirectCommandRunner().run(
                ["/bin/sh", "-c", command], timeout: mode == "timeout" ? 0.5 : 2
            )
            XCTAssertEqual(mode, "success")
        } catch let error as CommandError {
            if mode == "timeout" {
                XCTAssertTrue(error.timedOut)
            } else if mode == "interrupt" {
                XCTAssertFalse(error.timedOut)
                XCTAssertEqual(error.status, SIGINT)
            } else {
                XCTAssertEqual(mode, "failure")
                XCTAssertFalse(error.timedOut)
                XCTAssertEqual(error.status, 7)
            }
        }

        XCTAssertEqual(Glibc.tcgetpgrp(descriptor), Glibc.getpgrp())
        var restored = termios()
        XCTAssertEqual(Glibc.tcgetattr(descriptor, &restored), 0)
        XCTAssertEqual(restored.c_iflag, original.c_iflag)
        XCTAssertEqual(restored.c_oflag, original.c_oflag)
        XCTAssertEqual(restored.c_cflag, original.c_cflag)
        XCTAssertEqual(restored.c_lflag, original.c_lflag)
        XCTAssertEqual(Glibc.cfgetispeed(&restored), Glibc.cfgetispeed(&original))
        XCTAssertEqual(Glibc.cfgetospeed(&restored), Glibc.cfgetospeed(&original))
        XCTAssertEqual(withUnsafeBytes(of: restored.c_cc) { Array($0) },
                       withUnsafeBytes(of: original.c_cc) { Array($0) })
        print("TERMINAL_RESTORED")
        // This subprocess fixture exits directly after assertions, without XCTest teardown threads.
        let failures = testRun?.totalFailureCount ?? 1
        fflush(nil)
        Glibc._exit(failures == 0 ? 0 : 1)
    }

    private func runTerminalFixture(mode: String) throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("inzone-direct-terminal-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let transcript = directory.appendingPathComponent("transcript")
        XCTAssertTrue(manager.createFile(atPath: transcript.path, contents: nil))
        let output = try FileHandle(forWritingTo: transcript)
        defer { try? output.close() }
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        let executable = CommandLine.arguments[0].replacingOccurrences(of: "'", with: "'\\''")
        process.arguments = ["--quiet", "--return", "--command",
            "exec '\(executable)' InzoneToolsTests.DirectCommandTerminalTests/testFixture", "/dev/null"]
        var environment = ProcessInfo.processInfo.environment
        environment[Self.fixtureKey] = mode
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + 6
        var sentInput = false
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            let text = String(decoding: try Data(contentsOf: transcript), as: UTF8.self)
            if mode != "timeout", !sentInput, text.contains("AUTH_READY") {
                let characters = mode == "interrupt" ? "\u{03}" : Self.inputMarker + "\n"
                try input.fileHandleForWriting.write(contentsOf: Data(characters.utf8))
                sentInput = true
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let text = String(decoding: try Data(contentsOf: transcript), as: UTF8.self)
        XCTAssertFalse(process.isRunning, "\(mode): fixture did not exit. \(text)")
        guard !process.isRunning else { return }
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(mode): \(text)")
        XCTAssertTrue(text.contains("AUTH_READY"), "\(mode): \(text)")
        XCTAssertTrue(text.contains("TERMINAL_RESTORED"), "\(mode): \(text)")
        XCTAssertFalse(text.contains(Self.inputMarker), "\(mode): input was echoed.")
        if mode != "timeout" { XCTAssertTrue(sentInput, mode) }
    }
}
