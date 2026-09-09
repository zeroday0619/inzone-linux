import Foundation
import Glibc
import InzoneCore

@_silgen_name("memfd_create")
private func systemMemfdCreate(_ name: UnsafePointer<CChar>, _ flags: UInt32) -> Int32

private enum SealedMemoryFileSupport {
    static let memoryFileCloseOnExec: UInt32 = 0x0001
    static let memoryFileAllowSealing: UInt32 = 0x0002
    static let memoryFileNoExecutableSeal: UInt32 = 0x0008
    static let memoryFileExecutable: UInt32 = 0x0010

    static let addSeals: Int32 = 1033
    static let getSeals: Int32 = 1034
    static let sealSeal: Int32 = 0x0001
    static let sealShrink: Int32 = 0x0002
    static let sealGrow: Int32 = 0x0004
    static let sealWrite: Int32 = 0x0008
    static let sealFutureWrite: Int32 = 0x0010
    static let sealExecutable: Int32 = 0x0020
    static let requiredSealMask = sealWrite | sealGrow | sealShrink | sealSeal
    static let modernMutableSealMask = sealWrite | sealGrow | sealShrink | sealFutureWrite
        | sealExecutable
    static let compatibleMutableSealMask = sealWrite | sealGrow | sealShrink

    static func create(name: String, flags: UInt32, compatibleFlags: UInt32?) throws -> Int32 {
        guard !name.isEmpty, !name.utf8.contains(0) else {
            throw InzoneError.message("A non-empty memory-file name without null bytes is required.")
        }

        var descriptor = name.withCString { systemMemfdCreate($0, flags) }
        if descriptor < 0 {
            let creationError = errno
            if creationError == EINVAL, let compatibleFlags {
                descriptor = name.withCString { systemMemfdCreate($0, compatibleFlags) }
            } else {
                throw posixError("Cannot create the sealed memory file", code: creationError)
            }
        }
        guard descriptor >= 0 else {
            throw posixError("Cannot create the sealed memory file")
        }
        return descriptor
    }

    static func write(_ data: Data, to descriptor: Int32, description: String) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Glibc.write(
                    descriptor, baseAddress.advanced(by: offset), bytes.count - offset
                )
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError("Cannot write \(description)")
                }
                guard written > 0 else {
                    throw InzoneError.message("Cannot write \(description): no data was written.")
                }
                offset += written
            }
        }
    }

    static func copy(sourceDescriptor: Int32, destinationDescriptor: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = Glibc.read(sourceDescriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("Cannot read the current executable snapshot")
            }
            if count == 0 { return }

            try buffer.withUnsafeBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return }
                var offset = 0
                while offset < count {
                    let written = Glibc.write(
                        destinationDescriptor, baseAddress.advanced(by: offset), count - offset
                    )
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw posixError("Cannot write the executable memory-file snapshot")
                    }
                    guard written > 0 else {
                        throw InzoneError.message(
                            "Cannot write the executable memory-file snapshot: no data was written."
                        )
                    }
                    offset += written
                }
            }
        }
    }

    @discardableResult
    static func requireRegularFile(
        descriptor: Int32, description: String, maximumSize: Int? = nil, expectedSize: off_t? = nil
    ) throws -> stat {
        var status = stat()
        guard Glibc.fstat(descriptor, &status) == 0 else {
            throw posixError("Cannot inspect \(description)")
        }
        guard (status.st_mode & S_IFMT) == S_IFREG, status.st_size >= 0 else {
            throw InzoneError.message("\(description) is not a regular file with a valid size.")
        }
        if let maximumSize {
            guard maximumSize >= 0, status.st_size <= off_t(maximumSize) else {
                throw InzoneError.message("\(description) exceeds its size limit.")
            }
        }
        if let expectedSize, status.st_size != expectedSize {
            throw InzoneError.message("\(description) does not have the expected size.")
        }
        return status
    }

    static func addRequiredSeals(to descriptor: Int32, description: String) throws {
        if Glibc.fcntl(descriptor, addSeals, modernMutableSealMask) != 0 {
            let modernSealError = errno
            guard modernSealError == EINVAL else {
                throw posixError("Cannot seal \(description)", code: modernSealError)
            }
            guard Glibc.fcntl(descriptor, addSeals, compatibleMutableSealMask) == 0 else {
                throw posixError("Cannot seal \(description)")
            }
        }
        guard Glibc.fcntl(descriptor, addSeals, sealSeal) == 0 else {
            throw posixError("Cannot finalize seals for \(description)")
        }
        try requireSeals(on: descriptor, description: description)
    }

    static func requireSeals(on descriptor: Int32, description: String) throws {
        let seals = Glibc.fcntl(descriptor, getSeals)
        guard seals >= 0 else {
            throw posixError("\(description) does not expose the required memory-file seals")
        }
        let missing = requiredSealMask & ~seals
        guard missing == 0 else {
            throw InzoneError.message(
                "\(description) is missing the required memory-file seals "
                    + "(mask 0x\(String(missing, radix: 16)))."
            )
        }
    }

    static func seals(at path: String) throws -> Int32 {
        let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError("Cannot open the file for seal inspection", path: path)
        }
        defer { _ = Glibc.close(descriptor) }

        let seals = Glibc.fcntl(descriptor, getSeals)
        guard seals >= 0 else {
            throw posixError("Cannot inspect memory-file seals", path: path)
        }
        return seals
    }

    static func read(descriptor: Int32, size: Int, description: String) throws -> Data {
        var result = Data()
        result.reserveCapacity(size)
        var buffer = [UInt8](repeating: 0, count: min(128 * 1024, max(1, size)))
        while true {
            let count = Glibc.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError("Cannot read \(description)")
            }
            if count == 0 { break }
            guard result.count <= size - count else {
                throw InzoneError.message("\(description) changed while it was read.")
            }
            result.append(contentsOf: buffer.prefix(count))
        }
        guard result.count == size else {
            throw InzoneError.message("\(description) changed while it was read.")
        }
        return result
    }

    static func isCanonicalProcFDPath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 5, components[0].isEmpty, components[1] == "proc",
              components[3] == "fd" else { return false }
        return isCanonicalDecimal(components[2], permitsZero: false)
            && isCanonicalDecimal(components[4], permitsZero: true)
    }

    private static func isCanonicalDecimal(_ value: Substring, permitsZero: Bool) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        if value == "0" { return permitsZero }
        return value.first != "0"
    }

    static func posixError(
        _ operation: String, path: String? = nil, code: Int32 = errno
    ) -> InzoneError {
        let reason = String(cString: Glibc.strerror(code))
        let target = path.map { " at \($0)" } ?? ""
        return InzoneError.message("\(operation)\(target): \(reason).")
    }
}

public final class SealedFile: @unchecked Sendable {
    static let requiredSealMask = SealedMemoryFileSupport.requiredSealMask

    public let procFDPath: String
    let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        procFDPath = "/proc/\(Glibc.getpid())/fd/\(fileDescriptor)"
    }

    deinit {
        _ = Glibc.close(fileDescriptor)
    }

    public static func snapshot(data: Data, name: String) throws -> SealedFile {
        let modernFlags = SealedMemoryFileSupport.memoryFileCloseOnExec
            | SealedMemoryFileSupport.memoryFileAllowSealing
            | SealedMemoryFileSupport.memoryFileNoExecutableSeal
        let compatibleFlags = SealedMemoryFileSupport.memoryFileCloseOnExec
            | SealedMemoryFileSupport.memoryFileAllowSealing
        let descriptor = try SealedMemoryFileSupport.create(
            name: name, flags: modernFlags, compatibleFlags: compatibleFlags
        )

        do {
            try SealedMemoryFileSupport.write(data, to: descriptor, description: "the data snapshot")
            guard Glibc.fchmod(descriptor, mode_t(0o400)) == 0 else {
                throw SealedMemoryFileSupport.posixError("Cannot set data snapshot permissions")
            }
            try SealedMemoryFileSupport.requireRegularFile(
                descriptor: descriptor, description: "The data snapshot", expectedSize: off_t(data.count)
            )
            try SealedMemoryFileSupport.addRequiredSeals(
                to: descriptor, description: "the data snapshot"
            )
        } catch {
            _ = Glibc.close(descriptor)
            throw error
        }

        return SealedFile(fileDescriptor: descriptor)
    }

    public static func readAndValidateSealedProcFD(path: String, maximumSize: Int) throws -> Data {
        guard maximumSize >= 0 else {
            throw InzoneError.message("A non-negative sealed file size limit is required.")
        }
        guard SealedMemoryFileSupport.isCanonicalProcFDPath(path) else {
            throw InzoneError.message("The sealed file path must use /proc/<pid>/fd/<fd>.")
        }

        let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SealedMemoryFileSupport.posixError("Cannot open the sealed file", path: path)
        }
        defer { _ = Glibc.close(descriptor) }

        let status = try SealedMemoryFileSupport.requireRegularFile(
            descriptor: descriptor, description: "The sealed file", maximumSize: maximumSize
        )
        try SealedMemoryFileSupport.requireSeals(on: descriptor, description: "The sealed file")
        return try SealedMemoryFileSupport.read(
            descriptor: descriptor, size: Int(status.st_size), description: "the sealed file"
        )
    }

    static func seals(at path: String) throws -> Int32 {
        try SealedMemoryFileSupport.seals(at: path)
    }
}

public final class SealedExecutable: @unchecked Sendable {
    static let requiredSealMask = SealedMemoryFileSupport.requiredSealMask

    public let procFDPath: String
    let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
        procFDPath = "/proc/\(Glibc.getpid())/fd/\(fileDescriptor)"
    }

    deinit {
        _ = Glibc.close(fileDescriptor)
    }

    public static func snapshotCurrentProcess() throws -> SealedExecutable {
        let sourcePath = "/proc/self/exe"
        let sourceDescriptor = Glibc.open(sourcePath, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw SealedMemoryFileSupport.posixError(
                "Cannot open the current executable snapshot", path: sourcePath
            )
        }
        defer { _ = Glibc.close(sourceDescriptor) }
        let sourceStatus = try SealedMemoryFileSupport.requireRegularFile(
            descriptor: sourceDescriptor, description: "The current executable"
        )

        let modernFlags = SealedMemoryFileSupport.memoryFileCloseOnExec
            | SealedMemoryFileSupport.memoryFileAllowSealing
            | SealedMemoryFileSupport.memoryFileExecutable
        let compatibleFlags = SealedMemoryFileSupport.memoryFileCloseOnExec
            | SealedMemoryFileSupport.memoryFileAllowSealing
        let memoryDescriptor = try SealedMemoryFileSupport.create(
            name: "inzone-tools-sealed", flags: modernFlags, compatibleFlags: compatibleFlags
        )

        do {
            try SealedMemoryFileSupport.copy(
                sourceDescriptor: sourceDescriptor, destinationDescriptor: memoryDescriptor
            )
            guard Glibc.fchmod(memoryDescriptor, mode_t(0o500)) == 0 else {
                throw SealedMemoryFileSupport.posixError(
                    "Cannot make the sealed executable snapshot executable"
                )
            }
            try SealedMemoryFileSupport.requireRegularFile(
                descriptor: memoryDescriptor, description: "The executable snapshot",
                expectedSize: sourceStatus.st_size
            )
            try SealedMemoryFileSupport.addRequiredSeals(
                to: memoryDescriptor, description: "the executable snapshot"
            )
        } catch {
            _ = Glibc.close(memoryDescriptor)
            throw error
        }

        return SealedExecutable(fileDescriptor: memoryDescriptor)
    }

    public static func requireCurrentProcessSealed() throws {
        do {
            try requireSealedExecutable(at: "/proc/self/exe")
        } catch {
            throw InzoneError.message(
                "The live system installer must run from an immutable sealed memfd. Run: make install."
            )
        }
    }

    static func requireSealedExecutable(at path: String) throws {
        let descriptor = Glibc.open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw SealedMemoryFileSupport.posixError(
                "Cannot open the executable for seal verification", path: path
            )
        }
        defer { _ = Glibc.close(descriptor) }
        try SealedMemoryFileSupport.requireRegularFile(
            descriptor: descriptor, description: "The executable at \(path)"
        )
        try SealedMemoryFileSupport.requireSeals(
            on: descriptor, description: "The executable at \(path)"
        )
    }

    static func seals(at path: String) throws -> Int32 {
        try SealedMemoryFileSupport.seals(at: path)
    }
}
