import CLADSPA
import Foundation
import Glibc
import InzoneCore

public struct DSPDiagnosticCase: Sendable {
    public let name: String
    public let options: ProfileOptions
}

public enum LinuxDSP {
    public static func stressSignal() -> [Float] {
        var generator = DiagnosticRandom(seed: 2987)
        var samples: [Float] = []
        samples.reserveCapacity(720000)
        for level: Double in [0, 0.00001, 0.0001, 0.001, 0.01, 0.1, 0.5, 1, 2, 0.1, 0] {
            for index in 0..<24000 {
                samples.append(Float(level * Glibc.sin(Double(index) * 0.1309)))
                samples.append(Float(level * 0.7 * Glibc.sin(Double(index) * 0.0471)))
            }
        }
        for _ in 0..<48000 {
            samples.append(Float(generator.uniform() * 0.9))
            samples.append(Float(generator.uniform() * 0.08))
        }
        for index in 0..<48000 {
            samples.append(index % 4096 == 0 ? 1.5 : 0)
            samples.append(index % 5000 == 0 ? -0.9 : 0)
        }
        return samples
    }

    public static func cases(paths: InzonePaths) throws -> [DSPDiagnosticCase] {
        try cases(assets: paths.assetsDirectory)
    }

    public static func cases(assets: URL) throws -> [DSPDiagnosticCase] {
        guard let bank = try JSONSupport.decode(Data(contentsOf: assets.appendingPathComponent("sony-presets.json"))) as? [String: Any],
              let presets = bank["presets"] as? [String: [String: Any]] else {
            throw InzoneError.message("Invalid Sony preset bank for DSP diagnostics.")
        }
        let settings = SettingsStore(paths: InzonePaths())
        var result: [DSPDiagnosticCase] = []
        for name in SonyPresets.names {
            guard let preset = presets[name] else { throw InzoneError.message("Missing diagnostic preset: \(name)") }
            for mode in 0...2 {
                var options = try settings.updated(ProfileOptions(), with: preset)
                options.drc = mode
                result.append(DSPDiagnosticCase(name: "\(name)-drc\(mode)", options: options))
            }
        }
        for mode in ["standard", "immersive"] {
            for automaticLevel in [false, true] {
                for compression in 0...2 {
                    let options = ProfileOptions(drc: compression, outputALC: automaticLevel,
                        equalizer: [12, -12, 6, -6, 3, -3, 10, -10, 1, -1], equalizerEnabled: true,
                        soundMode: mode, baseEqualizer: false)
                    let name = "custom-\(mode)-alc\(automaticLevel ? "True" : "False")-drc\(compression)"
                    result.append(DSPDiagnosticCase(name: name, options: options))
                }
            }
        }
        return result
    }
}

public final class LADSPAGraphRunner {
    private typealias DescriptorFunction = @convention(c) (UInt) -> UnsafePointer<LADSPA_Descriptor>?
    private let handle: UnsafeMutableRawPointer
    private let descriptor: DescriptorFunction
    private let indices: [String: UInt] = [
        "inzone_spatial_alc": 0, "inzone_drc": 1, "inzone_alc": 2,
        "inzone_mic_agc": 3, "inzone_biquad": 4, "inzone_eq_biquad": 5,
    ]

    public init(plugin: URL) throws {
        guard let loaded = dlopen(plugin.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "Unknown dynamic loader error."
            throw InzoneError.message("Cannot load native DSP plugin: \(reason)")
        }
        guard let symbol = dlsym(loaded, "ladspa_descriptor") else {
            dlclose(loaded)
            throw InzoneError.message("Native DSP plugin does not export ladspa_descriptor.")
        }
        handle = loaded
        descriptor = unsafeBitCast(symbol, to: DescriptorFunction.self)
    }

    deinit { dlclose(handle) }

    public func execute(graph: [String: Any], channels: [[Float]]) throws -> [[Float]] {
        defer { withExtendedLifetime(self) {} }
        guard let inputs = graph["inputs"] as? [String], !inputs.isEmpty,
              let outputs = graph["outputs"] as? [String], !outputs.isEmpty,
              let nodes = graph["nodes"] as? [[String: Any]],
              let links = graph["links"] as? [[String: String]],
              let frames = channels.first?.count, channels.count % inputs.count == 0,
              channels.allSatisfy({ $0.count == frames }) else {
            throw InzoneError.message("Invalid LADSPA diagnostic graph or channel count.")
        }
        let names = nodes.compactMap { $0["name"] as? String }
        guard names.count == nodes.count, Set(names).count == names.count, Set(inputs).count == inputs.count,
              links.allSatisfy({ $0["input"] != nil && $0["output"] != nil }) else {
            throw InzoneError.message("Graph nodes must have unique names and links must name both ports.")
        }
        var result: [[Float]] = []
        for stream in 0..<(channels.count / inputs.count) {
            var values = Dictionary(uniqueKeysWithValues: inputs.enumerated().map {
                ($0.element, channels[stream * inputs.count + $0.offset])
            })
            var pending = nodes
            while !pending.isEmpty {
                var remaining: [[String: Any]] = []
                var progress = false
                for node in pending {
                    for link in links {
                        if let value = values[link["output"]!] { values[link["input"]!] = value }
                    }
                    guard let name = node["name"] as? String, let label = node["label"] as? String,
                          let type = node["type"] as? String else { throw InzoneError.message("Invalid DSP node identity.") }
                    if type == "builtin" {
                        guard let input = values[name + ":In"] else { remaining.append(node); continue }
                        switch label {
                        case "copy": values[name + ":Out"] = input
                        case "linear":
                            guard let controls = node["control"] as? [String: Any],
                                  let multiplier = controls["Mult"] as? NSNumber,
                                  let addition = controls["Add"] as? NSNumber else { throw InzoneError.message("Linear DSP controls are missing.") }
                            let multiply = multiplier.floatValue
                            let add = addition.floatValue
                            values[name + ":Out"] = input.map {
                                let product = Float(Double($0) * Double(multiply))
                                return Float(Double(product) + Double(add))
                            }
                        default: throw InzoneError.message("Unsupported diagnostic builtin: \(label)")
                        }
                    } else if type == "ladspa" {
                        guard let index = indices[label], let pointer = descriptor(index) else { throw InzoneError.message("Unsupported diagnostic LADSPA label: \(label)") }
                        let metadata = pointer.pointee
                        guard let flags = metadata.PortDescriptors, let ports = metadata.PortNames else { throw InzoneError.message("LADSPA port metadata is missing.") }
                        let audioInputs = (0..<Int(metadata.PortCount)).filter { flags[$0] & 8 != 0 && flags[$0] & 1 != 0 }
                        guard audioInputs.allSatisfy({ port in
                            guard let portName = ports[port] else { return false }
                            return values[name + ":" + String(cString: portName)] != nil
                        }) else { remaining.append(node); continue }
                        let rendered = try render(pointer: pointer, node: node, values: values, frames: frames)
                        values.merge(rendered) { _, replacement in replacement }
                    } else { throw InzoneError.message("Unsupported diagnostic node type: \(type)") }
                    progress = true
                }
                guard progress else { throw InzoneError.message("Unresolved graph dependencies: " + remaining.compactMap { $0["name"] as? String }.joined(separator: ", ")) }
                pending = remaining
            }
            for output in outputs {
                guard let value = values[output] else { throw InzoneError.message("Unresolved graph output: \(output)") }
                result.append(value)
            }
        }
        return result
    }

    private func render(pointer: UnsafePointer<LADSPA_Descriptor>, node: [String: Any],
                        values: [String: [Float]], frames: Int) throws -> [String: [Float]] {
        let metadata = pointer.pointee
        guard let instantiate = metadata.instantiate, let connect = metadata.connect_port,
              let activate = metadata.activate, let run = metadata.run, let cleanup = metadata.cleanup,
              let flags = metadata.PortDescriptors, let ports = metadata.PortNames,
              let name = node["name"] as? String, let instance = instantiate(pointer, 48000) else {
            throw InzoneError.message("Cannot instantiate the diagnostic LADSPA node.")
        }
        defer { cleanup(instance) }
        let controls = node["control"] as? [String: Any] ?? [:]
        var storage: [(UnsafeMutablePointer<Float>, Int)] = []
        var audioBuffers: [Int: UnsafeMutablePointer<Float>] = [:]
        var outputPorts: [Int] = []
        defer { for (buffer, count) in storage { buffer.deinitialize(count: count); buffer.deallocate() } }
        for port in 0..<Int(metadata.PortCount) {
            guard let portPointer = ports[port] else { throw InzoneError.message("LADSPA port name is missing.") }
            let portName = String(cString: portPointer)
            if flags[port] & 4 != 0 {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                buffer.initialize(to: (controls[portName] as? NSNumber)?.floatValue ?? 0)
                storage.append((buffer, 1))
                connect(instance, UInt(port), buffer)
            } else if flags[port] & 8 != 0 {
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: max(1, frames))
                buffer.initialize(repeating: 0, count: frames)
                storage.append((buffer, frames))
                if flags[port] & 1 != 0 {
                    guard let input = values[name + ":" + portName] else { throw InzoneError.message("LADSPA input is unresolved.") }
                    input.withUnsafeBufferPointer { source in
                        if let base = source.baseAddress { buffer.update(from: base, count: frames) }
                    }
                }
                if flags[port] & 2 != 0 { outputPorts.append(port) }
                audioBuffers[port] = buffer
            }
        }
        activate(instance)
        let sizes = [1, 3, 7, 8, 127, 256, 513]
        var offset = 0
        var block = 0
        while offset < frames {
            let count = min(sizes[block % sizes.count], frames - offset)
            for (port, buffer) in audioBuffers { connect(instance, UInt(port), buffer.advanced(by: offset)) }
            run(instance, UInt(count))
            offset += count
            block += 1
        }
        return Dictionary(uniqueKeysWithValues: outputPorts.map { port in
            (name + ":" + String(cString: ports[port]!), Array(UnsafeBufferPointer(start: audioBuffers[port]!, count: frames)))
        })
    }
}

public enum FloatSamples {
    public static func encode(_ samples: [Float]) -> Data {
        samples.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
    }

    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count % 4 == 0 else { throw InzoneError.message("Raw float data length must be divisible by four.") }
        return data.withUnsafeBytes { buffer in
            stride(from: 0, to: data.count, by: 4).map { offset in
                Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
            }
        }
    }
}

struct DiagnosticRandom {
    private var state = [UInt32](repeating: 0, count: 624)
    private var position = 624

    init(seed: UInt32) {
        state[0] = 19650218
        for index in 1..<624 { state[index] = 1812433253 &* (state[index - 1] ^ (state[index - 1] >> 30)) &+ UInt32(index) }
        var index = 1
        for _ in 0..<624 {
            state[index] = (state[index] ^ ((state[index - 1] ^ (state[index - 1] >> 30)) &* 1664525)) &+ seed
            index += 1
            if index == 624 { state[0] = state[623]; index = 1 }
        }
        for _ in 0..<623 {
            state[index] = (state[index] ^ ((state[index - 1] ^ (state[index - 1] >> 30)) &* 1566083941)) &- UInt32(index)
            index += 1
            if index == 624 { state[0] = state[623]; index = 1 }
        }
        state[0] = 0x80000000
    }

    mutating func uniform() -> Double {
        let high = Double(next() >> 5)
        let low = Double(next() >> 6)
        return -1 + 2 * ((high * 67108864 + low) / 9007199254740992)
    }

    private mutating func next() -> UInt32 {
        if position >= 624 {
            for index in 0..<624 {
                let value = (state[index] & 0x80000000) | (state[(index + 1) % 624] & 0x7fffffff)
                state[index] = state[(index + 397) % 624] ^ (value >> 1) ^ (value & 1 == 0 ? 0 : 0x9908b0df)
            }
            position = 0
        }
        var value = state[position]
        position += 1
        value ^= value >> 11
        value ^= (value << 7) & 0x9d2c5680
        value ^= (value << 15) & 0xefc60000
        value ^= value >> 18
        return value
    }
}
