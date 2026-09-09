import Foundation
import Testing
import SwiftTUI
import InzoneCore
@testable import InzoneTUI

@MainActor
struct VisualPreviewTests {
    @Test func exportRenderedScreensWhenRequested() throws {
        guard let directory = ProcessInfo.processInfo.environment["INZONE_TUI_PREVIEW_DIRECTORY"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (columns, rows) in [(72, 24), (120, 36)] {
            for (name, screen, controls) in [
                ("profile", TerminalScreen.profiles, false),
                ("profile-controls", .profiles, true),
                ("device-tools", .profiles, true),
                ("equalizer", .equalizer, false),
                ("equalizer-example", .equalizer, false),
                ("device", .device, false),
                ("presets", .presets, false),
                ("automation", .automation, false),
                ("prompt", .prompt, false),
            ] {
                // The worker-free model keeps visual inspection independent of hardware and user configuration.
                let model = TerminalModel()
                model.selected = 1
                model.screen = screen
                if name == "equalizer-example" {
                    model.equalizer = [4, 3, -2, -6, 0, 2, 6, 3, -1, -4]
                    model.equalizerIndex = 6
                }
                model.showsProfileControls = controls
                model.showsSystemControls = name == "device-tools"
                model.promptTitle = "Import profile"
                model.promptText = "/path/to/profile.json"
                let rendered = ViewRenderer.render(
                    TerminalRoot(model: model).frame(width: columns, height: rows),
                    proposedSize: ProposedViewSize(columns: columns, rows: rows))
                #expect(rendered.size.columns == columns)
                #expect(rendered.size.rows == rows)
                try rendered.ansiText.write(to: output.appendingPathComponent("\(name)-\(columns)x\(rows).ansi"),
                    atomically: true, encoding: .utf8)
            }
            var fields = Dictionary(uniqueKeysWithValues: InzoneDevice.fields.map { ($0.name, $0.values[0]) })
            fields.merge(["anc": 1, "ambient_level": 12, "game_chat": 50, "sidetone": 5,
                          "toggle_nc": 1, "toggle_ambient": 1, "nc_startup": 3,
                          "bt_startup": 2, "auto_power": 30, "guidance": 1]) { _, value in value }
            let device = TerminalModel(previewDeviceSnapshot: [
                "connected": true, "fields": fields,
                "battery": ["percent": 85, "state": "discharging"],
                "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
            ], hostLevels: ["game_volume": 80, "chat_volume": 60, "mic_volume": 70, "mic_mute": 0])
            for section in TerminalDeviceSection.allCases {
                device.selectDeviceSection(section)
                let rendered = ViewRenderer.render(
                    TerminalRoot(model: device).frame(width: columns, height: rows),
                    proposedSize: ProposedViewSize(columns: columns, rows: rows))
                #expect(rendered.size.columns == columns)
                #expect(rendered.size.rows == rows)
                try rendered.ansiText.write(to: output.appendingPathComponent("device-\(section.rawValue.lowercased())-\(columns)x\(rows).ansi"),
                    atomically: true, encoding: .utf8)
            }
        }
        let status = TerminalDeviceStatus(snapshot: [
            "connected": true, "battery": ["percent": 85, "state": "charging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
        ])
        let rendered = ViewRenderer.render(TerminalDeviceStatusView(status: status),
            proposedSize: ProposedViewSize(columns: 70, rows: 5))
        try rendered.ansiText.write(to: output.appendingPathComponent("device-connected.ansi"),
            atomically: true, encoding: .utf8)
    }
}
