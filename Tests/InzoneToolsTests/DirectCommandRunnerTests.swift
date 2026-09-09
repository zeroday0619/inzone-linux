import Foundation
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class DirectCommandRunnerTests: XCTestCase {
    func testRunnerRequiresAbsoluteCommandAndUsesRootWorkingDirectory() throws {
        let runner = DirectCommandRunner()

        XCTAssertEqual(try runner.run(["/bin/sh", "-c", "test \"$PWD\" = /"]), "")
        XCTAssertThrowsError(try runner.run(["sh", "-c", "exit 0"])) { error in
            XCTAssertTrue(error.localizedDescription.contains("absolute command path"), error.localizedDescription)
        }
        XCTAssertThrowsError(try runner.run(["/bin/cat"], input: Data())) { error in
            XCTAssertTrue(error.localizedDescription.contains("do not accept buffered input"), error.localizedDescription)
        }
    }

    func testRunnerReportsFailureAndTimeoutWithoutCaptureFiles() throws {
        let runner = DirectCommandRunner()

        XCTAssertThrowsError(try runner.run(["/bin/sh", "-c", "exit 7"])) { error in
            guard let commandError = error as? CommandError else {
                return XCTFail("Expected CommandError.")
            }
            XCTAssertEqual(commandError.status, 7)
            XCTAssertEqual(commandError.output, "")
            XCTAssertFalse(commandError.timedOut)
        }
        XCTAssertThrowsError(try runner.run(["/bin/sleep", "10"], timeout: 0.05)) { error in
            XCTAssertTrue((error as? CommandError)?.timedOut == true)
        }
    }
}
