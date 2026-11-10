import SwiftUI

/// Lays views out in rows, wrapping as text does: boost chips, a card's buttons and context row.
/// A view wider than the row gets the row's width and wraps (or truncates) inside it.
struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat? = nil
    /// Where each row sits: at the leading side, or at the trailing side as a tile's buttons do.
    var alignment: HorizontalAlignment = .leading
    /// Where they all fit on one row, the views from this index on sit at its trailing end and the
    /// rest at its leading end, as a tile's buttons do; on more rows, every row follows `alignment`.
    var trailingFrom: Int? = nil

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let available = proposal.width ?? .infinity
        let rows = rows(width: available, subviews: subviews)
        var width = rows.map(\.width).max() ?? 0
        // Split across the row, so it takes the whole of it.
        if isSplit(rows), available.isFinite { width = max(width, available) }
        let height = rows.map(\.height).reduce(0, +) + rowSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(width: bounds.width, subviews: subviews)
        let split = isSplit(rows)
        var y = bounds.minY
        for row in rows {
            var x = alignment == .trailing ? bounds.maxX - row.width : bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                if split, index == trailingFrom {
                    let rest = row.sizes[index...].map(\.width)
                    x = bounds.maxX - (rest.reduce(0, +) + spacing * CGFloat(rest.count - 1))
                }
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + rowSpacing
        }
    }

    private var rowSpacing: CGFloat { lineSpacing ?? spacing }

    private func isSplit(_ rows: [Row]) -> Bool {
        guard let trailingFrom, rows.count == 1 else { return false }
        return trailingFrom > 0 && trailingFrom < rows[0].indices.count
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [Row] {
        let sizes = subviews.map { subview in
            var size = subview.sizeThatFits(.unspecified)
            if size.width > width {
                size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = min(size.width, width)
            }
            return size
        }
        return FlowRows.rows(widths: sizes.map(\.width), in: width, spacing: spacing).map { range in
            let rowSizes = Array(sizes[range])
            return Row(
                indices: Array(range), sizes: rowSizes,
                width: rowSizes.map(\.width).reduce(0, +) + spacing * CGFloat(rowSizes.count - 1),
                height: rowSizes.map(\.height).max() ?? 0)
        }
    }
}

/// Where a flow of views breaks into rows: each takes the views that fit beside one another in
/// order, and a view wider than the whole row has one to itself.
enum FlowRows {
    static func rows(widths: [CGFloat], in available: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var rows: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if index > start, used + spacing + width > available {
                rows.append(start..<index)
                start = index
                used = width
            } else {
                used = index == start ? width : used + spacing + width
            }
        }
        if start < widths.count { rows.append(start..<widths.count) }
        return rows
    }
}
