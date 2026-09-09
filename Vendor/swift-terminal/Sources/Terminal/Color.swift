/// A type-erased SGR color.
///
/// Use `AnyColor` when an API needs to store or compare colors without
/// preserving the concrete color type. Equality and hashing preserve the
/// concrete type, so two colors are equal only when they wrap the same color
/// type and value.
@frozen
public struct AnyColor: Terminal.SGR.Color {

    private let box: any _AnyColorBox

    /// Creates a type-erased color from a concrete SGR color.
    ///
    /// - Parameter color: The concrete color value to wrap.
    public init<C>(_ color: C)
    where C: Terminal.SGR.Color {
        self.box = _ConcreteColorBox(color: color)
    }

    /// The value wrapped by this instance.
    public var base: Any {
        box.base
    }

    // MARK: Equatable

    public static func == (lhs: AnyColor, rhs: AnyColor) -> Bool {
        lhs.box.isEqual(to: rhs.box)
    }

    // MARK: Hashable

    public func hash(into hasher: inout Hasher) {
        box.hash(into: &hasher)
    }

    // MARK: Terminal.SGR.Color

    public var background: String {
        box.background
    }

    public var foreground: String {
        box.foreground
    }
}

/// The standard 16 ANSI terminal colors.
///
/// These colors map to the conventional 8 base colors and 8 bright colors used
/// by SGR foreground and background parameters. The actual RGB values are
/// terminal-theme dependent.
@frozen
public enum Color16: CaseIterable, Codable, Terminal.SGR.Color {

    /// The standard black color.
    case black

    /// The standard red color.
    case red

    /// The standard green color.
    case green

    /// The standard yellow color.
    case yellow

    /// The standard blue color.
    case blue

    /// The standard magenta color.
    case magenta

    /// The standard cyan color.
    case cyan

    /// The standard white color.
    case white

    /// The bright black color, commonly rendered as gray.
    case brightBlack

    /// The bright red color.
    case brightRed

    /// The bright green color.
    case brightGreen

    /// The bright yellow color.
    case brightYellow

    /// The bright blue color.
    case brightBlue

    /// The bright magenta color.
    case brightMagenta

    /// The bright cyan color.
    case brightCyan

    /// The bright white color.
    case brightWhite

    fileprivate var rawValue: UInt8 {
        switch self {
        case .black:
            0
        case .red:
            1
        case .green:
            2
        case .yellow:
            3
        case .blue:
            4
        case .magenta:
            5
        case .cyan:
            6
        case .white:
            7
        case .brightBlack:
            8
        case .brightRed:
            9
        case .brightGreen:
            10
        case .brightYellow:
            11
        case .brightBlue:
            12
        case .brightMagenta:
            13
        case .brightCyan:
            14
        case .brightWhite:
            15
        }
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(UInt8.self)
        self = Color16.allCases.first(where: {$0.rawValue == rawValue % 16})!
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: Terminal.SGR.Color

    public var background: String {
        switch self {
        case .black:
            "40"
        case .red:
            "41"
        case .green:
            "42"
        case .yellow:
            "43"
        case .blue:
            "44"
        case .magenta:
            "45"
        case .cyan:
            "46"
        case .white:
            "47"
        case .brightBlack:
            "100"
        case .brightRed:
            "101"
        case .brightGreen:
            "102"
        case .brightYellow:
            "103"
        case .brightBlue:
            "104"
        case .brightMagenta:
            "105"
        case .brightCyan:
            "106"
        case .brightWhite:
            "107"
        }
    }

    public var foreground: String {
        switch self {
        case .black:
            "30"
        case .red:
            "31"
        case .green:
            "32"
        case .yellow:
            "33"
        case .blue:
            "34"
        case .magenta:
            "35"
        case .cyan:
            "36"
        case .white:
            "37"
        case .brightBlack:
            "90"
        case .brightRed:
            "91"
        case .brightGreen:
            "92"
        case .brightYellow:
            "93"
        case .brightBlue:
            "94"
        case .brightMagenta:
            "95"
        case .brightCyan:
            "96"
        case .brightWhite:
            "97"
        }
    }
}

/// An indexed color from the 256-color terminal palette.
///
/// Values `0...15` correspond to the standard 16 ANSI colors. Values `16...231`
/// conventionally address the 6x6x6 color cube, and values `232...255`
/// conventionally address the grayscale ramp.
@frozen
public struct Color256: Codable, RawRepresentable, Terminal.SGR.Color {

    /// Creates an indexed color from its 8-bit palette index.
    ///
    /// - Parameter rawValue: The terminal palette index.
    public init(_ rawValue: UInt8) {
        self.rawValue = rawValue
    }

    /// Creates an indexed color matching a standard 16-color value.
    ///
    /// - Parameter color16: The standard ANSI color to represent in the
    ///   256-color palette.
    public init(_ color16: Color16) {
        self.rawValue = .init(color16.rawValue)
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(UInt8.self)
        self.rawValue = rawValue
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    // MARK: RawRepresentable

    public var rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    // MARK: Terminal.SGR.Color

    public var background: String {
        "48;5;\(rawValue)"
    }

    public var foreground: String {
        "38;5;\(rawValue)"
    }
}

/// A 24-bit RGB terminal color.
///
/// True-color SGR parameters encode the red, green, and blue components
/// directly. Terminals that do not support 24-bit color may approximate or
/// ignore these values.
@frozen
public struct TrueColor: Codable, Terminal.SGR.Color {

    /// The red component.
    public var red: UInt8

    /// The green component.
    public var green: UInt8

    /// The blue component.
    public var blue: UInt8

    /// Creates a 24-bit RGB terminal color.
    ///
    /// - Parameters:
    ///   - red: The red component.
    ///   - green: The green component.
    ///   - blue: The blue component.
    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    // MARK: Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int32.self)
        self.red = UInt8((rawValue >> 16) & 0xFF)
        self.green = UInt8((rawValue >> 8) & 0xFF)
        self.blue = UInt8(rawValue & 0xFF)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        let rawValue = (Int32(red) << 16) | (Int32(green) << 8) | Int32(blue)
        try container.encode(rawValue)
    }

    // MARK: Terminal.SGR.Color

    public var background: String {
        "48;2;\(red);\(green);\(blue)"
    }

    public var foreground: String {
        "38;2;\(red);\(green);\(blue)"
    }
}

// MARK: -

@usableFromInline
internal protocol _AnyColorBox: Sendable {

    var base: Any {
        get
    }

    // MARK: (Equatable)

    func isEqual(to other: any _AnyColorBox) -> Bool

    // MARK: (Hashable)

    func hash(into hasher: inout Hasher)

    // MARK: (Terminal.SGR.Color)

    var background: String {
        get
    }

    var foreground: String {
        get
    }
}

@usableFromInline
internal struct _ConcreteColorBox<C>: _AnyColorBox
where C: Terminal.SGR.Color {

    private let color: C

    internal init(color: C) {
        self.color = color
    }

    // MARK: _AnyColorBox

    @usableFromInline
    internal var base: Any {
        color
    }

    // MARK: (Equatable)

    @usableFromInline
    internal func isEqual(to other: any _AnyColorBox) -> Bool {
        guard let other = other as? _ConcreteColorBox<C>
        else {
            return false
        }
        return self.color == other.color
    }

    // MARK: (Hashable)

    @usableFromInline
    internal func hash(into hasher: inout Hasher) {
        color.hash(into: &hasher)
    }

    // MARK: (Terminal.SGR.Color)

    @usableFromInline
    internal var background: String {
        color.background
    }

    @usableFromInline
    internal var foreground: String {
        color.foreground
    }
}
