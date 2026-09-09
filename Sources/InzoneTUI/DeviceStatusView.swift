import SwiftTUI
import InzoneCore

struct TerminalDeviceStatus: Sendable {
    enum Connection: Sendable { case reading, connected, disconnected, unavailable }
    var connection = Connection.reading
    var batteryPercent: Int?
    var powerState = "unknown"
    var headsetFirmware: String?
    var dongleFirmware: String?
    var headphoneHardwareVolume: Int?
    var headphoneHardwareVolumePercent: Int?
    var bluetoothPowerState = "unknown"
    var bluetoothConnectionState = "unknown"
    var microphoneAttached: Bool?
    var microphoneMuted: Bool?

    init() {}

    init(snapshot: [String: Any]) {
        if let connected = snapshot["connected"] as? Bool {
            connection = connected ? .connected : .disconnected
        } else {
            connection = .unavailable
        }
        guard connection == .connected else { return }
        if let battery = snapshot["battery"] as? [String: Any] {
            if let percent = battery["percent"] as? Int, (0...100).contains(percent) { batteryPercent = percent }
            powerState = battery["state"] as? String ?? "unknown"
        }
        if let firmware = snapshot["firmware"] as? [String: String] {
            headsetFirmware = firmware["headset"]
            dongleFirmware = firmware["dongle"]
        }
        if let headphone = snapshot["headphone"] as? [String: Any] {
            headphoneHardwareVolume = Self.validHardwareVolume(headphone["volume"] as? Int)
            headphoneHardwareVolumePercent = Self.validPercent(headphone["percent"] as? Int)
        }
        if let bluetooth = snapshot["bluetooth"] as? [String: Any] {
            bluetoothPowerState = bluetooth["power"] as? String ?? "unknown"
            bluetoothConnectionState = bluetooth["connection"] as? String ?? "unknown"
        }
        microphoneAttached = snapshot["microphone_attached"] as? Bool
        if let microphone = snapshot["microphone"] as? [String: Any] {
            microphoneMuted = microphone["muted"] as? Bool
        } else {
            microphoneMuted = snapshot["microphone_muted"] as? Bool
        }
    }

    mutating func apply(_ notification: DeviceNotification) {
        if connection == .disconnected, notification.values["connected"] == nil {
            return
        }
        if let connected = notification.values["connected"] {
            connection = connected == 1 ? .connected : .disconnected
            if connected != 1 {
                batteryPercent = nil
                powerState = "unknown"
                headsetFirmware = nil
                dongleFirmware = nil
                headphoneHardwareVolume = nil
                headphoneHardwareVolumePercent = nil
                bluetoothPowerState = "unknown"
                bluetoothConnectionState = "unknown"
                microphoneAttached = nil
                microphoneMuted = nil
                return
            }
        }
        if let percent = notification.values["battery_percent"] {
            batteryPercent = Self.validPercent(percent)
        }
        if let state = notification.status["battery_state"] {
            powerState = state
        } else if let state = notification.values["battery_state"] {
            powerState = [0: "discharging", 1: "charging", 2: "error"][state] ?? "unknown"
        }
        if let version = notification.status["firmware_headset"] { headsetFirmware = version }
        if let version = notification.status["firmware_dongle"] { dongleFirmware = version }
        if let volume = notification.values["headphone_volume"] {
            headphoneHardwareVolume = Self.validHardwareVolume(volume)
        }
        if let percent = notification.values["headphone_volume_percent"] {
            headphoneHardwareVolumePercent = Self.validPercent(percent)
        }
        if let state = notification.status["bluetooth_power"] { bluetoothPowerState = state }
        if let state = notification.status["bluetooth_connection"] { bluetoothConnectionState = state }
        if let attached = notification.values["microphone_attached"] { microphoneAttached = attached == 1 }
        if let muted = notification.values["headset_microphone_mute"] { microphoneMuted = muted == 1 }
    }

    private static func validPercent(_ value: Int?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return value
    }

    private static func validHardwareVolume(_ value: Int?) -> Int? {
        guard let value, (0...30).contains(value) else { return nil }
        return value
    }

    var connectionLabel: String {
        switch connection {
        case .reading: "Checking"
        case .connected: "Connected"
        case .disconnected: "Disconnected"
        case .unavailable: "Unavailable"
        }
    }

    var powerLabel: String {
        guard connection == .connected else { return "Not reported" }
        switch powerState {
        case "charging": return "Charging"
        case "discharging": return "On battery"
        case "error": return "Charge error"
        default: return "Unknown"
        }
    }

    var percentLabel: String { batteryPercent.map { "\($0)%" } ?? "—" }
    var batteryLine: String { "Battery: " + percentLabel + " · " + powerLabel }
    var firmwareLine: String { "Firmware: Headset \(headsetFirmware ?? "—") / Dongle \(dongleFirmware ?? "—")" }
    var hardwareVolumeLabel: String {
        guard connection == .connected, let headphoneHardwareVolume else { return "Not reported" }
        let level = "\(headphoneHardwareVolume) / 30"
        return headphoneHardwareVolumePercent.map { level + " · \($0)%" } ?? level
    }
    var bluetoothPowerLabel: String {
        guard connection == .connected else { return "Not reported" }
        return Self.label(bluetoothPowerState, labels: ["off": "Off", "on": "On"])
    }
    var bluetoothConnectionLabel: String {
        guard connection == .connected else { return "Not reported" }
        return Self.label(bluetoothConnectionState, labels: [
            "not_applicable": "Not applicable", "unconnected": "Unconnected",
            "connected": "Connected", "pairing": "Pairing",
        ])
    }
    var microphoneAttachmentLabel: String {
        guard connection == .connected else { return "Not reported" }
        return microphoneAttached.map { $0 ? "Attached" : "Detached" } ?? "Not reported"
    }
    var microphoneMuteLabel: String {
        guard connection == .connected else { return "Not reported" }
        return microphoneMuted.map { $0 ? "Muted" : "Unmuted" } ?? "Not reported"
    }
    var bluetoothLine: String {
        guard bluetoothPowerLabel != "Not reported" else { return "BT Not reported" }
        if bluetoothPowerState == "off" { return "BT " + bluetoothPowerLabel }
        return "BT " + bluetoothPowerLabel + " · " + bluetoothConnectionLabel
    }
    var microphoneLine: String {
        "Mic " + microphoneAttachmentLabel + " · " + microphoneMuteLabel
    }
    var meter: String {
        guard let batteryPercent else { return "Not reported" }
        let filled = batteryPercent == 0 ? 0 : max(1, batteryPercent / 10)
        return String(repeating: "━", count: filled) + String(repeating: "─", count: 10 - filled)
    }

    private static func label(_ value: String, labels: [String: String]) -> String {
        labels[value] ?? "Unknown"
    }
}

@MainActor
struct TerminalDeviceStatusView: View {
    let status: TerminalDeviceStatus

    private var batteryColor: TrueColor {
        if status.powerState == "error" { return TerminalTheme.danger }
        guard let percent = status.batteryPercent else { return TerminalTheme.muted }
        if percent <= 20 { return TerminalTheme.danger }
        return TerminalTheme.text
    }

    var body: some View {
        TerminalEqualColumns(spacing: 2) {
            card("Battery") {
                Text(status.percentLabel + "  " + status.powerLabel).bold().foregroundStyle(batteryColor)
                Text(status.meter).foregroundStyle(TerminalTheme.muted)
            }
            card("Connection") {
                Text(status.connectionLabel).bold().foregroundStyle(TerminalTheme.text)
                Text("Volume " + status.hardwareVolumeLabel).foregroundStyle(TerminalTheme.muted)
                Text(status.bluetoothLine).foregroundStyle(TerminalTheme.muted)
                Text(status.microphoneLine).foregroundStyle(TerminalTheme.muted)
            }
            card("Firmware") {
                Text("Headset " + terminalText(status.headsetFirmware ?? "—"))
                Text("Dongle  " + terminalText(status.dongleFirmware ?? "—"))
            }
        }
        .frame(height: 5)
        .background(TerminalTheme.surface)
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(TerminalTheme.muted)
                content()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1)
        .frame(height: 5)
    }
}
