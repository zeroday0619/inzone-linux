import SwiftTUI

enum TerminalDeviceSection: String, CaseIterable {
    case noise = "Noise", sound = "Sound", microphone = "Mic", system = "System", info = "Info"

    static func section(for key: String) -> Self {
        switch key {
        case "anc", "ambient_level", "voice_focus": .noise
        case "game_chat", "game_volume", "chat_volume": .sound
        case "sidetone", "mic_volume", "mic_mute": .microphone
        default: .system
        }
    }

    func swiped(columns: Int, rows: Int) -> Self? {
        guard columns.magnitude >= 4, columns.magnitude / 2 >= rows.magnitude,
              let index = Self.allCases.firstIndex(of: self) else { return nil }
        let next = min(Self.allCases.count - 1, max(0, index + (columns < 0 ? 1 : -1)))
        return next == index ? nil : Self.allCases[next]
    }
}

@MainActor
struct TerminalDeviceTabs: View {
    let selected: TerminalDeviceSection
    let columns: Int
    var enabled = true
    let onSelect: (TerminalDeviceSection) -> Void
    @GestureState private var pressed: TerminalDeviceSection?

    var body: some View {
        TerminalEqualColumns(spacing: 1) {
            ForEach(TerminalDeviceSection.allCases, id: \.self) { section in
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Text(section.rawValue).bold(section == selected)
                    Spacer(minLength: 0)
                }
                .frame(height: 3)
                .foregroundStyle(enabled ? TerminalTheme.text : TerminalTheme.muted)
                .background(pressed == section ? TerminalTheme.pressed
                    : (selected == section ? TerminalTheme.raised : TerminalTheme.background))
            }
        }
        .frame(width: columns, height: 3)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($pressed) { value, state, _ in
                    state = value.translation.columns.magnitude < 4 ? section(at: value.startLocation) : nil
                }
                .onEnded { value in
                    if let next = selected.swiped(columns: value.translation.columns, rows: value.translation.rows) {
                        onSelect(next)
                    } else if value.translation.columns.magnitude <= 1, value.translation.rows.magnitude <= 1,
                              let target = section(at: value.startLocation), section(at: value.location) == target {
                        onSelect(target)
                    }
                },
            isEnabled: enabled
        )
    }

    private func section(at point: Point) -> TerminalDeviceSection? {
        guard point.row >= 0, point.row < 3, point.column >= 0, point.column < columns else { return nil }
        let count = TerminalDeviceSection.allCases.count
        let available = max(0, columns - count + 1)
        let width = available / count
        let remainder = available % count
        var first = 0
        for (index, section) in TerminalDeviceSection.allCases.enumerated() {
            let size = width + (index < remainder ? 1 : 0)
            if point.column >= first && point.column < first + size { return section }
            first += size + 1
        }
        return nil
    }
}

@MainActor
struct TerminalDeviceOverview: View {
    let status: TerminalDeviceStatus

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(status.connectionLabel).bold()
                Spacer(minLength: 0)
                Text(status.batteryPercent == nil ? "Battery unavailable" : status.percentLabel + " · " + status.powerLabel)
                    .foregroundStyle((status.batteryPercent ?? 100) <= 20 || status.powerState == "error"
                        ? TerminalTheme.danger : TerminalTheme.text)
            }
            HStack {
                Spacer(minLength: 0)
                Text(status.batteryPercent == nil ? "" : status.meter).foregroundStyle(TerminalTheme.muted)
            }
        }
        .frame(height: 2)
    }
}
