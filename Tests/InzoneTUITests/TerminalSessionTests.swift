import Foundation
import Glibc
import Testing
import SwiftTUI

struct TerminalSessionTests {
    private func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func screen(_ data: Data, columns: Int = 80, rows: Int = 24) -> String {
        let scalars = Array(String(decoding: data, as: UTF8.self).unicodeScalars)
        var cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
        var row = 0, column = 0, index = 0
        var widths: [Unicode.Scalar: Int] = [:]
        // SwiftTUI updates changed cells in place, so stripping ANSI would lose unchanged text.
        while index < scalars.count {
            let scalar = scalars[index]
            index += 1
            if scalar.value == 27 {
                guard index < scalars.count else { break }
                let kind = scalars[index]
                index += 1
                if kind == "[" {
                    let start = index
                    while index < scalars.count && !(0x40...0x7e).contains(scalars[index].value) { index += 1 }
                    guard index < scalars.count else { break }
                    let parameters = String(String.UnicodeScalarView(scalars[start..<index]))
                    let command = scalars[index]
                    index += 1
                    let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                    switch command {
                    case "H", "f":
                        row = min(rows - 1, max(0, (values.first ?? 1) - 1))
                        column = min(columns - 1, max(0, (values.count > 1 ? values[1] : 1) - 1))
                    case "J" where values.first == 2:
                        cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
                    case "K":
                        for position in column..<columns { cells[row][position] = " " }
                    case "h" where parameters == "?1049":
                        cells = Array(repeating: Array(repeating: " ", count: columns), count: rows)
                        row = 0; column = 0
                    default: break
                    }
                } else if kind == "]" {
                    while index < scalars.count {
                        if scalars[index].value == 7 { index += 1; break }
                        if scalars[index].value == 27, index + 1 < scalars.count, scalars[index + 1] == "\\" {
                            index += 2; break
                        }
                        index += 1
                    }
                }
                continue
            }
            if scalar == "\r" { column = 0; continue }
            if scalar == "\n" { row = min(rows - 1, row + 1); continue }
            if scalar.value < 32 || scalar.value == 127 { continue }
            let width = widths[scalar] ?? RunGroup(String(scalar)).measure().maximumContentColumns
            widths[scalar] = width
            if width == 0 {
                if column > 0 { cells[row][column - 1] += String(scalar) }
                continue
            }
            if column >= columns { column = 0; row = min(rows - 1, row + 1) }
            cells[row][column] = String(scalar)
            if width > 1 {
                for position in (column + 1)..<min(columns, column + width) { cells[row][position] = "" }
            }
            column += width
        }
        return cells.map { $0.joined() }.joined(separator: "\n")
    }

    @Test(.timeLimit(.minutes(1)), arguments: [80, 120])
    func interactiveMenusAcceptRealTerminalInputWithoutChangingSettings(columns: Int) throws {
        func screen(_ data: Data) -> String { self.screen(data, columns: columns) }
        let manager = FileManager.default
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let executable = URL(fileURLWithPath: ProcessInfo.processInfo.environment["INZONE_TEST_EXECUTABLE"]
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
                .appendingPathComponent("inzone-profile").path)
        try #require(manager.isExecutableFile(atPath: executable.path), "The inzone-profile executable must be built before the PTY test.")
        try #require(manager.isExecutableFile(atPath: "/usr/bin/script"), "The PTY test requires util-linux script.")
        let home = manager.temporaryDirectory.appendingPathComponent("inzone-terminal-\(UUID().uuidString)")
        try manager.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: home) }
        let config = home.appendingPathComponent(".config/inzone-h9-ii")
        let wireplumber = home.appendingPathComponent(".config/wireplumber/wireplumber.conf.d")
        let binaries = home.appendingPathComponent("bin")
        for directory in [config, wireplumber, binaries] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for name in ["fps", "music", "voice", "balanced", "original"] {
            try manager.copyItem(at: root.appendingPathComponent("configs/\(name).conf"),
                                 to: config.appendingPathComponent("\(name).conf"))
        }
        try manager.copyItem(at: config.appendingPathComponent("balanced.conf"),
                             to: config.appendingPathComponent("surround.conf"))
        let active = wireplumber.appendingPathComponent("51-inzone-h9-ii.conf")
        let original = try Data(contentsOf: config.appendingPathComponent("balanced.conf"))
        try original.write(to: active)
        let commands = home.appendingPathComponent("commands.log")
        let commandScript = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \(quoted(commands.path))\nexit 1\n"
        // The fixture blocks every external audio mutation even if a key is misrouted.
        for name in ["systemctl", "pactl", "pw-dump", "wpctl", "pw-loopback"] {
            let file = binaries.appendingPathComponent(name)
            try Data(commandScript.utf8).write(to: file)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let transcript = home.appendingPathComponent("terminal.log")
        _ = manager.createFile(atPath: transcript.path, contents: nil)
        let output = try FileHandle(forWritingTo: transcript)
        defer { try? output.close() }
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["--quiet", "--return", "--command",
            "/usr/bin/stty rows 24 cols \(columns); exec \(quoted(executable.path)) --tui", "/dev/null"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["PATH"] = binaries.path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["TERM"] = "xterm-256color"
        environment["LANG"] = "C.UTF-8"
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        defer {
            if process.isRunning {
                try? input.fileHandleForWriting.write(contentsOf: Data([3]))
                Thread.sleep(forTimeInterval: 0.3)
            }
            if process.isRunning { process.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }

        func waitFor(_ text: String, timeout: TimeInterval = 5) throws {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                let data = try Data(contentsOf: transcript)
                if screen(data).contains(text) { return }
                if !process.isRunning { break }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let contents = screen(try Data(contentsOf: transcript))
            Issue.record("Terminal did not display '\(text)'. Transcript: \(contents)")
            throw SessionFailure.missingScreen
        }

        func send(_ keys: String, expecting text: String) throws {
            try input.fileHandleForWriting.write(contentsOf: Data(keys.utf8))
            try waitFor(text)
            Thread.sleep(forTimeInterval: 0.25)
        }

        func location(of label: String, rowOffset: Int = 0) throws -> String {
            let lines = screen(try Data(contentsOf: transcript)).components(separatedBy: "\n")
            // Action labels occupy padded cells; boundaries exclude headings and longer labels.
            let pattern = "(?:(?<= {2})|(?<=^ ))" + NSRegularExpression.escapedPattern(for: label) + "(?= {2}|$)"
            let row = try #require(lines.firstIndex(where: { $0.range(of: pattern, options: .regularExpression) != nil }), "Missing click target: \(label)")
            let range = try #require(lines[row].range(of: pattern, options: .regularExpression))
            let column = RunGroup(String(lines[row][..<range.lowerBound])).measure().maximumContentColumns
            return "\(column + 1);\(row + 1 + rowOffset)"
        }

        func click(_ label: String, rowOffset: Int = 0, expecting text: String) throws {
            let location = try location(of: label, rowOffset: rowOffset)
            try send("\u{1b}[<0;\(location)M\u{1b}[<0;\(location)m", expecting: text)
        }

        try waitFor("INZONE H9 II", timeout: 10)
        Thread.sleep(forTimeInterval: 0.35)
        let initialScreen = screen(try Data(contentsOf: transcript))
        #expect(initialScreen.contains("Balanced"))
        #expect(!initialScreen.contains("4  Balanced"))
        #expect(!initialScreen.contains("Active"))
        #expect(!initialScreen.contains("ACTIVE PROFILE"))
        if columns >= 110 {
            try click("Automation", expecting: "Auto Profiles / Stopped")
            try click("Profiles", expecting: "INZONE H9 II / Profiles")
        }
        try click("Restore Defaults", expecting: "Restores saved tone")
        try click("Controls", expecting: "Changes apply immediately to Restore Defaults.")
        try click("Equalizer", expecting: "Changes apply immediately to Restore Defaults.")
        #expect(!screen(try Data(contentsOf: transcript)).contains("10-band EQ"))
        try click("Back", expecting: "INZONE H9 II / Profiles")
        try click("Music", expecting: "Original sound. Stability first.")
        let voiceLocation = try location(of: "Voice")
        try send("\u{1b}[<0;\(voiceLocation)M", expecting: "Original sound. Stability first.")
        #expect(!screen(try Data(contentsOf: transcript)).contains("Clearer voices."))
        try send("\u{1b}[<32;1;1M\u{1b}[<0;1;1m", expecting: "Original sound. Stability first.")
        #expect(!screen(try Data(contentsOf: transcript)).contains("Clearer voices."))
        try click("Voice", expecting: "Clearer voices. Less microphone rumble.")
        try click("Music", expecting: "Original sound. Stability first.")
        try send("\u{1b}[<65;3;5M", expecting: "Clearer voices. Less microphone rumble.")
        try send("\u{1b}[<64;3;5M", expecting: "Original sound. Stability first.")
        try click("Controls", rowOffset: 1, expecting: "Changes apply immediately to Music.")
        try click("Equalizer", rowOffset: -1, expecting: "10-band EQ / Music")
        try click("16k", expecting: "16k Hz")
        try click("31.5", expecting: "31.5 Hz")
        try click("+ 1 dB", rowOffset: 1, expecting: "+1.0 dB")
        try click("›", rowOffset: -1, expecting: "63 Hz")
        try click("‹", rowOffset: 1, expecting: "31.5 Hz")
        try click("Reset all", expecting: "+0.0 dB")
        try click("Cancel", rowOffset: -1, expecting: "INZONE H9 II / Profiles")
        try click("Controls", expecting: "Changes apply immediately to Music.")
        try click("Device & apps", expecting: "Personal HRTF import")
        try click("Manage sound profiles", expecting: "Sound Profile Collection")
        try click("Back", expecting: "INZONE H9 II / Profiles")
        try click("Controls", expecting: "Changes apply immediately to Music.")
        try click("Device & apps", expecting: "Manage sound profiles")
        try click("Automation", expecting: "Auto Profiles / Stopped")
        try click("Add rule", rowOffset: 1, expecting: "Executable name/path")
        try click("Cancel", rowOffset: -1, expecting: "Auto Profiles / Stopped")
        try click("Back", expecting: "INZONE H9 II / Profiles")
        try click("Compact", expecting: "Touch layout")
        try click("Voice", expecting: "Clearer voices. Less microphone rumble.")
        try click("Music", expecting: "Original sound. Stability first.")
        try send("\u{1b}[<65;3;5M", expecting: "Clearer voices. Less microphone rumble.")
        try send("\u{1b}[<64;3;5M", expecting: "Original sound. Stability first.")
        try click("E: EQ", expecting: "10-band EQ / Music")
        try click("+", expecting: "+1.0 dB")
        try click("Reset", expecting: "+0.0 dB")
        try click("Cancel", expecting: "INZONE H9 II")
        try click("U: Automation", expecting: "Auto Profiles")
        try click("A: Add/Edit", expecting: "Executable name/path")
        try click("Cancel", expecting: "Auto Profiles")
        try click("Back", expecting: "INZONE H9 II")
        try send("S", expecting: "Sony EQ Presets")
        try send("\u{1b}", expecting: "INZONE H9 II")
        try send("E", expecting: "10-band EQ")
        try send("\u{1b}", expecting: "INZONE H9 II")
        try send("U", expecting: "Auto Profiles")
        try send("\u{1b}", expecting: "INZONE H9 II")
        try send("I", expecting: "personalized HKI")
        try send("\r", expecting: "INZONE H9 II")
        try input.fileHandleForWriting.write(contentsOf: Data("Q".utf8))
        let exitDeadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < exitDeadline { Thread.sleep(forTimeInterval: 0.02) }
        try #require(!process.isRunning, "Uppercase Q must terminate the terminal application.")
        #expect(process.terminationStatus == 0)
        let raw = try String(contentsOf: transcript, encoding: .utf8)
        #expect(raw.contains("\u{1b}[?1003h"))
        #expect(raw.contains("\u{1b}[?1006h"))
        #expect(raw.contains("\u{1b}[?1003l"))
        #expect(raw.contains("\u{1b}[?1006l"))
        #expect(try Data(contentsOf: active) == original)
        #expect(!manager.fileExists(atPath: config.appendingPathComponent("profile-settings.json").path))
        #expect(!manager.fileExists(atPath: config.appendingPathComponent("auto-profiles.json").path))
        #expect(!manager.fileExists(atPath: config.appendingPathComponent("personal").path))
        if let recorded = try? String(contentsOf: commands, encoding: .utf8) {
            #expect(recorded.split(separator: "\n").allSatisfy {
                $0 == "--user is-active --quiet inzone-profile-auto.service"
            })
        }
    }

    private enum SessionFailure: Error { case missingScreen }
}
