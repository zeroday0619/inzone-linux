import Foundation
import XCTest
@testable import InzoneCore

final class PulseStreamParkingTests: XCTestCase {
    func testApplicationStreamsSurviveVirtualSinkReplacementWithoutMovingOtherRoutes() throws {
        let runner = ParkingRunner()
        let parking = try XCTUnwrap(PulseStreamParking.park(runner: runner))

        XCTAssertEqual(runner.inputs[101]?.sink, 50)
        XCTAssertEqual(runner.inputs[102]?.sink, 50)
        XCTAssertEqual(runner.inputs[105]?.sink, 50)
        XCTAssertEqual(runner.inputs[103]?.sink, 40)
        XCTAssertEqual(runner.inputs[104]?.sink, 20)

        runner.sinks.removeValue(forKey: 10)
        runner.sinks.removeValue(forKey: 11)
        try parking.finish(defaultSink: ProfileController.chat)

        XCTAssertEqual(runner.inputs[101]?.sink, 30)
        XCTAssertEqual(runner.inputs[102]?.sink, 20)
        XCTAssertEqual(runner.inputs[105]?.sink, 30)
        XCTAssertEqual(runner.inputs[103]?.sink, 40)
        XCTAssertEqual(runner.inputs[104]?.sink, 20)
        XCTAssertNil(runner.sinks[50])
        XCTAssertEqual(runner.unloadedModules, ["900"])
    }

    func testRollbackReparksPartiallyReleasedStreamsBeforeRestoringOldSink() throws {
        let runner = ParkingRunner()
        let parking = try XCTUnwrap(PulseStreamParking.park(
            runner: runner, previousDefaultSink: "inzone.sony-downmix"
        ))
        runner.inputs[101]?.sink = 30
        try parking.parkAgain()
        XCTAssertEqual(runner.inputs[101]?.sink, 50)

        try parking.restoreOriginalRouting()
        XCTAssertEqual(runner.inputs[101]?.sink, 10)
        XCTAssertEqual(runner.inputs[105]?.sink, 11)
        XCTAssertNil(runner.sinks[50])
    }

    func testNoManagedApplicationStreamDoesNotCreateParkingSink() throws {
        let runner = ParkingRunner()
        runner.inputs = [103: (sink: 40, client: "503"), 104: (sink: 20, client: "-")]
        XCTAssertNil(try PulseStreamParking.park(
            runner: runner, previousDefaultSink: "inzone.sony-downmix"
        ))
        XCTAssertEqual(runner.loadedModules, 0)
    }

    private final class ParkingRunner: CommandRunning, @unchecked Sendable {
        var sinks = [
            10: "inzone.sony-downmix", 11: "inzone.sony-downmix.5.1",
            20: ProfileController.game, 30: ProfileController.chat,
            40: "alsa_output.other-device",
        ]
        var inputs: [Int: (sink: Int, client: String)] = [
            101: (sink: 10, client: "501"), 102: (sink: 20, client: "502"),
            103: (sink: 40, client: "503"), 104: (sink: 20, client: "-"),
            105: (sink: 11, client: "505"),
        ]
        var loadedModules = 0
        var unloadedModules: [String] = []

        func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
            if arguments == ["pactl", "get-default-sink"] {
                return "inzone.sony-downmix\n"
            }
            if arguments == ["pactl", "list", "short", "sinks"] {
                return sinks.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)\tPipeWire\n" }.joined()
            }
            if arguments == ["pactl", "list", "short", "sink-inputs"] {
                return inputs.sorted { $0.key < $1.key }.map {
                    "\($0.key)\t\($0.value.sink)\t\($0.value.client)\tPipeWire\n"
                }.joined()
            }
            if arguments.count == 4, arguments.prefix(3) == ["pactl", "load-module", "module-null-sink"] {
                loadedModules += 1
                sinks[50] = String(arguments[3].dropFirst("sink_name=".count))
                return "900\n"
            }
            if arguments.count == 4, arguments.prefix(2) == ["pactl", "move-sink-input"],
               let identifier = Int(arguments[2]), let sink = sinks.first(where: { $0.value == arguments[3] })?.key {
                inputs[identifier]?.sink = sink
                return ""
            }
            if arguments == ["pactl", "unload-module", "900"] {
                guard !inputs.values.contains(where: { $0.sink == 50 }) else {
                    throw InzoneError.message("The temporary sink still has active streams.")
                }
                sinks.removeValue(forKey: 50)
                unloadedModules.append("900")
                return ""
            }
            XCTFail("Unexpected command: \(arguments)")
            throw InzoneError.message("Unexpected test command.")
        }
    }
}
