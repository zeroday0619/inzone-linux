import Foundation

/// Keeps application playback streams connected while the managed sinks are rebuilt.
final class PulseStreamParking {
    private struct SinkInput {
        let identifier: Int
        let sinkIdentifier: Int
        let client: String
    }

    private struct ParkedInput {
        let identifier: Int
        let originalSink: String
        let followsDefault: Bool
    }

    private let runner: any CommandRunning
    private let sinkName: String
    private let moduleIdentifier: String
    private let previousDefaultSink: String
    private let inputs: [ParkedInput]

    private init(
        runner: any CommandRunning, sinkName: String, moduleIdentifier: String,
        previousDefaultSink: String, inputs: [ParkedInput]
    ) {
        self.runner = runner
        self.sinkName = sinkName
        self.moduleIdentifier = moduleIdentifier
        self.previousDefaultSink = previousDefaultSink
        self.inputs = inputs
    }

    static func park(
        runner: any CommandRunning, previousDefaultSink: String? = nil
    ) throws -> PulseStreamParking? {
        let sinks = try listSinks(runner: runner)
        let inputList = try listInputs(runner: runner)
        let candidates = inputList.compactMap { input -> (Int, String)? in
            guard input.client != "-", let sink = sinks[input.sinkIdentifier],
                  sink == ProfileController.game || sink == ProfileController.chat
                    || sink.hasPrefix("inzone.sony-") else { return nil }
            return (input.identifier, sink)
        }
        guard !candidates.isEmpty else { return nil }
        let defaultSink = try previousDefaultSink ?? runner.run(["pactl", "get-default-sink"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = candidates.map { identifier, sink in
            return ParkedInput(
                identifier: identifier, originalSink: sink,
                followsDefault: sink == defaultSink
            )
        }

        let sinkName = "inzone_h9_ii_park_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let output = try runner.run([
            "pactl", "load-module", "module-null-sink", "sink_name=\(sinkName)",
        ], input: nil, timeout: 10)
        let moduleIdentifier = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Int(moduleIdentifier) != nil else {
            throw InzoneError.message("PulseAudio did not return a temporary sink module identifier.")
        }
        let parking = PulseStreamParking(
            runner: runner, sinkName: sinkName, moduleIdentifier: moduleIdentifier,
            previousDefaultSink: defaultSink, inputs: selected
        )
        do {
            try parking.parkAgain()
            return parking
        } catch {
            let parkingError = error
            do { try parking.restoreOriginalRouting() }
            catch let restorationError {
                throw InzoneError.message(
                    "\(parkingError.localizedDescription) Temporary sink restoration also failed: "
                        + restorationError.localizedDescription
                )
            }
            throw parkingError
        }
    }

    func parkAgain() throws {
        let parkingSink = try waitForSink(named: sinkName)
        for input in inputs {
            try move(input.identifier, to: sinkName, sinkIdentifier: parkingSink)
        }
    }

    func finish(defaultSink: String) throws {
        let sinks = try Self.listSinks(runner: runner)
        guard let defaultIdentifier = sinks.first(where: { $0.value == defaultSink })?.key else {
            throw InzoneError.message("The playback sink is unavailable after profile switching: \(defaultSink).")
        }
        for input in inputs {
            let originalIdentifier = sinks.first(where: { $0.value == input.originalSink })?.key
            let target = input.followsDefault || originalIdentifier == nil ? defaultSink : input.originalSink
            let targetIdentifier = target == defaultSink ? defaultIdentifier : originalIdentifier!
            try move(input.identifier, to: target, sinkIdentifier: targetIdentifier)
        }
        if let parkingIdentifier = sinks.first(where: { $0.value == sinkName })?.key,
           try Self.listInputs(runner: runner).contains(where: { $0.sinkIdentifier == parkingIdentifier }) {
            throw InzoneError.message("The temporary playback sink still has active streams.")
        }
        _ = try runner.run(["pactl", "unload-module", moduleIdentifier], input: nil, timeout: 10)
    }

    func restoreOriginalRouting() throws {
        try finish(defaultSink: previousDefaultSink)
    }

    private func move(_ identifier: Int, to sink: String, sinkIdentifier: Int) throws {
        guard let current = try Self.listInputs(runner: runner).first(where: { $0.identifier == identifier }),
              current.sinkIdentifier != sinkIdentifier else { return }
        do {
            _ = try runner.run([
                "pactl", "move-sink-input", String(identifier), sink,
            ], input: nil, timeout: 10)
        } catch {
            guard try Self.listInputs(runner: runner).contains(where: { $0.identifier == identifier }) else { return }
            throw error
        }
        for _ in 0..<100 {
            guard let observed = try Self.listInputs(runner: runner).first(where: { $0.identifier == identifier }) else {
                return
            }
            if observed.sinkIdentifier == sinkIdentifier { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw InzoneError.message("Playback stream \(identifier) did not move to \(sink).")
    }

    private func waitForSink(named name: String) throws -> Int {
        for _ in 0..<100 {
            if let identifier = try Self.listSinks(runner: runner).first(where: { $0.value == name })?.key {
                return identifier
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw InzoneError.message("The temporary playback sink did not appear: \(name).")
    }

    private static func listSinks(runner: any CommandRunning) throws -> [Int: String] {
        let output = try runner.run(["pactl", "list", "short", "sinks"], input: nil, timeout: 5)
        var sinks: [Int: String] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: \.isWhitespace)
            if columns.count >= 2, let identifier = Int(columns[0]) {
                sinks[identifier] = String(columns[1])
            }
        }
        return sinks
    }

    private static func listInputs(runner: any CommandRunning) throws -> [SinkInput] {
        let output = try runner.run(["pactl", "list", "short", "sink-inputs"], input: nil, timeout: 5)
        return output.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 3, let identifier = Int(columns[0]),
                  let sinkIdentifier = Int(columns[1]) else { return nil }
            return SinkInput(
                identifier: identifier, sinkIdentifier: sinkIdentifier, client: String(columns[2])
            )
        }
    }
}
