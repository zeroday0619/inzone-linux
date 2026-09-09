import Foundation

public struct GraphRenderer: Sendable {
    public static let game = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
    public static let sink = "inzone.sony-surround"
    public static let channels = ["FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR"]
    // The original Sony amplifier uses Float-rounded gains instead of Double pow results.
    public static let attenuate: Double = 0x1.01d3f4p-3
    public static let recover: Double = 0x1.fc5ebcp+2
    public let paths: InzonePaths

    public init(paths: InzonePaths) { self.paths = paths }

    public func render(profile: String, template: String) throws -> String {
        guard SettingsStore.profiles.contains(profile) else { return template }
        let options = try SettingsStore(paths: paths).options(profile)
        let text = template.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#")
        }.joined(separator: "\n")
        guard var config = try JSONSupport.decode(Data(text.utf8)) as? [String: Any] else {
            throw InzoneError.message("Profile configuration must be a JSON object")
        }
        if profile == "surround" {
            let assets = options.hrtf == "personal" ? paths.shareDirectory.appendingPathComponent("personal") : paths.assetsDirectory
            guard isFile(assets.appendingPathComponent("manifest.json")) else {
                throw InzoneError.message("Import HRTF filters before activating surround")
            }
            let graph = try buildSurround(assets: assets, plugin: paths.pluginURL)
            config["wireplumber.profiles"] = ["main": ["node.software-dsp": "required"]]
            config["node.software-dsp.rules"] = [[
                "matches": [["node.name": Self.game]],
                "actions": ["create-filter": ["filter-graph": try JSONSupport.encode(graph, pretty: false), "hide-parent": false]],
            ]]
        }
        let plugin = try daemonPlugin()
        var rules: [[String: Any]] = []
        if let existing = config["node.filter-graph.rules"] {
            guard let existingRules = existing as? [[String: Any]] else {
                throw InzoneError.message("Invalid filter graph rules")
            }
            rules = existingRules
        }
        let target = profile == "voice" ? "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat" : Self.game
        for index in rules.indices {
            var matches = try ruleMatches(rules[index])
            for matchIndex in matches.indices where (matches[matchIndex]["node.name"] as? String ?? "").contains("alsa_output") {
                matches[matchIndex]["node.name"] = target
            }
            rules[index]["matches"] = matches
            if !options.baseEqualizer, matches.contains(where: { ($0["node.name"] as? String ?? "").contains("alsa_output") }) {
                try setGraphs([try JSONSupport.encode(identity(), pretty: false)], in: &rules[index])
            }
        }
        let outputEnabled = options.outputALC || options.drc != 0 || options.hasEqualizer || options.soundMode == "immersive"
        for (category, enabled) in [("output", outputEnabled), ("input", options.microphoneAGC)] where enabled {
            var matching = try rules.indices.filter { index in
                try ruleMatches(rules[index]).contains { ($0["node.name"] as? String ?? "").contains("alsa_" + category) }
            }
            if matching.isEmpty {
                rules.append([
                    "matches": [["node.name": category == "output" ? target : "~alsa_input[.]usb-Sony_INZONE_H9_II-00[.].*"]],
                    "actions": ["create-filter-graph": [try JSONSupport.encode(identity(), pretty: false)]],
                ])
                matching = [rules.count - 1]
            }
            for index in matching {
                let graphs = try graphs(in: rules[index])
                guard graphs.count == 1,
                      var graph = try JSONSupport.decode(Data(graphs[0].utf8)) as? [String: Any] else {
                    throw InzoneError.message("Unsupported existing DSP graph")
                }
                if category == "output" {
                    var rendered = [graph]
                    if options.outputALC { rendered.append(attenuation()) }
                    if options.soundMode == "immersive" { rendered.append(try immersive(plugin: plugin)) }
                    if options.hasEqualizer { rendered.append(try customEqualizer(plugin: plugin, options: options)) }
                    if options.outputALC || options.drc != 0 { rendered.append(stereoDynamics(plugin: plugin, options: options)) }
                    // PipeWire executes higher indices first and copies each value into a 4096-byte buffer.
                    let encoded = try rendered.reversed().map { try JSONSupport.encode($0, pretty: false) }
                    guard encoded.count <= 8, encoded.allSatisfy({ $0.utf8.count < 4096 }) else {
                        throw InzoneError.message("PipeWire inline graph size limit exceeded")
                    }
                    try setGraphs(encoded, in: &rules[index])
                } else {
                    guard var nodes = graph["nodes"] as? [[String: Any]],
                          var links = graph["links"] as? [[String: Any]],
                          let outputs = graph["outputs"] as? [String], let previous = outputs.first else {
                        throw InzoneError.message("Invalid microphone DSP graph")
                    }
                    nodes.append(["type": "ladspa", "name": "mic_agc", "plugin": plugin, "label": "inzone_mic_agc", "control": ["Enable": 1]])
                    links.append(link(previous, "mic_agc:Input"))
                    graph["nodes"] = nodes
                    graph["links"] = links
                    graph["outputs"] = ["mic_agc:Output"]
                    try setGraphs([try JSONSupport.encode(graph, pretty: false)], in: &rules[index])
                }
            }
        }
        config["node.filter-graph.rules"] = rules
        return "# INZONE profile: \(profile)\n" + (try JSONSupport.encode(config)) + "\n"
    }

    public func buildSurround(assets: URL, plugin: URL, drc: Int = 0) throws -> [String: Any] {
        let assets = assets.standardizedFileURL.resolvingSymlinksInPath()
        let plugin = plugin.standardizedFileURL.resolvingSymlinksInPath()
        guard isFile(plugin) else { throw InzoneError.message("Build the native INZONE DSP plugin before generating the graph") }
        guard (0...2).contains(drc) else { throw InzoneError.message("DRC mode must be 0, 1, or 2") }
        let manifestData = try Data(contentsOf: assets.appendingPathComponent("manifest.json"))
        guard let manifest = try JSONSupport.decode(manifestData) as? [String: Any],
              (manifest["rate"] as? Int) == 48000, (manifest["taps"] as? Int) == 512 else {
            throw InzoneError.message("HRTF assets must use 48000 Hz and 512 taps")
        }
        if let rawChannels = manifest["channels"] {
            guard let channels = rawChannels as? [String: Any], Set(channels.keys) == Set(Self.channels) else {
                throw InzoneError.message("HRTF manifest does not contain the required 7.1 channels")
            }
        }
        for channel in Self.channels where !isFile(assets.appendingPathComponent(channel + ".wav")) {
            throw InzoneError.message("Missing HRTF channel: \(channel)")
        }
        let coefficientData = try Data(contentsOf: assets.appendingPathComponent("h9-ii-biquads.json"))
        let coefficients = try coefficientRows(JSONSupport.decode(coefficientData), count: 7)
        var nodes: [[String: Any]] = []
        var links: [[String: Any]] = []
        for (index, channel) in Self.channels.enumerated() {
            nodes.append(["type": "builtin", "name": "copy" + channel, "label": "copy"])
            for ear in 0..<2 {
                let name = "conv\(channel)_\(ear)"
                nodes.append([
                    "type": "builtin", "name": name, "label": "convolver",
                    "config": ["filename": assets.appendingPathComponent(channel + ".wav").path, "channel": ear, "blocksize": 128],
                ])
                links.append(link("copy\(channel):Out", name + ":In"))
                links.append(link(name + ":Out", "mix\(ear):In \(index + 1)"))
            }
        }
        for ear in 0..<2 {
            nodes.append(["type": "builtin", "name": "mix\(ear)", "label": "mixer"])
            var previous = "mix\(ear):Out"
            for (index, row) in coefficients.enumerated() {
                let name = "eq\(ear)_\(index)"
                nodes.append(biquad(name: name, plugin: plugin.path, label: "inzone_biquad", row: row))
                links.append(link(previous, name + ":Input"))
                previous = name + ":Output"
            }
            links.append(link(previous, "spatial_alc:Input " + (ear == 0 ? "L" : "R")))
        }
        nodes.append(["type": "ladspa", "name": "spatial_alc", "plugin": plugin.path, "label": "inzone_spatial_alc", "control": ["Boost": 1]])
        nodes.append(["type": "ladspa", "name": "drc", "plugin": plugin.path, "label": "inzone_drc", "control": ["Mode": drc]])
        for ear in ["L", "R"] { links.append(link("spatial_alc:Output " + ear, "drc:Input " + ear)) }
        return [
            "node.description": "INZONE H9 II - Sony Surround (experimental)", "audio.rate": 48000,
            "filter.graph": ["nodes": nodes, "links": links, "inputs": Self.channels.map { "copy" + $0 + ":In" }, "outputs": ["drc:Output L", "drc:Output R"]],
            "capture.props": [
                "node.name": Self.sink, "node.description": "INZONE H9 II - Sony Surround (experimental)",
                "media.class": "Audio/Sink", "audio.channels": 8, "audio.position": Self.channels,
                "node.latency": "256/48000", "node.rate": "1/48000", "priority.session": 1500,
                "stream.dont-remix": true, "channelmix.upmix": false,
            ],
            "playback.props": [
                "node.name": "inzone.sony-surround.output", "node.description": "Sony HRTF to INZONE Game",
                "audio.channels": 2, "audio.position": ["FL", "FR"], "node.passive": true,
                "target.object": Self.game, "node.dont-fallback": true, "node.dont-reconnect": true, "stream.dont-remix": true,
            ],
        ]
    }

    private func daemonPlugin() throws -> String {
        let manifest = paths.assetsDirectory.appendingPathComponent("plugin.json")
        var name = "inzone_dsp"
        if FileManager.default.fileExists(atPath: manifest.path) {
            guard let value = try JSONSupport.decode(Data(contentsOf: manifest)) as? [String: Any],
                  let pluginName = value["name"] as? String else {
                throw InzoneError.message("Invalid plugin manifest")
            }
            name = pluginName
        }
        guard name.range(of: "\\Ainzone_dsp(?:_[a-f0-9]{16})?\\z", options: .regularExpression) != nil else {
            throw InzoneError.message("Invalid plugin name")
        }
        return name
    }

    private func asset(_ name: String) throws -> Any {
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [paths.assetsDirectory.appendingPathComponent(name), sourceRoot.appendingPathComponent("assets").appendingPathComponent(name)]
        guard let file = candidates.first(where: isFile) else { throw InzoneError.message("Missing Sony DSP asset: \(name)") }
        return try JSONSupport.decode(Data(contentsOf: file))
    }

    private func customEqualizer(plugin: String, options: ProfileOptions) throws -> [String: Any] {
        guard let value = try asset("sony-eq-tables.json") as? [String: Any], let tables = value["tables"] as? [String: Any] else {
            throw InzoneError.message("Invalid Sony EQ tables")
        }
        let bands = ["31_5", "63", "125", "250", "500", "1000", "2000", "4000", "8000", "16000"]
        var rows: [[Double]] = []
        for (index, band) in bands.enumerated() {
            guard let values = tables[band] as? [[Double]], values.count == 25, values.allSatisfy({ $0.count == 7 }) else {
                throw InzoneError.message("Invalid Sony EQ band: \(band)")
            }
            rows.append(Array(values[12 - Int(options.equalizer[index])].dropFirst(2)))
        }
        return try equalizerGraph(plugin: plugin, prefix: "custom", rows: coefficientRows(rows, count: 10))
    }

    private func immersive(plugin: String) throws -> [String: Any] {
        guard let value = try asset("sony-presets.json") as? [String: Any], let rawRows = value["immersive_coefficients"] else {
            throw InzoneError.message("Missing Sony immersive coefficients")
        }
        return try equalizerGraph(plugin: plugin, prefix: "immersive", rows: coefficientRows(rawRows, count: 10))
    }

    private func coefficientRows(_ value: Any, count: Int) throws -> [[Double]] {
        guard let rows = value as? [[Double]], rows.count == count,
              rows.allSatisfy({ $0.count == 5 && $0.allSatisfy { $0.isFinite && abs($0) <= 64 } }) else {
            throw InzoneError.message("Invalid Sony biquad coefficients")
        }
        return rows
    }

    private func equalizerGraph(plugin: String, prefix: String, rows: [[Double]]) -> [String: Any] {
        var nodes: [[String: Any]] = [["type": "builtin", "name": "copy", "label": "copy"]]
        var links: [[String: Any]] = []
        var previous = "copy:Out"
        for (index, row) in rows.enumerated() {
            let name = prefix + String(index)
            nodes.append(biquad(name: name, plugin: plugin, label: "inzone_eq_biquad", row: row))
            links.append(link(previous, name + ":Input"))
            previous = name + ":Output"
        }
        return ["nodes": nodes, "links": links, "inputs": ["copy:In"], "outputs": [previous]]
    }

    private func stereoDynamics(plugin: String, options: ProfileOptions) -> [String: Any] {
        var nodes: [[String: Any]] = ["L", "R"].map { ["type": "builtin", "name": $0 + "_copy", "label": "copy"] }
        var links: [[String: Any]] = []
        var outputs = ["L_copy:Out", "R_copy:Out"]
        if options.outputALC {
            nodes.append([
                "type": "ladspa", "name": "output_alc", "plugin": plugin, "label": "inzone_alc",
                "control": ["Enable": 1, "Threshold": -18, "Ratio": 1000, "Attack": 0.001, "Release": 1],
            ])
            for (index, ear) in ["L", "R"].enumerated() {
                nodes.append(["type": "builtin", "name": "recover" + ear, "label": "linear", "control": ["Mult": Self.recover, "Add": 0]])
                links.append(link(outputs[index], "output_alc:Input " + ear))
                links.append(link("output_alc:Output " + ear, "recover" + ear + ":In"))
                outputs[index] = "recover" + ear + ":Out"
            }
        }
        if options.drc != 0 {
            nodes.append(["type": "ladspa", "name": "game_drc", "plugin": plugin, "label": "inzone_drc", "control": ["Mode": options.drc]])
            for (index, ear) in ["L", "R"].enumerated() {
                links.append(link(outputs[index], "game_drc:Input " + ear))
                outputs[index] = "game_drc:Output " + ear
            }
        }
        return ["nodes": nodes, "links": links, "inputs": ["L_copy:In", "R_copy:In"], "outputs": outputs]
    }

    private func identity() -> [String: Any] {
        ["nodes": [["type": "builtin", "name": "copy", "label": "copy"]], "links": [[String: Any]](), "inputs": ["copy:In"], "outputs": ["copy:Out"]]
    }

    private func attenuation() -> [String: Any] {
        ["nodes": [["type": "builtin", "name": "sony_amp1", "label": "linear", "control": ["Mult": Self.attenuate, "Add": 0]]],
         "links": [[String: Any]](), "inputs": ["sony_amp1:In"], "outputs": ["sony_amp1:Out"]]
    }

    private func biquad(name: String, plugin: String, label: String, row: [Double]) -> [String: Any] {
        ["type": "ladspa", "name": name, "plugin": plugin, "label": label,
         "control": Dictionary(uniqueKeysWithValues: zip(["b0", "b1", "b2", "a1", "a2"], row))]
    }

    private func link(_ output: String, _ input: String) -> [String: Any] { ["output": output, "input": input] }

    private func ruleMatches(_ rule: [String: Any]) throws -> [[String: Any]] {
        guard let matches = rule["matches"] as? [[String: Any]] else { throw InzoneError.message("Invalid DSP rule matches") }
        return matches
    }

    private func graphs(in rule: [String: Any]) throws -> [String] {
        guard let actions = rule["actions"] as? [String: Any], let graphs = actions["create-filter-graph"] as? [String] else {
            throw InzoneError.message("Invalid DSP filter graph action")
        }
        return graphs
    }

    private func setGraphs(_ graphs: [String], in rule: inout [String: Any]) throws {
        guard var actions = rule["actions"] as? [String: Any] else { throw InzoneError.message("Invalid DSP rule actions") }
        actions["create-filter-graph"] = graphs
        rule["actions"] = actions
    }

    private func isFile(_ file: URL) -> Bool {
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
}
