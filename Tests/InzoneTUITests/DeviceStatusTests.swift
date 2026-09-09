import Foundation
import Testing
import SwiftTUI
@testable import InzoneTUI

@MainActor
struct DeviceStatusTests {
    @Test func missingAndInvalidBatteryPercentRemainUnreported() {
        let batteries: [[String: Any]] = [
            [:], ["percent": NSNull()], ["percent": -1], ["percent": 101],
        ]
        for battery in batteries {
            let status = TerminalDeviceStatus(snapshot: ["connected": true, "battery": battery])
            #expect(status.batteryPercent == nil)
            #expect(status.percentLabel == "—")
            #expect(status.meter == "Not reported")
            #expect(status.powerLabel == "Unknown")
            #expect(!status.batteryLine.contains("0%"))
            #expect(!status.batteryLine.contains("Discharging"))
        }
        let missingBattery = TerminalDeviceStatus(snapshot: ["connected": true])
        #expect(missingBattery.batteryPercent == nil)
        #expect(missingBattery.powerLabel == "Unknown")
    }

    @Test func chargeStatesPreserveReportedMeaning() {
        for (state, label) in [
            ("charging", "Charging"), ("discharging", "On battery"),
            ("error", "Charge error"), ("unknown", "Unknown"), ("unexpected", "Unknown"),
        ] {
            let status = TerminalDeviceStatus(snapshot: [
                "connected": true, "battery": ["percent": 85, "state": state],
            ])
            #expect(status.percentLabel == "85%")
            #expect(status.powerLabel == label)
            #expect(status.meter.count == 10)
        }
    }

    @Test func validBatteryEndpointsRemainDistinctFromMissingData() {
        for percent in [0, 1, 20, 85, 100] {
            let status = TerminalDeviceStatus(snapshot: [
                "connected": true, "battery": ["percent": percent],
            ])
            #expect(status.percentLabel == "\(percent)%")
            #expect(status.meter.count == 10)
            #expect(status.meter != "Not reported")
        }
    }

    @Test func disconnectedSnapshotDiscardsStaleBatteryAndFirmware() {
        let status = TerminalDeviceStatus(snapshot: [
            "connected": false,
            "battery": ["percent": 85, "state": "charging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
        ])
        #expect(status.connectionLabel == "Disconnected")
        #expect(status.batteryPercent == nil)
        #expect(status.percentLabel == "—")
        #expect(status.powerLabel == "Not reported")
        #expect(status.headsetFirmware == nil)
        #expect(status.dongleFirmware == nil)
    }

    @Test func statusCardsPreserveCompleteValuesAcrossSupportedWidths() {
        let status = TerminalDeviceStatus(snapshot: [
            "connected": true,
            "battery": ["percent": 85, "state": "charging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
        ])
        for columns in [70, 78, 88, 112] {
            let rendered = ViewRenderer.render(
                TerminalDeviceStatusView(status: status),
                proposedSize: ProposedViewSize(columns: columns, rows: 5)
            )
            #expect(rendered.size.columns == columns)
            #expect(rendered.size.rows == 5)
            for label in ["Battery", "Connection", "Firmware", "85%  Charging", "Connected", "USB wireless", "Headset 1.2.3.4", "Dongle  5.6.7.8"] {
                #expect(rendered.text.contains(label), "\(columns) columns: missing \(label)")
            }
            for line in rendered.lines {
                #expect(RunGroup(line).measure().maximumContentColumns == columns)
            }
        }
    }

    @Test func equalColumnsKeepFlexibleActionsWithinEvenlyDistributedCells() {
        for columns in [69, 71, 77, 87, 111] {
            let rendered = ViewRenderer.render(
                TerminalEqualColumns(spacing: 2) {
                    TerminalAction(title: "A", width: nil, action: {})
                    TerminalAction(title: "B", width: nil, action: {})
                    TerminalAction(title: "C", width: nil, action: {})
                },
                proposedSize: ProposedViewSize(columns: columns, rows: nil)
            )
            #expect(rendered.size.columns == columns)
            #expect(rendered.size.rows == 3)
            let cells = Array(rendered.lines[1])
            let contentColumns = columns - 4
            var start = 0
            for (index, title) in Array("ABC").enumerated() {
                let width = contentColumns / 3 + (index < contentColumns % 3 ? 1 : 0)
                let position = cells.firstIndex(of: title)
                #expect(position != nil)
                if let position {
                    #expect(position >= start && position < start + width)
                    #expect(abs(position - (start + width / 2)) <= 1)
                }
                start += width + (index < 2 ? 2 : 0)
            }
            #expect(start == columns)
        }
    }
}
