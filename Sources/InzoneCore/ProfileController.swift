import Foundation

/// Applies profiles and verifies that their requested routing and DSP are available.
public final class ProfileController: Sendable {
    public static let game = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
    public static let chat = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat"
    public static let surround = "inzone.sony-surround"
    public static let card = "alsa_card.usb-Sony_INZONE_H9_II-00"
    public static let cardProfile = "output:stereo-game+output:stereo-chat+input:mono-chat"
    public static let profiles = ["fps", "music", "voice", "balanced", "surround"]

    public let paths: InzonePaths
    public let runner: any CommandRunning

    public init(paths: InzonePaths, runner: any CommandRunning = SystemCommandRunner()) {
        self.paths = paths
        self.runner = runner
    }

    public func status() throws -> String {
        let text = try String(contentsOf: paths.activeProfile, encoding: .utf8)
        let first = text.components(separatedBy: .newlines).first ?? ""
        let prefix = "# INZONE profile: "
        return first.hasPrefix(prefix) ? String(first.dropFirst(prefix.count)) : "original"
    }

    public func isConnected() throws -> Bool {
        try snapshot().nodes.contains { $0.name.contains("Sony_INZONE_H9_II") }
    }

    public func activate(
        _ name: String,
        automatic: Bool = false,
        autoToken: String? = nil
    ) throws {
        try validateProfile(name)
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let automation = AutomationStore(paths: paths)
        if automatic, automation.manualToken() != autoToken {
            throw InzoneError.message("Automatic switching was cancelled because the manual selection changed.")
        }
        try apply(name)
        if !automatic {
            try automation.markManual()
        }
    }

    public func changeOptions(_ name: String, updates: [String: Any]) throws {
        guard Self.profiles.contains(name) else {
            throw InzoneError.message("DSP options cannot be edited for the restore profile.")
        }
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let settings = SettingsStore(paths: paths)
        let previous = try settings.load()
        var next = previous
        next[name] = try settings.updated(settings.options(name), with: updates)
        try settings.save(next)
        do {
            try apply(name)
            try AutomationStore(paths: paths).markManual()
        } catch {
            do {
                try settings.save(previous)
            } catch let restorationError {
                throw rollbackError(original: error, restoration: restorationError)
            }
            throw error
        }
    }

    public func importSettings(_ data: Data) throws {
        let settings = SettingsStore(paths: paths)
        let next = try settings.decode(data)
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let previous = try settings.load()
        try settings.save(next)
        do {
            let current = try status()
            if Self.profiles.contains(current) {
                try apply(current)
                try AutomationStore(paths: paths).markManual()
            }
        } catch {
            do {
                try settings.save(previous)
            } catch let restorationError {
                throw rollbackError(original: error, restoration: restorationError)
            }
            throw error
        }
    }

    private func validateProfile(_ name: String) throws {
        guard Self.profiles.contains(name) || name == "restore" else {
            throw InzoneError.message("Unknown profile: \(name)")
        }
    }

    private func switchLock() throws -> FileLock {
        try FileLock(url: paths.configDirectory.appendingPathComponent("switch.lock"))
    }

    private func writeActive(_ text: String) throws {
        try AtomicFile.write(Data(text.utf8), to: paths.activeProfile, permissions: 0o644)
    }

    private func restartWirePlumber() throws {
        let restart = ["systemctl", "--user", "restart", "wireplumber.service"]
        do {
            _ = try runner.run(restart)
        } catch let error as CommandError where !error.timedOut {
            let result = try runner.run([
                "systemctl", "--user", "show", "wireplumber.service", "-p", "Result", "--value",
            ])
            guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "start-limit-hit" else {
                throw error
            }
            _ = try runner.run(["systemctl", "--user", "reset-failed", "wireplumber.service"])
            _ = try runner.run(restart)
        }
    }

    private func apply(_ name: String) throws {
        let candidate = paths.configDirectory.appendingPathComponent(
            name == "restore" ? "original.conf" : name + ".conf"
        )
        let previous = try String(contentsOf: paths.activeProfile, encoding: .utf8)
        let wasConnected = try isConnected()
        let previousDefault = try runner.run(["pactl", "get-default-sink"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let template = try String(contentsOf: candidate, encoding: .utf8)
        let rendered = try GraphRenderer(paths: paths).render(profile: name, template: template)
        try writeActive(rendered)
        do {
            try restartWirePlumber()
            _ = try runner.run(["systemctl", "--user", "is-active", "wireplumber.service"])
            if wasConnected {
                try verifyConnectedProfile(name)
            }
        } catch {
            do {
                try restore(previous, defaultSink: previousDefault)
            } catch let restorationError {
                throw rollbackError(original: error, restoration: restorationError)
            }
            throw error
        }
    }

    private func restore(_ previous: String, defaultSink: String) throws {
        try writeActive(previous)
        try restartWirePlumber()
        for attempt in 0..<40 {
            do {
                _ = try runner.run(["pactl", "set-default-sink", defaultSink])
                return
            } catch let error as CommandError where !error.timedOut {
                guard attempt < 39 else { throw error }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    private func rollbackError(original: any Error, restoration: any Error) -> InzoneError {
        .message("\(original.localizedDescription) Rollback also failed: \(restoration.localizedDescription)")
    }

    private func verifyConnectedProfile(_ name: String) throws {
        let expected = [
            "fps": 128, "music": 512, "voice": 256,
            "balanced": 256, "restore": 256, "surround": 256,
        ][name]!
        var outputs: [Node] = []
        var available = false
        for _ in 0..<40 {
            let nodes = try snapshot().nodes
            outputs = nodes.filter { $0.name == Self.game || $0.name == Self.chat }
            let hasSurround = nodes.contains { $0.name == Self.surround }
            let correctLatency = outputs.count == 2
                && outputs.allSatisfy { $0.latency == "\(expected)/48000" }
            if correctLatency && hasSurround == (name == "surround") {
                available = true
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard available else {
            throw InzoneError.message("H9 II Game/Chat output latency or DSP availability verification failed.")
        }

        let target = name == "surround" ? Self.surround : (name == "voice" ? Self.chat : Self.game)
        _ = try runner.run(["pactl", "set-default-sink", target])
        let options = name == "restore" ? ProfileOptions() : try SettingsStore(paths: paths).options(name)
        let hasEqualizer = options.equalizerEnabled || options.equalizer.contains { $0 != 0 }
        let hasAdditionalDSP = options.drc != 0 || options.outputALC || hasEqualizer
            || options.soundMode == "immersive"
        if ["fps", "voice", "surround"].contains(name) || hasAdditionalDSP {
            // Silence starts the filters without producing an audible verification signal.
            _ = try runner.run([
                "pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000",
                "--channels", "2", "--latency", "256", "--target", target, "-",
            ], input: Data(count: 4096 * 8), timeout: 8)
        }

        if ["fps", "voice"].contains(name), options.baseEqualizer {
            let properties = try outputProperties(target, outputs: outputs)
            guard properties.contains("eq0:") else {
                throw InzoneError.message("Base equalizer loading verification failed.")
            }
        }
        if hasAdditionalDSP {
            let sink = name == "voice" ? Self.chat : Self.game
            let properties = try outputProperties(sink, outputs: outputs)
            var required: [String] = []
            if options.drc != 0 { required.append("game_drc:") }
            if options.outputALC { required.append("output_alc:") }
            if hasEqualizer { required.append("custom") }
            if options.soundMode == "immersive" { required.append("immersive") }
            guard required.allSatisfy(properties.contains) else {
                throw InzoneError.message("Additional output DSP loading verification failed.")
            }
        }
        if name == "surround" {
            let current = try snapshot()
            let names = Dictionary(current.nodes.map { ($0.identifier, $0.name) }, uniquingKeysWith: { _, latest in latest })
            let linked = current.links.contains {
                names[$0.output] == "inzone.sony-surround.output" && names[$0.input] == Self.game
            }
            guard linked else {
                throw InzoneError.message("Surround output is not linked to the H9 II Game output.")
            }
        }
    }

    private func outputProperties(_ name: String, outputs: [Node]) throws -> String {
        guard let output = outputs.first(where: { $0.name == name }) else {
            throw InzoneError.message("The H9 II output node was not found.")
        }
        return try runner.run(["pw-cli", "enum-params", output.identifier, "Props"])
    }

    private struct Node {
        let identifier: String
        let name: String
        let latency: String?
    }

    private struct Link {
        let output: String
        let input: String
    }

    private struct Snapshot {
        var nodes: [Node] = []
        var links: [Link] = []
    }

    private func snapshot() throws -> Snapshot {
        let text = try runner.run(["pw-dump"])
        guard let objects = try JSONSupport.decode(Data(text.utf8)) as? [[String: Any]] else {
            throw InzoneError.message("The PipeWire status response must be a JSON array.")
        }
        var result = Snapshot()
        for object in objects {
            guard let information = object["info"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "PipeWire:Interface:Node":
                guard let properties = information["props"] as? [String: Any],
                      let name = properties["node.name"] as? String,
                      let identifier = identifier(object["id"]) else { continue }
                result.nodes.append(Node(
                    identifier: identifier, name: name, latency: properties["node.latency"] as? String
                ))
            case "PipeWire:Interface:Link":
                guard let output = identifier(information["output-node-id"]),
                      let input = identifier(information["input-node-id"]) else { continue }
                result.links.append(Link(output: output, input: input))
            default:
                continue
            }
        }
        return result
    }

    private func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String
    }
}
