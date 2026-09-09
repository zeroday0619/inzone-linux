/// A terminal grid position.
///
/// Terminal coordinates are expressed in cells. `column` is the horizontal
/// offset and `row` is the vertical offset.
public struct Point: Codable, Equatable, Hashable, Sendable {

    /// The horizontal cell offset.
    public var column: Int

    /// The vertical cell offset.
    public var row: Int

    /// Creates a point from terminal cell coordinates.
    ///
    /// - Parameters:
    ///   - column: The horizontal cell offset.
    ///   - row: The vertical cell offset.
    public init(column: Int, row: Int) {
        self.column = column
        self.row = row
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.row = try container.decode(Int.self)
        self.column = try container.decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(row)
        try container.encode(column)
    }
}

extension Point {

    /// The point at column `0`, row `0`.
    public static let zero: Point = .init(column: 0, row: 0)

    public init() {
        self = .zero
    }
}

// MARK: -

/// A terminal grid extent.
///
/// Terminal sizes are expressed in cells. `columns` is the width and `rows` is
/// the height.
public struct Size: Codable, Equatable, Hashable, Sendable {

    /// The number of terminal columns.
    public var columns: Int

    /// The number of terminal rows.
    public var rows: Int

    /// Creates a size from a terminal cell extent.
    ///
    /// - Parameters:
    ///   - columns: The number of terminal columns.
    ///   - rows: The number of terminal rows.
    public init(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.rows = try container.decode(Int.self)
        self.columns = try container.decode(Int.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(rows)
        try container.encode(columns)
    }
}

extension Size {

    /// A size with `0` columns and `0` rows.
    public static let zero: Size = .init(columns: 0, rows: 0)

    public init() {
        self = .zero
    }
}

// MARK: -

/// A rectangular region in a terminal grid.
public struct Rect: Codable, Equatable, Hashable, Sendable {

    /// The top-left point of the rectangle.
    public var origin: Point

    /// The cell extent of the rectangle.
    public var size: Size

    /// Creates a rectangle from an origin and size.
    ///
    /// - Parameters:
    ///   - origin: The top-left point of the rectangle.
    ///   - size: The cell extent of the rectangle.
    public init(origin: Point, size: Size) {
        self.origin = origin
        self.size = size
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.origin = try container.decode(Point.self)
        self.size = try container.decode(Size.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(origin)
        try container.encode(size)
    }
}

extension Rect {

    /// A rectangle with zero origin and zero size.
    public static let zero: Rect = .init(origin: .zero, size: .zero)

    public init() {
        self = .zero
    }
}
