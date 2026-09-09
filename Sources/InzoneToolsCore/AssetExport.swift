import CoreFoundation
import Foundation
import InzoneCore

public enum AssetExport {
    public static let equalizerSourceType = "PCWidget.ViewModel.ApoFileCommunication"
    public static let presetSourceType = "PCWidget.ViewModel.SoundQualitySettingsViewModel"

    private static let presetNames = ["FLAT", "FPS1", "FPS2", "FPS3", "IMMERSION_FLAT", "BASS_BOOST", "MUSIC_VIDEO"]
    private static let equalizerFields = ["31_5Hz", "63Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz"]

    public static func equalizerTables(payload: URL, decompiled: URL, destination: URL) throws {
        let source = try readText(decompiled.appendingPathComponent(equalizerSourceType + ".decompiled.cs"))
        let expression = #"decimal\[,] Table(\w+) = new decimal\[25, 7\]\s*\{(.*?)\n\s*\};"#
        var tables = [String: [[Double]]]()
        for match in try matches(expression, in: source, options: [.dotMatchesLineSeparators]) {
            let name = match[0]
            let rows = try matches(#"\{([^{}]+)\}"#, in: match[1]).map { row in
                try row[0].components(separatedBy: ",").map { column in
                    var text = column.trimmingCharacters(in: .whitespacesAndNewlines)
                    if text.hasSuffix("m") { text.removeLast() }
                    guard let value = Double(text), value.isFinite else {
                        throw InzoneError.message("Unexpected Sony EQ table: invalid coefficient in \(name).")
                    }
                    return value
                }
            }
            guard rows.count == 25, rows.enumerated().allSatisfy({ index, row in
                row.count == 7 && row[0] == Double(12 - index)
            }) else { throw InzoneError.message("Unexpected Sony EQ table: \(name) must contain 25 ordered seven-column rows.") }
            guard tables.updateValue(rows, forKey: name) == nil else {
                throw InzoneError.message("Unexpected duplicate Sony EQ table: \(name).")
            }
        }
        guard tables.count == 10 else { throw InzoneError.message("Expected ten Sony EQ bands.") }
        let result: [String: Any] = [
            "managed_dll_sha256": try Digests.sha256(Data(contentsOf: payload.appendingPathComponent("inzonehub.dll"))),
            "rate": 48000,
            "tables": tables,
        ]
        try write(result, name: "sony-eq-tables.json", destination: destination)
    }

    public static func presets(payload: URL, decompiled: URL, destination: URL) throws {
        let source = try readText(decompiled.appendingPathComponent(presetSourceType + ".decompiled.cs"))
        var presets = [String: [String: Any]]()
        for name in presetNames {
            let marker = "case EQ_PRESET." + name + ":"
            guard let range = source.range(of: marker, options: .backwards),
                  let end = source.range(of: "break;", range: range.upperBound..<source.endIndex) else {
                throw InzoneError.message("Missing Sony preset case: \(name).")
            }
            let body = String(source[range.upperBound..<end.lowerBound])
            let gains = try equalizerFields.map { field in
                let pattern = "EQGain_" + NSRegularExpression.escapedPattern(for: field) + #" = (-?\d+);"#
                guard let match = try matches(pattern, in: body).first, let gain = Int(match[0]) else {
                    throw InzoneError.message("Missing integer EQ gain for \(name): \(field).")
                }
                return gain
            }
            presets[name.lowercased()] = [
                "eq": gains,
                "sound_mode": name == "IMMERSION_FLAT" ? "immersive" : "standard",
                "output_alc": name != "FLAT",
                "eq_enable": name != "FLAT" && name != "IMMERSION_FLAT",
                "base_eq": false,
            ]
        }
        let control = payload.appendingPathComponent("control.yaml")
        let rawControl = try Data(contentsOf: control)
        let controlText = try text(rawControl, path: control)
        guard let marker = controlText.range(of: "mode_equalizer:") else {
            throw InzoneError.message("Missing mode_equalizer section in control.yaml.")
        }
        var mode = String(controlText[marker.upperBound...])
        if let end = mode.range(of: "\nequalizer:") { mode = String(mode[..<end.lowerBound]) }
        if let parameters = mode.range(of: "params:") { mode = String(mode[..<parameters.lowerBound]) }
        let fields = ["b0", "b1", "b2", "a1", "a2"]
        var columns = [String: [Double]]()
        for field in fields {
            guard let match = try matches("- " + field + #": (\[[^\]]+\])"#, in: mode).first,
                  let values = try JSONSupport.decode(Data(match[0].utf8)) as? [NSNumber], values.count >= 10,
                  values.allSatisfy({ CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite }) else {
                throw InzoneError.message("Missing or invalid mode_equalizer coefficient column: \(field).")
            }
            columns[field] = values.map(\.doubleValue)
        }
        // Native Equalizer::SetParameters gives the coefficient arrays precedence over parameter arrays.
        let coefficients = (0..<10).map { index in fields.map { columns[$0]![index] } }
        let result: [String: Any] = [
            "managed_dll_sha256": try Digests.sha256(Data(contentsOf: payload.appendingPathComponent("inzonehub.dll"))),
            "control_yaml_sha256": Digests.sha256(rawControl),
            "rate": 48000,
            "presets": presets,
            "immersive_coefficients": coefficients,
        ]
        try write(result, name: "sony-presets.json", destination: destination)
    }

    public static func disassemble(input: URL, start: UInt64, end: UInt64) throws -> String {
        let imageBase: UInt64 = 0x180000000
        let (startAddress, startOverflow) = start.addingReportingOverflow(imageBase)
        let (endAddress, endOverflow) = end.addingReportingOverflow(imageBase)
        guard !startOverflow, !endOverflow else { throw InzoneError.message("Disassembly RVA is out of range.") }
        let expression = try NSRegularExpression(pattern: #"^\s*([0-9a-f]+):"#)
        var output = [String]()
        for line in try readText(input).components(separatedBy: "\n") {
            guard let match = expression.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line),
                  let address = UInt64(line[range], radix: 16), address >= startAddress, address < endAddress else { continue }
            let parts = line.components(separatedBy: "\t")
            if parts.count > 2, let instruction = parts.last, instruction != "int3" {
                let escapedInstruction = TerminalOutput.escaped(instruction, preservingNewlines: false)
                output.append(String(line[range]) + " " + escapedInstruction)
            }
        }
        return output.isEmpty ? "" : output.joined(separator: "\n") + "\n"
    }

    private static func matches(_ expression: String, in source: String,
                                options: NSRegularExpression.Options = []) throws -> [[String]] {
        let regularExpression = try NSRegularExpression(pattern: expression, options: options)
        return try regularExpression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map { match in
            try (1..<match.numberOfRanges).map { index in
                guard let range = Range(match.range(at: index), in: source) else {
                    throw InzoneError.message("Incomplete asset extraction match.")
                }
                return String(source[range])
            }
        }
    }

    private static func readText(_ path: URL) throws -> String {
        try text(Data(contentsOf: path), path: path)
    }

    private static func text(_ data: Data, path: URL) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw InzoneError.message("Asset source is not UTF-8: \(path.path).")
        }
        return value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private static func write(_ value: [String: Any], name: String, destination: URL) throws {
        let output = try JSONSupport.encode(value) + "\n"
        try AtomicFile.write(Data(output.utf8), to: destination.appendingPathComponent(name), permissions: 0o644)
    }
}
