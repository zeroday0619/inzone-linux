import Foundation
import SwiftTUI

struct EqualizerGraphGeometry {
    static let axisWidth = 5
    let columns: Int
    let plotRows: Int
    let bandCount: Int

    init(columns: Int, rows: Int, bandCount: Int = 10) {
        let count = max(1, bandCount)
        self.columns = max(Self.axisWidth + count, columns)
        self.bandCount = count
        let available = max(3, rows - 1)
        plotRows = available.isMultiple(of: 2) ? available - 1 : available
    }

    var zeroRow: Int { plotRows / 2 }

    func bandRange(_ index: Int) -> Range<Int> {
        let width = columns - Self.axisWidth
        let base = width / bandCount
        let remainder = width % bandCount
        let first = Self.axisWidth + index * base + min(index, remainder)
        return first..<(first + base + (index < remainder ? 1 : 0))
    }

    func band(at column: Int) -> Int? {
        guard column >= Self.axisWidth, column < columns else { return nil }
        return (0..<bandCount).first { bandRange($0).contains(column) }
    }

    func row(for gain: Double) -> Int {
        let value = gain.isFinite ? min(12, max(-12, gain)) : 0
        return Int(((12 - value) * Double(plotRows - 1) / 24).rounded())
    }

    func gain(at row: Int) -> Double {
        let position = min(plotRows - 1, max(0, row))
        return (12 - Double(position) * 24 / Double(plotRows - 1)).rounded()
    }
}

@MainActor
struct TerminalEqualizerGraph: View {
    private struct DragTarget {
        let index: Int
        let changesGain: Bool
    }

    @GestureState private var dragTarget: DragTarget?
    static let frequencies = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    let values: [Double]
    let selected: Int
    let columns: Int
    let rows: Int
    var enabled = true
    let onSelect: (Int) -> Void
    let onChange: (Int, Double) -> Void

    var body: some View {
        let geometry = EqualizerGraphGeometry(columns: columns, rows: rows)
        VStack(spacing: 0) {
            ForEach(0..<geometry.plotRows) { row in
                HStack(spacing: 0) {
                    Text(axisLabel(row, geometry: geometry)).foregroundStyle(TerminalTheme.muted)
                        .frame(width: EqualizerGraphGeometry.axisWidth, height: 1)
                    ForEach(0..<10) { index in
                        let gain = values.indices.contains(index) ? values[index] : 0
                        let end = geometry.row(for: gain)
                        let hasBar = row >= min(end, geometry.zeroRow) && row <= max(end, geometry.zeroRow)
                        Text(bar(row: row, end: end, width: geometry.bandRange(index).count, zero: geometry.zeroRow))
                            .foregroundStyle(hasBar ? (index == selected ? TerminalTheme.accent : TerminalTheme.muted) : TerminalTheme.raised)
                            .bold(index == selected)
                    }
                }
            }
            HStack(spacing: 0) {
                Text(" Hz").foregroundStyle(TerminalTheme.muted).frame(width: EqualizerGraphGeometry.axisWidth, height: 1)
                ForEach(0..<10) { index in
                    Text(Self.frequencies[index]).bold(index == selected)
                        .frame(width: geometry.bandRange(index).count, height: 1)
                        .foregroundStyle(index == selected ? TerminalTheme.text : TerminalTheme.muted)
                        .background(index == selected ? TerminalTheme.raised : TerminalTheme.background)
                }
            }
        }
        .frame(width: columns, height: rows, alignment: .topLeading)
        .gesture(
            DragGesture(minimumDistance: 0)
                .updating($dragTarget) { value, target, _ in
                    if target == nil, let index = geometry.band(at: value.startLocation.column),
                       value.startLocation.row >= 0, value.startLocation.row <= geometry.plotRows {
                        target = DragTarget(index: index, changesGain: value.startLocation.row < geometry.plotRows)
                    }
                }
                .onChanged { value in update(value, geometry: geometry) }
                .onEnded { value in update(value, geometry: geometry) },
            isEnabled: enabled
        )
    }

    private func update(_ value: DragGesture.Value, geometry: EqualizerGraphGeometry) {
        guard enabled, let target = dragTarget else { return }
        onSelect(target.index)
        // Frequency-label taps select only; a captured vertical drag edits its original band.
        if target.changesGain && value.translation.rows != 0 {
            onChange(target.index, geometry.gain(at: value.location.row))
        }
    }

    private func axisLabel(_ row: Int, geometry: EqualizerGraphGeometry) -> String {
        let label: String
        switch row {
        case 0: label = "+12"
        case geometry.zeroRow: label = "0"
        case geometry.plotRows - 1: label = "−12"
        case geometry.row(for: 6): label = "+6"
        case geometry.row(for: -6): label = "−6"
        default: label = ""
        }
        return String(repeating: " ", count: 3 - label.count) + label + (row == geometry.zeroRow ? " ┼" : " │")
    }

    private func bar(row: Int, end: Int, width: Int, zero: Int) -> String {
        var cells = Array(repeating: Character(row == zero ? "─" : " "), count: width)
        if row >= min(end, zero) && row <= max(end, zero) {
            let size = min(3, width)
            let first = (width - size) / 2
            for column in first..<(first + size) { cells[column] = row == end ? "━" : "█" }
        }
        return String(cells)
    }
}
