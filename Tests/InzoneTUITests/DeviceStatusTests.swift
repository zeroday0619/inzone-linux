import Foundation
import Testing
import SwiftTUI
import InzoneCore
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

    @Test func connectedSnapshotDecodesHardwareBluetoothAndMicrophoneStatus() {
        let status = TerminalDeviceStatus(snapshot: [
            "connected": true,
            "headphone": ["volume": 17, "percent": 57],
            "bluetooth": ["power": "on", "connection": "pairing"],
            "microphone_attached": true,
            "microphone": ["muted": true],
        ])
        #expect(status.headphoneHardwareVolume == 17)
        #expect(status.headphoneHardwareVolumePercent == 57)
        #expect(status.hardwareVolumeLabel == "17 / 30 · 57%")
        #expect(status.bluetoothPowerLabel == "On")
        #expect(status.bluetoothConnectionLabel == "Pairing")
        #expect(status.microphoneAttachmentLabel == "Attached")
        #expect(status.microphoneMuteLabel == "Muted")
    }

    @Test func decodedStateLabelsCoverEveryReportedBluetoothAndMicrophoneState() {
        for (power, expected) in [("off", "Off"), ("on", "On"), ("unexpected", "Unknown")] {
            let status = TerminalDeviceStatus(snapshot: [
                "connected": true,
                "bluetooth": ["power": power, "connection": "not_applicable"],
            ])
            #expect(status.bluetoothPowerLabel == expected)
        }
        for (connection, expected) in [
            ("not_applicable", "Not applicable"), ("unconnected", "Unconnected"),
            ("connected", "Connected"), ("pairing", "Pairing"), ("unexpected", "Unknown"),
        ] {
            let status = TerminalDeviceStatus(snapshot: [
                "connected": true,
                "bluetooth": ["power": "on", "connection": connection],
            ])
            #expect(status.bluetoothConnectionLabel == expected)
        }
        for (attached, muted, attachmentLabel, muteLabel) in [
            (true, true, "Attached", "Muted"),
            (false, false, "Detached", "Unmuted"),
        ] {
            let status = TerminalDeviceStatus(snapshot: [
                "connected": true,
                "microphone_attached": attached,
                "microphone_muted": muted,
            ])
            #expect(status.microphoneAttachmentLabel == attachmentLabel)
            #expect(status.microphoneMuteLabel == muteLabel)
        }
    }

    @Test func notificationPatchesMergeWithoutErasingUnrelatedStatus() throws {
        var status = TerminalDeviceStatus(snapshot: [
            "connected": true,
            "battery": ["percent": 85, "state": "charging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
            "headphone": ["volume": 17, "percent": 57],
            "bluetooth": ["power": "on", "connection": "connected"],
            "microphone_attached": true,
            "microphone": ["muted": false],
        ])

        status.apply(try InzoneDevice.decodeNotification(event: 97, payload: Data([0, 3])))
        status.apply(try InzoneDevice.decodeNotification(event: 36, payload: Data([1, 255, 255])))

        #expect(status.bluetoothPowerLabel == "Off")
        #expect(status.bluetoothConnectionLabel == "Not applicable")
        #expect(status.microphoneMuteLabel == "Muted")
        #expect(status.microphoneAttachmentLabel == "Attached")
        #expect(status.hardwareVolumeLabel == "17 / 30 · 57%")
        #expect(status.batteryPercent == 85)
        #expect(status.headsetFirmware == "1.2.3.4")
        #expect(status.dongleFirmware == "5.6.7.8")
    }

    @Test func notificationPatchesValidateUnavailablePercentAndVolumeSentinels() throws {
        var status = TerminalDeviceStatus(snapshot: ["connected": true])
        status.apply(try InzoneDevice.decodeNotification(event: 33, payload: Data([0, 31, 255])))
        #expect(status.headphoneHardwareVolume == nil)
        #expect(status.headphoneHardwareVolumePercent == nil)
        #expect(status.hardwareVolumeLabel == "Not reported")
    }

    @Test func disconnectNotificationClearsPreviouslyReportedHardwareState() throws {
        var status = TerminalDeviceStatus(snapshot: [
            "connected": true,
            "battery": ["percent": 85, "state": "charging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
            "headphone": ["volume": 20, "percent": 67],
            "bluetooth": ["power": "on", "connection": "connected"],
            "microphone_attached": true,
            "microphone": ["muted": true],
        ])
        status.apply(try InzoneDevice.decodeNotification(event: 1, payload: Data([0])))
        #expect(status.connection == .disconnected)
        #expect(status.batteryPercent == nil)
        #expect(status.headsetFirmware == nil)
        #expect(status.dongleFirmware == nil)
        #expect(status.hardwareVolumeLabel == "Not reported")
        #expect(status.bluetoothPowerLabel == "Not reported")
        #expect(status.microphoneAttachmentLabel == "Not reported")
        #expect(status.microphoneMuteLabel == "Not reported")
    }

    @Test func disconnectedStatusIgnoresLaterNonConnectionNotifications() throws {
        var status = TerminalDeviceStatus(snapshot: [
            "connected": true,
            "battery": ["percent": 75, "state": "discharging"],
        ])
        status.apply(try InzoneDevice.decodeNotification(event: 1, payload: Data([0])))
        status.apply(try InzoneDevice.decodeNotification(event: 4, payload: Data([1, 99])))
        #expect(status.connection == .disconnected)
        #expect(status.batteryPercent == nil)
        #expect(status.powerState == "unknown")
    }

    @Test func statusCardsPreserveCompleteValuesAcrossSupportedWidths() {
        let status = TerminalDeviceStatus(snapshot: [
            "connected": true,
            "battery": ["percent": 85, "state": "charging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
            "headphone": ["volume": 17, "percent": 57],
            "bluetooth": ["power": "on", "connection": "connected"],
            "microphone_attached": true,
            "microphone": ["muted": true],
        ])
        for columns in [70, 72, 78, 88, 112] {
            let rendered = ViewRenderer.render(
                TerminalDeviceStatusView(status: status),
                proposedSize: ProposedViewSize(columns: columns, rows: 5)
            )
            #expect(rendered.size.columns == columns)
            #expect(rendered.size.rows == 5)
            for label in [
                "Battery", "Connection", "Firmware", "85%  Charging", "Connected",
                "Volume 17 / 30 · 57%", "BT On · Connected", "Mic Attached · Muted",
                "Headset 1.2.3.4", "Dongle  5.6.7.8",
            ] {
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
