import Foundation
import XCTest
@testable import InzoneCore

final class TerminalJSONTests: XCTestCase {
    func testEscapedJSONPreservesDecodedControlsAndStructuralLineFeeds() throws {
        let rawUnsafe = "\u{007F}\u{0085}\u{009B}\u{202A}\u{202E}\u{2066}\u{2028}\u{2029}\u{E0001}"
        let json = "{\n  \"value\" : \"\\u0000\\u0007\\u001B\(rawUnsafe)\"\n}"

        let escaped = TerminalOutput.escapedJSON(json)

        XCTAssertEqual(
            escaped,
            "{\n  \"value\" : \"\\u0000\\u0007\\u001B\\u007F\\u0085\\u009B"
                + "\\u202A\\u202E\\u2066\\u2028\\u2029\\uDB40\\uDC01\"\n}"
        )
        XCTAssertEqual(escaped.filter { $0 == "\n" }.count, 2)
        let decoded = try XCTUnwrap(JSONSupport.decode(Data(escaped.utf8)) as? [String: String])
        XCTAssertEqual(decoded["value"], "\u{0000}\u{0007}\u{001B}" + rawUnsafe)
        assertOnlyStructuralLineFeedsRemainRaw(escaped)
    }

    private func assertOnlyStructuralLineFeedsRemainRaw(
        _ output: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        let unsafe = output.unicodeScalars.filter { scalar in
            let value = scalar.value
            if value == 0x0A { return false }
            let category = scalar.properties.generalCategory
            return value < 0x20 || value == 0x7F || (0x80...0x9F).contains(value)
                || category == .control || category == .format || category == .lineSeparator
                || category == .paragraphSeparator || category == .surrogate
        }
        XCTAssertTrue(unsafe.isEmpty, "Raw terminal controls: \(unsafe)", file: file, line: line)
    }
}
