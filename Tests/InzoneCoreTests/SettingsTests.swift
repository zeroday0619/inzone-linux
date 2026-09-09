import Foundation
import XCTest
@testable import InzoneCore

final class SettingsTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func fixture(_ body: (InzonePaths) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try body(InzonePaths(home: home))
    }

    private func configuration(_ text: String) throws -> [String: Any] {
        let json = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        return try XCTUnwrap(JSONSupport.decode(Data(json.utf8)) as? [String: Any])
    }

    private func rules(_ config: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(config["node.filter-graph.rules"] as? [[String: Any]])
    }

    private func graphs(_ rule: [String: Any]) throws -> [[String: Any]] {
        let actions = try XCTUnwrap(rule["actions"] as? [String: Any])
        let encoded = try XCTUnwrap(actions["create-filter-graph"] as? [String])
        XCTAssertTrue(encoded.allSatisfy { $0.utf8.count < 4096 })
        return try encoded.map { try XCTUnwrap(JSONSupport.decode(Data($0.utf8)) as? [String: Any]) }
    }

    private func nodes(_ graph: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(graph["nodes"] as? [[String: Any]])
    }

    func testDefaultsAndLegacyJSONKeys() throws {
        try fixture { paths in
            let store = SettingsStore(paths: paths)
            XCTAssertEqual(try store.load(), [:])
            XCTAssertEqual(try store.options("music"), ProfileOptions())
            XCTAssertEqual(try store.decode(Data(#"{"music":{"drc":2}}"#.utf8))["music"], ProfileOptions(drc: 2))
            let encoded = try store.encode(["music": ProfileOptions()])
            let value = try XCTUnwrap(JSONSupport.decode(Data(encoded.utf8)) as? [String: [String: Any]])
            XCTAssertEqual(Set(value["music"]!.keys), Set(["drc", "output_alc", "mic_agc", "hrtf", "eq", "eq_enable", "sound_mode", "base_eq"]))
            let codable = try JSONSupport.decode(JSONEncoder().encode(ProfileOptions())) as? [String: Any]
            XCTAssertEqual(Set(try XCTUnwrap(codable).keys), Set(value["music"]!.keys))
        }
    }

    func testStrictJSONTypesAndUnknownKeys() throws {
        try fixture { paths in
            let store = SettingsStore(paths: paths)
            for text in [
                "[]", "null", #"{"missing":{}}"#, #"{"music":false}"#, #"{"music":{"extra":0}}"#,
                #"{"music":{"drc":true}}"#, #"{"music":{"drc":1.0}}"#, #"{"music":{"drc":1e0}}"#,
                #"{"music":{"drc":"1"}}"#, #"{"music":{"drc":3}}"#, #"{"music":{"drc":-1}}"#,
                #"{"music":{"output_alc":1}}"#, #"{"music":{"mic_agc":"yes"}}"#,
                #"{"music":{"eq_enable":0}}"#, #"{"music":{"base_eq":null}}"#,
                #"{"music":{"hrtf":"../../x"}}"#, #"{"music":{"sound_mode":"unknown"}}"#,
                #"{"music":{"eq":[0,0,0,0,0,0,0,0,0,true]}}"#,
                #"{"music":{"eq":[0,0,0,0,0,0,0,0,0,0.5]}}"#,
                #"{"music":{"eq":[0,0,0,0,0,0,0,0,0,13]}}"#,
                #"{"music":{"eq":[0]}}"#,
            ] {
                XCTAssertThrowsError(try store.decode(Data(text.utf8)), text)
            }
            XCTAssertThrowsError(try store.updated(ProfileOptions(), with: ["eq": Array(repeating: Double.nan, count: 10)]))
            XCTAssertThrowsError(try store.updated(ProfileOptions(), with: ["eq": Array(repeating: Double.infinity, count: 10)]))
            XCTAssertEqual(try store.updated(ProfileOptions(), with: ["eq": [-12, 12, 0, 0, 0, 0, 0, 0, 0, 0]]).equalizer.prefix(2), [-12, 12])
        }
    }

    func testAtomicSavePermissionsAndInvalidUpdatePreservesFile() throws {
        try fixture { paths in
            let store = SettingsStore(paths: paths)
            let first = ProfileOptions(drc: 1, outputALC: true)
            try store.save(["music": first])
            XCTAssertEqual(try store.options("music"), first)
            let file = paths.configDirectory.appendingPathComponent("profile-settings.json")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertThrowsError(try store.save(["music": ProfileOptions(drc: 3)]))
            XCTAssertEqual(try store.options("music"), first)
            try store.save(["voice": ProfileOptions(microphoneAGC: true)])
            XCTAssertEqual(try store.load(), ["voice": ProfileOptions(microphoneAGC: true)])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: paths.configDirectory.path), ["profile-settings.json"])
        }
    }

    func testVoiceTargetsChatAndKeepsMicrophoneIndependent() throws {
        try fixture { paths in
            try SettingsStore(paths: paths).save(["voice": ProfileOptions(drc: 2, outputALC: true, microphoneAGC: true)])
            let template = try String(contentsOf: root.appendingPathComponent("configs/voice.conf"), encoding: .utf8)
            let config = try configuration(GraphRenderer(paths: paths).render(profile: "voice", template: template))
            let rules = try rules(config)
            let matches = try XCTUnwrap(rules[0]["matches"] as? [[String: String]])
            XCTAssertEqual(matches[0]["node.name"], "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat")
            let outputGraphs = try graphs(rules[0])
            let dynamics = try XCTUnwrap(outputGraphs.first { graph in
                (graph["nodes"] as? [[String: Any]])?.contains { $0["label"] as? String == "inzone_alc" } == true
            })
            XCTAssertEqual(dynamics["inputs"] as? [String], ["L_copy:In", "R_copy:In"])
            XCTAssertEqual(dynamics["outputs"] as? [String], ["game_drc:Output L", "game_drc:Output R"])
            let microphone = try XCTUnwrap(graphs(rules[1]).first)
            XCTAssertTrue(try nodes(microphone).contains { $0["label"] as? String == "inzone_mic_agc" })
            XCTAssertEqual(microphone["outputs"] as? [String], ["mic_agc:Output"])
            XCTAssertEqual((microphone["inputs"] as? [String])?.count, 1)
        }
    }

    func testSonyGraphSignalOrderAndExactGains() throws {
        try fixture { paths in
            try FileManager.default.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
            for name in ["sony-eq-tables.json", "sony-presets.json"] {
                let source = root.appendingPathComponent("assets/" + name)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw XCTSkip("Run make assets for the shipped Sony coefficient tables.")
                }
                try Data(contentsOf: source).write(to: paths.assetsDirectory.appendingPathComponent(name))
            }
            let plugin = "inzone_dsp_0123456789abcdef"
            try Data("{\"name\":\"\(plugin)\"}".utf8).write(to: paths.assetsDirectory.appendingPathComponent("plugin.json"))
            let options = ProfileOptions(drc: 2, outputALC: true, equalizer: [12, -12, 6, -6, 3, -3, 10, -10, 1, -1], equalizerEnabled: true, soundMode: "immersive", baseEqualizer: false)
            try SettingsStore(paths: paths).save(["fps": options])
            let template = try String(contentsOf: root.appendingPathComponent("configs/fps.conf"), encoding: .utf8)
            let config = try configuration(GraphRenderer(paths: paths).render(profile: "fps", template: template))
            let ordered = Array(try graphs(XCTUnwrap(rules(config).first)).reversed())
            XCTAssertEqual(ordered.count, 5)
            let names = try ordered.map { try nodes($0).compactMap { $0["name"] as? String } }
            XCTAssertEqual(names[0], ["copy"])
            XCTAssertEqual(names[1], ["sony_amp1"])
            XCTAssertTrue(names[2].contains("immersive9"))
            XCTAssertTrue(names[3].contains("custom9"))
            XCTAssertTrue(names[4].contains("output_alc"))
            XCTAssertTrue(names[4].contains("game_drc"))
            let attenuationControl = try XCTUnwrap(nodes(ordered[1])[0]["control"] as? [String: Double])
            XCTAssertEqual(Float(try XCTUnwrap(attenuationControl["Mult"])).bitPattern, 0x3e00e9fa)
            XCTAssertEqual(GraphRenderer.attenuate, Double(Float(bitPattern: 0x3e00e9fa)))
            let dynamicsNodes = try nodes(ordered[4])
            let recovery = try XCTUnwrap(dynamicsNodes.first { $0["name"] as? String == "recoverL" })
            let recoveryControl = try XCTUnwrap(recovery["control"] as? [String: Double])
            XCTAssertEqual(Float(try XCTUnwrap(recoveryControl["Mult"])).bitPattern, 0x40fe2f5e)
            XCTAssertEqual(GraphRenderer.recover, Double(Float(bitPattern: 0x40fe2f5e)))
            for graph in ordered {
                for node in try nodes(graph) where node["type"] as? String == "ladspa" {
                    XCTAssertEqual(node["plugin"] as? String, plugin)
                }
            }
        }
    }

    func testGraphLimitsAndPluginNamesAreRejected() throws {
        try fixture { paths in
            let store = SettingsStore(paths: paths)
            let renderer = GraphRenderer(paths: paths)
            try store.save(["music": ProfileOptions(drc: 1)])
            let hugeGraph = try JSONSupport.encode(["nodes": [], "links": [], "inputs": ["copy:In"], "outputs": ["copy:Out"], "padding": String(repeating: "x", count: 4096)])
            let template = try JSONSupport.encode(["node.filter-graph.rules": [["matches": [["node.name": GraphRenderer.game]], "actions": ["create-filter-graph": [hugeGraph]]]]])
            XCTAssertThrowsError(try renderer.render(profile: "music", template: template))
            try FileManager.default.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
            for name in ["../inzone_dsp", "inzone_dsp_0123456789abcdef\n", "inzone_dsp_DEADBEEF01234567", "inzone_dsp_bad"] {
                try Data(JSONSupport.encode(["name": name]).utf8).write(to: paths.assetsDirectory.appendingPathComponent("plugin.json"))
                XCTAssertThrowsError(try renderer.render(profile: "music", template: "{}"), name)
            }
            XCTAssertEqual(try renderer.render(profile: "normal", template: "unchanged"), "unchanged")
        }
    }

    func testSurroundChannelsAndAssetValidation() throws {
        try fixture { paths in
            try FileManager.default.createDirectory(at: paths.assetsDirectory, withIntermediateDirectories: true)
            try AtomicFile.write(Data(), to: paths.pluginURL)
            for channel in GraphRenderer.channels {
                try Data().write(to: paths.assetsDirectory.appendingPathComponent(channel + ".wav"))
            }
            try Data(#"{"rate":48000,"taps":512}"#.utf8).write(to: paths.assetsDirectory.appendingPathComponent("manifest.json"))
            let coefficients = Array(repeating: [1, 0, 0, 0, 0], count: 7)
            try Data(JSONSupport.encode(coefficients).utf8).write(to: paths.assetsDirectory.appendingPathComponent("h9-ii-biquads.json"))
            let renderer = GraphRenderer(paths: paths)
            let complete = try renderer.buildSurround(assets: paths.assetsDirectory, plugin: paths.pluginURL, drc: 2)
            let graph = try XCTUnwrap(complete["filter.graph"] as? [String: Any])
            XCTAssertEqual(graph["inputs"] as? [String], GraphRenderer.channels.map { "copy" + $0 + ":In" })
            let nodes = try nodes(graph)
            XCTAssertEqual(nodes.filter { $0["label"] as? String == "convolver" }.count, 16)
            XCTAssertEqual(nodes.filter { $0["label"] as? String == "inzone_biquad" }.count, 14)
            let links = try XCTUnwrap(graph["links"] as? [[String: String]])
            XCTAssertEqual(Set(links.compactMap { $0["input"] }).count, links.count)
            let drc = try XCTUnwrap(nodes.first { $0["name"] as? String == "drc" })
            XCTAssertEqual((drc["control"] as? [String: Int])?["Mode"], 2)
            XCTAssertThrowsError(try renderer.buildSurround(assets: paths.assetsDirectory, plugin: paths.pluginURL, drc: 3))
            try FileManager.default.removeItem(at: paths.assetsDirectory.appendingPathComponent("SL.wav"))
            XCTAssertThrowsError(try renderer.buildSurround(assets: paths.assetsDirectory, plugin: paths.pluginURL))
            try FileManager.default.removeItem(at: paths.pluginURL)
            XCTAssertThrowsError(try renderer.buildSurround(assets: paths.assetsDirectory, plugin: paths.pluginURL))
        }
    }
}
