import Foundation
import Glibc
import XCTest
@testable import InzoneCore

final class SupportTests: XCTestCase {
    func testCommandPreservesArgumentsAndInput() throws {
        let runner = SystemCommandRunner()
        let text = "A user's file\n$(exit 99)"
        XCTAssertEqual(try runner.run(["/usr/bin/printf", "%s", text]), text)
        XCTAssertEqual(try runner.run(["/bin/cat"], input: Data(text.utf8)), text)
    }

    func testCommandFailureAndTimeout() throws {
        XCTAssertThrowsError(try SystemCommandRunner().run(["/bin/sh", "-c", "printf failure >&2; exit 7"])) { error in
            guard let failure = error as? CommandError else { return XCTFail("Expected CommandError.") }
            XCTAssertEqual(failure.status, 7)
            XCTAssertEqual(failure.output, "failure")
            XCTAssertFalse(failure.timedOut)
        }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try SystemCommandRunner().run(["/bin/sleep", "10"], timeout: 0.05)) { error in
            XCTAssertTrue((error as? CommandError)?.timedOut == true)
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 2)
    }

    func testSuccessfulCommandDiagnosticsDoNotCorruptJSON() throws {
        let output = try SystemCommandRunner().run(["/bin/sh", "-c", "printf warning >&2; printf '[1,2]' "])
        XCTAssertEqual(try JSONSupport.decode(Data(output.utf8)) as? [Int], [1, 2])
    }

    func testAtomicReplacementAndPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/settings.json")
        try AtomicFile.write(Data("old".utf8), to: file)
        try AtomicFile.write(Data("new".utf8), to: file)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "new")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["settings.json"])
    }

    func testAtomicReplacementAnchorsSymlinkedParentAndReplacesLeafLink() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let actual = directory.appendingPathComponent("actual")
        let parent = directory.appendingPathComponent("parent")
        let sentinel = directory.appendingPathComponent("sentinel")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: actual)
        try FileManager.default.createSymbolicLink(
            at: actual.appendingPathComponent("settings.json"), withDestinationURL: sentinel
        )

        try AtomicFile.write(Data("replacement".utf8), to: parent.appendingPathComponent("settings.json"), permissions: 0o640)

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel")
        XCTAssertEqual(try String(contentsOf: actual.appendingPathComponent("settings.json"), encoding: .utf8), "replacement")
        let attributes = try FileManager.default.attributesOfItem(atPath: actual.appendingPathComponent("settings.json").path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    }

    func testStagedPublicationReplacesLeafLinkWithoutChangingItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("sentinel")
        let destination = directory.appendingPathComponent("result")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: sentinel)

        let stagedFile = try AtomicFile.stage(for: destination, permissions: 0o644)
        try stagedFile.fileHandle.write(contentsOf: Data("replacement".utf8))
        var stagedStatus = stat()
        XCTAssertEqual(Glibc.fstat(stagedFile.fileHandle.fileDescriptor, &stagedStatus), 0)
        try stagedFile.publish()

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "replacement")
        let sentinelAttributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        let destinationAttributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((sentinelAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(destinationAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((destinationAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
        var destinationStatus = stat()
        XCTAssertEqual(Glibc.lstat(destination.path, &destinationStatus), 0)
        XCTAssertEqual(destinationStatus.st_dev, stagedStatus.st_dev)
        XCTAssertEqual(destinationStatus.st_ino, stagedStatus.st_ino)
    }

    func testStagedPublicationRejectsReplacedTemporaryPath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("sentinel")
        let destination = directory.appendingPathComponent("result")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
        let stagedFile = try AtomicFile.stage(for: destination, permissions: 0o644)
        try stagedFile.fileHandle.write(contentsOf: Data("replacement".utf8))
        try FileManager.default.removeItem(at: stagedFile.temporaryURL)
        try FileManager.default.createSymbolicLink(at: stagedFile.temporaryURL, withDestinationURL: sentinel)

        XCTAssertThrowsError(try stagedFile.publish())

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel")
        let attributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAtomicNoReplaceRejectsExistingAndRacingDestinations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent("result")
        try AtomicFile.write(Data("existing".utf8), to: destination)
        XCTAssertThrowsError(try AtomicFile.write(
            Data("replacement".utf8), to: destination, replacing: false
        ))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "existing")

        try FileManager.default.removeItem(at: destination)
        let stagedFile = try AtomicFile.stage(for: destination, replacing: false)
        try stagedFile.fileHandle.write(contentsOf: Data("staged".utf8))
        try Data("racing".utf8).write(to: destination)
        XCTAssertThrowsError(try stagedFile.publish())
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "racing")
    }

    func testPostCommitDirectorySyncRetriesInterruptAndDoesNotThrowFailure() {
        var attempts = 0
        let synchronized = AtomicFile.synchronizeDirectoryAfterCommit(-1) { _ in
            attempts += 1
            errno = attempts == 1 ? EINTR : EIO
            return -1
        }
        XCTAssertFalse(synchronized)
        XCTAssertEqual(attempts, 2)
        XCTAssertTrue(AtomicFile.synchronizeDirectoryAfterCommit(-1) { _ in 0 })
    }

    func testTerminalOutputEscapesControlsAndPreservesOptionalNewlines() {
        let value = "\u{C815}\u{C0C1}\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\n\u{B05D}"
        XCTAssertEqual(
            TerminalOutput.escaped(value),
            "\u{C815}\u{C0C1}\\u{001B}\\u{007F}\\u{0085}\\u{202E}\\u{2028}\\u{2029}\\u{000A}\u{B05D}"
        )
        XCTAssertEqual(
            TerminalOutput.escaped(value, preservingNewlines: true),
            "\u{C815}\u{C0C1}\\u{001B}\\u{007F}\\u{0085}\\u{202E}\\u{2028}\\u{2029}\n\u{B05D}"
        )
    }
}
