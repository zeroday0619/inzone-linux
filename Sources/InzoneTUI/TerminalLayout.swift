import SwiftTUI

/// Distributes terminal cells evenly so adjacent rows share their outer edges.
struct TerminalEqualColumns: Layout {
    var spacing = 2

    static var layoutProperties: LayoutProperties {
        var properties = LayoutProperties()
        properties.stackOrientation = .horizontal
        return properties
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> Size {
        guard !subviews.isEmpty else { return Size() }
        let columns: Int
        if let proposedColumns = proposal.columns, proposedColumns != Int.max {
            columns = max(0, proposedColumns)
        } else {
            let naturalWidth = subviews.map { $0.sizeThatFits(.unspecified).columns }.max() ?? 0
            columns = naturalWidth * subviews.count + max(0, spacing) * (subviews.count - 1)
        }
        let distribution = columnDistribution(columns: columns, count: subviews.count)
        let rows = zip(subviews, distribution.widths).map { subview, width in
            subview.sizeThatFits(ProposedViewSize(columns: width, rows: nil)).rows
        }.max() ?? 0
        return Size(columns: columns, rows: rows)
    }

    func placeSubviews(
        in bounds: Rect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let distribution = columnDistribution(columns: bounds.size.columns, count: subviews.count)
        var column = bounds.origin.column
        for (subview, width) in zip(subviews, distribution.widths) {
            subview.place(
                at: Point(column: column, row: bounds.origin.row),
                anchor: .topLeading,
                proposal: ProposedViewSize(columns: width, rows: bounds.size.rows)
            )
            column += width + distribution.spacing
        }
    }

    private func columnDistribution(columns: Int, count: Int) -> (widths: [Int], spacing: Int) {
        guard count > 0 else { return ([], 0) }
        let availableColumns = max(0, columns)
        let gap = count > 1 ? min(max(0, spacing), availableColumns / (count - 1)) : 0
        let contentColumns = availableColumns - gap * (count - 1)
        let width = contentColumns / count
        let remainder = contentColumns % count
        // Leading cells receive the remainder so integer division never leaves a trailing gap.
        return ((0..<count).map { width + ($0 < remainder ? 1 : 0) }, gap)
    }
}
