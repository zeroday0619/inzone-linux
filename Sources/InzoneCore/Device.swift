import Dispatch
import Foundation
import Glibc

public struct DeviceField: Equatable, Sendable {
    public let name: String
    public let eventName: String
    public let index: Int
    public let values: [Int]
    public let label: String
    public let labels: [String]
    public var minimum: Int { values.min() ?? 0 }
    public var maximum: Int { values.max() ?? 0 }

    public init(name: String, eventName: String, index: Int, values: [Int], label: String, labels: [String] = []) {
        self.name = name
        self.eventName = eventName
        self.index = index
        self.values = values
        self.label = label
        self.labels = labels
    }
}

private struct DeviceEvent: Sendable {
    let name: String
    let identifier: Int
    let minimumLength: Int
    let writable: Bool

    init(name: String, identifier: Int, minimumLength: Int, writable: Bool = false) {
        self.name = name
        self.identifier = identifier
        self.minimumLength = minimumLength
        self.writable = writable
    }
}

private let deviceEvents: [DeviceEvent] = [
    .init(name: "connection", identifier: 1, minimumLength: 1),
    .init(name: "model", identifier: 2, minimumLength: 6),
    .init(name: "firmware", identifier: 3, minimumLength: 8),
    .init(name: "battery", identifier: 4, minimumLength: 2),
    .init(name: "headphone", identifier: 33, minimumLength: 3, writable: true),
    .init(name: "balance", identifier: 34, minimumLength: 1, writable: true),
    .init(name: "sidetone", identifier: 35, minimumLength: 2, writable: true),
    .init(name: "microphone", identifier: 36, minimumLength: 3),
    .init(name: "ambient", identifier: 65, minimumLength: 4, writable: true),
    .init(name: "nc_toggle", identifier: 66, minimumLength: 3, writable: true),
    .init(name: "nc_startup", identifier: 67, minimumLength: 1, writable: true),
    .init(name: "bluetooth", identifier: 97, minimumLength: 2),
    .init(name: "bt_startup", identifier: 99, minimumLength: 1, writable: true),
    .init(name: "auto_power", identifier: 129, minimumLength: 2, writable: true),
    .init(name: "language", identifier: 131, minimumLength: 1, writable: true),
    .init(name: "guidance", identifier: 132, minimumLength: 1, writable: true),
    .init(name: "mic_attached", identifier: 143, minimumLength: 1),
]

public struct HIDPacket: Equatable, Sendable {
    public let event: Int
    public let kind: Int
    public let sequence: Int
    public let source: Int
    public let payload: Data
}

public struct DeviceNotification: Equatable, Sendable {
    public let revision: UInt64
    public let eventName: String
    public let event: Int
    public let payload: Data
    public let values: [String: Int]
    public let status: [String: String]
}

public struct DeviceSnapshot {
    public let status: [String: Any]
    public let watermarks: [String: UInt64]

    public func shouldApply(_ notification: DeviceNotification) -> Bool {
        notification.revision > (watermarks[notification.eventName] ?? 0)
    }
}

public struct DeviceObservation {
    public let snapshot: DeviceSnapshot
    public let notifications: AsyncStream<DeviceNotification>

    public func shouldApply(_ notification: DeviceNotification) -> Bool {
        snapshot.shouldApply(notification)
    }
}

public enum HIDPacketCodec {
    public static func command(event: Int, kind: Int, sequence: Int, payload: Data = Data()) throws -> Data {
        guard let definition = deviceEvents.first(where: { $0.identifier == event }),
              kind == 1 || (kind == 2 && definition.writable) else {
            throw InzoneError.message("Unsupported H9 II command.")
        }
        guard payload.count <= 50, (1...65535).contains(sequence), kind == 2 || payload.isEmpty else {
            throw InzoneError.message("Invalid H9 II command payload or sequence.")
        }
        let address: UInt8 = event == 1 ? 0x21 : 0x41
        var packet: [UInt8] = [1, 0, 0xfc, UInt8(8 + payload.count), 0x96, 0xc3, address,
                               UInt8(event), UInt8(kind), UInt8(sequence & 255), UInt8(sequence >> 8)]
        packet.append(contentsOf: payload)
        packet.append(packet.dropFirst(4).reduce(0, &+))
        return Data([2, UInt8(packet.count)] + packet + Array(repeating: 0, count: 62 - packet.count))
    }

    public static func parsePacket(_ data: Data) throws -> HIDPacket {
        let packet = Array(data)
        guard packet.count >= 12, packet[0] == 4, packet[1] == 0xff,
              packet.count == Int(packet[2]) + 3, packet[3] == 0 else {
            throw InzoneError.message("Invalid HCI response length.")
        }
        guard packet[3..<(packet.count - 1)].reduce(0, &+) == packet.last else {
            throw InzoneError.message("HCI checksum mismatch.")
        }
        guard packet[4] == 0x96, packet[5] == 0xc3, [0x12, 0x14].contains(packet[6]),
              [0x10, 0x20, 0xa0].contains(packet[8]) else {
            throw InzoneError.message("Invalid Sony HCI response.")
        }
        guard packet[7] != 160 else {
            throw InzoneError.message("Unsupported H9 II firmware update protocol event.")
        }
        return HIDPacket(event: Int(packet[7]), kind: Int(packet[8]),
                         sequence: Int(packet[9]) | Int(packet[10]) << 8,
                         source: Int(packet[6] & 15), payload: Data(packet[11..<(packet.count - 1)]))
    }
}

private struct NotificationKey: Hashable {
    let event: Int
    let source: Int
    let sequence: Int
}

private struct NotificationAssembly {
    let payload: Data
    let updatedAt: TimeInterval
}

private struct ResponseKey: Equatable {
    let event: Int
    let sequence: Int
    let source: Int
    let kind: Int

    func matches(_ packet: HIDPacket) -> Bool {
        packet.event == event && packet.sequence == sequence && packet.source == source && packet.kind == kind
    }
}

private struct ResponseEnvelope {
    let packet: HIDPacket
    let notificationRevision: UInt64
}

private struct DeviceTimeout: Error, LocalizedError, CustomStringConvertible {
    let name: String
    var description: String { "No H9 II response: \(name)" }
    var errorDescription: String? { description }
}

public final class InzoneDevice: @unchecked Sendable {
    public static let fields: [DeviceField] = [
        .init(name: "headphone_volume", eventName: "headphone", index: 1, values: Array(0...30), label: "Headphone hardware volume"),
        .init(name: "anc", eventName: "ambient", index: 0, values: [0, 1, 2], label: "Noise control", labels: ["Off", "Noise cancelling", "Ambient sound"]),
        .init(name: "ambient_level", eventName: "ambient", index: 1, values: Array(1...20), label: "Ambient sound level"),
        .init(name: "voice_focus", eventName: "ambient", index: 3, values: [0, 1], label: "Ambient voice focus", labels: ["Off", "On"]),
        .init(name: "game_chat", eventName: "balance", index: 0, values: Array(stride(from: 0, through: 100, by: 10)), label: "Game/chat balance (50: center)"),
        .init(name: "sidetone", eventName: "sidetone", index: 0, values: Array(0...10), label: "Sidetone"),
        .init(name: "toggle_off", eventName: "nc_toggle", index: 0, values: [0, 1], label: "Button cycle: off", labels: ["Exclude", "Include"]),
        .init(name: "toggle_nc", eventName: "nc_toggle", index: 1, values: [0, 1], label: "Button cycle: noise cancelling", labels: ["Exclude", "Include"]),
        .init(name: "toggle_ambient", eventName: "nc_toggle", index: 2, values: [0, 1], label: "Button cycle: ambient", labels: ["Exclude", "Include"]),
        .init(name: "nc_startup", eventName: "nc_startup", index: 0, values: [0, 1, 2, 3], label: "Noise control at startup", labels: ["Off", "Noise cancelling", "Ambient", "Previous"]),
        .init(name: "bt_startup", eventName: "bt_startup", index: 0, values: [0, 1, 2], label: "Bluetooth at startup", labels: ["Off", "On", "Previous"]),
        .init(name: "auto_power", eventName: "auto_power", index: 0, values: [0, 5, 15, 30, 60, 180], label: "Automatic power off (minutes, 0: disabled)"),
        .init(name: "language", eventName: "language", index: 0, values: [0, 1, 2], label: "Voice guidance language", labels: ["English", "Japanese", "Chinese"]),
        .init(name: "guidance", eventName: "guidance", index: 0, values: [0, 1], label: "Voice guidance and notifications", labels: ["Off", "On"]),
    ]

    private var descriptor: Int32 = -1
    private var deviceLock: FileLock?
    private let operationLock = NSRecursiveLock()
    private let state = NSCondition()
    private let readerQueue = DispatchQueue(label: "inzone.hid.reader")
    private var readerSource: DispatchSourceRead?
    private var buffer: [UInt8] = []
    private var responsePackets: [ResponseEnvelope] = []
    private var activeResponse: ResponseKey?
    private var notificationParts: [NotificationKey: NotificationAssembly] = [:]
    private var notificationQueue: [DeviceNotification] = []
    private var notificationContinuations: [UUID: AsyncStream<DeviceNotification>.Continuation] = [:]
    private var notificationRevision: UInt64 = 0
    private var readerFailure: InzoneError?
    private var sequence = Int.random(in: 1...65534)

    public convenience init() throws {
        try self.init(home: InzonePaths().home)
    }

    public init(home: URL, deviceURL: URL? = nil) throws {
        let directory = home.appendingPathComponent(".config/inzone-h9-ii")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        deviceLock = try FileLock(url: directory.appendingPathComponent("device.lock"), nonblocking: true)
        do {
            let path = try deviceURL ?? Self.discover()
            descriptor = Glibc.open(path.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else { throw Self.systemError("Open H9 II HID device") }
            startReader()
        } catch {
            if descriptor >= 0 { _ = Glibc.close(descriptor); descriptor = -1 }
            deviceLock = nil
            throw error
        }
    }

    init(home: URL, ownedDescriptor: Int32) throws {
        guard ownedDescriptor >= 0 else { throw InzoneError.message("Invalid HID transport descriptor.") }
        deviceLock = try FileLock(url: home.appendingPathComponent(".config/inzone-h9-ii/device.lock"), nonblocking: true)
        descriptor = ownedDescriptor
        let flags = Glibc.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Glibc.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            _ = Glibc.close(descriptor)
            descriptor = -1
            deviceLock = nil
            throw Self.systemError("Configure H9 II HID transport")
        }
        startReader()
    }

    deinit { close() }

    public func close() {
        state.lock()
        let closingDescriptor = descriptor
        descriptor = -1
        let closingDeviceLock = deviceLock
        deviceLock = nil
        let source = readerSource
        readerSource = nil
        let continuations = Array(notificationContinuations.values)
        notificationContinuations.removeAll()
        state.broadcast()
        state.unlock()
        source?.cancel()
        if closingDescriptor >= 0 { _ = Glibc.close(closingDescriptor) }
        readerQueue.async { continuations.forEach { $0.finish() } }
        withExtendedLifetime(closingDeviceLock) {}
    }

    private func startReader() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: readerQueue)
        source.setEventHandler { [weak self] in self?.readAvailableReport() }
        readerSource = source
        source.resume()
    }

    public static func discover(sysDirectory: URL = URL(fileURLWithPath: "/sys/class/hidraw"),
                                deviceDirectory: URL = URL(fileURLWithPath: "/dev")) throws -> URL {
        let entries = (try? FileManager.default.contentsOfDirectory(at: sysDirectory, includingPropertiesForKeys: nil)) ?? []
        let found = entries.filter { entry in
            guard entry.lastPathComponent.hasPrefix("hidraw"),
                  let text = try? String(contentsOf: entry.appendingPathComponent("device/uevent"), encoding: .utf8) else { return false }
            return text.split(separator: "\n").contains { $0.uppercased() == "HID_ID=0003:0000054C:00000FA8" }
        }
        guard found.count == 1 else { throw InzoneError.message("Connect exactly one H9 II USB dongle.") }
        return deviceDirectory.appendingPathComponent(found[0].lastPathComponent)
    }

    private static func systemError(_ operation: String) -> InzoneError {
        .message("\(operation): \(String(cString: strerror(errno)))")
    }

    public func transact(_ name: String, kind: Int = 1, payload: Data = Data(), timeout: TimeInterval = 1.5) throws -> Data {
        try transactWithWatermark(name, kind: kind, payload: payload, timeout: timeout).payload
    }

    private func transactWithWatermark(_ name: String, kind: Int = 1, payload: Data = Data(),
                                       timeout: TimeInterval = 1.5) throws
        -> (payload: Data, notificationWatermark: UInt64) {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard timeout.isFinite, timeout > 0 else { throw InzoneError.message("HID transaction timeout must be positive and finite.") }
        guard let event = deviceEvents.first(where: { $0.name == name }) else { throw InzoneError.message("Unknown H9 II event: \(name)") }
        guard kind == 1 || (kind == 2 && event.writable) else {
            throw InzoneError.message("Unsupported H9 II command: \(name)")
        }

        sequence = sequence % 65535 + 1
        let expectedSequence = sequence
        let report = try HIDPacketCodec.command(event: event.identifier, kind: kind, sequence: expectedSequence, payload: payload)
        let expectedResponse = ResponseKey(event: event.identifier, sequence: expectedSequence,
                                           source: event.identifier == 1 ? 2 : 4,
                                           kind: kind == 2 ? 0x20 : 0x10)
        state.lock()
        guard descriptor >= 0 else { state.unlock(); throw InzoneError.message("H9 II device is closed.") }
        activeResponse = expectedResponse
        responsePackets.removeAll()
        let written = report.withUnsafeBytes { Glibc.write(descriptor, $0.baseAddress, $0.count) }
        if written != report.count {
            let error = Self.systemError("Send complete H9 II HID command")
            activeResponse = nil
            state.unlock()
            throw error
        }
        state.unlock()

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var parts = Data()
        var responseWatermark: UInt64 = 0
        state.lock()
        defer { activeResponse = nil; state.unlock() }
        while true {
            if let index = responsePackets.firstIndex(where: { expectedResponse.matches($0.packet) }) {
                let response = responsePackets.remove(at: index)
                responseWatermark = response.notificationRevision
                parts.append(response.packet.payload)
                guard parts.count <= 1024 else { throw InzoneError.message("Command response limit exceeded.") }
                if response.packet.payload.count < 50 {
                    guard parts.count >= event.minimumLength else { throw InzoneError.message("Device returned incomplete parameters.") }
                    return (parts, responseWatermark)
                }
                continue
            }
            if let readerFailure { throw readerFailure }
            guard descriptor >= 0 else { throw InzoneError.message("H9 II device is closed.") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { break }
            _ = state.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        throw DeviceTimeout(name: name)
    }

    public func notifications() -> AsyncStream<DeviceNotification> {
        AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation in
            let identifier = UUID()
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.removeNotificationContinuation(identifier)
            }
            state.lock()
            if descriptor < 0 || readerFailure != nil {
                state.unlock()
                continuation.finish()
                return
            }
            notificationContinuations[identifier] = continuation
            state.unlock()
        }
    }

    public func nextNotification(timeout: TimeInterval = 1.5) throws -> DeviceNotification? {
        guard timeout.isFinite, timeout > 0 else {
            throw InzoneError.message("HID notification timeout must be positive and finite.")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        state.lock()
        defer { state.unlock() }
        while notificationQueue.isEmpty {
            if let readerFailure { throw readerFailure }
            guard descriptor >= 0 else { throw InzoneError.message("H9 II device is closed.") }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            if remaining <= 0 { return nil }
            _ = state.wait(until: Date(timeIntervalSinceNow: remaining))
        }
        return notificationQueue.removeFirst()
    }

    private func removeNotificationContinuation(_ identifier: UUID) {
        state.lock()
        notificationContinuations.removeValue(forKey: identifier)
        state.unlock()
    }

    private func readAvailableReport() {
        var delivered: [DeviceNotification] = []
        var continuations: [AsyncStream<DeviceNotification>.Continuation] = []
        var failedContinuations: [AsyncStream<DeviceNotification>.Continuation] = []
        var failedSource: DispatchSourceRead?
        state.lock()
        guard descriptor >= 0 else { state.unlock(); return }
        var reportsRead = 0
        readLoop: while reportsRead < 64 {
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = Glibc.read(descriptor, &bytes, bytes.count)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { break }
                readerFailure = Self.systemError("Read H9 II response")
                break
            }
            if count == 0 {
                readerFailure = InzoneError.message("H9 II USB device disconnected.")
                break
            }
            reportsRead += 1
            guard bytes[0] == 2 else { continue }
            do {
                guard count >= 2, bytes[1] <= 62, count >= Int(bytes[1]) + 2 else {
                    throw InzoneError.message("Invalid HID report.")
                }
                buffer.append(contentsOf: bytes[2..<(2 + Int(bytes[1]))])
                guard buffer.count <= 2048 else {
                    buffer.removeAll()
                    throw InzoneError.message("HID response buffer limit exceeded.")
                }
                delivered.append(contentsOf: parseBufferedPackets())
            } catch {
                // Reset framing after a malformed report so later device notifications remain available.
                buffer.removeAll()
                continue readLoop
            }
        }
        if readerFailure != nil {
            continuations = Array(notificationContinuations.values)
            failedContinuations = continuations
            notificationContinuations.removeAll()
            failedSource = readerSource
            readerSource = nil
        } else {
            continuations = Array(notificationContinuations.values)
        }
        state.broadcast()
        state.unlock()

        failedSource?.cancel()
        for notification in delivered {
            continuations.forEach { $0.yield(notification) }
        }
        failedContinuations.forEach { $0.finish() }
    }

    private func parseBufferedPackets() -> [DeviceNotification] {
        var delivered: [DeviceNotification] = []
        while buffer.count >= 3 {
            guard buffer[0] == 4, buffer[1] == 0xff else {
                buffer.removeAll()
                break
            }
            let size = Int(buffer[2]) + 3
            if buffer.count < size { break }
            let raw = Data(buffer.prefix(size))
            buffer.removeFirst(size)
            // Ignore unsupported firmware update protocol traffic without exposing it as a device event.
            if raw.count > 7, raw[7] == 160 { continue }
            guard let packet = try? HIDPacketCodec.parsePacket(raw) else {
                buffer.removeAll()
                break
            }
            if packet.kind == 0xa0 {
                if let event = deviceEvents.first(where: { $0.identifier == packet.event }),
                   packet.source != (event.identifier == 1 ? 2 : 4) {
                    continue
                }
                let key = NotificationKey(event: packet.event, source: packet.source, sequence: packet.sequence)
                let now = ProcessInfo.processInfo.systemUptime
                notificationParts = notificationParts.filter { now - $0.value.updatedAt <= 5 }
                var payload = notificationParts.removeValue(forKey: key)?.payload ?? Data()
                payload.append(packet.payload)
                guard payload.count <= 1024 else { continue }
                if packet.payload.count == 50 {
                    notificationParts[key] = NotificationAssembly(payload: payload, updatedAt: now)
                    if notificationParts.count > 64 { notificationParts.removeValue(forKey: notificationParts.keys.first!) }
                    continue
                }
                if let event = deviceEvents.first(where: { $0.identifier == packet.event }),
                   payload.count < event.minimumLength {
                    continue
                }
                notificationRevision &+= 1
                if notificationRevision == 0 { notificationRevision = 1 }
                let notification = Self.makeNotification(event: packet.event, payload: payload,
                                                         revision: notificationRevision)
                notificationQueue.append(notification)
                if notificationQueue.count > 256 { notificationQueue.removeFirst(notificationQueue.count - 256) }
                delivered.append(notification)
            } else {
                if activeResponse?.matches(packet) == true {
                    if responsePackets.count < 22 {
                        responsePackets.append(ResponseEnvelope(packet: packet,
                                                                notificationRevision: notificationRevision))
                    }
                }
            }
        }
        return delivered
    }

    private static func makeNotification(event: Int, payload: Data, revision: UInt64) -> DeviceNotification {
        let eventName = deviceEvents.first(where: { $0.identifier == event })?.name ?? "event_\(event)"
        let decoded = decodedNotification(eventName: eventName, payload: Array(payload))
        return DeviceNotification(revision: revision, eventName: eventName, event: event, payload: payload,
                                  values: decoded.values, status: decoded.status)
    }

    public static func decodeNotification(event: Int, payload: Data) throws -> DeviceNotification {
        guard let definition = deviceEvents.first(where: { $0.identifier == event }),
              payload.count >= definition.minimumLength else {
            throw InzoneError.message("Unsupported or incomplete H9 II notification.")
        }
        return makeNotification(event: event, payload: payload, revision: 0)
    }

    private static func decodedNotification(eventName: String, payload: [UInt8])
        -> (values: [String: Int], status: [String: String]) {
        var values: [String: Int] = [:]
        var status: [String: String] = [:]
        for field in fields where field.eventName == eventName && payload.count > field.index {
            values[field.name] = Int(payload[field.index])
        }
        switch eventName {
        case "connection" where !payload.isEmpty:
            values["connected"] = payload[0] == 1 ? 1 : 0
        case "battery" where payload.count >= 2:
            values["battery_state"] = Int(payload[0])
            values["battery_percent"] = Int(payload[1])
            status["battery_state"] = [0: "discharging", 1: "charging", 2: "error"][Int(payload[0])] ?? "unknown"
        case "firmware" where payload.count >= 8:
            for (index, name) in ["headset", "dongle"].enumerated() {
                let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(payload[index * 4 + $1]) << ($1 * 8) }
                status["firmware_\(name)"] = versionString(value)
            }
        case "headphone" where payload.count >= 3:
            values["headphone_mute"] = Int(payload[0])
            values["headphone_volume"] = Int(payload[1])
            values["headphone_volume_percent"] = Int(payload[2])
            status["headphone_mute"] = [0: "unmuted", 1: "muted"][Int(payload[0])] ?? "unknown"
        case "microphone" where payload.count >= 3:
            values["headset_microphone_mute"] = Int(payload[0])
            values["headset_microphone_volume"] = Int(payload[1])
            values["headset_microphone_volume_percent"] = Int(payload[2])
            status["headset_microphone_mute"] = [0: "unmuted", 1: "muted"][Int(payload[0])] ?? "unknown"
        case "bluetooth" where payload.count >= 2:
            values["bluetooth_power"] = Int(payload[0])
            values["bluetooth_connection"] = Int(payload[1])
            status["bluetooth_power"] = [0: "off", 1: "on"][Int(payload[0])] ?? "unknown"
            status["bluetooth_connection"] = payload[0] == 0
                ? "not_applicable"
                : ([0: "unconnected", 1: "connected", 2: "pairing"][Int(payload[1])] ?? "unknown")
        case "mic_attached" where !payload.isEmpty:
            values["microphone_attached"] = payload[0] == 0 ? 1 : 0
        default:
            break
        }
        return (values, status)
    }

    private static func versionString(_ value: UInt32) -> String {
        let major = value & 255
        let minor = (value >> 8) & 4095
        let build = value >> 20
        let majorText = major <= 99 ? String(format: "%02u", major) : "--"
        let minorText = minor <= 999 ? String(format: "%03u", minor) : "---"
        let buildText = build <= 999 ? String(format: "%03u", build) : "---"
        return "\(majorText).\(minorText).\(buildText)"
    }

    public func snapshot() throws -> [String: Any] {
        try snapshotWithWatermarks().status
    }

    public func snapshotWithWatermarks() throws -> DeviceSnapshot {
        operationLock.lock()
        defer { operationLock.unlock() }
        let connection = try transactWithWatermark("connection")
        var data = ["connection": Array(connection.payload)]
        var watermarks = ["connection": connection.notificationWatermark]
        guard data["connection"]?.first == 1 else {
            return DeviceSnapshot(status: ["connected": false, "raw": data], watermarks: watermarks)
        }
        for event in deviceEvents where event.name != "connection" {
            do {
                let response = try transactWithWatermark(event.name)
                data[event.name] = Array(response.payload)
                watermarks[event.name] = response.notificationWatermark
            }
            catch is DeviceTimeout { continue }
        }
        return DeviceSnapshot(status: Self.describe(data), watermarks: watermarks)
    }

    public func observe() throws -> DeviceObservation {
        operationLock.lock()
        defer { operationLock.unlock() }
        let stream = notifications()
        return DeviceObservation(snapshot: try snapshotWithWatermarks(), notifications: stream)
    }

    public func setField(_ name: String, value: Int) throws {
        try setField(name, value: value, verificationTimeout: 1.5)
    }

    func setField(_ name: String, value: Int, verificationTimeout: TimeInterval) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard verificationTimeout.isFinite, verificationTimeout > 0 else {
            throw InzoneError.message("Device verification timeout must be positive and finite.")
        }
        guard let field = Self.fields.first(where: { $0.name == name }), field.values.contains(value) else {
            throw InzoneError.message("Unknown device field or out-of-range value: \(name)")
        }
        var payload = Array(try transact(field.eventName))
        if payload[field.index] == value { return }
        payload[field.index] = UInt8(value)
        if field.eventName == "nc_toggle", payload.prefix(3).reduce(0, { $0 + Int($1) }) < 2 {
            throw InzoneError.message("The noise-control button must include at least two modes.")
        }
        if field.eventName == "auto_power", value != 0 { payload[1] = UInt8(value) }
        _ = try transact(field.eventName, kind: 2, payload: Data(payload))
        let deadline = ProcessInfo.processInfo.systemUptime + verificationTimeout
        var lastObserved: Int?
        repeat {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            do {
                let observed = Array(try transact(field.eventName, timeout: remaining))
                lastObserved = Int(observed[field.index])
                if lastObserved == value { return }
            } catch is DeviceTimeout {
                break
            }
            // Verify convergence without repeating a command the headset may have already applied.
            let delay = min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime))
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        } while ProcessInfo.processInfo.systemUptime < deadline
        let observed = lastObserved.map(String.init) ?? "no reply"
        throw InzoneError.message(
            "Unconfirmed \(field.name): requested \(value), observed \(observed)."
        )
    }

    public static func describe(_ data: [String: [UInt8]]) -> [String: Any] {
        var values: [String: Int] = [:]
        for field in fields {
            if let payload = data[field.eventName], payload.count > field.index { values[field.name] = Int(payload[field.index]) }
        }
        var result: [String: Any] = ["connected": true, "fields": values]
        if let battery = data["battery"], battery.count >= 2 {
            let states = [0: "discharging", 1: "charging", 2: "error"]
            result["battery"] = ["percent": battery[1] <= 100 ? Int(battery[1]) as Any : NSNull(),
                                 "state": states[Int(battery[0])] ?? "unknown"]
        }
        if let firmware = data["firmware"], firmware.count >= 8 {
            var versions: [String: String] = [:]
            for (index, name) in ["headset", "dongle"].enumerated() {
                let value = (0..<4).reduce(UInt32(0)) { $0 | UInt32(firmware[index * 4 + $1]) << ($1 * 8) }
                versions[name] = versionString(value)
            }
            result["firmware"] = versions
        }
        if let headphone = data["headphone"], headphone.count >= 3 {
            result["headphone"] = [
                "muted": headphone[0] == 1,
                "mute_value": Int(headphone[0]),
                "volume": Int(headphone[1]),
                "percent": headphone[2] == 255 ? NSNull() as Any : Int(headphone[2]) as Any,
            ]
        }
        if let microphone = data["microphone"], microphone.count >= 3 {
            result["microphone_muted"] = microphone[0] == 1
            result["microphone"] = [
                "muted": microphone[0] == 1,
                "mute_value": Int(microphone[0]),
                "volume": microphone[1] == 255 ? NSNull() as Any : Int(microphone[1]) as Any,
                "percent": microphone[2] == 255 ? NSNull() as Any : Int(microphone[2]) as Any,
            ]
        }
        if let attached = data["mic_attached"]?.first { result["microphone_attached"] = attached == 0 }
        if let bluetooth = data["bluetooth"], bluetooth.count >= 2 {
            let powerStates = [0: "off", 1: "on"]
            let connectionStates = [0: "unconnected", 1: "connected", 2: "pairing"]
            result["bluetooth"] = [
                "power": powerStates[Int(bluetooth[0])] ?? "unknown",
                "power_value": Int(bluetooth[0]),
                "connection": bluetooth[0] == 0
                    ? "not_applicable"
                    : (connectionStates[Int(bluetooth[1])] ?? "unknown"),
                "connection_value": Int(bluetooth[1]),
            ]
        }
        // Model and serial bytes are excluded from the public status representation.
        return result
    }

    public static func hostLevels(runner: any CommandRunning) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for category in ["sinks", "sources"] {
            let output = try runner.run(["pactl", "-f", "json", "list", category], input: nil, timeout: 5)
            guard let nodes = try JSONSupport.decode(Data(output.utf8)) as? [[String: Any]] else { throw InzoneError.message("Invalid host audio status.") }
            for (key, target, nodeCategory) in hostTargets where category == nodeCategory {
                guard let node = nodes.first(where: { $0["name"] as? String == target }),
                      let volumes = node["volume"] as? [String: [String: Any]],
                      let first = volumes["front-left"] ?? volumes["mono"] ?? volumes.keys.sorted().first.flatMap({ volumes[$0] }),
                      let percent = first["value_percent"] as? String,
                      let value = Int(percent.replacingOccurrences(of: "%", with: "")) else { continue }
                result[key] = value
                if key == "mic_volume", let muted = node["mute"] as? Bool { result["mic_mute"] = muted ? 1 : 0 }
            }
        }
        return result
    }

    public static func setHostField(_ name: String, value: Int, runner: any CommandRunning) throws {
        let arguments: [String]
        if name == "mic_mute", (0...1).contains(value) {
            arguments = ["pactl", "set-source-mute", microphoneTarget, String(value)]
        } else if let (_, target, category) = hostTargets.first(where: { $0.0 == name }), (0...100).contains(value) {
            arguments = ["pactl", category == "sinks" ? "set-sink-volume" : "set-source-volume", target, "\(value)%"]
        } else { throw InzoneError.message("Invalid host audio field or value.") }
        _ = try runner.run(arguments, input: nil, timeout: 5)
    }
}

private let gameTarget = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
private let microphoneTarget = "alsa_input.usb-Sony_INZONE_H9_II-00.mono-chat"
private let hostTargets = [
    ("game_volume", gameTarget, "sinks"),
    ("chat_volume", "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat", "sinks"),
    ("mic_volume", microphoneTarget, "sources"),
]

public final class MicrophoneMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var expiry: DispatchWorkItem?
    private var identifier: UUID?

    public init() {}
    deinit { stop() }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        expiry?.cancel()
        expiry = nil
        identifier = nil
        Self.terminate(process)
        process = nil
        let next = Process()
        next.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        let guardProperties = "{ node.dont-fallback = true node.dont-reconnect = true }"
        next.arguments = ["pw-loopback", "-n", "inzone.mic-test", "-c", "1", "-m", "MONO",
                          "-C", microphoneTarget, "-P", gameTarget, "-i", guardProperties, "-o", guardProperties]
        next.standardOutput = FileHandle.nullDevice
        next.standardError = FileHandle.nullDevice
        try next.run()
        process = next
        let current = UUID()
        identifier = current
        let task = DispatchWorkItem { [weak self] in self?.expire(current) }
        expiry = task
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: task)
    }

    public func stop() {
        lock.lock()
        let running = process
        process = nil
        identifier = nil
        expiry?.cancel()
        expiry = nil
        lock.unlock()
        Self.terminate(running)
    }

    private func expire(_ expected: UUID) {
        lock.lock()
        guard identifier == expected else { lock.unlock(); return }
        let running = process
        process = nil
        identifier = nil
        expiry = nil
        lock.unlock()
        Self.terminate(running)
    }

    private static func terminate(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { usleep(10_000) }
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}
