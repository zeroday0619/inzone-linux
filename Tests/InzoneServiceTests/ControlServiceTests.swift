import CInzoneDBus
import Foundation
import InzoneCore
import InzoneServiceCore
import XCTest

private final class RecordingBackend: ControlBackend {
    var requests: [ControlRequest] = []
    var failure: Error?
    var response: [String: Any] = ["version": 1, "active_profile": "balanced"]
    func state() throws -> [String: Any] { response }
    func apply(_ request: ControlRequest) throws {
        if let failure { throw failure }
        requests.append(request)
    }
}

final class ControlServiceTests: XCTestCase {
    func testGetStateDoesNotApplyAnOperation() throws {
        let backend = RecordingBackend()
        let result = try ControlDispatcher(backend: backend).handle(method: "GetState")
        let state = try XCTUnwrap(JSONSupport.decode(Data(result.utf8)) as? [String: Any])
        XCTAssertEqual(state["active_profile"] as? String, "balanced")
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testTypedRequestsReachBackendAndReturnUpdatedState() throws {
        let backend = RecordingBackend()
        let dispatcher = ControlDispatcher(backend: backend)
        let requests: [(String, String, String, Int)] = [
            ("ActivateProfile", "voice", "", 0),
            ("SetProfileOptions", "voice", #"{"mic_agc":true,"eq_enable":false}"#, 0),
            ("SetDeviceField", "ambient_level", "", 4),
            ("SetHostField", "mic_volume", "", 73),
            ("CreateProfile", "Meeting", "voice", 0),
            ("RenameProfile", "custom", "Meetings", 0),
            ("DeleteProfile", "custom", "", 0),
            ("ApplyPreset", "music", "bass_boost", 0),
            ("BindApplication", "Discord", "voice", -2),
            ("RemoveApplication", "Discord", "", 0),
            ("SetAutomationEnabled", "", "", 1),
        ]
        for (method, first, second, value) in requests {
            _ = try dispatcher.handle(method: method, first: first, second: second, value: value)
        }
        XCTAssertEqual(backend.requests.map { $0.method.rawValue }, requests.map { $0.0 })
        XCTAssertEqual(backend.requests[1].options?["mic_agc"] as? Bool, true)
        XCTAssertEqual(backend.requests[8].value, -2)
    }

    func testInvalidRequestsCannotReachBackend() throws {
        let backend = RecordingBackend()
        let dispatcher = ControlDispatcher(backend: backend)
        let invalid: [(String, String, String, Int)] = [
            ("Execute", "rm", "", 0), ("GetState", "unexpected", "", 0),
            ("ActivateProfile", "", "", 0), ("CreateProfile", "Name", "", 0),
            ("SetProfileOptions", "music", "[]", 0),
            ("SetProfileOptions", "music", #"{"mic_agc":1}"#, 0),
            ("SetProfileOptions", "music", #"{"eq":[0,0,0,0,0,0,0,0,0,0.5]}"#, 0),
            ("SetProfileOptions", "music", #"{"unknown":true}"#, 0),
            ("SetDeviceField", "firmware", "", 1),
            ("SetDeviceField", "ambient_level", "", 0),
            ("SetHostField", "mic_volume", "", 101),
            ("SetHostField", "mic_mute", "", 2),
            ("SetAutomationEnabled", "", "", 2),
            ("BindApplication", "Discord", "voice", 1001),
            ("ActivateProfile", String(repeating: "x", count: 4097), "", 0),
        ]
        for (method, first, second, value) in invalid {
            XCTAssertThrowsError(try dispatcher.handle(method: method, first: first, second: second, value: value)) { error in
                XCTAssertTrue(error is ControlRequestError, "\(method): \(error)")
            }
        }
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testMutationFailurePropagatesInsteadOfReturningSuccessState() throws {
        let backend = RecordingBackend()
        backend.failure = InzoneError.message("Device verification failed.")
        XCTAssertThrowsError(try ControlDispatcher(backend: backend).handle(method: "ActivateProfile", first: "voice")) { error in
            XCTAssertEqual(error.localizedDescription, "Device verification failed.")
        }
        XCTAssertTrue(backend.requests.isEmpty)
    }

    func testOfflineStateAndProfileLifecycleAvoidHardwareAccess() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dispatcher = ControlDispatcher(backend: LiveControlBackend(paths: InzonePaths(home: directory), offline: true))
        func state(_ method: String, _ first: String = "", _ second: String = "", _ value: Int = 0) throws -> [String: Any] {
            let text = try dispatcher.handle(method: method, first: first, second: second, value: value)
            return try XCTUnwrap(JSONSupport.decode(Data(text.utf8)) as? [String: Any])
        }
        let initial = try state("GetState")
        XCTAssertEqual((initial["profiles"] as? [[String: Any]])?.count, 5)
        XCTAssertEqual((initial["device"] as? [String: Any])?["connected"] as? Bool, false)
        XCTAssertFalse((initial["device_error"] as? String)?.isEmpty ?? true)
        XCTAssertEqual((initial["device_fields"] as? [[String: Any]])?.count, InzoneDevice.fields.count)
        let created = try state("CreateProfile", "Meeting", "voice")
        let profiles = try XCTUnwrap(created["profiles"] as? [[String: Any]])
        let identifier = try XCTUnwrap(profiles.last?["id"] as? String)
        XCTAssertEqual(profiles.last?["name"] as? String, "Meeting")
        _ = try state("RenameProfile", identifier, "Daily meeting")
        let bound = try state("BindApplication", "Discord", identifier, -3)
        let rules = try XCTUnwrap((bound["automation"] as? [String: Any])?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.first?["profile"] as? String, identifier)
        XCTAssertEqual(rules.first?["priority"] as? Int, -3)
        XCTAssertThrowsError(try state("DeleteProfile", identifier))
        _ = try state("RemoveApplication", "Discord")
        let deleted = try state("DeleteProfile", identifier)
        XCTAssertEqual((deleted["profiles"] as? [[String: Any]])?.count, 5)
        XCTAssertThrowsError(try state("ActivateProfile", "voice"))
        XCTAssertThrowsError(try state("SetHostField", "mic_volume", "", 50))
    }

    func testUnreadableProfileStatusRemainsAnError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = InzonePaths(home: directory)
        try FileManager.default.createDirectory(at: paths.activeProfile, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = try LiveControlBackend(paths: paths, offline: true).state()
        XCTAssertEqual(state["active_profile"] as? String, "")
        XCTAssertFalse((state["profile_error"] as? String)?.isEmpty ?? true)
    }

    func testIsolatedSessionBusRoundTrip() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-dbus-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = directory.appendingPathComponent("libinzone-dbus.so")
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("inzone-service")
        let script = try XCTUnwrap(Bundle.module.url(forResource: "session_bus", withExtension: "py", subdirectory: "Fixtures"))
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("Build the inzone-service product before running the D-Bus integration test.")
        }
        func run(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, String(decoding: data, as: UTF8.self))
        }
        try run(["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-shared", "-fPIC",
                 "-I", root.appendingPathComponent("Sources/CInzoneDBus/include").path,
                 root.appendingPathComponent("Sources/CInzoneDBus/InzoneDBus.c").path,
                 "-lsystemd", "-o", library.path])
        try run(["dbus-run-session", "--", "python3", script.path, binary.path, library.path])
    }

    func testClientRejectsUnknownMethodBeforeOpeningSessionBus() {
        var response: UnsafeMutablePointer<CChar>?
        var message: UnsafeMutablePointer<CChar>?
        let result = inzone_dbus_call("Unknown", "", "", 0, &response, &message)
        defer { inzone_dbus_free(response); inzone_dbus_free(message) }
        XCTAssertLessThan(result, 0)
        XCTAssertNil(response)
        XCTAssertEqual(message.map { String(cString: $0) }, "Unknown D-Bus method.")
    }
}
