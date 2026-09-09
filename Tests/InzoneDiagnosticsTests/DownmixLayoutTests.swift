import Foundation
import Glibc
import XCTest
import InzoneCore
@testable import InzoneDiagnostics

final class DownmixLayoutTests: XCTestCase {
    private struct LayoutCapture {
        let layout: GraphRenderer.InputChannelLayout
        let samples: [Float]
        let links: Set<String>
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testDownmixSinksPreserveNativeLayoutsAndZeroMissingFIRInputs() throws {
        try requireRuntime()
        let stereo = try capture(layout: .stereo, activeChannels: GraphRenderer.InputChannelLayout.stereo.channels)
        let fivePointOne = try capture(
            layout: .fivePointOne,
            activeChannels: GraphRenderer.InputChannelLayout.fivePointOne.channels
        )
        let sevenPointOne = try capture(
            layout: .sevenPointOne,
            activeChannels: GraphRenderer.InputChannelLayout.sevenPointOne.channels
        )
        let stereoReference = try capture(
            layout: .sevenPointOne,
            activeChannels: GraphRenderer.InputChannelLayout.stereo.channels
        )
        let fivePointOneReference = try capture(
            layout: .sevenPointOne,
            activeChannels: GraphRenderer.InputChannelLayout.fivePointOne.channels
        )

        try assertExactLinks(stereo)
        try assertExactLinks(fivePointOne)
        try assertExactLinks(sevenPointOne)
        XCTAssertGreaterThan(peak(sevenPointOne.samples), 0.00001)
        try assertEquivalent(stereo.samples, stereoReference.samples, name: "stereo")
        try assertEquivalent(fivePointOne.samples, fivePointOneReference.samples, name: "5.1")
    }

    func testDownmixPlaybackNodeLingersUntilItsTargetAppears() throws {
        try requireRuntime()
        let graph = try downmixGraph(layout: .stereo)
        let captureProperties = try XCTUnwrap(graph["capture.props"] as? [String: Any])
        let playbackProperties = try XCTUnwrap(graph["playback.props"] as? [String: Any])
        let sinkName = try XCTUnwrap(captureProperties["node.name"] as? String)
        let outputName = try XCTUnwrap(playbackProperties["node.name"] as? String)
        XCTAssertEqual(playbackProperties["target.object"] as? String, GraphRenderer.game)
        XCTAssertEqual(playbackProperties["node.linger"] as? Bool, true)
        XCTAssertEqual(playbackProperties["node.dont-reconnect"] as? Bool, false)

        let artifacts = try artifactDirectory()
        defer { try? FileManager.default.removeItem(at: artifacts) }
        let session = try startSession(graph: graph, artifacts: artifacts, label: "linger")
        defer { session.close() }
        let wirePlumber = try startWirePlumber(session)
        try session.waitFor(description: "unlinked lingering playback node") {
            let nodes = try session.nodes()
            return nodes[sinkName] != nil && nodes[outputName] != nil
        }
        guard wirePlumber.isRunning else {
            throw InzoneError.message("The isolated WirePlumber policy exited before the linger check.")
        }
        let initialNodes = try session.nodes()
        let initialIdentifier = try nodeIdentifier(outputName, nodes: initialNodes)
        let initialProperties = try nodeProperties(outputName, nodes: initialNodes)
        XCTAssertTrue(boolean(initialProperties["node.linger"]))
        XCTAssertFalse(boolean(initialProperties["node.dont-reconnect"]))
        XCTAssertTrue(try linkMappings(session: session, outputNode: outputName, inputNode: GraphRenderer.game).isEmpty)

        _ = try session.run([
            "pw-cli", "create-node", "adapter",
            "{ factory.name = support.null-audio-sink node.name = \(GraphRenderer.game) "
                + "node.description = late-target media.class = Audio/Sink "
                + "audio.position = [ FL FR ] object.linger = true }",
        ])
        let expectedLinks = Set(["FL>FL", "FR>FR"])
        do {
            try session.waitFor(timeout: 6, description: "late INZONE target links") {
                let nodes = try session.nodes()
                guard nodes[GraphRenderer.game] != nil, nodes[outputName] != nil else { return false }
                return try linkMappings(
                    session: session, outputNode: outputName, inputNode: GraphRenderer.game
                ) == expectedLinks
            }
        } catch {
            throw try diagnosticError(error, session: session, artifacts: artifacts)
        }
        XCTAssertNotNil(try session.nodes()[GraphRenderer.game])
        XCTAssertEqual(try nodeIdentifier(outputName, nodes: session.nodes()), initialIdentifier)
    }

    private func capture(
        layout: GraphRenderer.InputChannelLayout,
        activeChannels: [String]
    ) throws -> LayoutCapture {
        var graph = try downmixGraph(layout: layout)
        let captureProperties = try XCTUnwrap(graph["capture.props"] as? [String: Any])
        var playbackProperties = try XCTUnwrap(graph["playback.props"] as? [String: Any])
        let sinkName = try XCTUnwrap(captureProperties["node.name"] as? String)
        let outputName = try XCTUnwrap(playbackProperties["node.name"] as? String)
        playbackProperties.removeValue(forKey: "target.object")
        playbackProperties["node.passive"] = false
        playbackProperties["node.always-process"] = true
        graph["playback.props"] = playbackProperties

        let artifacts = try artifactDirectory()
        defer { try? FileManager.default.removeItem(at: artifacts) }
        let session = try startSession(graph: graph, artifacts: artifacts, label: layout.rawValue)
        defer { session.close() }
        _ = try startWirePlumber(session)

        let outputURL = session.directory.appendingPathComponent("output.f32")
        let output = try session.outputFile(outputURL)
        defer { try? output.close() }
        let recorder = try session.start([
            "pw-cat", "--record", "--raw", "--format", "f32", "--rate", "48000",
            "--channels", "2", "--channel-map", "FL,FR", "--target", "0",
            "--latency", "256", "--properties",
            "{ node.name = layout-record node.always-process = true }", "-",
        ], output: output)
        do {
            try session.waitFor(description: "downmix output and recorder ports") {
                let inputs = try session.run(["pw-link", "--input"])
                let outputs = try session.run(["pw-link", "--output"])
                return inputs.contains("layout-record") && outputs.contains(outputName)
            }
        } catch {
            throw try diagnosticError(error, session: session, artifacts: artifacts)
        }
        for channel in ["FL", "FR"] {
            _ = try session.run([
                "pw-link", outputName + ":output_" + channel,
                "layout-record:input_" + channel,
            ])
        }
        let inputURL = session.directory.appendingPathComponent("input.f32")
        try FloatSamples.encode(signal(clientChannels: layout.channels, activeChannels: activeChannels))
            .write(to: inputURL)
        let player = try session.start([
            "pw-cat", "--playback", "--raw", "--format", "f32", "--rate", "48000",
            "--channels", String(layout.channels.count),
            "--channel-map", layout.channels.joined(separator: ","),
            "--target", sinkName, "--latency", "256", "--properties",
            "{ node.name = layout-play }", inputURL.path,
        ])
        try session.waitFor(description: "native-layout player node") {
            try session.nodes()["layout-play"] != nil || !player.isRunning
        }
        guard player.isRunning else {
            throw InzoneError.message("The native-layout player exited before WirePlumber linked it.")
        }
        let expectedLinks = Set(layout.channels.map { $0 + ">" + $0 })
        try session.waitFor(timeout: 6, description: "exact native-layout links") {
            try linkMappings(session: session, outputNode: "layout-play", inputNode: sinkName) == expectedLinks
        }
        let links = try linkMappings(session: session, outputNode: "layout-play", inputNode: sinkName)
        try session.wait(player, timeout: 8)
        Thread.sleep(forTimeInterval: 0.1)
        if recorder.isRunning { _ = Glibc.kill(recorder.processIdentifier, SIGINT) }
        try session.wait(recorder, timeout: 3, requireSuccess: false)
        try output.synchronize()
        try output.seek(toOffset: 0)
        let samples = try FloatSamples.decode(try output.readToEnd() ?? Data())
        guard !samples.isEmpty, samples.count % 2 == 0, samples.allSatisfy(\.isFinite) else {
            throw InzoneError.message("The native-layout downmix capture is empty or invalid.")
        }
        return LayoutCapture(layout: layout, samples: samples, links: links)
    }

    private func startSession(
        graph: [String: Any], artifacts: URL, label: String
    ) throws -> IsolatedPipeWireSession {
        let session = try IsolatedPipeWireSession(
            prefix: "inzone-layout-" + label,
            remote: "inzone-layout-test",
            logURL: artifacts.appendingPathComponent("process.log")
        )
        session.setEnvironment("INZONE_DSP_DATA_DIR", value: repository.path)
        do {
            var server = session.baseServer()
            var modules = server["context.modules"] as? [[String: Any]] ?? []
            modules.append(["name": "libpipewire-module-filter-chain", "args": graph])
            server["context.modules"] = modules
            try session.writeServer(server)
            let daemon = try session.start(["pipewire", "-c", session.serverURL.path])
            try session.waitFor(description: "isolated layout PipeWire server") {
                FileManager.default.fileExists(atPath: session.socketURL.path) || !daemon.isRunning
            }
            guard daemon.isRunning else {
                let log = (try? String(
                    contentsOf: artifacts.appendingPathComponent("process.log"), encoding: .utf8
                )) ?? ""
                throw InzoneError.message("The isolated layout PipeWire server failed to start: " + log)
            }
            return session
        } catch {
            session.close()
            throw error
        }
    }

    private func startWirePlumber(_ session: IsolatedPipeWireSession) throws -> Process {
        let process = try session.start(["wireplumber", "--profile", "policy"])
        Thread.sleep(forTimeInterval: 0.2)
        guard process.isRunning else {
            throw InzoneError.message("The isolated WirePlumber 0.5 policy failed to start.")
        }
        return process
    }

    private func diagnosticError(
        _ error: Error,
        session: IsolatedPipeWireSession,
        artifacts: URL
    ) throws -> InzoneError {
        let nodes = (try? session.nodes().keys.sorted().joined(separator: ",")) ?? "unavailable"
        let inputs = (try? session.run(["pw-link", "--input"])) ?? "unavailable"
        let outputs = (try? session.run(["pw-link", "--output"])) ?? "unavailable"
        let links = (try? session.run(["pw-link", "--links"])) ?? "unavailable"
        let log = (try? String(
            contentsOf: artifacts.appendingPathComponent("process.log"), encoding: .utf8
        )) ?? "unavailable"
        return InzoneError.message(
            error.localizedDescription + "\nnodes=" + nodes + "\ninputs=" + inputs
                + "\noutputs=" + outputs + "\nlinks=" + links + "\nlog=" + log
        )
    }

    private func linkMappings(
        session: IsolatedPipeWireSession,
        outputNode: String,
        inputNode: String
    ) throws -> Set<String> {
        guard let snapshot = try JSONSupport.decode(Data(session.run(["pw-dump"]).utf8)) as? [[String: Any]] else {
            throw InzoneError.message("Invalid PipeWire layout snapshot.")
        }
        var nodeIdentifiers: [String: Int] = [:]
        for object in snapshot where object["type"] as? String == "PipeWire:Interface:Node" {
            guard let identifier = integer(object["id"]),
                  let info = object["info"] as? [String: Any],
                  let properties = info["props"] as? [String: Any],
                  let name = properties["node.name"] as? String else { continue }
            nodeIdentifiers[name] = identifier
        }
        guard let outputNodeIdentifier = nodeIdentifiers[outputNode],
              let inputNodeIdentifier = nodeIdentifiers[inputNode] else { return [] }

        var ports: [Int: (node: Int, channel: String)] = [:]
        for object in snapshot where object["type"] as? String == "PipeWire:Interface:Port" {
            guard let identifier = integer(object["id"]),
                  let info = object["info"] as? [String: Any],
                  let properties = info["props"] as? [String: Any],
                  let node = integer(properties["node.id"]),
                  let channel = channel(properties) else { continue }
            ports[identifier] = (node, channel)
        }
        var result = Set<String>()
        for object in snapshot where object["type"] as? String == "PipeWire:Interface:Link" {
            guard let info = object["info"] as? [String: Any],
                  let outputPortIdentifier = integer(info["output-port-id"]),
                  let inputPortIdentifier = integer(info["input-port-id"]),
                  let output = ports[outputPortIdentifier], let input = ports[inputPortIdentifier],
                  output.node == outputNodeIdentifier, input.node == inputNodeIdentifier else { continue }
            result.insert(output.channel + ">" + input.channel)
        }
        return result
    }

    private func nodeIdentifier(
        _ name: String, nodes: [String: [String: Any]]
    ) throws -> Int {
        guard let identifier = integer(nodes[name]?["id"]) else {
            throw InzoneError.message("The PipeWire node is missing: " + name)
        }
        return identifier
    }

    private func nodeProperties(
        _ name: String, nodes: [String: [String: Any]]
    ) throws -> [String: Any] {
        guard let info = nodes[name]?["info"] as? [String: Any],
              let properties = info["props"] as? [String: Any] else {
            throw InzoneError.message("The PipeWire node properties are missing: " + name)
        }
        return properties
    }

    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func boolean(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return string == "true" }
        return false
    }

    private func channel(_ properties: [String: Any]) -> String? {
        if let channel = properties["audio.channel"] as? String { return channel }
        guard let name = properties["port.name"] as? String,
              let separator = name.lastIndex(of: "_") else { return nil }
        return String(name[name.index(after: separator)...])
    }

    private func signal(clientChannels: [String], activeChannels: [String]) -> [Float] {
        let leadingFrames = 48000
        let responseSpacing = 2048
        let trailingFrames = 24000
        let frames = leadingFrames + GraphRenderer.channels.count * responseSpacing + trailingFrames
        var samples = [Float](repeating: 0, count: frames * clientChannels.count)
        for channel in activeChannels {
            guard let clientIndex = clientChannels.firstIndex(of: channel),
                  let canonicalIndex = GraphRenderer.channels.firstIndex(of: channel) else { continue }
            let frame = leadingFrames + canonicalIndex * responseSpacing
            samples[frame * clientChannels.count + clientIndex] = Float(canonicalIndex + 1) * 0.05
        }
        return samples
    }

    private func assertExactLinks(_ capture: LayoutCapture) throws {
        XCTAssertEqual(
            capture.links,
            Set(capture.layout.channels.map { $0 + ">" + $0 }),
            capture.layout.rawValue
        )
    }

    private func assertEquivalent(_ actual: [Float], _ reference: [Float], name: String) throws {
        let frames = GraphRenderer.channels.count * 2048 + 2048
        let actualWindow = Array(try alignedWindow(actual, frames: frames))
        let referenceWindow = Array(try alignedWindow(reference, frames: frames))
        XCTAssertEqual(actualWindow.count, referenceWindow.count, name)
        var maximumError: Float = 0
        for index in actualWindow.indices {
            maximumError = max(maximumError, abs(actualWindow[index] - referenceWindow[index]))
        }
        XCTAssertLessThan(maximumError, 0.000001, name + " maximum error")
    }

    private func alignedWindow(_ samples: [Float], frames: Int) throws -> ArraySlice<Float> {
        guard let onset = stride(from: 0, to: samples.count, by: 2).first(where: {
            abs(samples[$0]) > 0.000000001 || abs(samples[$0 + 1]) > 0.000000001
        }) else {
            throw InzoneError.message("The downmix layout capture has no audible onset.")
        }
        let end = onset + frames * 2
        guard end <= samples.count else {
            throw InzoneError.message("The downmix layout capture is shorter than the comparison window.")
        }
        return samples[onset..<end]
    }

    private func peak(_ samples: [Float]) -> Float {
        samples.map(abs).max() ?? 0
    }

    private func downmixGraph(layout: GraphRenderer.InputChannelLayout) throws -> [String: Any] {
        try GraphRenderer(paths: InzonePaths(), firDataRoot: repository).buildDownmix(
            assets: repository.appendingPathComponent("assets"),
            plugin: repository.appendingPathComponent("native/inzone_dsp.so"),
            layout: layout
        )
    }

    private func artifactDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("inzone-layout-artifacts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func requireRuntime() throws {
        for program in ["pipewire", "wireplumber", "pw-cat", "pw-cli", "pw-dump", "pw-link"] {
            guard FileManager.default.isExecutableFile(atPath: "/usr/bin/" + program) else {
                throw XCTSkip("The real PipeWire layout test requires " + program + ".")
            }
        }
        for file in [
            repository.appendingPathComponent("native/inzone_dsp.so"),
            repository.appendingPathComponent("assets/manifest.json"),
            repository.appendingPathComponent("assets/fir-bank.bin"),
        ] where !FileManager.default.fileExists(atPath: file.path) {
            throw XCTSkip("Build the native plugin and FIR assets before running the real PipeWire layout test.")
        }
    }
}
