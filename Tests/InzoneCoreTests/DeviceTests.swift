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
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 160, kind: 1, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 3, kind: 2, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 2, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 36, kind: 2, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 97, kind: 2, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 3, sequence: 1))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 1, sequence: 0))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 1, sequence: 65536))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 4, kind: 1, sequence: 1, payload: Data(repeating: 0, count: 51)))
        XCTAssertThrowsError(try HIDPacketCodec.command(event: 3, kind: 1, sequence: 1, payload: Data([0])))
        XCTAssertNoThrow(try HIDPacketCodec.command(event: 3, kind: 1, sequence: 1))
        XCTAssertNoThrow(try HIDPacketCodec.command(event: 33, kind: 2, sequence: 1, payload: Data(repeating: 0, count: 50)))
        for kind: UInt8 in [0x10, 0x20, 0xa0] {
            var updatePacket = Self.notification(event: 160, sequence: 1, payload: [1])
            updatePacket[8] = kind
            updatePacket[updatePacket.count - 1] = updatePacket.dropFirst(3).dropLast().reduce(0, &+)
            XCTAssertThrowsError(try HIDPacketCodec.parsePacket(Data(updatePacket)))
        }
        XCTAssertThrowsError(try InzoneDevice.decodeNotification(event: 160, payload: Data([1])))
        XCTAssertThrowsError(try InzoneDevice.decodeNotification(event: 33, payload: Data([0, 1])))
        XCTAssertEqual(try InzoneDevice.decodeNotification(event: 97, payload: Data([1, 2])).status["bluetooth_connection"],
                       "pairing")
    }

    func testH9IIWritableFieldMatrixExcludesStatusOnlyMuteAndFirmwareValues() {
        XCTAssertEqual(InzoneDevice.fields.map(\.name), [
            "headphone_volume", "anc", "ambient_level", "voice_focus", "game_chat",
            "sidetone", "toggle_off", "toggle_nc", "toggle_ambient", "nc_startup",
            "bt_startup", "auto_power", "language", "guidance",
        ])
        XCTAssertEqual(
            InzoneDevice.fields.first { $0.name == "game_chat" }?.values,
            Array(stride(from: 0, through: 100, by: 10))
        )
        XCTAssertFalse(InzoneDevice.fields.contains { $0.name.contains("mute") })
        XCTAssertFalse(InzoneDevice.fields.contains { $0.name.contains("firmware") })
    }

    func testStatusExcludesIdentifyingBytesAndDecodesFields() {
        let snapshot = InzoneDevice.describe([
            "connection": [1], "model": [5, 3, 0x12, 0x34, 0, 0], "battery": [0, 13],
            "firmware": [1, 1, 0, 0, 1, 1, 0, 0], "ambient": [0, 20, 255, 0],
            "headphone": [0, 17, 255], "microphone": [1, 255, 255],
            "bluetooth": [0, 3], "mic_attached": [0],
        ])
        XCTAssertNil(snapshot["model"])
        XCTAssertNil(snapshot["raw"])
        XCTAssertEqual((snapshot["firmware"] as? [String: String])?["headset"], "01.001.000")
        XCTAssertEqual((snapshot["fields"] as? [String: Int])?["ambient_level"], 20)
        XCTAssertEqual((snapshot["fields"] as? [String: Int])?["headphone_volume"], 17)
        XCTAssertNil((snapshot["fields"] as? [String: Int])?["headphone_mute"])
        XCTAssertNil((snapshot["fields"] as? [String: Int])?["headset_microphone_mute"])
        XCTAssertEqual(snapshot["microphone_muted"] as? Bool, true)
        XCTAssertEqual(snapshot["microphone_attached"] as? Bool, true)
        let headphone = snapshot["headphone"] as? [String: Any]
        XCTAssertEqual(headphone?["muted"] as? Bool, false)
        XCTAssertEqual(headphone?["volume"] as? Int, 17)
        XCTAssertTrue(headphone?["percent"] is NSNull)
        let microphone = snapshot["microphone"] as? [String: Any]
        XCTAssertTrue(microphone?["volume"] is NSNull)
        XCTAssertTrue(microphone?["percent"] is NSNull)
        let bluetooth = snapshot["bluetooth"] as? [String: Any]
        XCTAssertEqual(bluetooth?["power"] as? String, "off")
        XCTAssertEqual(bluetooth?["connection"] as? String, "not_applicable")
        XCTAssertEqual(bluetooth?["connection_value"] as? Int, 3)
        let invalidBattery = InzoneDevice.describe(["battery": [8, 255]])["battery"] as? [String: Any]
        XCTAssertTrue(invalidBattery?["percent"] is NSNull)
        XCTAssertEqual(invalidBattery?["state"] as? String, "unknown")
        let unavailableFirmware = InzoneDevice.describe(["firmware": Array(repeating: 255, count: 8)])
        XCTAssertEqual((unavailableFirmware["firmware"] as? [String: String])?["headset"], "--.---.---")
        XCTAssertEqual((unavailableFirmware["firmware"] as? [String: String])?["dongle"], "--.---.---")
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

    func testFutureSequenceResponseCannotSatisfyNextTransaction() throws {
        try withMockDevice(server: { descriptor in
            guard let firstRequest = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(firstRequest, sequenceOffset: 1, payload: [9, 99]))
            Self.send(descriptor, bytes: Self.response(firstRequest, payload: [0, 41]))
            guard let secondRequest = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(secondRequest, payload: [0, 42]))
        }) { device in
            XCTAssertEqual(try device.transact("battery"), Data([0, 41]))
            XCTAssertEqual(try device.transact("battery"), Data([0, 42]))
        }
    }

    func testUnsolicitedNotificationIsDeliveredWithoutTransaction() throws {
        try withMockDevice(server: { descriptor in
            Self.send(descriptor, bytes: Self.notification(event: 33, sequence: 7, payload: [0, 21, 255]))
        }) { device in
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.eventName, "headphone")
            XCTAssertEqual(notification.event, 33)
            XCTAssertEqual(notification.payload, Data([0, 21, 255]))
            XCTAssertEqual(notification.values["headphone_mute"], 0)
            XCTAssertEqual(notification.values["headphone_volume"], 21)
            XCTAssertEqual(notification.values["headphone_volume_percent"], 255)
            XCTAssertEqual(notification.status["headphone_mute"], "unmuted")
        }
    }

    func testActiveNotificationDoesNotCompleteMatchingTransaction() throws {
        try withMockDevice(server: { descriptor in
            guard let request = Self.receive(descriptor) else { return }
            let sequence = Int(request[11]) | Int(request[12]) << 8
            let active = Self.notification(event: Int(request[9]), sequence: sequence, payload: [1, 88])
            let response = Self.response(request, payload: [0, 42])
            Self.send(descriptor, bytes: active + response)
        }) { device in
            XCTAssertEqual(try device.transact("battery"), Data([0, 42]))
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.eventName, "battery")
            XCTAssertEqual(notification.values["battery_percent"], 88)
            XCTAssertEqual(notification.status["battery_state"], "charging")
        }
    }

    func testFragmentedMultipartNotificationIsDeliveredOnce() throws {
        try withMockDevice(server: { descriptor in
            let firstPayload = Array(repeating: UInt8(9), count: 50)
            let first = Self.notification(event: 200, sequence: 11, payload: firstPayload)
            Self.send(descriptor, bytes: Array(first.prefix(4)))
            Self.send(descriptor, bytes: Array(first.dropFirst(4)))
            Self.send(descriptor, bytes: Self.notification(event: 200, sequence: 11, payload: [8, 7]))
            usleep(200_000)
        }) { device in
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.eventName, "event_200")
            XCTAssertEqual(notification.payload, Data(Array(repeating: UInt8(9), count: 50) + [8, 7]))
            XCTAssertNil(try device.nextNotification(timeout: 0.05))
        }
    }

    func testFirmwareUpdateNotificationsAreIgnored() throws {
        try withMockDevice(server: { descriptor in
            Self.send(descriptor, bytes: Self.notification(event: 160, sequence: 1, payload: [1, 2, 3]))
            Self.send(descriptor, bytes: Self.notification(event: 97, sequence: 2, payload: [0, 3]))
            usleep(200_000)
        }) { device in
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.event, 97)
            XCTAssertEqual(notification.status["bluetooth_power"], "off")
            XCTAssertEqual(notification.status["bluetooth_connection"], "not_applicable")
            XCTAssertNil(try device.nextNotification(timeout: 0.05))
        }
    }

    func testKnownNotificationFromWrongSourceIsIgnored() throws {
        try withMockDevice(server: { descriptor in
            Self.send(descriptor, bytes: Self.notification(event: 33, source: 2, sequence: 1, payload: [0, 9, 255]))
            Self.send(descriptor, bytes: Self.notification(event: 33, sequence: 2, payload: [0, 21, 255]))
        }) { device in
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.values["headphone_volume"], 21)
        }
    }

    func testMalformedNotificationDoesNotStopLaterTraffic() throws {
        try withMockDevice(server: { descriptor in
            var malformed = Self.notification(event: 33, sequence: 1, payload: [0, 9, 255])
            malformed[malformed.count - 1] ^= 1
            Self.send(descriptor, bytes: malformed)
            Self.send(descriptor, bytes: Self.notification(event: 33, sequence: 2, payload: [0, 22, 255]))
        }) { device in
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.values["headphone_volume"], 22)
        }
    }

    func testIncompleteKnownNotificationIsIgnored() throws {
        try withMockDevice(server: { descriptor in
            Self.send(descriptor, bytes: Self.notification(event: 33, sequence: 1, payload: [0, 9]))
            Self.send(descriptor, bytes: Self.notification(event: 33, sequence: 2, payload: [0, 22, 255]))
            usleep(200_000)
        }) { device in
            let notification = try XCTUnwrap(device.nextNotification(timeout: 0.5))
            XCTAssertEqual(notification.values["headphone_volume"], 22)
            XCTAssertNil(try device.nextNotification(timeout: 0.05))
        }
    }

    func testFirmwareAndStatusSetTransactionsAreRejectedBeforeWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        defer { device.close(); _ = Glibc.close(descriptors[1]) }
        XCTAssertThrowsError(try device.transact("firmware", kind: 2, payload: Data(repeating: 0, count: 8)))
        XCTAssertThrowsError(try device.transact("bluetooth", kind: 2, payload: Data([1, 1])))
        var polling = pollfd(fd: descriptors[1], events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(Glibc.poll(&polling, 1, 50), 0)
    }

    func testFirmwareVersionGetRemainsReadOnlyAndDecoded() throws {
        let headsetValue = UInt32(99) | UInt32(0x234) << 8 | UInt32(0x345) << 20
        let dongleValue = UInt32(100) | UInt32(1000) << 8 | UInt32(1000) << 20
        let firmwareBytes = [headsetValue, dongleValue].flatMap { value in
            (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) }
        }
        try withMockDevice(server: { descriptor in
            guard let request = Self.receive(descriptor) else { return }
            XCTAssertEqual(request[9], 3)
            XCTAssertEqual(request[10], 1)
            XCTAssertEqual(request[4], 0xfc)
            XCTAssertEqual(request[5], 8)
            Self.send(descriptor, bytes: Self.response(request, payload: firmwareBytes))
        }) { device in
            let payload = Array(try device.transact("firmware"))
            let firmware = InzoneDevice.describe(["firmware": payload])["firmware"] as? [String: String]
            XCTAssertEqual(firmware?["headset"], "99.564.837")
            XCTAssertEqual(firmware?["dongle"], "--.---.---")
        }
    }

    func testCloseWakesBlockedTransactionAndIsConcurrentSafe() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        let transactionFinished = expectation(description: "Blocked transaction is released by close")
        DispatchQueue.global().async {
            do {
                _ = try device.transact("battery", timeout: 5)
                XCTFail("The closed transport completed a blocked transaction.")
            } catch {}
            transactionFinished.fulfill()
        }
        XCTAssertNotNil(Self.receive(descriptors[1]))

        let closeGroup = DispatchGroup()
        for _ in 0..<8 {
            closeGroup.enter()
            DispatchQueue.global().async {
                device.close()
                closeGroup.leave()
            }
        }
        XCTAssertEqual(closeGroup.wait(timeout: .now() + 1), .success)
        wait(for: [transactionFinished], timeout: 1)
        _ = Glibc.close(descriptors[1])
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

    func testHardwareVolumeWritePreservesMuteAndPercent() throws {
        try withMockDevice(server: { descriptor in
            guard let headphoneRead = Self.receive(descriptor) else { return }
            XCTAssertEqual(headphoneRead[9], 33)
            Self.send(descriptor, bytes: Self.response(headphoneRead, payload: [1, 12, 255]))
            guard let headphoneWrite = Self.receive(descriptor) else { return }
            XCTAssertEqual(Array(headphoneWrite[13..<16]), [1, 20, 255])
            Self.send(descriptor, bytes: Self.response(headphoneWrite, kind: 0x20, payload: [1, 20, 255]))
            guard let headphoneVerify = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(headphoneVerify, payload: [1, 20, 255]))

        }) { device in
            XCTAssertNoThrow(try device.setField("headphone_volume", value: 20))
        }
    }

    func testEveryDeviceFieldUsesItsExactPayloadOffsetAndPreservesOtherBytes() throws {
        let cases: [(name: String, event: UInt8, initial: [UInt8], expected: [UInt8], value: Int)] = [
            ("ambient_level", 65, [0, 20, 255, 0], [0, 10, 255, 0], 10),
            ("voice_focus", 65, [0, 20, 255, 0], [0, 20, 255, 1], 1),
            ("game_chat", 34, [50], [70], 70),
            ("sidetone", 35, [4, 255], [8, 255], 8),
            ("toggle_off", 66, [0, 1, 1], [1, 1, 1], 1),
            ("toggle_nc", 66, [1, 0, 1], [1, 1, 1], 1),
            ("toggle_ambient", 66, [1, 1, 0], [1, 1, 1], 1),
            ("nc_startup", 67, [0], [3], 3),
            ("bt_startup", 99, [0], [2], 2),
            ("auto_power", 129, [5, 5], [30, 30], 30),
            ("language", 131, [0], [2], 2),
            ("guidance", 132, [1], [0], 0),
        ]
        try withMockDevice(server: { descriptor in
            for testCase in cases {
                guard let read = Self.receive(descriptor) else { return }
                XCTAssertEqual(read[9], testCase.event)
                Self.send(descriptor, bytes: Self.response(read, payload: testCase.initial))
                guard let write = Self.receive(descriptor) else { return }
                XCTAssertEqual(write[9], testCase.event)
                XCTAssertEqual(write[10], 2)
                XCTAssertEqual(Array(write[13..<(13 + testCase.expected.count)]), testCase.expected)
                Self.send(descriptor, bytes: Self.response(write, kind: 0x20, payload: testCase.expected))
                guard let verify = Self.receive(descriptor) else { return }
                XCTAssertEqual(verify[10], 1)
                Self.send(descriptor, bytes: Self.response(verify, payload: testCase.expected))
            }
        }) { device in
            for testCase in cases {
                XCTAssertNoThrow(try device.setField(testCase.name, value: testCase.value))
            }
        }
    }

    func testNoiseControlToggleRejectsFewerThanTwoModesWithoutWriting() throws {
        try withMockDevice(server: { descriptor in
            guard let read = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(read, payload: [1, 1, 0]))
            usleep(50_000)
            var unexpected = [UInt8](repeating: 0, count: 64)
            XCTAssertLessThanOrEqual(Glibc.recv(descriptor, &unexpected, unexpected.count, Int32(MSG_DONTWAIT)), 0)
        }) { device in
            XCTAssertThrowsError(try device.setField("toggle_off", value: 0))
        }
    }

    func testNotificationStreamDoesNotReplayQueuedEventsAndKeepsTransportOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        defer { device.close() }
        let server = descriptors[1]
        DispatchQueue.global().async {
            defer { _ = Glibc.close(server) }
            Self.send(server, bytes: Self.notification(event: 36, sequence: 3, payload: [0, 255, 255]))
            usleep(100_000)
            Self.send(server, bytes: Self.notification(event: 36, sequence: 4, payload: [1, 255, 255]))
            guard let request = Self.receive(server) else { return }
            Self.send(server, bytes: Self.response(request, payload: [0, 67]))
        }
        try await Task.sleep(for: .milliseconds(50))
        let received = await Task { () -> DeviceNotification? in
            for await notification in device.notifications() { return notification }
            return nil
        }.value
        XCTAssertEqual(received?.eventName, "microphone")
        XCTAssertEqual(received?.values["headset_microphone_mute"], 1)
        XCTAssertEqual(try device.transact("battery"), Data([0, 67]))
    }

    func testNotificationStreamDeliversFinalEventBeforeDisconnect() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        defer { device.close() }
        let stream = device.notifications()
        let server = descriptors[1]
        DispatchQueue.global().async {
            Self.send(server, bytes: Self.notification(event: 97, sequence: 9, payload: [1, 2]))
            _ = Glibc.close(server)
        }
        var iterator = stream.makeAsyncIterator()
        let notification = await iterator.next()
        XCTAssertEqual(notification?.eventName, "bluetooth")
        XCTAssertEqual(notification?.status["bluetooth_power"], "on")
        XCTAssertEqual(notification?.status["bluetooth_connection"], "pairing")
        let completion = await iterator.next()
        XCTAssertNil(completion)
    }

    func testObservationWatermarkRejectsPreResponseNotificationAndAcceptsLaterOne() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors), 0)
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        defer { device.close() }
        let server = descriptors[1]
        DispatchQueue.global().async {
            defer { _ = Glibc.close(server) }
            while let request = Self.receive(server) {
                let event = request[9]
                let payload: [UInt8]
                switch event {
                case 1: payload = [1]
                case 2: payload = [5, 3, 0, 0, 0, 0]
                case 3: payload = Array(repeating: 0, count: 8)
                case 4: payload = [0, 50]
                case 33:
                    Self.send(server, bytes: Self.notification(event: 33, sequence: 900, payload: [0, 5, 255]))
                    let response = Self.response(request, payload: [0, 10, 255])
                    let later = Self.notification(event: 33, sequence: 901, payload: [0, 20, 255])
                    Self.send(server, bytes: response + later)
                    continue
                case 34: payload = [50]
                case 35: payload = [5, 255]
                case 36: payload = [0, 255, 255]
                case 65: payload = [0, 20, 255, 0]
                case 66: payload = [1, 1, 0]
                case 67: payload = [0]
                case 97: payload = [0, 3]
                case 99: payload = [2]
                case 129: payload = [5, 5]
                case 131: payload = [0]
                case 132: payload = [1]
                case 143: payload = [0]
                default: return
                }
                Self.send(server, bytes: Self.response(request, payload: payload))
                if event == 143 { return }
            }
        }

        let observation = try device.observe()
        let fields = observation.snapshot.status["fields"] as? [String: Int]
        XCTAssertEqual(fields?["headphone_volume"], 10)
        XCTAssertEqual(observation.snapshot.watermarks["headphone"], 1)
        var iterator = observation.notifications.makeAsyncIterator()
        let firstNotification = await iterator.next()
        let secondNotification = await iterator.next()
        let beforeResponse = try XCTUnwrap(firstNotification)
        let afterResponse = try XCTUnwrap(secondNotification)
        XCTAssertEqual(beforeResponse.revision, 1)
        XCTAssertEqual(afterResponse.revision, 2)
        XCTAssertFalse(observation.shouldApply(beforeResponse))
        XCTAssertTrue(observation.shouldApply(afterResponse))
        XCTAssertEqual(afterResponse.values["headphone_volume"], 20)
    }

    func testSetIgnoresReadResponseWithMatchingTransaction() throws {
        try withMockDevice(server: { descriptor in
            guard let request = Self.receive(descriptor) else { return }
            XCTAssertEqual(request[10], 2)
            let unrelated = Self.response(request, kind: 0x10, payload: [0, 20, 255, 0])
            let acknowledgement = Self.response(request, kind: 0x20, payload: [1, 20, 255, 0])
            Self.send(descriptor, bytes: unrelated + acknowledgement)
        }) { device in
            XCTAssertEqual(try device.transact("ambient", kind: 2, payload: Data([1, 20, 255, 0])),
                           Data([1, 20, 255, 0]))
        }
    }

    func testFieldVerificationWaitsForUpdatedReadbackWithoutRewriting() throws {
        try withMockDevice(server: { descriptor in
            guard let initial = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(initial, payload: [0, 20, 255, 0]))
            guard let write = Self.receive(descriptor) else { return }
            XCTAssertEqual(write[10], 2)
            XCTAssertEqual(Array(write[13..<17]), [1, 20, 255, 0])
            Self.send(descriptor, bytes: Self.response(write, kind: 0x20, payload: [1, 20, 255, 0]))
            for observed: UInt8 in [0, 1] {
                guard let query = Self.receive(descriptor) else { return }
                XCTAssertEqual(query[10], 1, "Verification must not repeat SET.")
                Self.send(descriptor, bytes: Self.response(query, payload: [observed, 20, 255, 0]))
            }
        }) { device in
            XCTAssertNoThrow(try device.setField("anc", value: 1, verificationTimeout: 0.5))
        }
    }

    func testPersistentMismatchReportsFieldRequestedAndObservedValues() throws {
        try withMockDevice(server: { descriptor in
            guard let initial = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(initial, payload: [0, 20, 255, 0]))
            guard let write = Self.receive(descriptor) else { return }
            Self.send(descriptor, bytes: Self.response(write, kind: 0x20, payload: [1, 20, 255, 0]))
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptorStatus = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                if Glibc.poll(&descriptorStatus, 1, 100) <= 0 { continue }
                var query = [UInt8](repeating: 0, count: 64)
                let count = Glibc.read(descriptor, &query, query.count)
                if count <= 0 { return }
                XCTAssertEqual(count, 64)
                XCTAssertEqual(query[10], 1)
                Self.send(descriptor, bytes: Self.response(query, payload: [0, 20, 255, 0]))
            }
        }) { device in
            XCTAssertThrowsError(try device.setField("anc", value: 1, verificationTimeout: 0.12)) { error in
                XCTAssertTrue(error.localizedDescription.contains("Unconfirmed anc:"))
                XCTAssertTrue(error.localizedDescription.contains("requested 1, observed 0"))
            }
        }
    }

    private func withMockDevice(server operation: @escaping @Sendable (Int32) -> Void,
                                body: (InzoneDevice) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, Int32(SOCK_SEQPACKET.rawValue), 0, &descriptors) == 0 else {
            XCTFail("Cannot create mock HID transport.")
            return
        }
        let device = try InzoneDevice(home: directory, ownedDescriptor: descriptors[0])
        let server = descriptors[1]
        let complete = expectation(description: "Mock HID exchange completed")
        DispatchQueue.global().async {
            defer { _ = Glibc.close(server); complete.fulfill() }
            operation(server)
        }
        defer { device.close(); wait(for: [complete], timeout: 3) }
        try body(device)
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

    private static func notification(event: Int, source: UInt8 = 4, sequence: Int, payload: [UInt8]) -> [UInt8] {
        var packet: [UInt8] = [4, 0xff, UInt8(payload.count + 9), 0, 0x96, 0xc3, 0x10 | source,
                               UInt8(event), 0xa0, UInt8(sequence & 255), UInt8((sequence >> 8) & 255)] + payload
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
