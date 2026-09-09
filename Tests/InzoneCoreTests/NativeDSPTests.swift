import CLADSPA
import Foundation
import Glibc
import XCTest
@testable import InzoneCore

final class NativeDSPTests: XCTestCase {
    func testPluginExportsOnlyLADSPAAndUsesNoSwiftSharedRuntime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plugin = root.appendingPathComponent("native/inzone_dsp.so").path
        let runner = SystemCommandRunner()
        let dynamic = try runner.run(["readelf", "-d", plugin])
        let libraries = dynamic.components(separatedBy: .newlines).filter { $0.contains("(NEEDED)") }
        XCTAssertEqual(libraries.count, 2)
        XCTAssertTrue(libraries.contains { $0.contains("[libm.so.6]") })
        XCTAssertTrue(libraries.contains { $0.contains("[libc.so.6]") })
        XCTAssertFalse(dynamic.contains("RPATH"))
        XCTAssertFalse(dynamic.contains("RUNPATH"))
        XCTAssertTrue(dynamic.contains("BIND_NOW"))
        XCTAssertTrue(dynamic.contains("(FINI)"))
        let symbols = try runner.run(["nm", "-D", "--defined-only", plugin])
        let exported = symbols.split(separator: "\n").compactMap { $0.split(whereSeparator: \.isWhitespace).last.map(String.init) }
        XCTAssertEqual(exported, ["ladspa_descriptor"])
    }

    func testDescriptorLabelsAndUnsupportedRates() throws {
        let library = try NativeDSPTestLibrary()
        defer { withExtendedLifetime(library) {} }
        let labels = ["inzone_spatial_alc", "inzone_drc", "inzone_alc", "inzone_mic_agc", "inzone_biquad", "inzone_eq_biquad",
                      "inzone_fir_standard", "inzone_fir_personal", "inzone_fir_downmix"]
        let portCounts: [UInt] = [6, 5, 9, 3, 7, 7, 11, 11, 11]
        for (index, label) in labels.enumerated() {
            let pointer = try XCTUnwrap(library.descriptor(UInt(index)), "Missing LADSPA descriptor \(index).")
            let descriptor = pointer.pointee
            XCTAssertEqual(String(cString: try XCTUnwrap(descriptor.Label)), label)
            XCTAssertEqual(descriptor.UniqueID, UInt(59870 + index))
            XCTAssertEqual(descriptor.PortCount, portCounts[index])
            let instantiate = try XCTUnwrap(descriptor.instantiate)
            for rate: UInt in [44100, 96000] {
                let unsupported = instantiate(pointer, rate)
                XCTAssertNil(unsupported, "\(label) accepted unsupported rate \(rate).")
                if let unsupported { descriptor.cleanup?(unsupported) }
            }
            if index < 6 {
                let handle = try XCTUnwrap(instantiate(pointer, 48000), "\(label) rejected 48 kHz.")
                try XCTUnwrap(descriptor.cleanup)(handle)
            }
        }
        XCTAssertNil(library.descriptor(9))
    }

    func testIrregularBlocksInPlaceAndReactivationPreserveExactSamples() throws {
        let library = try NativeDSPTestLibrary()
        defer { withExtendedLifetime(library) {} }
        var left = [Float](repeating: 0, count: 48000)
        var right = [Float](repeating: 0, count: 48000)
        for index in 0..<48000 {
            left[index] = Float(2.0 * Glibc.sin(Double(index) * 0.1309))
            right[index] = Float(0.7 * Glibc.sin(Double(index) * 0.0471))
        }
        let source: [[Float]] = [left, right]
        let cases: [(index: UInt, controls: [Float], channels: Int)] = [
            (2, [1, -18, 1000, 0.001, 1], 2),
            (1, [0], 2), (1, [1], 2), (1, [2], 2),
            (3, [1], 1), (0, [1], 2), (0, [0], 2),
            (4, [0.5, 0.25, 0, -0.5, 0.2], 1),
            (5, [0.5, 0.25, 0, -0.5, 0.2], 1),
        ]
        for test in cases {
            let pointer = try XCTUnwrap(library.descriptor(test.index))
            let descriptor = pointer.pointee
            let handle = try XCTUnwrap(try XCTUnwrap(descriptor.instantiate)(pointer, 48000))
            let cleanup = try XCTUnwrap(descriptor.cleanup)
            defer { cleanup(handle) }
            let connect = try XCTUnwrap(descriptor.connect_port)
            let controlData = UnsafeMutablePointer<Float>.allocate(capacity: test.controls.count)
            controlData.initialize(repeating: 0, count: test.controls.count)
            defer { controlData.deinitialize(count: test.controls.count); controlData.deallocate() }
            for (index, value) in test.controls.enumerated() {
                controlData[index] = value
                connect(handle, UInt(index + 2 * test.channels), controlData.advanced(by: index))
            }
            let latency = UnsafeMutablePointer<Float>.allocate(capacity: 1)
            latency.initialize(to: 0)
            defer { latency.deinitialize(count: 1); latency.deallocate() }
            if test.index == 0 { connect(handle, 5, latency) }
            let input = Array(source.prefix(test.channels))
            let expected = try render(descriptor: descriptor, handle: handle, source: input,
                                      blocks: [48000], inPlace: false)
            let context = "descriptor \(test.index), controls \(test.controls)"
            XCTAssertTrue(expected.allSatisfy { channel in channel.allSatisfy { $0.isFinite } }, "Non-finite output for \(context).")
            if test.index == 1 {
                if test.controls == [0] {
                    assertExactSamples(expected, input, context: "DRC bypass")
                } else {
                    XCTAssertLessThanOrEqual(expected.flatMap { $0 }.map(abs).max() ?? .infinity, 1, context)
                }
            }
            if test.index == 2 {
                XCTAssertLessThan(expected[0].suffix(4800).map(abs).max() ?? .infinity, 0.14, context)
            }
            for inPlace in [false, true] {
                let observed = try render(descriptor: descriptor, handle: handle, source: input,
                                          blocks: [1, 3, 7, 8, 127, 256, 513], inPlace: inPlace)
                assertExactSamples(observed, expected, context: "\(context), in-place \(inPlace)")
            }
            if test.index == 0 {
                XCTAssertEqual(latency.pointee, 32, context)
                XCTAssertTrue(expected[0].prefix(32).allSatisfy { $0 == 0 }, context)
                XCTAssertTrue(expected[1].prefix(32).allSatisfy { $0 == 0 }, context)
            }
        }
    }

    func testBiquadsResetNonFiniteOutputAndRecoverImmediately() throws {
        let library = try NativeDSPTestLibrary()
        defer { withExtendedLifetime(library) {} }
        let cases: [(descriptor: UInt, controls: [Float])] = [
            (4, [64, 1, 0, 1, 0]),
            (5, [1.00096228, -1.99933741, 0.99839213, -1.99933741, 0.99935441]),
        ]
        for test in cases {
            let pointer = try XCTUnwrap(library.descriptor(test.descriptor))
            let descriptor = pointer.pointee
            let handle = try XCTUnwrap(try XCTUnwrap(descriptor.instantiate)(pointer, 48000))
            let cleanup = try XCTUnwrap(descriptor.cleanup)
            defer { cleanup(handle) }
            let connect = try XCTUnwrap(descriptor.connect_port)
            let controlData = UnsafeMutablePointer<Float>.allocate(capacity: test.controls.count)
            controlData.initialize(repeating: 0, count: test.controls.count)
            defer { controlData.deinitialize(count: test.controls.count); controlData.deallocate() }
            for (index, value) in test.controls.enumerated() {
                controlData[index] = value
                connect(handle, UInt(index + 2), controlData.advanced(by: index))
            }

            _ = try render(descriptor: descriptor, handle: handle, source: [[1, 0]],
                           blocks: [2], inPlace: false)
            let source = [[Float.greatestFiniteMagnitude, 1, 0, 0]]
            let observed = try render(descriptor: descriptor, handle: handle, source: source,
                                      blocks: [1, 3], inPlace: false, shouldActivate: false)[0]
            let context = "descriptor \(test.descriptor)"
            XCTAssertEqual(observed[0].bitPattern, Float(0).bitPattern, context)
            XCTAssertTrue(observed.allSatisfy(\.isFinite), context)
            XCTAssertEqual(observed[1].bitPattern, test.controls[0].bitPattern,
                           "\(context) did not recover on the next sample.")

            let reactivated = try render(descriptor: descriptor, handle: handle, source: [[1, 0]],
                                         blocks: [2], inPlace: false)[0]
            XCTAssertTrue(reactivated.allSatisfy(\.isFinite), "\(context), reactivated")
            XCTAssertEqual(reactivated[0].bitPattern, test.controls[0].bitPattern,
                           "\(context) retained history across activation.")
        }
    }

    private func render(descriptor: LADSPA_Descriptor, handle: LADSPA_Handle, source: [[Float]],
                        blocks: [Int], inPlace: Bool, shouldActivate: Bool = true) throws -> [[Float]] {
        let frames = try XCTUnwrap(source.first?.count)
        let connect = try XCTUnwrap(descriptor.connect_port)
        let run = try XCTUnwrap(descriptor.run)
        if shouldActivate { try XCTUnwrap(descriptor.activate)(handle) }
        var inputs: [UnsafeMutablePointer<Float>] = []
        for channel in source {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            channel.withUnsafeBufferPointer { values in
                if let base = values.baseAddress { pointer.update(from: base, count: frames) }
            }
            inputs.append(pointer)
        }
        let outputs: [UnsafeMutablePointer<Float>]
        if inPlace {
            outputs = inputs
        } else {
            outputs = source.map { _ in
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
                pointer.initialize(repeating: 0, count: frames)
                return pointer
            }
        }
        defer {
            for pointer in inputs { pointer.deinitialize(count: frames); pointer.deallocate() }
            if !inPlace {
                for pointer in outputs { pointer.deinitialize(count: frames); pointer.deallocate() }
            }
        }
        var position = 0
        var blockIndex = 0
        while position < frames {
            let count = min(blocks[blockIndex % blocks.count], frames - position)
            for (index, pointer) in (inputs + outputs).enumerated() {
                connect(handle, UInt(index), pointer.advanced(by: position))
            }
            run(handle, UInt(count))
            position += count
            blockIndex += 1
        }
        return outputs.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    private func assertExactSamples(_ observed: [[Float]], _ expected: [[Float]], context: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(observed.count, expected.count, context, file: file, line: line)
        guard observed.count == expected.count else { return }
        for channel in observed.indices {
            XCTAssertEqual(observed[channel].count, expected[channel].count, context, file: file, line: line)
            guard observed[channel].count == expected[channel].count else { return }
            for frame in observed[channel].indices where observed[channel][frame].bitPattern != expected[channel][frame].bitPattern {
                XCTFail("\(context), channel \(channel), frame \(frame): \(observed[channel][frame]) differs from \(expected[channel][frame]).", file: file, line: line)
                return
            }
        }
    }
}

private final class NativeDSPTestLibrary {
    typealias DescriptorFunction = @convention(c) (UInt) -> UnsafePointer<LADSPA_Descriptor>?
    let descriptor: DescriptorFunction
    private let handle: UnsafeMutableRawPointer

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plugin = root.appendingPathComponent("native/inzone_dsp.so")
        guard let loaded = dlopen(plugin.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "Unknown dynamic loader error."
            throw InzoneError.message("Build the native DSP plugin before running its ABI tests: \(detail)")
        }
        guard let symbol = dlsym(loaded, "ladspa_descriptor") else {
            dlclose(loaded)
            throw InzoneError.message("The native DSP plugin does not export ladspa_descriptor.")
        }
        handle = loaded
        descriptor = unsafeBitCast(symbol, to: DescriptorFunction.self)
    }

    deinit { dlclose(handle) }
}
