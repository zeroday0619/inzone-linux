import SwiftTUI

struct TerminalDeviceStatus: Sendable {
    enum Connection: Sendable { case reading, connected, disconnected, unavailable }
    var connection = Connection.reading
    var batteryPercent: Int?
    var powerState = "unknown"
    var headsetFirmware: String?
    var dongleFirmware: String?

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
    var meter: String {
        guard let batteryPercent else { return "Not reported" }
        let filled = batteryPercent == 0 ? 0 : max(1, batteryPercent / 10)
        return String(repeating: "━", count: filled) + String(repeating: "─", count: 10 - filled)
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
                Text(status.connectionLabel).bold()
                    .foregroundStyle(TerminalTheme.text)
                Text(status.connection == .connected ? "USB wireless" : "Refresh to check").foregroundStyle(TerminalTheme.muted)
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
        .padding(1)
        .frame(height: 5)
    }
}
