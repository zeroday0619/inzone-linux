import Foundation
import Glibc
import XCTest
@testable import InzoneCore

final class DeviceTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        let characters = Array(hex)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    func testObservedWirePackets() throws {
        let report = try HIDPacketCodec.command(event: 4, kind: 1, sequence: 1)
        XCTAssertEqual(report.count, 64)
        XCTAssertEqual(report.prefix(14), bytes("020c0100fc0896c34104010100a0"))
        let battery = try HIDPacketCodec.parsePacket(bytes("04ff0b0096c31404100100000d8f"))
        XCTAssertEqual(battery.event, 4)
        XCTAssertEqual(battery.kind, 16)
        XCTAssertEqual(battery.sequence, 1)
        XCTAssertEqual(battery.source, 4)
        XCTAssertEqual(battery.payload, Data([0, 13]))
        let ambient = try HIDPacketCodec.parsePacket(bytes("04ff0d0096c314411001000014ff00d2"))
        XCTAssertEqual(ambient.payload, Data([0, 20, 255, 0]))
        let connection = try HIDPacketCodec.command(event: 1, kind: 1, sequence: 65535)
        XCTAssertEqual(connection[8], 0x21)
        XCTAssertEqual(connection[11], 0xff)
        XCTAssertEqual(connection[12], 0xff)
    }

    func testCorruptionAndUnsafeCommandsAreRejected() throws {
        let packet = bytes("04ff0b0096c31404100100000d8f")
        for index in packet.indices {
            var corrupt = packet
            corrupt[index] ^= 1
            XCTAssertThrowsError(try HIDPacketCodec.parsePacket(corrupt), "Corruption at byte \(index)")
        }
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 160, kind: 2, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 3, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 1, sequence: 0))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 1, sequence: 65536))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 1, sequence: 1, payload: Data(repeating: 0, count: 51)))
        XCTAssertNoThrow(try HIDPacketCodec.command(event: 4, kind: 2, sequence: 1, payload: Data(repeating: 0, count: 50)))
    }

    func testStatusExcludesIdentifyingBytesAndDecodesFields() {
        let snapshot = InzoneDevice.describe([
            "connection": [1], "model": [5, 3, 0x12, 0x34, 0, 0], "battery": [0, 13],
            "firmware": [1, 1, 0, 0, 1, 1, 0, 0], "ambient": [0, 20, 255, 0],
            "microphone": [1, 0, 0], "mic_attached": [0],
        ])
        XCTAssertNil(snapshot["model"])
        XCTAssertNil(snapshot["raw"])
        XCTAssertEqual((snapshot["firmware"] as? [String: String])?["headset"], "01.001.000")
        XCTAssertEqual((snapshot["fields"] as? [String: Int])?["ambient_level"], 20)
        XCTAssertEqual(snapshot["microphone_muted"] as? Bool, true)
        XCTAssertEqual(snapshot["microphone_attached"] as? Bool, true)
        let invalidBattery = InzoneDevice.describe(["battery": [8, 255]])["battery"] as? [String: Any]
        XCTAssertTrue(invalidBattery?["percent"] is NSNull)
        XCTAssertEqual(invalidBattery?["state"] as? String, "unknown")
    }

    func testDiscoveryRequiresExactlyOneMatchingDongle() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("hidraw0/device")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try Data("HID_ID=0003:0000054C:00000FA8\n".utf8).write(to: first.appendingPathComponent("uevent"))
        XCTAssertEqual(try InzoneDevice.discover(sysDirectory: directory).path, "/dev/hidraw0")
        let second = directory.appendingPathComponent("hidraw1/device")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("HID_ID=0003:0000054c:00000fa8\n".utf8).write(to: second.appendingPathComponent("uevent"))
        XCTAssertThrowsError(try InzoneDevice.discover(sysDirectory: directory))
        try Data("HID_ID=0003:00001234:00005678\n".utf8).write(to: first.appendingPathComponent("uevent"))
        XCTAssertEqual(try InzoneDevice.discover(sysDirectory: directory).path, "/dev/hidraw1")
        try Data("HID_ID=0003:00001234:00005678\n".utf8).write(to: second.appendingPathComponent("uevent"))
        XCTAssertThrowsError(try InzoneDevice.discover(sysDirectory: directory))
    }

    func testHostControlsUseExactDeviceTargetsAndValidatedRanges() throws {
        let runner = DeviceRunner()
        try InzoneDevice.setHostField("game_volume", value: 42, runner: runner)
        try InzoneDevice.setHostField("mic_mute", value: 1, runner: runner)
        XCTAssertEqual(runner.calls, [
            ["pactl", "set-sink-volume", "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game", "42%"],
            ["pactl", "set-source-mute", "alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat", "1"],
        ])
        XCTAssertThrowsError(try InzoneDevice.setHostField("game_volume", value: 101, runner: runner))
        XCTAssertThrowsError(try InzoneDevice.setHostField("mic_mute", value: 2, runner: runner))
        XCTAssertThrowsError(try InzoneDevice.setHostField("other", value: 0, runner: runner))
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testHostStatusReadsVolumeAndMicrophoneMute() throws {
        let runner = DeviceRunner(output: #"[{"name":"alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game","volume":{"front-right":{"value_percent":"50%"},"front-left":{"value_percent":"42%"}},"mute":false},{"name":"alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat","volume":{"mono":{"value_percent":"70%"}},"mute":true}]"#)
        let levels = try InzoneDevice.hostLevels(runner: runner)
        XCTAssertEqual(levels["game_volume"], 42)
        XCTAssertEqual(levels["mic_volume"], 70)
        XCTAssertEqual(levels["mic_mute"], 1)
        XCTAssertNil(levels["chat_volume"])
    }

    func testTransportReassemblesFragmentsAndMatchesMultipartReplies() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        defer { device.close() }
        let server = descriptors[1]
        let complete = expectation(description: "Mock HID device completes fragmented response")
        DispatchQueue.global().async {
            defer { _ = Glibc.close(server); complete.fulfill() }
            guard let request = Self.receive(server) else { return }
            let wrong = Self.response(request, sequenceOffset: 1, payload: [9])
            Self.send(server, bytes: wrong)
            let first = Self.response(request, payload: Array(repeating: 7, count: 50))
            Self.send(server, bytes: Array(first.prefix(3)))
            Self.send(server, bytes: Array(first.dropFirst(3)))
            Self.send(server, bytes: Self.response(request, payload: [8, 9]))
        }
        XCTAssertEqual(try device.transact("battery"), Data(Array(repeating: 7, count: 50) + [8, 9]))
        wait(for: [complete], timeout: 3)
    }

    func testFieldWritePreservesOtherParametersAndReadsBack() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        defer { device.close() }
        let server = descriptors[1]
        let complete = expectation(description: "Mock HID device completes read-modify-write")
        DispatchQueue.global().async {
            defer { _ = Glibc.close(server); complete.fulfill() }
            guard let initial = Self.receive(server) else { return }
            XCTAssertEqual(initial[10], 1)
            Self.send(server, bytes: Self.response(initial, payload: [0, 20, 255, 0]))
            guard let write = Self.receive(server) else { return }
            XCTAssertEqual(write[10], 2)
            XCTAssertEqual(Array(write[13..<17]), [1, 20, 255, 0])
            Self.send(server, bytes: Self.response(write, kind: 0x20, payload: [1, 20, 255, 0]))
            guard let readback = Self.receive(server) else { return }
            XCTAssertEqual(readback[10], 1)
            Self.send(server, bytes: Self.response(readback, payload: [1, 20, 255, 0]))
        }
        XCTAssertNoThrow(try device.setField("anc", value: 1))
        wait(for: [complete], timeout: 3)
    }

    private static func receive(_ descriptor: Int32) -> [UInt8]? {
        var polling = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        guard Glibc.poll(&polling, 1, 2000) > 0 else { XCTFail("Mock device did not receive a command."); return nil }
        var buffer = [UInt8](repeating: 0, count: 64)
        guard Glibc.read(descriptor, &buffer, buffer.count) == 64 else { XCTFail("Expected a 64-byte HID command."); return nil }
        return buffer
    }

    private static func response(_ request: [UInt8], kind: UInt8 = 0x10, sequenceOffset: Int = 0, payload: [UInt8]) -> [UInt8] {
        let sequence = (Int(request[11]) | Int(request[12]) << 8) + sequenceOffset
        var packet: [UInt8] = [4, 0xff, UInt8(payload.count + 9), 0, 0x96, 0xc3,
                               request[9] == 1 ? 0x12 : 0x14, request[9], kind,
                               UInt8(sequence & 255), UInt8((sequence >> 8) & 255)] + payload
        packet.append(packet.dropFirst(3).reduce(0, &+))
        return packet
    }

    private static func send(_ descriptor: Int32, bytes: [UInt8]) {
        let report = [2, UInt8(bytes.count)] + bytes
        let result = report.withUnsafeBytes { Glibc.write(descriptor, $0.baseAddress, $0.count) }
        XCTAssertEqual(result, report.count)
    }
}

private final class DeviceRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    private let output: String
    init(output: String = "") { self.output = output }
    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(arguments)
        return output
    }
}
