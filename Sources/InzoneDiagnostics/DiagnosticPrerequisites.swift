import Foundation
import InzoneCore

public enum DiagnosticPrerequisites {
    public static func requirePrograms(_ names: [String]) throws {
        let directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false)
        for name in names {
            let available = directories.contains { directory in
                FileManager.default.isExecutableFile(atPath: URL(fileURLWithPath: String(directory))
                    .appendingPathComponent(name).path)
            }
            guard available else { throw InzoneError.message("Diagnostic command is unavailable: \(name).") }
        }
    }
}
