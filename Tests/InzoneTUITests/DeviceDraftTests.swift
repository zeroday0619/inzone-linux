import Foundation
import Testing
import SwiftTUI
import InzoneCore
@testable import SwiftTUIEssentials
@testable import InzoneTUI

@MainActor
struct DeviceDraftTests {
    private func model() -> TerminalModel {
        let fields = Dictionary(uniqueKeysWithValues: InzoneDevice.fields.map { ($0.name, $0.values[0]) })
        return TerminalModel(previewDeviceSnapshot: [
            "connected": true,
            "battery": ["percent": 85, "state": "discharging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
            "fields": fields,
        ], hostLevels: ["game_volume": 50, "chat_volume": 50, "mic_volume": 50, "mic_mute": 0])
    }

    @Test func selectionAndWorkspaceNavigationPreserveIndependentChanges() {
        let model = model()
        model.adjustDeviceValue(at: 0, direction: 1)
        model.adjustDeviceValue(at: 1, direction: 1)
        #expect(model.pendingDeviceCount == 2)
        #expect(model.pendingDeviceValue(at: 0) == 1)
        #expect(model.pendingDeviceValue(at: 1) == 1)
        model.selectRow(0)
        #expect(model.devicePending == 1)
        _ = model.handle(KeyPress(key: .downArrow, characters: ""), terminate: {})
        #expect(model.devicePending == 1)
        model.navigate(to: .profiles)
        model.navigate(to: .device)
        #expect(model.pendingDeviceCount == 2)
    }

    @Test func hardwareVolumeRespectsZeroThroughThirtyAndReturningToOriginalRemovesDraft() throws {
        let model = model()
        let volumeIndex = try #require(InzoneDevice.fields.firstIndex { $0.name == "headphone_volume" })
        model.adjustDeviceValue(at: volumeIndex, direction: -1)
        #expect(model.pendingDeviceCount == 0)
        for _ in 0..<40 { model.adjustDeviceValue(at: volumeIndex, direction: 1) }
        #expect(model.pendingDeviceValue(at: volumeIndex) == 30)
        model.adjustDeviceValue(at: volumeIndex, direction: 1)
        #expect(model.pendingDeviceValue(at: volumeIndex) == 30)
        for _ in 0..<30 { model.adjustDeviceValue(at: volumeIndex, direction: -1) }
        #expect(model.pendingDeviceValue(at: volumeIndex) == nil)
        #expect(model.pendingDeviceCount == 0)
        model.adjustDeviceValue(at: -1, direction: 1)
        model.adjustDeviceValue(at: 999, direction: 1)
        #expect(model.pendingDeviceCount == 0)
    }

    @Test func hardwareVolumeAndHostMicrophoneMuteDraftsRemainIndependent() throws {
        let model = model()
        let hardwareVolumeIndex = try #require(InzoneDevice.fields.firstIndex {
            $0.name == "headphone_volume"
        })
        let hostMuteIndex = InzoneDevice.fields.count + 3

        model.adjustDeviceValue(at: hardwareVolumeIndex, direction: 1)
        model.adjustDeviceValue(at: hostMuteIndex, direction: 1)
        #expect(model.pendingDeviceValue(at: hardwareVolumeIndex) == 1)
        #expect(model.pendingDeviceValue(at: hostMuteIndex) == 1)
        #expect(model.pendingDeviceCount == 2)

        model.adjustDeviceValue(at: hardwareVolumeIndex, direction: -1)
        #expect(model.pendingDeviceValue(at: hardwareVolumeIndex) == nil)
        #expect(model.pendingDeviceValue(at: hostMuteIndex) == 1)
        #expect(model.pendingDeviceCount == 1)
    }

    @Test func discardClearsAllChangesAndBusyProtectsDrafts() {
        let model = model()
        model.adjustDeviceValue(at: 0, direction: 1)
        model.adjustDeviceValue(at: 1, direction: 1)
        model.busy = true
        model.resetDeviceChanges()
        model.adjustDeviceValue(at: 0, direction: 1)
        model.selectRow(0)
        model.applyDeviceChanges()
        #expect(model.pendingDeviceCount == 2)
        #expect(model.pendingDeviceValue(at: 0) == 1)
        #expect(model.deviceIndex == 1)
        model.busy = false
        model.resetDeviceChanges()
        #expect(model.pendingDeviceCount == 0)
    }

    @Test func previewRefreshAndApplyCannotFalselyConfirmDrafts() async {
        let model = model()
        model.adjustDeviceValue(at: 0, direction: 1)
        await model.refresh()
        model.applyDeviceChanges()
        #expect(model.pendingDeviceValue(at: 0) == 1)
        #expect(model.pendingDeviceCount == 1)
        #expect(!model.busy)
    }

    @Test func hardwareNotificationsUpdateImmediatelyAndPreserveConflictingDrafts() throws {
        let model = model()
        let volumeIndex = try #require(InzoneDevice.fields.firstIndex { $0.name == "headphone_volume" })
        model.adjustDeviceValue(at: volumeIndex, direction: 1)
        #expect(model.pendingDeviceValue(at: volumeIndex) == 1)

        model.applyPreviewDeviceNotification(try InzoneDevice.decodeNotification(
            event: 33, payload: Data([0, 2, 255])
        ))
        #expect(model.pendingDeviceValue(at: volumeIndex) == 1)
        #expect(model.deviceStatus.hardwareVolumeLabel == "2 / 30")

        model.applyPreviewDeviceNotification(try InzoneDevice.decodeNotification(
            event: 33, payload: Data([0, 1, 255])
        ))
        #expect(model.pendingDeviceValue(at: volumeIndex) == nil)
        #expect(model.deviceStatus.hardwareVolumeLabel == "1 / 30")
        #expect(model.message == "Device status updated.")
    }

    @Test func disconnectNotificationMakesHardwareDraftUnavailableUntilReconnect() throws {
        let model = model()
        let volumeIndex = try #require(InzoneDevice.fields.firstIndex { $0.name == "headphone_volume" })
        model.adjustDeviceValue(at: volumeIndex, direction: 1)
        model.applyPreviewDeviceNotification(try InzoneDevice.decodeNotification(
            event: 1, payload: Data([0])
        ))
        #expect(model.deviceStatus.connection == .disconnected)
        #expect(model.pendingDeviceCount == 1)
        #expect(!model.canApplyDeviceChanges)

        var fields = Dictionary(uniqueKeysWithValues: InzoneDevice.fields.map { ($0.name, $0.values[0]) })
        fields["headphone_volume"] = 2
        model.applyPreviewDeviceSnapshot(
            ["connected": true, "fields": fields, "headphone": ["volume": 2, "percent": 7]],
            hostLevels: ["game_volume": 50, "chat_volume": 50, "mic_volume": 50, "mic_mute": 0]
        )
        #expect(model.deviceStatus.connection == .connected)
        #expect(model.deviceStatus.hardwareVolumeLabel == "2 / 30 · 7%")
        #expect(model.pendingDeviceApplicationOrder.contains("headphone_volume"))
        #expect(model.canApplyDeviceChanges)
    }

    @Test func snapshotWatermarksRejectQueuedStaleNotifications() {
        let watermarks: [String: UInt64] = ["headphone": 42]
        #expect(!shouldApplyDeviceNotification(revision: 41, eventName: "headphone", watermarks: watermarks))
        #expect(!shouldApplyDeviceNotification(revision: 42, eventName: "headphone", watermarks: watermarks))
        #expect(shouldApplyDeviceNotification(revision: 43, eventName: "headphone", watermarks: watermarks))
        #expect(shouldApplyDeviceNotification(revision: 1, eventName: "battery", watermarks: watermarks))
    }

    @Test func noiseControlCycleEnablesReplacementBeforeRemovingActiveMode() throws {
        var fields = Dictionary(uniqueKeysWithValues: InzoneDevice.fields.map { ($0.name, $0.values[0]) })
        fields["toggle_off"] = 1
        fields["toggle_nc"] = 1
        fields["toggle_ambient"] = 0
        let model = TerminalModel(previewDeviceSnapshot: ["connected": true, "fields": fields])
        let offIndex = try #require(InzoneDevice.fields.firstIndex { $0.name == "toggle_off" })
        let ambientIndex = try #require(InzoneDevice.fields.firstIndex { $0.name == "toggle_ambient" })

        model.adjustDeviceValue(at: offIndex, direction: -1)
        model.adjustDeviceValue(at: ambientIndex, direction: 1)
        #expect(model.pendingDeviceApplicationOrder.first == "toggle_ambient")
        #expect(model.pendingDeviceApplicationOrder.last == "toggle_off")
    }

    @Test func everyDeviceSettingRemainsReachableAcrossSections() {
        let model = model()
        let keys = InzoneDevice.fields.map(\.name) + ["game_volume", "chat_volume", "mic_volume", "mic_mute"]
        #expect(TerminalDeviceSection.section(for: "headphone_volume") == .sound)
        var reachable = Set<Int>()
        for section in TerminalDeviceSection.allCases {
            model.selectDeviceSection(section)
            for index in model.deviceSectionIndices {
                #expect(TerminalDeviceSection.section(for: keys[index]) == section)
                reachable.insert(index)
                model.selectRow(index)
                #expect(model.deviceSection == section)
                #expect(model.deviceIndex == index)
            }
        }
        #expect(reachable == Set(keys.indices))
        model.selectDeviceSection(.info)
        #expect(model.deviceSectionIndices.isEmpty)
        for (index, key) in keys.enumerated() {
            model.selectRow(index)
            #expect(model.deviceSection == TerminalDeviceSection.section(for: key))
        }
    }

    @Test func connectedDeviceSectionsPreserveActionsAtMinimumViewport() {
        let model = model()
        for section in TerminalDeviceSection.allCases {
            model.selectDeviceSection(section)
            let rendered = ViewRenderer.render(
                TerminalRoot(model: model).frame(width: 72, height: 24),
                proposedSize: ProposedViewSize(columns: 72, rows: 24))
            #expect(rendered.size.columns == 72)
            #expect(rendered.size.rows == 24)
            for label in ["Noise", "Sound", "Mic", "System", "Info", "Back", "Discard", "Refresh", "Apply"] {
                #expect(rendered.text.contains(label), "\(section): missing \(label)")
            }
            if section == .microphone { #expect(rendered.text.contains("Test mic")) }
        }
    }

    @Test func pointerAdjustmentsAndSectionChangesPreserveDraftsUntilDiscard() throws {
        let model = model()
        let runtime = StateRuntime()
        let noiseControlIndex = try #require(InzoneDevice.fields.firstIndex { $0.name == "anc" })

        func tap(_ title: String, onRowContaining rowLabel: String? = nil) throws {
            let block = try #require(runtime.block(
                from: TerminalRoot(model: model).frame(width: 72, height: 24),
                in: RenderProposal(columns: 72, rows: 24)))
            let row = try #require(block.lines.firstIndex { line in
                line.contains(title) && (rowLabel == nil || line.contains(rowLabel!))
            }, "Missing \(title) on row containing \(rowLabel ?? "any text"): \(block.lines)")
            let line = block.lines[row]
            let range = try #require(line.range(of: title))
            let location = Point(column: line.distance(from: line.startIndex, to: range.lowerBound), row: row)
            _ = runtime.dispatch(PointerPress(button: .left, location: location, phase: .down))
            _ = runtime.dispatch(PointerPress(button: .left, location: location, phase: .up))
        }

        try tap("+", onRowContaining: "Noise control")
        #expect(model.pendingDeviceValue(at: noiseControlIndex) == 1)
        try tap("Sound")
        #expect(model.deviceSection == .sound)
        #expect(model.pendingDeviceCount == 1)
        try tap("+", onRowContaining: "Headphone hardware volume")
        let hardwareVolumeIndex = try #require(InzoneDevice.fields.firstIndex {
            $0.name == "headphone_volume"
        })
        #expect(model.pendingDeviceValue(at: hardwareVolumeIndex) == 1)
        #expect(model.pendingDeviceCount == 2)
        try tap("Mic", onRowContaining: "Noise")
        #expect(model.deviceSection == .microphone)
        try tap("Discard")
        #expect(model.pendingDeviceCount == 0)
        #expect(!model.busy)
    }
}
