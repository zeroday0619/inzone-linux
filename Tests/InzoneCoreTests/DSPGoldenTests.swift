import CLADSPA
import Foundation
import Glibc
#if !DSP_GOLDEN_TOOL
import XCTest
@testable import InzoneCore
#else
import InzoneCore
#endif

// The fixture records the retired C implementation using synthetic input generated below.
// Floating-point bit patterns preserve signed zero, subnormals, and NaN payloads in JSON.
private struct DSPGoldenFixture: Codable {
    let version: Int
    let provenance: [String: String]
    let descriptors: [DSPGoldenDescriptor]
    let cases: [DSPGoldenCase]
}

private struct DSPGoldenDescriptor: Codable, Equatable {
    struct Port: Codable, Equatable {
        let name: String
        let descriptor: Int
        let hint: Int
        let lowerBits: UInt32
        let upperBits: UInt32
    }
    let identifier: UInt
    let label: String
    let name: String
    let maker: String
    let copyright: String
    let properties: Int
    let ports: [Port]
    let callbacks: [String]

    init(_ descriptor: LADSPA_Descriptor) {
        identifier = descriptor.UniqueID
        label = String(cString: descriptor.Label)
        name = String(cString: descriptor.Name)
        maker = String(cString: descriptor.Maker)
        copyright = String(cString: descriptor.Copyright)
        properties = Int(descriptor.Properties)
        ports = (0..<Int(descriptor.PortCount)).map { index in
            let range = descriptor.PortRangeHints[index]
            return Port(name: String(cString: descriptor.PortNames[index]!),
                        descriptor: Int(descriptor.PortDescriptors[index]),
                        hint: Int(range.HintDescriptor), lowerBits: range.LowerBound.bitPattern,
                        upperBits: range.UpperBound.bitPattern)
        }
        var available: [String] = []
        if descriptor.instantiate != nil { available.append("instantiate") }
        if descriptor.connect_port != nil { available.append("connect_port") }
        if descriptor.activate != nil { available.append("activate") }
        if descriptor.run != nil { available.append("run") }
        if descriptor.run_adding != nil { available.append("run_adding") }
        if descriptor.set_run_adding_gain != nil { available.append("set_run_adding_gain") }
        if descriptor.deactivate != nil { available.append("deactivate") }
        if descriptor.cleanup != nil { available.append("cleanup") }
        callbacks = available
    }
}

private struct DSPGoldenEvent: Codable, Equatable {
    let frame: Int
    let controlBits: [UInt32?]

    init(_ controls: [Float?]) { self.init(0, controls) }

    init(_ frame: Int, _ controls: [Float?]) {
        self.frame = frame
        controlBits = controls.map { $0?.bitPattern }
    }
}

private struct DSPGoldenScenario: Codable, Equatable {
    let name: String
    let descriptor: UInt
    let events: [DSPGoldenEvent]
    var channels: Int { descriptor < 3 ? 2 : 1 }
    static let frameCount = 32768

    static var all: [DSPGoldenScenario] {
        var scenarios: [DSPGoldenScenario] = []
        func add(_ descriptor: UInt, _ name: String, _ controls: [Float?]) {
            scenarios.append(Self(name: "\(descriptor)-\(name)", descriptor: descriptor,
                                  events: [DSPGoldenEvent(controls)]))
        }
        let defaults: [[Float?]] = [[1], [0], [1, -18, 1000, 0.001, 1], [1], [1, 0, 0, 0, 0], [1, 0, 0, 0, 0]]
        for descriptor: UInt in 0..<6 {
            let values = defaults[Int(descriptor)]
            add(descriptor, "unconnected", values.map { _ in nil })
            add(descriptor, "defaults", values)
            for (name, invalid) in [("nan", Float(bitPattern: 0x7fc12345)),
                                    ("positive-infinity", Float.infinity),
                                    ("negative-infinity", -Float.infinity)] {
                add(descriptor, name, values.map { _ in invalid })
            }
            if descriptor == 0 || descriptor == 1 || descriptor == 3 {
                for value: Float in [-100, -0.0, 0.49, 0.5, 1, 1.49, 1.5, 2, 100] {
                    add(descriptor, "control-\(value.bitPattern)", [value])
                }
                scenarios.append(Self(name: "\(descriptor)-runtime-changes", descriptor: descriptor, events: [
                    DSPGoldenEvent([1]), DSPGoldenEvent(13, [0]), DSPGoldenEvent(67, [0.49]),
                    DSPGoldenEvent(511, [0.5]), DSPGoldenEvent(1029, [1.49]),
                    DSPGoldenEvent(4095, [1.5]), DSPGoldenEvent(8193, [Float.nan]),
                    DSPGoldenEvent(12295, [1]), DSPGoldenEvent(16003, [nil]),
                    DSPGoldenEvent(24573, [0]), DSPGoldenEvent(28679, [1]),
                ]))
            } else if descriptor == 2 {
                add(descriptor, "bypass", [0, -18, 1000, 0.001, 1])
                add(descriptor, "lower-clamp", [-1, -100, -1, -1, -1])
                add(descriptor, "upper-clamp", [2, 20, 2000, 3, 20])
                for (index, name, low, high): (Int, String, Float, Float) in [
                    (1, "threshold", -100, 20), (2, "ratio", -1, 2000),
                    (3, "attack", -1, 3), (4, "release", -1, 20),
                ] {
                    var controls: [Float?] = [1, -18, 4, 0.001, 0.1]
                    controls[index] = low
                    add(descriptor, "\(name)-lower-clamp", controls)
                    controls[index] = high
                    add(descriptor, "\(name)-upper-clamp", controls)
                }
                add(descriptor, "fast-envelope", [1, -35, 4, 0.0001, 0.0001])
                add(descriptor, "slow-envelope", [1, -6, 2.5, 2, 10])
                add(descriptor, "partial-defaults", [1, nil, 3.75, nil, 0.05])
                scenarios.append(Self(name: "2-runtime-changes", descriptor: descriptor, events: [
                    DSPGoldenEvent(defaults[2]), DSPGoldenEvent(13, [0, -18, 1000, 0.001, 1]),
                    DSPGoldenEvent(511, [0.5, -35, 4, 0.0001, 0.1]),
                    DSPGoldenEvent(4095, [1, -18, 20, 0.1, 0.5]),
                    DSPGoldenEvent(8193, [nil, nil, nil, nil, nil]),
                    DSPGoldenEvent(12295, [1, -18, 1000, 0.001, 1]),
                    DSPGoldenEvent(16385, [1, Float.nan, 2000, 0, 20]),
                ]))
            } else {
                add(descriptor, "stable-filter", [0.5, 0.25, -0.125, -0.5, 0.2])
                add(descriptor, "delayed-feedforward", [0, 0, 1, 0, 0])
                add(descriptor, "lower-clamp", [-100, -100, -100, 0, 0])
                add(descriptor, "upper-clamp", [100, 100, 100, 0, 0])
                add(descriptor, "partial-defaults", [nil, 0.25, nil, -0.5, 0.2])
                add(descriptor, "unstable-feedback", [1, 0, 0, -100, 100])
                scenarios.append(Self(name: "\(descriptor)-runtime-changes", descriptor: descriptor, events: [
                    DSPGoldenEvent([0.5, 0.25, -0.125, -0.5, 0.2]),
                    DSPGoldenEvent(13, [0.5, 0.25, -0.125, -0.5, 0.2]),
                    DSPGoldenEvent(67, [1, 0, 0, 0, 0]),
                    DSPGoldenEvent(511, [1, -0.0, 0, 0, 0]),
                    DSPGoldenEvent(4095, [0.5, 0.25, -0.125, -0.5, 0.2]),
                    DSPGoldenEvent(8193, [Float.nan, nil, nil, nil, nil]),
                    DSPGoldenEvent(12295, [nil, nil, nil, nil, nil]),
                    DSPGoldenEvent(16385, [0, 0, 1, 0, 0]),
                ]))
            }
        }
        return scenarios
    }

    static func source(channels: Int) -> [[Float]] {
        let amplitudes: [Float] = [0, 0.00001, 0.0005, 0.002, 0.008, 0.03, 0.1, 0.3,
                                   1, 3, 0, 0, 0.03, 0.002, 0.00001, 0]
        return (0..<channels).map { channel in
            var state: UInt32 = 0x61c88647 &+ UInt32(channel)
            return (0..<frameCount).map { frame in
                state = state &* 1664525 &+ 1013904223
                let noise = Float(Int32(bitPattern: state) >> 8) / 8388608
                let amplitude = amplitudes[(frame / 2048 + channel * 3) % amplitudes.count]
                // Sparse impulses leave time for the detector to visit its gate and expansion regions.
                if frame == 16385 || frame == 28673 { return channel == 0 ? 2 : -1.5 }
                switch frame % 997 {
                case 31: return Float(bitPattern: 0x7fc12345)
                case 32: return .infinity
                case 33: return -.infinity
                case 34: return Float(bitPattern: 1)
                case 35: return Float(bitPattern: 0x80000001)
                case 36: return Float.leastNormalMagnitude
                case 37: return -Float.leastNormalMagnitude
                case 38: return -0.0
                default: return noise * amplitude
                }
            }
        }
    }
}

private struct DSPGoldenCase: Codable, Equatable {
    struct Checkpoint: Codable, Equatable {
        let frame: Int
        let bits: UInt32
    }
    let scenario: DSPGoldenScenario
    let channelSHA256: [String]
    let checkpoints: [[Checkpoint]]
    let latencyBits: [UInt32]

    init(scenario: DSPGoldenScenario, rendered: DSPGoldenRender) {
        self.scenario = scenario
        channelSHA256 = rendered.output.map { samples in
            Digests.sha256(DSPGoldenRender.bytes(samples))
        }
        let positions = Set([0, 1, 7, 8, 23, 24, 31, 32, 33, 39, 66, 67, 68, 510, 511, 512, 2047, 2048, 4095,
                                             4096, 8192, 8193, 12295, 16385, 24573, 32767])
        checkpoints = rendered.output.map { samples in
            positions.sorted().map { Checkpoint(frame: $0, bits: samples[$0].bitPattern) }
        }
        latencyBits = rendered.latencyBits
    }
}

private struct DSPGoldenRender {
    let output: [[Float]]
    let latencyBits: [UInt32]

    static func bytes(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }
}

private struct DSPGoldenError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func dspGoldenToolStandardErrorData(_ error: Error) -> Data {
    let escapedError = TerminalOutput.escaped(String(describing: error), preservingNewlines: false)
    return Data((escapedError + "\n").utf8)
}

private final class DSPGoldenLibrary {
    static let retiredDescriptorCount = 6
    typealias DescriptorFunction = @convention(c) (UInt) -> UnsafePointer<LADSPA_Descriptor>?
    let descriptor: DescriptorFunction
    private let handle: UnsafeMutableRawPointer

    init(path: String) throws {
        guard let loaded = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw DSPGoldenError(dlerror().map { String(cString: $0) } ?? "The DSP library could not be loaded.")
        }
        guard let symbol = dlsym(loaded, "ladspa_descriptor") else {
            dlclose(loaded)
            throw DSPGoldenError("The DSP library does not export ladspa_descriptor.")
        }
        handle = loaded
        descriptor = unsafeBitCast(symbol, to: DescriptorFunction.self)
    }

    deinit { dlclose(handle) }

    func retiredMetadata() throws -> [DSPGoldenDescriptor] {
        try (0..<Self.retiredDescriptorCount).map { index in
            guard let pointer = descriptor(UInt(index)) else { throw DSPGoldenError("Descriptor \(index) is missing.") }
            return DSPGoldenDescriptor(pointer.pointee)
        }
    }
}

private final class DSPGoldenInstance {
    private let library: DSPGoldenLibrary
    private let descriptor: LADSPA_Descriptor
    private let handle: LADSPA_Handle
    private let controls = UnsafeMutablePointer<Float>.allocate(capacity: 5)
    private let latency = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    init(library: DSPGoldenLibrary, index: UInt) throws {
        guard let pointer = library.descriptor(index), let instantiate = pointer.pointee.instantiate,
              let handle = instantiate(pointer, 48000) else {
            controls.deallocate()
            latency.deallocate()
            throw DSPGoldenError("Descriptor \(index) could not be instantiated at 48 kHz.")
        }
        self.library = library
        descriptor = pointer.pointee
        self.handle = handle
        controls.initialize(repeating: 0, count: 5)
        latency.initialize(to: -1)
    }

    deinit {
        descriptor.cleanup?(handle)
        controls.deinitialize(count: 5)
        controls.deallocate()
        latency.deinitialize(count: 1)
        latency.deallocate()
        withExtendedLifetime(library) {}
    }

    func render(_ scenario: DSPGoldenScenario, blocks: [Int] = [1, 3, 7, 8, 127, 256, 513],
                inPlace: Bool = false, interruption: (() throws -> Void)? = nil) throws -> DSPGoldenRender {
        guard let connect = descriptor.connect_port, let activate = descriptor.activate,
              let run = descriptor.run else { throw DSPGoldenError("A required DSP callback is missing.") }
        let source = DSPGoldenScenario.source(channels: scenario.channels)
        let frames = DSPGoldenScenario.frameCount
        let inputs = source.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            channel.withUnsafeBufferPointer { pointer.initialize(from: $0.baseAddress!, count: frames) }
            return pointer
        }
        let outputs = inPlace ? inputs : source.map { _ -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: Float(bitPattern: 0x7fcabcde), count: frames)
            return pointer
        }
        defer {
            for pointer in inputs { pointer.deinitialize(count: frames); pointer.deallocate() }
            if !inPlace { for pointer in outputs { pointer.deinitialize(count: frames); pointer.deallocate() } }
        }
        func apply(_ event: DSPGoldenEvent) {
            for (index, bits) in event.controlBits.enumerated() {
                if let bits {
                    controls[index] = Float(bitPattern: bits)
                    connect(handle, UInt(2 * scenario.channels + index), controls.advanced(by: index))
                } else {
                    connect(handle, UInt(2 * scenario.channels + index), nil)
                }
            }
        }
        apply(scenario.events[0])
        if scenario.descriptor == 0 { connect(handle, 5, latency) }
        latency.pointee = -1
        activate(handle)
        // Hosts can call zero-frame runs before connecting audio ports and when controls change.
        run(handle, 0)
        var latencyBits: [UInt32] = scenario.descriptor == 0 ? [latency.pointee.bitPattern] : []
        var position = 0
        var blockIndex = 0
        var eventIndex = 1
        var interrupted = false
        while position < frames {
            if eventIndex < scenario.events.count, position == scenario.events[eventIndex].frame {
                apply(scenario.events[eventIndex])
                run(handle, 0)
                if scenario.descriptor == 0 { latencyBits.append(latency.pointee.bitPattern) }
                eventIndex += 1
            }
            let eventEnd = eventIndex < scenario.events.count ? scenario.events[eventIndex].frame : frames
            let count = min(blocks[blockIndex % blocks.count], eventEnd - position)
            for (index, pointer) in (inputs + outputs).enumerated() {
                connect(handle, UInt(index), pointer.advanced(by: position))
            }
            run(handle, UInt(count))
            position += count
            blockIndex += 1
            if !interrupted, position >= 5000, let interruption {
                interrupted = true
                try interruption()
            }
        }
        run(handle, 0)
        if scenario.descriptor == 0 { latencyBits.append(latency.pointee.bitPattern) }
        return DSPGoldenRender(output: outputs.map { Array(UnsafeBufferPointer(start: $0, count: frames)) },
                               latencyBits: latencyBits)
    }
}

#if !DSP_GOLDEN_TOOL
final class DSPGoldenTests: XCTestCase {
    private var pluginPath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("native/inzone_dsp.so").path
    }

    private func fixture() throws -> DSPGoldenFixture {
        let path = try XCTUnwrap(Bundle.module.url(forResource: "dsp-golden", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(DSPGoldenFixture.self, from: Data(contentsOf: path))
    }

    func testToolEscapesUntrustedErrorTextBeforeWritingStandardError() {
        let error = DSPGoldenError("failure\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\nnext")
        let output = String(decoding: dspGoldenToolStandardErrorData(error), as: UTF8.self)

        XCTAssertEqual(
            output,
            "failure\\u{001B}\\u{007F}\\u{0085}\\u{202E}\\u{2028}\\u{2029}\\u{000A}next\n"
        )
    }

    func testFullDescriptorContractMatchesRetiredCImplementation() throws {
        let reference = try fixture()
        XCTAssertEqual(reference.version, 1)
        let library = try DSPGoldenLibrary(path: pluginPath)
        XCTAssertEqual(try library.retiredMetadata(), reference.descriptors)
        XCTAssertNil(library.descriptor(9))
        XCTAssertNil(library.descriptor(UInt.max))
    }

    func testFIRDescriptorContractIsSeparateFromRetiredCFixture() throws {
        let library = try DSPGoldenLibrary(path: pluginPath)
        let labels = ["inzone_fir_standard", "inzone_fir_personal", "inzone_fir_downmix"]
        let names = ["INZONE standard 7.1 FIR", "INZONE personalized 7.1 FIR",
                     "INZONE disabled-surround downmix FIR"]
        let portNames = ["Input FL", "Input FR", "Input FC", "Input LFE", "Input RL", "Input RR",
                         "Input SL", "Input SR", "Output L", "Output R", "latency"]
        for offset in 0..<3 {
            let pointer = try XCTUnwrap(library.descriptor(UInt(DSPGoldenLibrary.retiredDescriptorCount + offset)))
            let metadata = DSPGoldenDescriptor(pointer.pointee)
            XCTAssertEqual(metadata.identifier, UInt(59_876 + offset))
            XCTAssertEqual(metadata.label, labels[offset])
            XCTAssertEqual(metadata.name, names[offset])
            XCTAssertEqual(metadata.maker, "inzone-linux")
            XCTAssertEqual(metadata.copyright, "Local interoperability implementation")
            XCTAssertEqual(metadata.properties, Int(LADSPA_PROPERTY_HARD_RT_CAPABLE))
            XCTAssertEqual(metadata.ports.map(\.name), portNames)
            XCTAssertEqual(metadata.ports.map(\.descriptor), Array(repeating: 9, count: 8) + [10, 10, 6])
            XCTAssertEqual(metadata.ports.map(\.hint), Array(repeating: 0, count: 10) + [3])
            XCTAssertTrue(metadata.ports.allSatisfy { $0.lowerBits == 0 && $0.upperBits == 0 })
            XCTAssertEqual(metadata.callbacks, ["instantiate", "connect_port", "activate", "run", "cleanup"])
        }
    }

    func testEveryDSPMatchesCReferenceSamplesAndControlTransitions() throws {
        let reference = try fixture()
        XCTAssertEqual(reference.cases.map(\.scenario), DSPGoldenScenario.all)
        let nonFiniteReferenceScenarios: Set<String> = [
            "4-unstable-feedback",
            "5-unstable-feedback",
        ]
        let scenariosWithNonFiniteCheckpoints = Set(reference.cases.compactMap { expected in
            expected.checkpoints.joined().contains { !Float(bitPattern: $0.bits).isFinite }
                ? expected.scenario.name : nil
        })
        XCTAssertEqual(scenariosWithNonFiniteCheckpoints, nonFiniteReferenceScenarios)
        let library = try DSPGoldenLibrary(path: pluginPath)
        // The retired C implementation entered a persistent NaN state for these deliberately
        // unstable feedback controls, while the Swift implementation now resets invalid state.
        for expected in reference.cases
            where !nonFiniteReferenceScenarios.contains(expected.scenario.name) {
            let instance = try DSPGoldenInstance(library: library, index: expected.scenario.descriptor)
            let observed = DSPGoldenCase(scenario: expected.scenario, rendered: try instance.render(expected.scenario))
            XCTAssertEqual(observed, expected, expected.scenario.name)
        }
    }

    func testReactivationInPlaceAndDifferentBlocksPreserveCReferenceSamples() throws {
        let reference = try fixture()
        let library = try DSPGoldenLibrary(path: pluginPath)
        for expected in reference.cases where expected.scenario.name.hasSuffix("runtime-changes") {
            let instance = try DSPGoldenInstance(library: library, index: expected.scenario.descriptor)
            for inPlace in [false, true, false] {
                let observed = try instance.render(expected.scenario, blocks: [32768], inPlace: inPlace)
                XCTAssertEqual(DSPGoldenCase(scenario: expected.scenario, rendered: observed), expected,
                               "\(expected.scenario.name), in-place \(inPlace)")
            }
        }
    }

    func testRepeatedLibraryLoadsAndSimultaneousInstancesHaveIndependentState() throws {
        let references = try fixture().cases.filter { $0.scenario.name.hasSuffix("runtime-changes") }
        for _ in 0..<3 {
            let library = try DSPGoldenLibrary(path: pluginPath)
            let instances = try references.map { try DSPGoldenInstance(library: library, index: $0.scenario.descriptor) }
            let siblings = try references.map { try DSPGoldenInstance(library: library, index: $0.scenario.descriptor) }
            for (index, expected) in references.enumerated() {
                // Processing another live instance midway through a stream detects shared DSP state.
                let rendered = try instances[index].render(expected.scenario) {
                    let sibling = try siblings[index].render(expected.scenario)
                    XCTAssertEqual(DSPGoldenCase(scenario: expected.scenario, rendered: sibling), expected,
                                   "\(expected.scenario.name), sibling")
                }
                XCTAssertEqual(DSPGoldenCase(scenario: expected.scenario, rendered: rendered), expected,
                               "\(expected.scenario.name), interrupted instance")
            }
        }
    }
}
#else
@main
private enum DSPGoldenTool {
    static func main() {
        do {
            try perform()
        } catch {
            FileHandle.standardError.write(dspGoldenToolStandardErrorData(error))
            exit(EXIT_FAILURE)
        }
    }

    private static func perform() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 3 else {
            throw DSPGoldenError("Usage: dsp-golden generate C_LIBRARY FIXTURE_JSON | compare C_LIBRARY SWIFT_LIBRARY")
        }
        let reference = try DSPGoldenLibrary(path: arguments[1])
        if arguments[0] == "generate" {
            let provenance = [
                "target": "x86_64-unknown-linux-gnu",
                "math_library": "glibc 2.43",
                "compiler": "GCC: (Debian 16.2.0-2) 16.2.0 (.comment in reference ELF)",
                "flags": "-O2 -Wall -Wextra -Werror -ffp-contract=off -Wno-missing-field-initializers -fPIC -shared -lm",
                "reference_elf_sha256": "6b947631928d6a20074ab56257ab106236bd32450ed79ac41008449c6714d713",
                "ladspa.c_sha256": "400b319f51106bc6864c41f9bb57d390e3792dafbc757e90b7ca74366dbb5f37",
                "dynamics.c_sha256": "c5a79a6109ecb3d9677e1df581258e4117af964b96566286b64e26bebff07ddb",
                "dynamics.h_sha256": "4026ea306a4caedc23eb8e08c14dcf881f4f50b5303b6f70daeb67154799c5d4",
                "spatial_alc.c_sha256": "9e4939c87b7887369ffb0bc59ca8f0497e9f6f9b0dfc6a975c8445c33445d8aa",
                "spatial_alc.h_sha256": "a9d2d4d674f850f176427feac605bb63c19a6fe240d001597e669aa8850e38e2",
                "input": "DSPGoldenScenario.source; 32768 Float samples per channel; UInt32 LCG; synthetic impulses, amplitude transitions, NaN, infinities, subnormals, signed zero",
                "digest": "SHA-256 over channel-major IEEE 754 binary32 bits in little-endian byte order; no normalization",
            ]
            guard try Digests.sha256(file: URL(fileURLWithPath: arguments[1])) == provenance["reference_elf_sha256"] else {
                throw DSPGoldenError("The supplied C library differs from the frozen reference ELF.")
            }
            let cases = try DSPGoldenScenario.all.map { scenario in
                let instance = try DSPGoldenInstance(library: reference, index: scenario.descriptor)
                return DSPGoldenCase(scenario: scenario, rendered: try instance.render(scenario))
            }
            let fixture = DSPGoldenFixture(version: 1, provenance: provenance,
                                           descriptors: try reference.retiredMetadata(), cases: cases)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(fixture).write(to: URL(fileURLWithPath: arguments[2]), options: .atomic)
            print("Generated \(cases.count) C-reference scenarios.")
        } else if arguments[0] == "compare" {
            let candidate = try DSPGoldenLibrary(path: arguments[2])
            guard try reference.retiredMetadata() == candidate.retiredMetadata() else {
                throw DSPGoldenError("Retired descriptor metadata differs.")
            }
            var differences = 0
            for scenario in DSPGoldenScenario.all {
                let expected = try DSPGoldenInstance(library: reference, index: scenario.descriptor).render(scenario)
                let observed = try DSPGoldenInstance(library: candidate, index: scenario.descriptor).render(scenario)
                var mismatchCount = 0
                for channel in expected.output.indices {
                    for frame in expected.output[channel].indices where expected.output[channel][frame].bitPattern != observed.output[channel][frame].bitPattern {
                        if mismatchCount < 4 {
                            let first = expected.output[channel][frame]
                            let second = observed.output[channel][frame]
                            print("\(scenario.name), channel \(channel), frame \(frame): C=\(first) [\(String(first.bitPattern, radix: 16))], Swift=\(second) [\(String(second.bitPattern, radix: 16))]")
                        }
                        mismatchCount += 1
                    }
                }
                if mismatchCount > 0 { print("\(scenario.name): \(mismatchCount) unequal sample bit patterns."); differences += 1 }
                if expected.latencyBits != observed.latencyBits { print("\(scenario.name): Latency differs."); differences += 1 }
            }
            guard differences == 0 else { throw DSPGoldenError("\(differences) scenarios differ.") }
            print("All \(DSPGoldenScenario.all.count) scenarios match exactly.")
        } else {
            throw DSPGoldenError("The command must be generate or compare.")
        }
    }
}
#endif
