import Foundation
import Glibc
import InzoneCore

public enum PipeWireDiagnostics {
    public static func runImpulse(repository: URL) throws -> [String: Any] {
        let analysis = repository.appendingPathComponent("analysis")
        let session = try IsolatedPipeWireSession(prefix: "inzone-dsp-test", remote: "inzone-test",
                                                  logURL: analysis.appendingPathComponent("pipewire-impulse.log"))
        defer { session.close() }
        var graph = try GraphRenderer(paths: InzonePaths()).buildSurround(
            assets: repository.appendingPathComponent("assets"), plugin: repository.appendingPathComponent("native/inzone_dsp.so"))
        guard var playback = graph["playback.props"] as? [String: Any] else { throw InzoneError.message("Surround playback properties are missing.") }
        playback.removeValue(forKey: "target.object")
        playback["node.passive"] = false
        playback["node.always-process"] = true
        graph["playback.props"] = playback
        var server = session.baseServer()
        var modules = server["context.modules"] as? [[String: Any]] ?? []
        modules.append(["name": "libpipewire-module-filter-chain", "args": graph])
        server["context.modules"] = modules
        try session.writeServer(server)
        let daemon = try session.start(["pipewire", "-c", session.serverURL.path])
        try session.waitFor(description: "isolated PipeWire server") {
            FileManager.default.fileExists(atPath: session.socketURL.path) || !daemon.isRunning
        }
        guard daemon.isRunning else { throw InzoneError.message("The isolated PipeWire server failed to start.") }

        let frames = 48000 + 8 * 4096 + 96000
        var samples = [Float](repeating: 0, count: frames * 8)
        for channel in 0..<8 { samples[(48000 + channel * 4096) * 8 + channel] = 0.125 }
        var generator = DiagnosticRandom(seed: 2987)
        let signalStart = 48000 + 8 * 4096
        let levels: [Double] = [0.05, 0.4, 2, 0.1]
        for frame in 0..<48000 {
            for channel in 0..<8 {
                samples[(signalStart + frame) * 8 + channel] = Float(levels[frame / 12000] * generator.uniform())
            }
        }
        let inputURL = session.directory.appendingPathComponent("input.raw")
        let outputURL = session.directory.appendingPathComponent("output.raw")
        try FloatSamples.encode(samples).write(to: inputURL)
        let output = try session.outputFile(outputURL)
        defer { try? output.close() }
        let recorder = try session.start(["pw-cat", "-r", "--raw", "--format", "f32", "--rate", "48000",
            "--channels", "2", "--target", "0", "--latency", "256", "-P",
            "{ node.name = test-record node.always-process = true }", "-"], output: output)
        let player = try session.start(["pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000",
            "--channels", "8", "--channel-map", GraphRenderer.channels.joined(separator: ","),
            "--target", "0", "--latency", "256", "-P", "{ node.name = test-play }", inputURL.path])
        try session.waitFor(description: "isolated playback and recording nodes") {
            let nodes = try session.nodes()
            return nodes["test-play"] != nil && nodes["test-record"] != nil
        }
        for (name, node) in try session.nodes() {
            guard ["test-play", "test-record", "inzone.sony-surround", "inzone.sony-surround.output"].contains(name),
                  let identifier = node["id"] as? NSNumber else { continue }
            let outputDirection = name == "test-play" || name == "inzone.sony-surround.output"
            let positions = name == "test-play" || name == "inzone.sony-surround" ? GraphRenderer.channels : ["FL", "FR"]
            let parameter = Self.portConfiguration(output: outputDirection, positions: positions)
            _ = try session.run(["pw-cli", "set-param", identifier.stringValue, "PortConfig", JSONSupport.encode(parameter, pretty: false)])
        }
        try session.waitFor(description: "isolated DSP ports") {
            let inputs = try session.run(["pw-link", "-i"])
            let outputs = try session.run(["pw-link", "-o"])
            return inputs.contains("test-record") && outputs.contains("test-play")
        }
        for channel in ["FL", "FR"] {
            _ = try session.run(["pw-link", "inzone.sony-surround.output:output_\(channel)", "test-record:input_\(channel)"])
        }
        for channel in GraphRenderer.channels {
            _ = try session.run(["pw-link", "test-play:output_\(channel)", "inzone.sony-surround:playback_\(channel)"])
        }
        try session.wait(player, timeout: 12)
        Thread.sleep(forTimeInterval: 0.2)
        if recorder.isRunning { _ = Glibc.kill(recorder.processIdentifier, SIGINT) }
        try session.wait(recorder, timeout: 3, requireSuccess: false)
        try output.synchronize()
        try output.seek(toOffset: 0)
        let values = try FloatSamples.decode(try output.readToEnd() ?? Data())
        guard !values.isEmpty, values.allSatisfy(\.isFinite),
              let first = stride(from: 0, to: values.count, by: 2).first(where: { abs(values[$0]) > 0.00001 }).map({ $0 / 2 }) else {
            throw InzoneError.message("The isolated surround graph produced no finite audible output.")
        }
        var peaks: [Double] = []
        for channel in 0..<8 {
            let start = max(0, first + channel * 4096 - 128) * 2
            let end = min(values.count, (first + channel * 4096 + 2048) * 2)
            guard start < end else { throw InzoneError.message("The surround recording is missing channel \(channel).") }
            peaks.append(Double(values[start..<end].map(abs).max() ?? 0))
        }
        let peak = Double(values.map(abs).max() ?? 0)
        let tail = Double(values.suffix(24000).map(abs).max() ?? 0)
        guard peaks.allSatisfy({ $0 > 0.00001 }), peak <= 1.000001, tail < 0.00001 else {
            throw InzoneError.message("Surround response, ALC bound, or silence recovery validation failed: peaks=\(peaks), peak=\(peak), tail=\(tail).")
        }
        let result: [String: Any] = ["samples": values.count, "channel_impulse_peaks": peaks, "peak": peak,
            "plugin_sha256": try Digests.sha256(file: repository.appendingPathComponent("native/inzone_dsp.so")),
            "silence_tail_peak": tail, "checks": "finite output, eight channel responses, ALC bound and silence recovery"]
        try Self.writeJSON(result, to: analysis.appendingPathComponent("impulse-results.json"))
        return result
    }

    static func portConfiguration(output: Bool, positions: [String]) -> [String: Any] {
        ["direction": output ? "Output" : "Input", "mode": "dsp", "format": [
            "mediaType": "audio", "mediaSubtype": "raw", "format": "F32P", "rate": 48000,
            "channels": positions.count, "position": positions,
        ]]
    }

    static func writeJSON(_ value: Any, to destination: URL) throws {
        try AtomicFile.write(Data((JSONSupport.encode(value) + "\n").utf8), to: destination)
    }
}

final class IsolatedPipeWireSession {
    let directory: URL
    let remote: String
    var serverURL: URL { directory.appendingPathComponent("server.conf") }
    var socketURL: URL { directory.appendingPathComponent(remote) }
    private var environment: [String: String]
    private let log: FileHandle
    private var cancellation: IsolatedDiagnosticCancellation?
    private var processes: [Process] = []
    private var closed = false

    init(prefix: String, remote: String, logURL: URL) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        self.remote = remote
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stagedLog = try AtomicFile.stage(for: logURL)
            log = try stagedLog.publishAndTakeFileHandle()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        var values = ProcessInfo.processInfo.environment
        values["PIPEWIRE_RUNTIME_DIR"] = directory.path
        values["XDG_RUNTIME_DIR"] = directory.path
        values["PIPEWIRE_REMOTE"] = remote
        values["XDG_CONFIG_HOME"] = directory.appendingPathComponent("config").path
        // Clients still require the installed client.conf while the daemon receives an explicit private configuration.
        for key in ["PIPEWIRE_CONFIG_DIR", "PIPEWIRE_CONFIG_NAME", "PIPEWIRE_CONFIG_PREFIX"] { values.removeValue(forKey: key) }
        environment = values
        cancellation = IsolatedDiagnosticCancellation()
    }

    deinit { close() }

    func stagePlugin(_ source: URL) throws -> String {
        let name = "inzone_dsp_" + (try Digests.sha256(file: source)).prefix(16)
        let libraryDirectory = directory.appendingPathComponent("ladspa")
        try FileManager.default.createDirectory(at: libraryDirectory, withIntermediateDirectories: true)
        let destination = libraryDirectory.appendingPathComponent(name + ".so")
        try FileManager.default.copyItem(at: source, to: destination)
        // The unique basename and private search path prevent an installed plugin from substituting for the build under test.
        environment["LADSPA_PATH"] = libraryDirectory.path
        return name
    }

    func close() {
        guard !closed else { return }
        closed = true
        for process in processes.reversed() { stop(process) }
        processes.removeAll()
        try? log.close()
        try? FileManager.default.removeItem(at: directory)
        cancellation = nil
    }

    func baseServer() -> [String: Any] {
        ["context.properties": ["core.daemon": true, "core.name": remote, "default.clock.rate": 48000, "default.clock.quantum": 256],
         "context.spa-libs": ["audio.convert.*": "audioconvert/libspa-audioconvert", "support.*": "support/libspa-support"],
         "context.modules": ["protocol-native", "access", "metadata", "spa-node-factory", "client-node", "adapter", "link-factory"].map { ["name": "libpipewire-module-" + $0] },
         "context.objects": [["factory": "spa-node-factory", "args": ["factory.name": "support.node.driver", "node.name": "Dummy-Driver", "node.group": "pipewire.dummy", "priority.driver": 200000]]]]
    }

    func writeServer(_ config: [String: Any]) throws {
        let text = try config.keys.sorted().map { key in "\(key) = \(try Self.spa(config[key]!))" }.joined(separator: "\n")
        try Data(text.utf8).write(to: serverURL)
    }

    private static func spa(_ value: Any) throws -> String {
        if let object = value as? [String: Any] {
            return try "{ " + object.keys.sorted().map { key in
                try JSONSupport.encode(key, pretty: false) + " = " + spa(object[key]!)
            }.joined(separator: " ") + " }"
        }
        if let array = value as? [Any] { return try "[ " + array.map(spa).joined(separator: " ") + " ]" }
        return try JSONSupport.encode(value, pretty: false)
    }

    func outputFile(_ url: URL) throws -> FileHandle {
        let stagedOutput = try AtomicFile.stage(for: url)
        return try stagedOutput.publishAndTakeFileHandle()
    }

    func start(_ arguments: [String], output: FileHandle? = nil) throws -> Process {
        try checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output ?? FileHandle.nullDevice
        process.standardError = log
        try process.run()
        processes.append(process)
        return process
    }

    func run(_ arguments: [String], timeout: TimeInterval = 8) throws -> String {
        let outputURL = directory.appendingPathComponent("command-\(UUID().uuidString)")
        let output = try outputFile(outputURL)
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = try start(arguments, output: output)
        try wait(process, timeout: timeout)
        try output.seek(toOffset: 0)
        return String(decoding: try output.readToEnd() ?? Data(), as: UTF8.self)
    }

    func wait(_ process: Process, timeout: TimeInterval, requireSuccess: Bool = true) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            try checkCancellation()
            Thread.sleep(forTimeInterval: 0.01)
        }
        try checkCancellation()
        guard !process.isRunning else {
            stop(process)
            throw InzoneError.message("Diagnostic command timed out: \(process.arguments?.joined(separator: " ") ?? "process")")
        }
        process.waitUntilExit()
        guard !requireSuccess || process.terminationStatus == 0 else {
            throw InzoneError.message("Diagnostic command exited with status \(process.terminationStatus): \(process.arguments?.joined(separator: " ") ?? "process")")
        }
    }

    func waitFor(timeout: TimeInterval = 5, description: String, condition: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try checkCancellation()
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw InzoneError.message("Timed out waiting for \(description).")
    }

    func checkCancellation() throws {
        guard isolatedDiagnosticCancelled == 0 else { throw InzoneError.message("Private PipeWire diagnostics were cancelled.") }
    }

    func nodes() throws -> [String: [String: Any]] {
        guard let snapshot = try JSONSupport.decode(Data(run(["pw-dump"]).utf8)) as? [[String: Any]] else {
            throw InzoneError.message("Invalid private PipeWire graph snapshot.")
        }
        var result: [String: [String: Any]] = [:]
        for node in snapshot where node["type"] as? String == "PipeWire:Interface:Node" {
            if let info = node["info"] as? [String: Any], let properties = info["props"] as? [String: Any],
               let name = properties["node.name"] as? String { result[name] = node }
        }
        return result
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { _ = Glibc.kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

nonisolated(unsafe) private var isolatedDiagnosticCancelled: sig_atomic_t = 0
private func isolatedDiagnosticSignalHandler(_ signal: Int32) { isolatedDiagnosticCancelled = 1 }

private final class IsolatedDiagnosticCancellation {
    private let previousInterrupt: sig_t?
    private let previousTermination: sig_t?

    init() {
        isolatedDiagnosticCancelled = 0
        previousInterrupt = Glibc.signal(SIGINT, isolatedDiagnosticSignalHandler)
        previousTermination = Glibc.signal(SIGTERM, isolatedDiagnosticSignalHandler)
    }

    deinit {
        _ = Glibc.signal(SIGINT, previousInterrupt)
        _ = Glibc.signal(SIGTERM, previousTermination)
    }
}
