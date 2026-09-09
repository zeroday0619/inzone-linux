import Foundation

extension TerminalOutput {
    /// JSON Unicode escapes keep terminal output safe without changing the decoded value.
    public static func escapedJSON(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A {
                result.unicodeScalars.append(scalar)
                continue
            }
            let category = scalar.properties.generalCategory
            let unsafe = value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .surrogate
            if unsafe {
                appendJSONEscape(value, to: &result)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private static func appendJSONEscape(_ value: UInt32, to result: inout String) {
        if value <= 0xFFFF {
            result += String(format: "\\u%04X", value)
            return
        }
        // JSON represents unsafe non-BMP scalars with UTF-16 surrogate pairs.
        let offset = value - 0x10000
        let high = 0xD800 + (offset >> 10)
        let low = 0xDC00 + (offset & 0x3FF)
        result += String(format: "\\u%04X\\u%04X", high, low)
    }
}
