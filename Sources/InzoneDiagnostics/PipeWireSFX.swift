import Foundation
import Glibc
import InzoneCore

public struct DSPComparison: Sendable {
    public let sampleCount: Int
    public let maximumAbsoluteError: Double
    public let rootMeanSquareError: Double
    public let transportOffsetFrames: Int
}

extension PipeWireDiagnostics {
    public static func compareSFX(actual: [Float], expected: [Float]) throws -> DSPComparison {
        guard !actual.isEmpty, !expected.isEmpty, actual.count % 2 == 0, expected.count % 2 == 0,
              actual.allSatisfy(\.isFinite), expected.allSatisfy(\.isFinite),
              let startActual = stride(from: 0, to: actual.count, by: 2).first(where: { abs(actual[$0]) > 0.000000000001 }),
              let startExpected = stride(from: 0, to: expected.count, by: 2).first(where: { abs(expected[$0]) > 0.000000000001 }) else {
            throw InzoneError.message("No finite stereo SFX recording or reference onset was found.")
        }
        let offset = (startActual - startExpected) / 2
        let observed = offset >= 0 ? Array(actual.dropFirst(offset * 2).prefix(expected.count)) : actual
        let reference = offset >= 0 ? expected : Array(expected.dropFirst(-offset * 2))
        guard observed.count == reference.count, !reference.isEmpty else {
            throw InzoneError.message("SFX recording length mismatch: \(observed.count) versus \(reference.count), offset \(offset).")
        }
        var maximumError = 0.0
        var squaredError = 0.0
        for index in reference.indices {
            let difference = Double(observed[index]) - Double(reference[index])
            maximumError = max(maximumError, abs(difference))
            squaredError += difference * difference
        }
        return DSPComparison(sampleCount: reference.count, maximumAbsoluteError: maximumError,
                             rootMeanSquareError: sqrt(squaredError / Double(reference.count)), transportOffsetFrames: offset)
    }

    public static func runSFX(repository: URL, paths: InzonePaths, indices: [Int] = [3, 18, 32]) throws -> [[String: Any]] {
        let cases = try LinuxDSP.cases(assets: repository.appendingPathComponent("assets"))
        guard indices.allSatisfy({ cases.indices.contains($0) }) else { throw InzoneError.message("SFX diagnostic case index is out of range.") }
        let signal = LinuxDSP.stressSignal()
        let pluginURL = repository.appendingPathComponent("native/inzone_dsp.so")
        let library = try LADSPAGraphRunner(plugin: pluginURL)
        let pluginDigest = try Digests.sha256(file: pluginURL)
        let analysis = repository.appendingPathComponent("analysis")
        var results: [[String: Any]] = []
        for index in indices {
            let test = cases[index]
            let session = try IsolatedPipeWireSession(prefix: "inzone-inline", remote: "inzone-sfx",
                                                      logURL: analysis.appendingPathComponent("pipewire-sfx-\(index).log"))
            defer { session.close() }
            let plugin = try session.stagePlugin(pluginURL)
            let temporaryPaths = InzonePaths(home: session.directory)
            try FileManager.default.createDirectory(at: temporaryPaths.assetsDirectory, withIntermediateDirectories: true)
            for name in ["sony-eq-tables.json", "sony-presets.json"] {
                try FileManager.default.copyItem(at: repository.appendingPathComponent("assets/" + name), to: temporaryPaths.assetsDirectory.appendingPathComponent(name))
            }
            try writeJSON(["name": plugin], to: temporaryPaths.assetsDirectory.appendingPathComponent("plugin.json"))
            try SettingsStore(paths: temporaryPaths).save(["balanced": test.options])
            let template = try String(contentsOf: repository.appendingPathComponent("configs/balanced.conf"), encoding: .utf8)
            let rendered = try GraphRenderer(paths: temporaryPaths).render(profile: "balanced", template: template)
            let content = rendered.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            guard let config = try JSONSupport.decode(Data(content.utf8)) as? [String: Any],
                  let rules = config["node.filter-graph.rules"] as? [[String: Any]] else {
                throw InzoneError.message("The rendered SFX profile does not contain output filter graphs.")
            }
            let graphs: [String]
            if let actions = rules.first?["actions"] as? [String: Any], let stages = actions["create-filter-graph"] as? [String] {
                graphs = stages
            } else if !test.options.outputALC, test.options.drc == 0, !test.options.hasEqualizer, test.options.soundMode == "standard" {
                let identity: [String: Any] = ["nodes": [["type": "builtin", "name": "copy", "label": "copy"]],
                    "links": [[String: String]](), "inputs": ["copy:In"], "outputs": ["copy:Out"]]
                graphs = [try JSONSupport.encode(identity, pretty: false)]
            } else { throw InzoneError.message("The rendered SFX profile is missing its expected processing stages.") }
            let inputURL = session.directory.appendingPathComponent("input.f32")
            let outputURL = session.directory.appendingPathComponent("output.raw")
            try FloatSamples.encode(signal).write(to: inputURL)
            try session.writeServer(session.baseServer())
            let daemon = try session.start(["pipewire", "-c", session.serverURL.path])
            try session.waitFor(timeout: 6, description: "isolated SFX server") {
                FileManager.default.fileExists(atPath: session.socketURL.path) || !daemon.isRunning
            }
            guard daemon.isRunning else { throw InzoneError.message("The isolated SFX server failed to start.") }
            let output = try session.outputFile(outputURL)
            defer { try? output.close() }
            let recorder = try session.start(["pw-cat", "-r", "--raw", "--format", "f32", "--rate", "48000",
                "--channels", "2", "--target", "0", "--latency", "256", "-P",
                "{ node.name = test-record node.always-process = true }", "-"], output: output)
            let player = try session.start(["pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000",
                "--channels", "2", "--target", "0", "--latency", "256", "-P", "{ node.name = test-play }", inputURL.path])
            try session.waitFor(timeout: 6, description: "SFX playback and recording nodes") {
                let nodes = try session.nodes()
                return nodes["test-play"] != nil && nodes["test-record"] != nil
            }
            let snapshot = try session.nodes()
            guard let playerIdentifier = snapshot["test-play"]?["id"] as? NSNumber else { throw InzoneError.message("SFX player node is missing.") }
            var parameters: [String] = []
            for (graphIndex, graph) in graphs.enumerated() {
                parameters.append("audioconvert.filter-graph.\(graphIndex)")
                parameters.append(graph)
            }
            _ = try session.run(["pw-cli", "set-param", playerIdentifier.stringValue, "Props", JSONSupport.encode(["params": parameters], pretty: false)])
            for name in ["test-record", "test-play"] {
                guard let identifier = snapshot[name]?["id"] as? NSNumber else { throw InzoneError.message("SFX stream node is missing.") }
                _ = try session.run(["pw-cli", "set-param", identifier.stringValue, "PortConfig",
                    JSONSupport.encode(portConfiguration(output: name == "test-play", positions: ["FL", "FR"]), pretty: false)])
            }
            try session.waitFor(timeout: 6, description: "SFX stream ports") {
                let inputs = try session.run(["pw-link", "-i"])
                let outputs = try session.run(["pw-link", "-o"])
                return inputs.contains("test-record") && outputs.contains("test-play")
            }
            for channel in ["FL", "FR"] {
                _ = try session.run(["pw-link", "test-play:output_\(channel)", "test-record:input_\(channel)"])
            }
            Thread.sleep(forTimeInterval: 0.1)
            let properties = try session.run(["pw-cli", "enum-params", playerIdentifier.stringValue, "Props"])
            var required: [String] = []
            if test.options.outputALC { required += ["sony_amp1:", "output_alc:"] }
            if test.options.hasEqualizer { required.append("custom9:") }
            if test.options.soundMode == "immersive" { required.append("immersive9:") }
            if test.options.drc != 0 { required.append("game_drc:") }
            guard required.allSatisfy(properties.contains) else { throw InzoneError.message("The real PipeWire loader did not instantiate every SFX stage for \(test.name).") }
            try session.wait(player, timeout: 12)
            Thread.sleep(forTimeInterval: 0.2)
            if recorder.isRunning { _ = Glibc.kill(recorder.processIdentifier, SIGINT) }
            try session.wait(recorder, timeout: 3, requireSuccess: false)
            try output.synchronize()
            try output.seek(toOffset: 0)
            let actualData = try output.readToEnd() ?? Data()
            let actual = try FloatSamples.decode(actualData)
            try writeSFXCapture(actualData, to: analysis, index: index)
            let decoded = try graphs.map { graph -> [String: Any] in
                guard let result = try JSONSupport.decode(Data(graph.utf8)) as? [String: Any] else { throw InzoneError.message("Invalid encoded SFX graph.") }
                return result
            }
            try writeJSON(decoded, to: analysis.appendingPathComponent("pipewire-sfx-\(index)-graphs.json"))
            try writeSFXProperties(properties, to: analysis, index: index)
            var native = [stride(from: 0, to: signal.count, by: 2).map { signal[$0] },
                          stride(from: 1, to: signal.count, by: 2).map { signal[$0] }]
            for graph in decoded.reversed() {
                try session.checkCancellation()
                native = try library.execute(graph: graph, channels: native)
            }
            guard native.count == 2, native[0].count == native[1].count else { throw InzoneError.message("The native SFX reference must have two equal-length channels.") }
            var expected: [Float] = []
            expected.reserveCapacity(native[0].count * 2)
            for frame in native[0].indices { expected.append(native[0][frame]); expected.append(native[1][frame]) }
            let comparison = try compareSFX(actual: actual, expected: expected)
            let result: [String: Any] = ["case": test.name, "samples": comparison.sampleCount,
                "max_absolute_error": comparison.maximumAbsoluteError, "rms_error": comparison.rootMeanSquareError,
                "transport_offset_frames": comparison.transportOffsetFrames]
            results.append(result)
            try writeJSON(["baseline": "same Linux LADSPA graph outside PipeWire",
                           "plugin_sha256": pluginDigest,
                           "pipewire": "real audioconvert.filter-graph.N in isolated stream", "cases": results],
                          to: analysis.appendingPathComponent("pipewire-sfx-results.json"))
            guard comparison.maximumAbsoluteError < 0.000001 else { throw InzoneError.message("SFX samples differ from the native reference by \(comparison.maximumAbsoluteError) in \(test.name).") }
        }
        return results
    }

    static func writeSFXCapture(_ data: Data, to analysis: URL, index: Int) throws {
        try AtomicFile.write(
            data, to: analysis.appendingPathComponent("pipewire-sfx-\(index).f32"), permissions: 0o644
        )
    }

    static func writeSFXProperties(_ properties: String, to analysis: URL, index: Int) throws {
        try AtomicFile.write(
            Data(properties.utf8), to: analysis.appendingPathComponent("pipewire-sfx-\(index)-props.txt"),
            permissions: 0o644
        )
    }
}
