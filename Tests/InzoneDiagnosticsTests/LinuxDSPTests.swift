import Foundation
import XCTest
import InzoneCore
@testable import InzoneDiagnostics

final class LinuxDSPTests: XCTestCase {
    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testIntegerSeedPreservesReferenceRandomSequence() {
        var generator = DiagnosticRandom(seed: 0)
        let uniform = [0.6888437030500962, 0.515908805880605, -0.15885683833831,
                       -0.4821664994140733, 0.02254944273721704]
        for value in uniform { XCTAssertEqual(generator.uniform(), value) }
    }

    func testStressSignalIncludesEveryLevelNoiseAndImpulseSegment() {
        let signal = LinuxDSP.stressSignal()
        XCTAssertEqual(signal.count, 720000)
        XCTAssertTrue(signal.allSatisfy(\.isFinite))
        XCTAssertTrue(signal.prefix(48000).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(signal[48002], 0)
        let noiseStart = 11 * 24000 * 2
        let impulsesStart = noiseStart + 48000 * 2
        XCTAssertTrue(stride(from: noiseStart, to: impulsesStart, by: 2).allSatisfy { abs(signal[$0]) <= 0.9 })
        XCTAssertTrue(stride(from: noiseStart + 1, to: impulsesStart, by: 2).allSatisfy { abs(signal[$0]) <= 0.08 })
        XCTAssertEqual(signal[impulsesStart], 1.5)
        XCTAssertEqual(signal[impulsesStart + 1], -0.9)
        XCTAssertEqual(signal[impulsesStart + 2], 0)
        XCTAssertEqual(signal[impulsesStart + 4096 * 2], 1.5)
        XCTAssertEqual(signal[impulsesStart + 5000 * 2 + 1], -0.9)
    }

    func testFloatBinaryIOPreservesIEEEBitsAndRejectsPartialWords() throws {
        let values = [Float(1), Float(-2), Float(bitPattern: 0x80000000), Float.infinity,
                      Float(bitPattern: 0x7fc12345)]
        let encoded = FloatSamples.encode(values)
        XCTAssertEqual(Array(encoded.prefix(8)), [0, 0, 0x80, 0x3f, 0, 0, 0, 0xc0])
        XCTAssertEqual(try FloatSamples.decode(encoded).map(\.bitPattern), values.map(\.bitPattern))
        XCTAssertThrowsError(try FloatSamples.decode(Data([0, 1, 2])))
    }

    func testCaseMatrixPreservesNamesOrderAndOptions() throws {
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent("assets/sony-presets.json").path) else {
            throw XCTSkip("Run make assets for the shipped Sony preset bank.")
        }
        let cases = try LinuxDSP.cases(assets: repository.appendingPathComponent("assets"))
        XCTAssertEqual(cases.count, 33)
        XCTAssertEqual(cases[3].name, "fps1-drc0")
        XCTAssertEqual(cases[18].name, "music_video-drc0")
        XCTAssertEqual(cases[32].name, "custom-immersive-alcTrue-drc2")
        XCTAssertEqual(cases[32].options.equalizer, [12, -12, 6, -6, 3, -3, 10, -10, 1, -1])
        XCTAssertTrue(cases[32].options.outputALC)
        XCTAssertEqual(cases[32].options.drc, 2)
        XCTAssertFalse(cases[21].options.outputALC)
        XCTAssertEqual(cases[21].options.soundMode, "standard")
    }

    func testGraphResolvesTopologyAndReplicatesMonoProcessingForStereo() throws {
        let runner = try LADSPAGraphRunner(plugin: repository.appendingPathComponent("native/inzone_dsp.so"))
        let graph: [String: Any] = [
            "nodes": [
                ["type": "ladspa", "name": "equalizer", "label": "inzone_eq_biquad", "control": ["b0": 0.5, "b1": 0, "b2": 0, "a1": 0, "a2": 0]],
                ["type": "builtin", "name": "gain", "label": "linear", "control": ["Mult": 2, "Add": 1]],
            ],
            "links": [["output": "gain:Out", "input": "equalizer:Input"]],
            "inputs": ["gain:In"], "outputs": ["equalizer:Output"],
        ]
        XCTAssertEqual(try runner.execute(graph: graph, channels: [[2, 4], [-2, -4]]), [[2.5, 4.5], [-1.5, -3.5]])
    }

    func testGraphDRCBypassUsesLinkedStereoPorts() throws {
        let runner = try LADSPAGraphRunner(plugin: repository.appendingPathComponent("native/inzone_dsp.so"))
        let graph: [String: Any] = ["nodes": [["type": "ladspa", "name": "drc", "label": "inzone_drc", "control": ["Mode": 0]]],
                                  "links": [[String: String]](), "inputs": ["drc:Input L", "drc:Input R"],
                                  "outputs": ["drc:Output L", "drc:Output R"]]
        let source: [[Float]] = [[0, 0.5, 2, -1], [1, -0.5, -2, 0]]
        XCTAssertEqual(try runner.execute(graph: graph, channels: source), source)
        XCTAssertThrowsError(try runner.execute(graph: graph, channels: [[1]]))
    }

    func testUnresolvedGraphDependenciesFailInsteadOfLooping() throws {
        let runner = try LADSPAGraphRunner(plugin: repository.appendingPathComponent("native/inzone_dsp.so"))
        let graph: [String: Any] = ["nodes": [["type": "builtin", "name": "copy", "label": "copy"]],
                                  "links": [[String: String]](), "inputs": ["missing:In"], "outputs": ["copy:Out"]]
        XCTAssertThrowsError(try runner.execute(graph: graph, channels: [[1, 2]]))
    }

    func testCaptureComparisonAlignsTransportAndMeasuresDoublePrecisionError() throws {
        let expected: [Float] = [0, 0, 0.5, -0.5, 1, -1, 0, 0]
        let actual: [Float] = [0, 0, 0, 0] + expected + [0, 0]
        let exact = try PipeWireDiagnostics.compareSFX(actual: actual, expected: expected)
        XCTAssertEqual(exact.transportOffsetFrames, 2)
        XCTAssertEqual(exact.sampleCount, expected.count)
        XCTAssertEqual(exact.maximumAbsoluteError, 0)
        XCTAssertEqual(exact.rootMeanSquareError, 0)
        var changed = expected
        changed[4] += 0.125
        let difference = try PipeWireDiagnostics.compareSFX(actual: changed, expected: expected)
        XCTAssertEqual(difference.maximumAbsoluteError, 0.125)
        XCTAssertEqual(difference.rootMeanSquareError, sqrt(0.125 * 0.125 / 8))
        let shorter = try PipeWireDiagnostics.compareSFX(actual: Array(expected.dropFirst(2)), expected: expected)
        XCTAssertEqual(shorter.transportOffsetFrames, -1)
        XCTAssertEqual(shorter.maximumAbsoluteError, 0)
        XCTAssertThrowsError(try PipeWireDiagnostics.compareSFX(actual: [0.5, -0.5], expected: expected))
        XCTAssertThrowsError(try PipeWireDiagnostics.compareSFX(actual: [0, 0], expected: expected))
        XCTAssertThrowsError(try PipeWireDiagnostics.compareSFX(actual: [Float.nan, 1], expected: expected))
    }

    func testSFXCaptureReplacesPlantedLeafSymlinkWithoutChangingSentinel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = directory.appendingPathComponent("analysis")
        let sentinel = directory.appendingPathComponent("capture-sentinel")
        let output = analysis.appendingPathComponent("pipewire-sfx-7.f32")
        let capture = Data([0x00, 0x80, 0x7f, 0xff])
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try Data("capture sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: sentinel)

        try PipeWireDiagnostics.writeSFXCapture(capture, to: analysis, index: 7)

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "capture sentinel")
        XCTAssertEqual(try Data(contentsOf: output), capture)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testSFXPropertiesReplacePlantedLeafSymlinkWithoutChangingSentinel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = directory.appendingPathComponent("analysis")
        let sentinel = directory.appendingPathComponent("properties-sentinel")
        let output = analysis.appendingPathComponent("pipewire-sfx-11-props.txt")
        let properties = "Props: \u{CD9C}\u{B825}\ncontrol = 0"
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        try Data("properties sentinel".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: sentinel)

        try PipeWireDiagnostics.writeSFXProperties(properties, to: analysis, index: 11)

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "properties sentinel")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), properties)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o644)
    }

    func testSFXArtifactWritersPreserveFreshOutputNamesAndContent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let analysis = directory.appendingPathComponent("analysis")
        let capture = Data([0x01, 0x02, 0x03, 0x04])
        let properties = "node.name = test-play\n"

        try PipeWireDiagnostics.writeSFXCapture(capture, to: analysis, index: 5)
        try PipeWireDiagnostics.writeSFXProperties(properties, to: analysis, index: 5)

        XCTAssertEqual(try Data(contentsOf: analysis.appendingPathComponent("pipewire-sfx-5.f32")), capture)
        XCTAssertEqual(
            try String(contentsOf: analysis.appendingPathComponent("pipewire-sfx-5-props.txt"), encoding: .utf8),
            properties
        )
    }

    func testPrivateCoreHarnessIsolatesEnvironmentAndCleansUpChildren() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try IsolatedPipeWireSession(prefix: "inzone-isolation-unit", remote: "inzone-unit-test",
                                                  logURL: directory.appendingPathComponent("process.log"))
        defer { session.close() }
        let environment = try session.run(["/usr/bin/printenv", "PIPEWIRE_REMOTE", "PIPEWIRE_RUNTIME_DIR", "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME"])
        XCTAssertEqual(environment, "inzone-unit-test\n\(session.directory.path)\n\(session.directory.path)\n\(session.directory.path)/config\n")
        let process = try session.start(["/bin/sleep", "20"])
        XCTAssertTrue(process.isRunning)
        session.close()
        XCTAssertFalse(process.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("process.log").path))
    }

    func testPrivateCoreLogReplacesLeafLinkWithoutChangingItsTarget() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sentinel = directory.appendingPathComponent("sentinel")
        let logURL = directory.appendingPathComponent("process.log")
        try Data("sentinel".utf8).write(to: sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: sentinel.path)
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: sentinel)

        let session = try IsolatedPipeWireSession(prefix: "inzone-log-unit", remote: "inzone-log-test", logURL: logURL)
        _ = try session.run(["/bin/sh", "-c", "printf diagnostic-log >&2"])
        session.close()

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "sentinel")
        XCTAssertEqual(try String(contentsOf: logURL, encoding: .utf8), "diagnostic-log")
        let sentinelAttributes = try FileManager.default.attributesOfItem(atPath: sentinel.path)
        let logAttributes = try FileManager.default.attributesOfItem(atPath: logURL.path)
        XCTAssertEqual((sentinelAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(logAttributes[.type] as? FileAttributeType, .typeRegular)
        XCTAssertEqual((logAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testPrivateCoreStagesTheExactBuiltPlugin() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try IsolatedPipeWireSession(prefix: "inzone-plugin-unit", remote: "inzone-plugin-test",
                                                  logURL: directory.appendingPathComponent("process.log"))
        defer { session.close() }
        let source = repository.appendingPathComponent("native/inzone_dsp.so")
        let digest = try Digests.sha256(file: source)
        let name = try session.stagePlugin(source)
        XCTAssertEqual(name, "inzone_dsp_" + digest.prefix(16))
        let privateDirectory = session.directory.appendingPathComponent("ladspa")
        XCTAssertEqual(try session.run(["/usr/bin/printenv", "LADSPA_PATH"]), privateDirectory.path + "\n")
        XCTAssertEqual(try Digests.sha256(file: privateDirectory.appendingPathComponent(name + ".so")), digest)
    }
}
