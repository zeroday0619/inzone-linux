import CInzoneDBus
import Foundation
import Glibc
import InzoneServiceCore

private func handleRequest(
    _ method: UnsafePointer<CChar>?, _ first: UnsafePointer<CChar>?, _ second: UnsafePointer<CChar>?,
    _ value: Int32, _ response: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?,
    _ errorMessage: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, _ context: UnsafeMutableRawPointer?
) -> Int32 {
    guard let method, let context else { return 1 }
    let dispatcher = Unmanaged<ControlDispatcher>.fromOpaque(context).takeUnretainedValue()
    do {
        let result = try dispatcher.handle(
            method: String(cString: method), first: first.map { String(cString: $0) } ?? "",
            second: second.map { String(cString: $0) } ?? "", value: Int(value)
        )
        response?.pointee = strdup(result)
        return response?.pointee == nil ? 2 : 0
    } catch {
        errorMessage?.pointee = strdup(error.localizedDescription)
        return error is ControlRequestError ? 1 : 2
    }
}

@main
struct InzoneControlService {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] {
            print("Usage: inzone-service [--offline]\nServe INZONE controls on the session D-Bus.\n--offline disables hardware and audio operations for isolated diagnostics.")
            return
        }
        guard arguments.isEmpty || arguments == ["--offline"] else {
            FileHandle.standardError.write(Data("Usage: inzone-service [--offline]\n".utf8))
            exit(2)
        }
        let dispatcher = ControlDispatcher(backend: LiveControlBackend(offline: arguments == ["--offline"]))
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = withExtendedLifetime(dispatcher) {
            inzone_dbus_serve(handleRequest, Unmanaged.passUnretained(dispatcher).toOpaque(), &errorMessage)
        }
        defer { inzone_dbus_free(errorMessage) }
        if result < 0 {
            let message = errorMessage.map { String(cString: $0) } ?? "D-Bus service failed."
            FileHandle.standardError.write(Data((message + "\n").utf8))
            exit(1)
        }
    }
}
