extension Terminal.SGR {

    /// A color representation that can produce SGR foreground and background
    /// parameters.
    ///
    /// Conforming types return only the SGR parameter body. Use
    /// `Terminal.SGR.foregroundColor(_:)` or
    /// `Terminal.SGR.backgroundColor(_:)` to wrap those parameters in a
    /// complete escape sequence.
    public protocol Color: Equatable, Hashable, Sendable {

        /// The SGR parameter that applies the color as a background.
        ///
        /// The returned string does not include the escape prefix or final `m`.
        var background: String {
            get
        }

        /// The SGR parameter that applies the color as a foreground.
        ///
        /// The returned string does not include the escape prefix or final `m`.
        var foreground: String {
            get
        }
    }

    /// Returns an escape sequence that applies a background color.
    ///
    /// - Parameter color: The color to use for the background.
    /// - Returns: A complete SGR escape sequence, including the escape prefix
    ///   and final `m`.
    public static func backgroundColor(_ color: any Color) -> String {
        "\u{1B}[\(color.background)m"
    }

    /// Returns an escape sequence that applies a foreground color.
    ///
    /// - Parameter color: The color to use for the foreground.
    /// - Returns: A complete SGR escape sequence, including the escape prefix
    ///   and final `m`.
    public static func foregroundColor(_ color: any Color) -> String {
        "\u{1B}[\(color.foreground)m"
    }

    /// An escape sequence that resets the background color to the terminal
    /// default.
    public static var resetBackgroundColor: String {
        "\u{1B}[49m"
    }

    /// An escape sequence that resets the foreground color to the terminal
    /// default.
    public static var resetForegroundColor: String {
        "\u{1B}[39m"
    }
}
