import CInzoneDBus
import Dispatch
import Foundation
import QtBridge

private struct DesktopRequest: Sendable {
    let method: String
    let first: String
    let second: String
    let value: Int32
}

private struct DesktopReply: Sendable {
    let method: String
    let state: String?
    let error: String?
}

private final class DesktopWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.zeroday0619.desktop.requests")
    private let lock = NSLock()
    private var replies: [DesktopReply] = []

    func submit(_ request: DesktopRequest) {
        queue.async { [self] in
            var response: UnsafeMutablePointer<CChar>?
            var errorMessage: UnsafeMutablePointer<CChar>?
            let status = inzone_dbus_call(
                request.method, request.first, request.second, request.value,
                &response, &errorMessage
            )
            defer {
                if let response { inzone_dbus_free(response) }
                if let errorMessage { inzone_dbus_free(errorMessage) }
            }
            let result: DesktopReply
            if status >= 0, let response {
                result = DesktopReply(method: request.method, state: String(cString: response), error: nil)
            } else {
                result = DesktopReply(
                    method: request.method, state: nil,
                    error: errorMessage.map { String(cString: $0) } ?? "The INZONE service did not return a response."
                )
            }
            lock.lock()
            replies.append(result)
            lock.unlock()
        }
    }

    func takeReply() -> DesktopReply? {
        lock.lock()
        defer { lock.unlock() }
        return replies.isEmpty ? nil : replies.removeFirst()
    }
}

@MainActor
@QtBridgeable
public final class GuiModel {
    public var stateJSON: String = "{}"
    public var busy: Bool = false
    public var refreshing: Bool = false
    public var connected: Bool = false
    public var errorMessage: String = ""
    public var notice: String = ""

    private let worker = DesktopWorker()
    private var connectionError = false

    public init() {}

    public func refresh() {
        guard !busy, !refreshing else { return }
        submit(method: "GetState", first: "", second: "", value: 0)
    }

    public func invoke(method: String, first: String, second: String, value: Int) {
        guard !busy else { return }
        guard let number = Int32(exactly: value) else {
            errorMessage = "The requested value is outside the supported range."
            return
        }
        let methods: Set<String> = [
            "ActivateProfile", "SetProfileOptions", "SetDeviceField", "SetHostField",
            "CreateProfile", "RenameProfile", "DeleteProfile", "ApplyPreset",
            "BindApplication", "RemoveApplication", "SetAutomationEnabled",
        ]
        guard methods.contains(method) else {
            errorMessage = "The requested operation is not supported."
            return
        }
        errorMessage = ""
        notice = ""
        connectionError = false
        submit(method: method, first: first, second: second, value: number)
    }

    public func dismissMessage() {
        errorMessage = ""
        notice = ""
    }

    public func poll() {
        // Qt owns the Linux main loop, so QML invokes this method on the UI thread.
        guard let reply = worker.takeReply() else { return }
        defer {
            if reply.method == "GetState" {
                refreshing = false
            } else {
                busy = false
                if reply.error != nil { refresh() }
            }
        }
        if let error = reply.error {
            errorMessage = error
            if reply.method == "GetState" {
                connected = false
                connectionError = true
            }
            return
        }
        guard let state = reply.state, let data = state.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] as? Int == 1 else {
            errorMessage = "The INZONE service returned an unsupported state response."
            connected = false
            connectionError = true
            return
        }
        stateJSON = state
        connected = true
        if connectionError {
            errorMessage = ""
            connectionError = false
        }
        if reply.method != "GetState" {
            notice = "Changes applied."
        }
    }

    private func submit(method: String, first: String, second: String, value: Int32) {
        if method == "GetState" {
            refreshing = true
        } else {
            busy = true
        }
        worker.submit(DesktopRequest(method: method, first: first, second: second, value: value))
    }
}
