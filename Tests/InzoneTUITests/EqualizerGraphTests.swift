import Testing
import SwiftTUI
@testable import SwiftTUIEssentials
@testable import InzoneTUI

@MainActor
struct EqualizerGraphTests {
    @Test func absoluteGainChangesClampRoundAndRespectModelGuards() {
        let model = TerminalModel()
        model.setEqualizerGain(at: 2, to: 6)
        #expect(model.equalizer[2] == 0)
        model.screen = .equalizer
        model.setEqualizerGain(at: 2, to: 6.4)
        #expect(model.equalizer[2] == 6)
        #expect(model.equalizerIndex == 2)
        model.setEqualizerGain(at: 2, to: 99)
        #expect(model.equalizer[2] == 12)
        model.setEqualizerGain(at: 2, to: -99)
        #expect(model.equalizer[2] == -12)
        for value in [Double.nan, .infinity, -.infinity] {
            model.setEqualizerGain(at: 2, to: value)
            #expect(model.equalizer[2] == -12)
        }
        for index in [-1, 10] { model.setEqualizerGain(at: index, to: 0) }
        #expect(model.equalizerIndex == 2)
        model.busy = true
        model.setEqualizerGain(at: 4, to: 8)
        #expect(model.equalizerIndex == 2)
        #expect(model.equalizer[4] == 0)
    }

    @Test func bandHitRegionsCoverPlotWithoutGapsOrAxisOverlap() {
        for columns in [70, 72, 80, 112, 120] {
            let geometry = EqualizerGraphGeometry(columns: columns, rows: 10)
            #expect(geometry.band(at: -1) == nil)
            #expect(geometry.band(at: 4) == nil)
            #expect(geometry.band(at: columns) == nil)
            var boundary = 5
            for index in 0..<10 {
                let range = geometry.bandRange(index)
                #expect(range.lowerBound == boundary)
                for column in range { #expect(geometry.band(at: column) == index) }
                boundary = range.upperBound
            }
            #expect(boundary == columns)
            #expect(geometry.bandRange(0).count - geometry.bandRange(9).count <= 1)
        }
    }

    @Test func gainMappingPreservesZeroAndClampsPlotEndpoints() {
        for rows in [4, 9, 10, 18, 26] {
            let geometry = EqualizerGraphGeometry(columns: 72, rows: rows)
            #expect(geometry.plotRows % 2 == 1)
            #expect(geometry.row(for: 0) == geometry.zeroRow)
            #expect(geometry.row(for: 12) == 0)
            #expect(geometry.row(for: -12) == geometry.plotRows - 1)
            #expect(geometry.row(for: .nan) == geometry.zeroRow)
            #expect(geometry.gain(at: geometry.zeroRow) == 0)
            #expect(geometry.gain(at: -20) == 12)
            #expect(geometry.gain(at: 100) == -12)
            for row in 0..<geometry.plotRows {
                let gain = geometry.gain(at: row)
                #expect(gain == gain.rounded())
                #expect((-12...12).contains(gain))
            }
        }
    }

    @Test func graphRendersAllFrequencyLabelsAndGainEndpoints() {
        for (columns, rows) in [(70, 8), (88, 12), (112, 18)] {
            let rendered = ViewRenderer.render(
                TerminalEqualizerGraph(values: [12, 6, 0, -6, -12, 1, 2, 3, 4, 5], selected: 4,
                    columns: columns, rows: rows, onSelect: { _ in }, onChange: { _, _ in }),
                proposedSize: ProposedViewSize(columns: columns, rows: rows))
            #expect(rendered.size.columns == columns)
            #expect(rendered.size.rows == rows)
            for label in TerminalEqualizerGraph.frequencies + ["+12", "−12", "Hz"] {
                #expect(rendered.text.contains(label))
            }
            for line in rendered.lines {
                #expect(RunGroup(line).measure().maximumContentColumns == columns)
            }
        }
    }

    @Test func pointerTapsSelectEveryBandWithoutChangingGain() throws {
        let runtime = StateRuntime()
        var selected = -1
        var changes = 0
        let geometry = EqualizerGraphGeometry(columns: 72, rows: 10)
        _ = try #require(runtime.block(from: TerminalEqualizerGraph(
            values: Array(repeating: 0, count: 10), selected: 0, columns: 72, rows: 10,
            onSelect: { selected = $0 }, onChange: { _, _ in changes += 1 })))
        for index in 0..<10 {
            for row in [0, geometry.zeroRow, geometry.plotRows] {
                let point = Point(column: geometry.bandRange(index).lowerBound, row: row)
                _ = runtime.dispatch(PointerPress(button: .left, location: point, phase: .down))
                _ = runtime.dispatch(PointerPress(button: .left, location: point, phase: .up))
                #expect(selected == index)
                #expect(changes == 0)
            }
        }
    }

    @Test func capturedDragClampsGainAndRetainsOriginalBand() throws {
        let runtime = StateRuntime()
        var selected = -1
        var changedBand = -1
        var gain = 0.0
        let geometry = EqualizerGraphGeometry(columns: 72, rows: 10)
        _ = try #require(runtime.block(from: TerminalEqualizerGraph(
            values: Array(repeating: 0, count: 10), selected: 0, columns: 72, rows: 10,
            onSelect: { selected = $0 }, onChange: { changedBand = $0; gain = $1 })))
        let start = Point(column: geometry.bandRange(2).lowerBound, row: geometry.zeroRow)
        _ = runtime.dispatch(PointerPress(button: .left, location: start, phase: .down))
        _ = runtime.dispatch(PointerMotion(button: .left, location: Point(column: 70, row: -5)))
        #expect(selected == 2)
        #expect(changedBand == 2)
        #expect(gain == 12)
        _ = runtime.dispatch(PointerMotion(button: .left, location: Point(column: 1, row: 30)))
        #expect(changedBand == 2)
        #expect(gain == -12)
        _ = runtime.dispatch(PointerPress(button: .left, location: Point(column: 1, row: 30), phase: .up))
        #expect(gain == -12)
    }

    @Test func labelDragsAndAxisGesturesNeverEditGain() throws {
        let runtime = StateRuntime()
        var changes = 0
        let geometry = EqualizerGraphGeometry(columns: 72, rows: 10)
        _ = try #require(runtime.block(from: TerminalEqualizerGraph(
            values: Array(repeating: 0, count: 10), selected: 0, columns: 72, rows: 10,
            onSelect: { _ in }, onChange: { _, _ in changes += 1 })))
        for start in [Point(column: 20, row: geometry.plotRows), Point(column: 2, row: 4)] {
            _ = runtime.dispatch(PointerPress(button: .left, location: start, phase: .down))
            _ = runtime.dispatch(PointerMotion(button: .left, location: Point(column: 30, row: 0)))
            _ = runtime.dispatch(PointerPress(button: .left, location: Point(column: 30, row: 0), phase: .up))
            #expect(changes == 0)
        }
    }

    @Test func resizeDuringDragKeepsTheOriginalBand() throws {
        let runtime = StateRuntime()
        var changedBand = -1
        var gain = 0.0
        func graph(columns: Int, rows: Int) -> TerminalEqualizerGraph {
            TerminalEqualizerGraph(values: Array(repeating: 0, count: 10), selected: 0,
                columns: columns, rows: rows, onSelect: { _ in },
                onChange: { changedBand = $0; gain = $1 })
        }
        let geometry = EqualizerGraphGeometry(columns: 72, rows: 10)
        _ = try #require(runtime.block(from: graph(columns: 72, rows: 10)))
        let start = Point(column: geometry.bandRange(7).lowerBound, row: geometry.zeroRow)
        _ = runtime.dispatch(PointerPress(button: .left, location: start, phase: .down))
        _ = try #require(runtime.block(from: graph(columns: 120, rows: 20)))
        _ = runtime.dispatch(PointerMotion(button: .left, location: Point(column: start.column, row: 0)))
        #expect(changedBand == 7)
        #expect(gain == 12)
        _ = runtime.dispatch(PointerPress(button: .left, location: Point(column: start.column, row: 0), phase: .up))
    }

    @Test func disabledGraphRejectsPointerInput() throws {
        let runtime = StateRuntime()
        var events = 0
        _ = try #require(runtime.block(from: TerminalEqualizerGraph(
            values: Array(repeating: 0, count: 10), selected: 0, columns: 72, rows: 10,
            enabled: false, onSelect: { _ in events += 1 }, onChange: { _, _ in events += 1 })))
        _ = runtime.dispatch(PointerPress(button: .left, location: Point(column: 20, row: 4), phase: .down))
        _ = runtime.dispatch(PointerMotion(button: .left, location: Point(column: 20, row: 0)))
        _ = runtime.dispatch(PointerPress(button: .left, location: Point(column: 20, row: 0), phase: .up))
        #expect(events == 0)
    }
}
