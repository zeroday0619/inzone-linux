import Testing
import SwiftTUI
import InzoneCore
@testable import SwiftTUIEssentials
@testable import InzoneTUI

@MainActor
struct DeviceSwipeTests {
    private func model() -> TerminalModel {
        let fields = Dictionary(uniqueKeysWithValues: InzoneDevice.fields.map { ($0.name, $0.values[0]) })
        return TerminalModel(previewDeviceSnapshot: [
            "connected": true,
            "battery": ["percent": 85, "state": "discharging"],
            "firmware": ["headset": "1.2.3.4", "dongle": "5.6.7.8"],
            "fields": fields,
        ], hostLevels: ["game_volume": 50, "chat_volume": 50, "mic_volume": 50, "mic_mute": 0])
    }

    private func location(_ title: String, rowContaining rowLabel: String? = nil,
                          model: TerminalModel, runtime: StateRuntime) throws -> Point {
        let block = try #require(runtime.block(
            from: TerminalRoot(model: model).frame(width: 72, height: 24),
            in: RenderProposal(columns: 72, rows: 24)))
        let row = try #require(block.lines.firstIndex { line in
            line.contains(title) && (rowLabel == nil || line.contains(rowLabel!))
        }, "Missing \(title) on row containing \(rowLabel ?? "any text"): \(block.lines)")
        let line = block.lines[row]
        let range = try #require(line.range(of: title))
        return Point(column: line.distance(from: line.startIndex, to: range.lowerBound), row: row)
    }

    private func drag(_ runtime: StateRuntime, from start: Point, columns: Int, rows: Int = 0) {
        let end = Point(column: start.column + columns, row: start.row + rows)
        _ = runtime.dispatch(PointerPress(button: .left, location: start, phase: .down))
        _ = runtime.dispatch(PointerMotion(button: .left, location: end))
        _ = runtime.dispatch(PointerPress(button: .left, location: end, phase: .up))
    }

    private func tap(_ runtime: StateRuntime, at point: Point) {
        _ = runtime.dispatch(PointerPress(button: .left, location: point, phase: .down))
        _ = runtime.dispatch(PointerPress(button: .left, location: point, phase: .up))
    }

    @Test func tabSwipesAdvanceOnceAndReverseWithoutWrapping() throws {
        let model = model()
        let runtime = StateRuntime()
        for expected in [TerminalDeviceSection.sound, .microphone, .system, .info, .info] {
            let point = try location("Sound", rowContaining: "Noise", model: model, runtime: runtime)
            drag(runtime, from: point, columns: -8)
            #expect(model.deviceSection == expected)
        }
        for expected in [TerminalDeviceSection.system, .microphone, .sound, .noise, .noise] {
            let point = try location("Sound", rowContaining: "Noise", model: model, runtime: runtime)
            drag(runtime, from: point, columns: 8)
            #expect(model.deviceSection == expected)
        }
        #expect(model.pendingDeviceCount == 0)
    }

    @Test func tapsStillSelectSectionsAndPreserveDrafts() throws {
        let model = model()
        let runtime = StateRuntime()
        model.adjustDeviceValue(at: 0, direction: 1)
        let info = try location("Info", rowContaining: "Noise", model: model, runtime: runtime)
        tap(runtime, at: info)
        #expect(model.deviceSection == .info)
        #expect(model.pendingDeviceValue(at: 0) == 1)
        let noise = try location("Noise", rowContaining: "Sound", model: model, runtime: runtime)
        tap(runtime, at: noise)
        #expect(model.deviceSection == .noise)
        #expect(model.pendingDeviceCount == 1)
    }

    @Test func contentSwipesCancelUnderlyingAdjustmentAndToggle() throws {
        let model = model()
        let runtime = StateRuntime()
        let adjustment = try location("+", rowContaining: "Noise control", model: model, runtime: runtime)
        drag(runtime, from: adjustment, columns: -8)
        #expect(model.deviceSection == .sound)
        #expect(model.pendingDeviceCount == 0)
        model.selectDeviceSection(.microphone)
        let toggle = try location("Off", rowContaining: "PipeWire microphone mute", model: model, runtime: runtime)
        drag(runtime, from: toggle, columns: -8)
        #expect(model.deviceSection == .system)
        #expect(model.pendingDeviceCount == 0)
        #expect(!model.busy)
    }

    @Test func verticalAndShortGesturesDoNotPage() throws {
        let model = model()
        let runtime = StateRuntime()
        for (columns, rows) in [(0, 5), (-4, 3), (-3, 0)] {
            let point = try location("Noise", rowContaining: "Sound", model: model, runtime: runtime)
            drag(runtime, from: Point(column: point.column + 5, row: point.row), columns: columns, rows: rows)
            #expect(model.deviceSection == .noise)
            #expect(model.pendingDeviceCount == 0)
        }
    }

    @Test func busyDeviceRejectsSectionTapsAndSwipes() throws {
        let model = model()
        let runtime = StateRuntime()
        model.busy = true
        let point = try location("Sound", rowContaining: "Noise", model: model, runtime: runtime)
        drag(runtime, from: point, columns: -8)
        tap(runtime, at: point)
        #expect(model.deviceSection == .noise)
        #expect(model.pendingDeviceCount == 0)
    }

    @Test func tabLabelsHaveEqualTopAndBottomPadding() {
        let rendered = ViewRenderer.render(
            TerminalDeviceTabs(selected: .noise, columns: 70, enabled: true, onSelect: { _ in }),
            proposedSize: ProposedViewSize(columns: 70, rows: 3))
        #expect(rendered.size.rows == 3)
        #expect(rendered.lines.count == 3)
        guard rendered.lines.count == 3 else { return }
        for section in TerminalDeviceSection.allCases {
            #expect(rendered.lines[1].contains(section.rawValue))
        }
        #expect(rendered.lines[0].allSatisfy { $0.isWhitespace })
        #expect(rendered.lines[2].allSatisfy { $0.isWhitespace })
    }
}
