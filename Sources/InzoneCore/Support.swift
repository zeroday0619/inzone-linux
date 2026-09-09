import Foundation
import Glibc

@_silgen_name("renameat2")
private func atomicFileRenameAt2(
    _ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>,
    _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32
) -> Int32

public enum InzoneError: Error, LocalizedError, Sendable {
    case message(String)

    public var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

public struct InzonePaths: Sendable {
    public let home: URL
    public var configDirectory: URL { home.appendingPathComponent(".config/inzone-h9-ii") }
    public var activeProfile: URL {
        home.appendingPathComponent(".config/wireplumber/wireplumber.conf.d/51-inzone-h9-ii.conf")
    }
    public var shareDirectory: URL { home.appendingPathComponent(".local/share/inzone-linux") }
    public var assetsDirectory: URL { shareDirectory.appendingPathComponent("assets") }
    public var pluginURL: URL { home.appendingPathComponent(".local/lib/ladspa/inzone_dsp.so") }

    public init(home: URL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"]
        ?? FileManager.default.homeDirectoryForCurrentUser.path)) {
        self.home = home.standardizedFileURL
    }
}

public enum JSONSupport {
    public static func decode(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func encode(_ value: Any, pretty: Bool = true) throws -> String {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        let data = try JSONSerialization.data(withJSONObject: value, options: options)
        guard let text = String(data: data, encoding: .utf8) else {
            throw InzoneError.message("JSON output is not UTF-8.")
        }
        return text
    }
}

public enum TerminalOutput {
    public static func escaped(_ text: String, preservingNewlines: Bool = false) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if preservingNewlines, value == 0x0A {
                result.unicodeScalars.append(scalar)
                continue
            }
            let category = scalar.properties.generalCategory
            let unsafe = value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .surrogate
            if unsafe {
                let digits = String(value, radix: 16, uppercase: true)
                result += "\\u{" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits + "}"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

public enum AtomicFile {
    public final class StagedFile {
        public let fileHandle: FileHandle
        let temporaryURL: URL

        private let directoryDescriptor: Int32
        private let closesDirectoryDescriptor: Bool
        private let destinationName: String
        private let temporaryName: String
        private let permissions: Int
        private let replacing: Bool
        private var published = false

        fileprivate init(
            directoryDescriptor: Int32, closesDirectoryDescriptor: Bool,
            destinationName: String, directoryURL: URL?, permissions: Int, replacing: Bool
        ) throws {
            try AtomicFile.validate(name: destinationName, permissions: permissions)
            let stagedName = ".\(destinationName).\(UUID().uuidString)"
            let descriptor = Glibc.openat(
                directoryDescriptor, stagedName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600)
            )
            guard descriptor >= 0 else {
                let error = AtomicFile.posixError("Create temporary file", path: destinationName)
                if closesDirectoryDescriptor { Glibc.close(directoryDescriptor) }
                throw error
            }

            self.destinationName = destinationName
            self.permissions = permissions
            self.replacing = replacing
            self.directoryDescriptor = directoryDescriptor
            self.closesDirectoryDescriptor = closesDirectoryDescriptor
            temporaryName = stagedName
            temporaryURL = (directoryURL ?? URL(fileURLWithPath: ".")).appendingPathComponent(stagedName)
            fileHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        deinit {
            _ = Glibc.unlinkat(directoryDescriptor, temporaryName, 0)
            if closesDirectoryDescriptor { Glibc.close(directoryDescriptor) }
        }

        public func publish() throws {
            guard !published else {
                throw InzoneError.message("Temporary file was already published as \(destinationName).")
            }
            let descriptor = fileHandle.fileDescriptor
            guard Glibc.fchmod(descriptor, mode_t(permissions)) == 0 else {
                throw AtomicFile.posixError("Set temporary file permissions", path: destinationName)
            }
            guard Glibc.fsync(descriptor) == 0 else {
                throw AtomicFile.posixError("Synchronize temporary file", path: destinationName)
            }
            var descriptorStatus = stat()
            guard Glibc.fstat(descriptor, &descriptorStatus) == 0 else {
                throw AtomicFile.posixError("Inspect temporary file", path: destinationName)
            }
            let renameResult: Int32
            if replacing {
                renameResult = Glibc.renameat(
                    directoryDescriptor, temporaryName, directoryDescriptor, destinationName
                )
            } else {
                renameResult = temporaryName.withCString { temporaryPath in
                    destinationName.withCString { destinationPath in
                        atomicFileRenameAt2(
                            directoryDescriptor, temporaryPath,
                            directoryDescriptor, destinationPath, 1
                        )
                    }
                }
            }
            guard renameResult == 0 else {
                throw AtomicFile.posixError("Replace destination file", path: destinationName)
            }
            var destinationStatus = stat()
            guard Glibc.fstatat(
                directoryDescriptor, destinationName, &destinationStatus, AT_SYMLINK_NOFOLLOW
            ) == 0,
                  (destinationStatus.st_mode & S_IFMT) == S_IFREG,
                  destinationStatus.st_dev == descriptorStatus.st_dev,
                  destinationStatus.st_ino == descriptorStatus.st_ino else {
                _ = Glibc.unlinkat(directoryDescriptor, destinationName, 0)
                throw InzoneError.message("Published file identity changed for \(destinationName).")
            }
            published = true
            // The rename is already committed, so directory synchronization cannot be reported as a pre-commit failure.
            _ = AtomicFile.synchronizeDirectoryAfterCommit(directoryDescriptor)
        }

        public func publishAndTakeFileHandle() throws -> FileHandle {
            try publish()
            return fileHandle
        }
    }

    public static func stage(
        for destination: URL, permissions: Int = 0o600, replacing: Bool = true
    ) throws -> StagedFile {
        try validate(name: destination.lastPathComponent, permissions: permissions)
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let directoryDescriptor = Glibc.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else {
            throw posixError("Open destination directory", path: directory.path)
        }
        return try StagedFile(
            directoryDescriptor: directoryDescriptor, closesDirectoryDescriptor: true,
            destinationName: destination.lastPathComponent, directoryURL: directory,
            permissions: permissions, replacing: replacing
        )
    }

    public static func write(
        _ data: Data, to destination: URL,
        permissions: Int = 0o600, replacing: Bool = true
    ) throws {
        let stagedFile = try stage(for: destination, permissions: permissions, replacing: replacing)
        try stagedFile.fileHandle.write(contentsOf: data)
        try stagedFile.publish()
    }

    public static func write(
        _ data: Data, inDirectoryDescriptor directoryDescriptor: Int32,
        name: String, permissions: Int = 0o600, replacing: Bool = true
    ) throws {
        let stagedFile = try StagedFile(
            directoryDescriptor: directoryDescriptor, closesDirectoryDescriptor: false,
            destinationName: name, directoryURL: nil,
            permissions: permissions, replacing: replacing
        )
        try stagedFile.fileHandle.write(contentsOf: data)
        try stagedFile.publish()
    }

    @discardableResult
    static func synchronizeDirectoryAfterCommit(
        _ descriptor: Int32, synchronizer: (Int32) -> Int32 = { Glibc.fsync($0) }
    ) -> Bool {
        while synchronizer(descriptor) != 0 {
            guard errno == EINTR else { return false }
        }
        return true
    }

    private static func posixError(_ operation: String, path: String) -> InzoneError {
        .message("\(operation) for \(path): \(String(cString: strerror(errno))).")
    }

    private static func validate(name: String, permissions: Int) throws {
        guard (0...0o7777).contains(permissions) else {
            throw InzoneError.message("Invalid file permissions for \(name).")
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw InzoneError.message("Invalid destination filename: \(name).")
        }
    }
}

public final class FileLock {
    private let descriptor: Int32

    public init(url: URL, nonblocking: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        descriptor = Glibc.open(url.path, O_WRONLY | O_CREAT | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else {
            throw InzoneError.message("Cannot open lock \(url.path): \(String(cString: strerror(errno))).")
        }
        guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
            let reason = String(cString: strerror(errno))
            Glibc.close(descriptor)
            throw InzoneError.message("Another operation holds \(url.lastPathComponent): \(reason).")
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        Glibc.close(descriptor)
    }
}

public struct CommandError: Error, LocalizedError, Sendable {
    public let arguments: [String]
    public let status: Int32
    public let output: String
    public let timedOut: Bool

    public init(arguments: [String], status: Int32, output: String, timedOut: Bool = false) {
        self.arguments = arguments
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }

    public var errorDescription: String? {
        let reason = timedOut ? "timed out" : "exited with status \(status)"
        let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(arguments.first ?? "Command") \(reason)." + (detail.isEmpty ? "" : " \(detail)")
    }
}

public protocol CommandRunning: Sendable {
    func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String
}

extension CommandRunning {
    public func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 15) throws -> String {
        try run(arguments, input: input, timeout: timeout)
    }
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 15) throws -> String {
        guard let command = arguments.first, !command.isEmpty, timeout > 0 else {
            throw InzoneError.message("A command and positive timeout are required.")
        }
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("inzone-command-\(UUID().uuidString)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("output")
        let errorURL = directory.appendingPathComponent("error")
        let inputURL = directory.appendingPathComponent("input")
        try (input ?? Data()).write(to: inputURL)
        guard manager.createFile(atPath: outputURL.path, contents: nil),
              manager.createFile(atPath: errorURL.path, contents: nil) else {
            throw InzoneError.message("Cannot prepare command output.")
        }
        let outputFile = try FileHandle(forWritingTo: outputURL)
        let errorFile = try FileHandle(forWritingTo: errorURL)
        let inputFile = try FileHandle(forReadingFrom: inputURL)
        defer { try? outputFile.close(); try? errorFile.close(); try? inputFile.close() }
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = Array(arguments.dropFirst())
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
        }
        process.standardInput = inputFile
        process.standardOutput = outputFile
        // Successful JSON commands may emit diagnostics that are not part of their response.
        process.standardError = errorFile
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
        let output = String(decoding: try Data(contentsOf: outputURL), as: UTF8.self)
        guard !timedOut && process.terminationStatus == 0 else {
            let diagnostics = String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
            throw CommandError(arguments: arguments, status: process.terminationStatus,
                               output: output + diagnostics, timedOut: timedOut)
        }
        return output
    }
}
