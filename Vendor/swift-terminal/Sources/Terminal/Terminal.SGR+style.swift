extension Terminal.SGR {

    /// A text display attribute that can be enabled and later reset with SGR.
    ///
    /// Each case maps to one SGR parameter for enabling the style and one
    /// parameter for resetting that style. The exact visual result depends on
    /// terminal support and user theme settings.
    public enum Style: Equatable, Sendable {

        /// Increased text weight, commonly rendered as bold or bright text.
        case bold

        /// Reduced intensity text.
        case dim

        /// Italic text.
        case italic

        /// Underlined text.
        case underline

        /// Blinking text.
        case blink

        /// Inverted foreground and background colors.
        case inverse

        /// Hidden or concealed text.
        case hidden

        /// Text with a horizontal line through it.
        case strikethrough

        /// The SGR parameter that enables this style.
        ///
        /// The returned string is only the numeric parameter, such as `"1"`;
        /// it does not include the escape prefix or final `m`.
        public var on: String {
            switch self {
            case .bold:
                "1"
            case .dim:
                "2"
            case .italic:
                "3"
            case .underline:
                "4"
            case .blink:
                "5"
            case .inverse:
                "7"
            case .hidden:
                "8"
            case .strikethrough:
                "9"
            }
        }

        /// The SGR parameter that resets this style.
        ///
        /// The returned string is only the numeric parameter, such as `"22"`;
        /// it does not include the escape prefix or final `m`.
        public var off: String {
            switch self {
            case .bold:
                "22"
            case .dim:
                "22"
            case .italic:
                "23"
            case .underline:
                "24"
            case .blink:
                "25"
            case .inverse:
                "27"
            case .hidden:
                "28"
            case .strikethrough:
                "29"
            }
        }
    }
}

extension Terminal.SGR {

    /// Returns an escape sequence that enables a text style.
    ///
    /// - Parameter style: The style to enable.
    /// - Returns: A complete SGR escape sequence, including the escape prefix
    ///   and final `m`.
    public static func style(_ style: Style) -> String {
        "\u{1B}[\(style.on)m"
    }

    /// Returns an escape sequence that resets a text style.
    ///
    /// - Parameter style: The style to reset.
    /// - Returns: A complete SGR escape sequence, including the escape prefix
    ///   and final `m`.
    public static func resetStyle(_ style: Style) -> String {
        "\u{1B}[\(style.off)m"
    }
}
