import Foundation
import XCTest
import InzoneCore
@testable import InzoneToolsCore

final class AssetExportTests: XCTestCase {
    private let names = ["FLAT", "FPS1", "FPS2", "FPS3", "IMMERSION_FLAT", "BASS_BOOST", "MUSIC_VIDEO"]
    private let fields = ["31_5Hz", "63Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func require(_ relative: String) throws -> URL {
        let path = repository.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: path.path) else { throw XCTSkip("Locally acquired asset is absent: \(relative)") }
        return path
    }

    private func withSources(_ body: (_ payload: URL, _ decompiled: URL, _ destination: URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-asset-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let payload = directory.appendingPathComponent("payload")
        let decompiled = directory.appendingPathComponent("decompiled")
        let destination = directory.appendingPathComponent("assets")
        for path in [payload, decompiled, destination] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        try Data("fixture managed DLL".utf8).write(to: payload.appendingPathComponent("inzonehub.dll"))
        try body(payload, decompiled, destination)
    }

    private func write(_ source: String, type: String, in directory: URL) throws {
        try Data(source.utf8).write(to: directory.appendingPathComponent(type + ".decompiled.cs"))
    }

    private func canonicalHash(_ file: URL) throws -> String {
        let value = try JSONSupport.decode(Data(contentsOf: file))
        return try Digests.sha256(Data(JSONSupport.encode(value).utf8))
    }

    private func tableSource(count: Int = 10) -> String {
        (0..<count).map { band in
            let rows = (0..<25).map { index in "    { \(12 - index)m, 3.20m, 1.25m, -1.5m, 0.25m, -1.5m, 0.25m }" }.joined(separator: ",\n")
            return "decimal[,] TableBand\(band) = new decimal[25, 7]\n{\n" + rows + "\n};"
        }.joined(separator: "\n")
    }

    private func presetSource() -> String {
        let complete = names.enumerated().map { index, name in
            let gains = fields.map { "EQGain_\($0) = \(index - 3);" }.joined(separator: "\n")
            return "case EQ_PRESET.\(name):\n" + gains + "\nbreak;"
        }.joined(separator: "\n")
        return "// Unicode context verifies UTF-16 regular expression ranges: \u{C18C}\u{B2C8}.\ncase EQ_PRESET.FLAT:\nEQGain_31_5Hz = 99;\nbreak;\n" + complete
    }

    private func controlSource() -> String {
        let columns = ["b0", "b1", "b2", "a1", "a2"].enumerated().map { column, name in
            "    - \(name): [" + (0..<12).map { String(column * 10 + $0) }.joined(separator: ", ") + "]"
        }.joined(separator: "\n")
        return "mode_equalizer:\n  coeffs:\n" + columns + "\n  params:\n    - b0: [999]\nequalizer:\n  coeffs:\n    - b0: [888]\n"
    }

    func testExistingEqualizerExtractionMatchesPinnedOracle() throws {
        let library = try require("analysis/payload/inzonehub.dll")
        let source = try require("analysis/decompiled/" + AssetExport.equalizerSourceType + ".decompiled.cs")
        try withSources { _, _, destination in
            try AssetExport.equalizerTables(payload: library.deletingLastPathComponent(), decompiled: source.deletingLastPathComponent(), destination: destination)
            let output = destination.appendingPathComponent("sony-eq-tables.json")
            XCTAssertEqual(try canonicalHash(output), "5096ca61d57c3061f52e14bad7f920d3d566f5f8052e69941e8e36fb323730d6")
            let value = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: output)) as? [String: Any])
            XCTAssertEqual(value["managed_dll_sha256"] as? String, "77082a578f25b2ef6722e256fd7f53de0d69678a8c852a7aaf4e8f569c542a5f")
            XCTAssertEqual(try Data(contentsOf: output).last, 10)
        }
    }

    func testExistingPresetExtractionMatchesPinnedOracle() throws {
        let library = try require("analysis/payload/inzonehub.dll")
        _ = try require("analysis/payload/control.yaml")
        let source = try require("analysis/decompiled/" + AssetExport.presetSourceType + ".decompiled.cs")
        try withSources { _, _, destination in
            try AssetExport.presets(payload: library.deletingLastPathComponent(), decompiled: source.deletingLastPathComponent(), destination: destination)
            let output = destination.appendingPathComponent("sony-presets.json")
            XCTAssertEqual(try canonicalHash(output), "83193365b6c7c5fc6a0588509d37c4f0feb4554c0f5194f483b2181651a138fd")
            let value = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: output)) as? [String: Any])
            XCTAssertEqual(value["control_yaml_sha256"] as? String, "859c9cc66538ab11156783199c2dcd19687895e72e48e4693799389c9aab4621")
            XCTAssertEqual(try Data(contentsOf: output).last, 10)
        }
    }

    func testSyntheticEqualizerTablesPreserveShapeGainsAndDecimalValues() throws {
        try withSources { payload, decompiled, destination in
            try write(tableSource().replacingOccurrences(of: "\n", with: "\r\n"), type: AssetExport.equalizerSourceType, in: decompiled)
            try AssetExport.equalizerTables(payload: payload, decompiled: decompiled, destination: destination)
            let value = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: destination.appendingPathComponent("sony-eq-tables.json"))) as? [String: Any])
            let tables = try XCTUnwrap(value["tables"] as? [String: [[Double]]])
            XCTAssertEqual(tables.count, 10)
            XCTAssertEqual(tables["Band0"]?.count, 25)
            XCTAssertEqual(tables["Band0"]?.first, [12, 3.2, 1.25, -1.5, 0.25, -1.5, 0.25])
            XCTAssertEqual(tables["Band9"]?.last?.first, -12)
            XCTAssertEqual(value["managed_dll_sha256"] as? String, Digests.sha256(Data("fixture managed DLL".utf8)))
            XCTAssertEqual(value["rate"] as? Int, 48000)
        }
    }

    func testMalformedEqualizerTablesPreserveExistingOutput() throws {
        let complete = tableSource()
        let invalid = [
            tableSource(count: 9),
            complete + "\n" + tableSource(count: 1),
            complete.replacingOccurrences(of: "{ 12m,", with: "{ 11m,"),
            complete.replacingOccurrences(of: "3.20m, ", with: ""),
            complete.replacingOccurrences(of: "3.20m", with: "NaNm"),
            complete.replacingOccurrences(of: "3.20m", with: "invalidm"),
        ]
        try withSources { payload, decompiled, destination in
            let output = destination.appendingPathComponent("sony-eq-tables.json")
            let sentinel = Data("previous output".utf8)
            try sentinel.write(to: output)
            for source in invalid {
                try write(source, type: AssetExport.equalizerSourceType, in: decompiled)
                XCTAssertThrowsError(try AssetExport.equalizerTables(payload: payload, decompiled: decompiled, destination: destination))
                XCTAssertEqual(try Data(contentsOf: output), sentinel)
            }
        }
    }

    func testPresetExtractionUsesFinalSwitchCasesAndEffectiveCoefficients() throws {
        try withSources { payload, decompiled, destination in
            try write(presetSource(), type: AssetExport.presetSourceType, in: decompiled)
            let control = controlSource().replacingOccurrences(of: "\n", with: "\r\n")
            try Data(control.utf8).write(to: payload.appendingPathComponent("control.yaml"))
            try AssetExport.presets(payload: payload, decompiled: decompiled, destination: destination)
            let value = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: destination.appendingPathComponent("sony-presets.json"))) as? [String: Any])
            let presets = try XCTUnwrap(value["presets"] as? [String: [String: Any]])
            XCTAssertEqual(presets.count, 7)
            XCTAssertEqual(presets["flat"]?["eq"] as? [Int], Array(repeating: -3, count: 10))
            XCTAssertEqual(presets["flat"]?["eq_enable"] as? Bool, false)
            XCTAssertEqual(presets["flat"]?["output_alc"] as? Bool, false)
            XCTAssertEqual(presets["immersion_flat"]?["sound_mode"] as? String, "immersive")
            XCTAssertEqual(presets["immersion_flat"]?["eq_enable"] as? Bool, false)
            XCTAssertEqual(presets["immersion_flat"]?["output_alc"] as? Bool, true)
            XCTAssertEqual(presets["fps1"]?["eq_enable"] as? Bool, true)
            XCTAssertEqual(presets["fps1"]?["base_eq"] as? Bool, false)
            let coefficients = try XCTUnwrap(value["immersive_coefficients"] as? [[Double]])
            XCTAssertEqual(coefficients.count, 10)
            XCTAssertEqual(coefficients.first, [0, 10, 20, 30, 40])
            XCTAssertEqual(coefficients.last, [9, 19, 29, 39, 49])
            XCTAssertEqual(value["control_yaml_sha256"] as? String, Digests.sha256(Data(control.utf8)))
        }
    }

    func testPresetExtractionRejectsMissingFieldsAndMalformedColumns() throws {
        let source = presetSource()
        let control = controlSource()
        let invalid: [(String, String)] = [
            (source.replacingOccurrences(of: "case EQ_PRESET.FPS1:", with: "case EQ_PRESET.UNKNOWN:"), control),
            (source.replacingOccurrences(of: "EQGain_63Hz = -2;", with: "EQGain_63Hz = variable;"), control),
            (source, control.replacingOccurrences(of: "mode_equalizer:", with: "missing:")),
            (source, control.replacingOccurrences(of: "- a1:", with: "- missing:")),
            (source, control.replacingOccurrences(of: "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]", with: "[0, 1]")),
            (source, control.replacingOccurrences(of: "[0, 1,", with: "[true, 1,")),
        ]
        try withSources { payload, decompiled, destination in
            for (invalidSource, invalidControl) in invalid {
                try write(invalidSource, type: AssetExport.presetSourceType, in: decompiled)
                try Data(invalidControl.utf8).write(to: payload.appendingPathComponent("control.yaml"))
                XCTAssertThrowsError(try AssetExport.presets(payload: payload, decompiled: decompiled, destination: destination))
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("sony-presets.json").path))
            }
        }
    }

    func testDisassemblySlicesRelativeAddressesAndOmitsInt3() throws {
        try withSources { payload, _, _ in
            let input = payload.appendingPathComponent("virtualizer.asm")
            let source = """
            Disassembly of section .text:
               180000fff:\t00\tbefore
               180001000:\t48 83 ec 28\tsub    rsp,0x28
               180001004:\tcc\tint3
               180001005:\t90\tnop
               180001006: missing-tab-columns
               180001010:\tc3\tret
            """
            try Data(source.utf8).write(to: input)
            XCTAssertEqual(try AssetExport.disassemble(input: input, start: 0x1000, end: 0x1010), "180001000 sub    rsp,0x28\n180001005 nop\n")
            XCTAssertEqual(try AssetExport.disassemble(input: input, start: 0x1010, end: 0x1000), "")
            XCTAssertEqual(try AssetExport.disassemble(input: input, start: 0x1000, end: 0x1000), "")
            XCTAssertThrowsError(try AssetExport.disassemble(input: input, start: UInt64.max, end: UInt64.max))
        }
    }

    func testDisassemblyEscapesTerminalControlsAndPreservesUnicode() throws {
        try withSources { payload, _, _ in
            let input = payload.appendingPathComponent("virtualizer-controls.asm")
            let instruction = "mov    \u{D55C}\u{AE00},e\u{301}\u{0000}\u{0007}\u{001B}[2J\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}"
            try Data(("   180001000:\t90\t" + instruction + "\n").utf8).write(to: input)

            let output = try AssetExport.disassemble(input: input, start: 0x1000, end: 0x1001)
            let expected = "180001000 mov    \u{D55C}\u{AE00},e\u{301}" + #"\u{0000}\u{0007}\u{001B}[2J\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}"# + "\n"
            XCTAssertEqual(output, expected)
            XCTAssertEqual(output.unicodeScalars.last?.value, 0x0A)
            XCTAssertEqual(output.unicodeScalars.filter { $0.value == 0x0A }.count, 1)
            for scalar in instruction.unicodeScalars where
                scalar.value < 0x20 || scalar.value == 0x7F || (0x80...0x9F).contains(scalar.value)
                    || scalar.properties.generalCategory == .control
                    || scalar.properties.generalCategory == .format
                    || scalar.properties.generalCategory == .lineSeparator
                    || scalar.properties.generalCategory == .paragraphSeparator
                    || scalar.properties.generalCategory == .surrogate
            {
                XCTAssertFalse(output.unicodeScalars.contains(scalar), "Raw terminal control: \(scalar.value)")
            }
        }
    }

    func testExistingDisassemblyOpeningInstructions() throws {
        let input = try require("analysis/virtualizer.asm")
        let output = try AssetExport.disassemble(input: input, start: 0x1000, end: 0x1007)
        XCTAssertEqual(output, "180001000 sub    rsp,0x28\n180001004 xor    r8d,r8d\n")
    }
}
