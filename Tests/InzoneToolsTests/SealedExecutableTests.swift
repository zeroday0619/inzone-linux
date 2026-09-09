import Foundation
import Glibc
import XCTest
@testable import InzoneToolsCore

final class SealedFileTests: XCTestCase {
    func testDataSnapshotIsRegularSealedAndBounded() throws {
        let data = Data("sealed plugin fixture\n".utf8)
        let snapshot = try SealedFile.snapshot(data: data, name: "plugin-snapshot")

        XCTAssertEqual(
            try SealedFile.readAndValidateSealedProcFD(path: snapshot.procFDPath, maximumSize: data.count),
            data
        )
        let seals = try SealedFile.seals(at: snapshot.procFDPath)
        XCTAssertEqual(seals & SealedFile.requiredSealMask, SealedFile.requiredSealMask)

        var status = stat()
        XCTAssertEqual(Glibc.fstat(snapshot.fileDescriptor, &status), 0)
        XCTAssertEqual(status.st_mode & S_IFMT, S_IFREG)
        XCTAssertEqual(status.st_size, off_t(data.count))
        XCTAssertEqual(status.st_mode & mode_t(0o111), 0)
    }

    func testDataSnapshotCannotBeModified() throws {
        let data = Data("immutable rule fixture\n".utf8)
        let snapshot = try SealedFile.snapshot(data: data, name: "rule-snapshot")
        var replacement: UInt8 = 0

        errno = 0
        XCTAssertEqual(Glibc.pwrite(snapshot.fileDescriptor, &replacement, 1, 0), -1)
        XCTAssertEqual(errno, EPERM)
        errno = 0
        XCTAssertEqual(Glibc.ftruncate(snapshot.fileDescriptor, 0), -1)
        XCTAssertEqual(errno, EPERM)
        XCTAssertEqual(
            try SealedFile.readAndValidateSealedProcFD(path: snapshot.procFDPath, maximumSize: data.count),
            data
        )
    }

    func testSealedReaderRejectsInvalidPathsAndBounds() throws {
        let data = Data("bounded fixture".utf8)
        let snapshot = try SealedFile.snapshot(data: data, name: "bounded-snapshot")

        for path in [
            "/proc/self/fd/3", "/proc/0/fd/3", "/proc/01/fd/3", "/proc/1/fd/03",
            "/proc/1/fd/3/", "/tmp/3",
        ] {
            XCTAssertThrowsError(try SealedFile.readAndValidateSealedProcFD(path: path, maximumSize: data.count))
        }
        XCTAssertThrowsError(
            try SealedFile.readAndValidateSealedProcFD(path: snapshot.procFDPath, maximumSize: data.count - 1)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("size limit"), error.localizedDescription)
        }
    }

    func testSealedReaderRejectsUnsealedRegularFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("unsealed".utf8).write(to: file)
        let descriptor = Glibc.open(file.path, O_RDONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { _ = Glibc.close(descriptor) }

        XCTAssertThrowsError(
            try SealedFile.readAndValidateSealedProcFD(
                path: "/proc/\(Glibc.getpid())/fd/\(descriptor)", maximumSize: 1024
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("required memory-file seals"), error.localizedDescription)
        }
    }
}

final class SealedExecutableTests: XCTestCase {
    func testSnapshotMatchesCurrentExecutableAndHasRequiredSeals() throws {
        let expected = try Data(contentsOf: URL(fileURLWithPath: "/proc/self/exe"))
        let snapshot = try SealedExecutable.snapshotCurrentProcess()

        XCTAssertEqual(snapshot.procFDPath, "/proc/\(Glibc.getpid())/fd/\(snapshot.fileDescriptor)")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: snapshot.procFDPath)), expected)
        let seals = try SealedExecutable.seals(at: snapshot.procFDPath)
        XCTAssertEqual(seals & SealedExecutable.requiredSealMask, SealedExecutable.requiredSealMask)
        XCTAssertNoThrow(try SealedExecutable.requireSealedExecutable(at: snapshot.procFDPath))

        var status = stat()
        XCTAssertEqual(Glibc.fstat(snapshot.fileDescriptor, &status), 0)
        XCTAssertNotEqual(status.st_mode & mode_t(0o111), 0)
    }

    func testSnapshotContentCannotBeModified() throws {
        let snapshot = try SealedExecutable.snapshotCurrentProcess()
        let original = try Data(contentsOf: URL(fileURLWithPath: snapshot.procFDPath))
        var replacement: UInt8 = 0

        errno = 0
        XCTAssertEqual(Glibc.pwrite(snapshot.fileDescriptor, &replacement, 1, 0), -1)
        XCTAssertEqual(errno, EPERM)
        errno = 0
        XCTAssertEqual(Glibc.ftruncate(snapshot.fileDescriptor, 0), -1)
        XCTAssertEqual(errno, EPERM)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: snapshot.procFDPath)), original)
    }

    func testSnapshotOwnsProcFDLifetime() throws {
        var snapshot: SealedExecutable? = try SealedExecutable.snapshotCurrentProcess()
        let path = try XCTUnwrap(snapshot?.procFDPath)

        XCTAssertEqual(Glibc.access(path, F_OK), 0)
        snapshot = nil
        XCTAssertEqual(Glibc.access(path, F_OK), -1)
        XCTAssertEqual(errno, ENOENT)
    }

    func testCurrentOnDiskExecutableIsRejected() {
        XCTAssertThrowsError(try SealedExecutable.requireCurrentProcessSealed()) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The live system installer must run from an immutable sealed memfd. Run: make install."
            )
        }
    }
}
