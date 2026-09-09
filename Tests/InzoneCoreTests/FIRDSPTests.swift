import CLADSPA
import Foundation
import Glibc
import XCTest
@testable import InzoneCore

final class FIRDSPTests: XCTestCase {
    private static let publicToInternal = [1, 2, 0, 7, 5, 6, 3, 4]
    private static let filenames = ["FL.wav", "FR.wav", "FC.wav", "LFE.wav", "RL.wav", "RR.wav", "SL.wav", "SR.wav"]

    func testStandardFIRMatchesDisassemblyOracleAcrossCallbackShapes() throws {
        let root = repositoryRoot()
        let directory = root.appendingPathComponent("assets")
        try requireVendorBank(directory)
        let coefficients = try loadCoefficients(directory)
        let source = finiteSource(frames: 96)
        let expected = disassemblyOracle(source: source, coefficients: coefficients)

        let library = try FIRTestLibrary()
        defer { withExtendedLifetime(library) {} }
        let whole = try FIRTestInstance(library: library, descriptor: 6, dataRoot: root)
        let irregular = try FIRTestInstance(library: library, descriptor: 6, dataRoot: root)
        let inPlace = try FIRTestInstance(library: library, descriptor: 6, dataRoot: root)
        XCTAssertEqual(try whole.render(source: source, blocks: [96], inPlace: false).latency.bitPattern,
                       Float(0).bitPattern)
        assertExact(try whole.render(source: source, blocks: [96], inPlace: false).output, expected)
        assertExact(try irregular.render(source: source, blocks: [1, 3, 7, 128, 257], inPlace: false).output, expected)
        assertExact(try inPlace.render(source: source, blocks: [17, 127, 2], inPlace: true).output, expected)
    }

    func testFIRPreprocessingAndActivationMatchSonyBoundary() throws {
        let root = repositoryRoot()
        let directory = root.appendingPathComponent("assets")
        try requireVendorBank(directory)
        let coefficients = try loadCoefficients(directory)
        let threshold = Float(bitPattern: 0x2f80_0000)
        var source = Array(repeating: Array(repeating: Float(0), count: 32), count: 8)
        source[0][0] = Float(bitPattern: 1)
        source[1][0] = -Float(bitPattern: 0x2f7f_ffff)
        source[2][0] = threshold
        source[3][0] = -threshold
        source[4][1] = .infinity
        source[5][2] = -.infinity
        source[6][3] = Float(bitPattern: 0x7fc1_2345)
        let expected = disassemblyOracle(source: source, coefficients: coefficients)

        let library = try FIRTestLibrary()
        defer { withExtendedLifetime(library) {} }
        let instance = try FIRTestInstance(library: library, descriptor: 6, dataRoot: root)
        let observed = try instance.render(source: source, blocks: [1, 511, 8], inPlace: false).output
        assertExact(observed, expected)
        XCTAssertTrue(observed.joined().contains(where: { !$0.isFinite }))

        var impulse = Array(repeating: Array(repeating: Float(0), count: 8), count: 8)
        impulse[0][0] = 1
        _ = try instance.render(source: impulse, blocks: [8], inPlace: false)
        let silence = Array(repeating: Array(repeating: Float(0), count: 8), count: 8)
        let reactivated = try instance.render(source: silence, blocks: [8], inPlace: false).output
        XCTAssertTrue(reactivated.joined().allSatisfy { $0.bitPattern == 0 })
    }

    func testDownmixDeltaFIRMatchesDisassemblyOracle() throws {
        let root = repositoryRoot()
        let directory = root.appendingPathComponent("assets/downmix")
        try requireVendorBank(directory)
        let coefficients = try loadCoefficients(directory)
        var source = finiteSource(frames: 520)
        source[0][32] = -source[2][32]
        source[3][64] = .infinity
        let expected = disassemblyOracle(source: source, coefficients: coefficients)

        let library = try FIRTestLibrary()
        defer { withExtendedLifetime(library) {} }
        let instance = try FIRTestInstance(library: library, descriptor: 8, dataRoot: root)
        let observed = try instance.render(source: source, blocks: [256, 1, 3, 127], inPlace: false).output
        assertExact(observed, expected)
    }

    func testSonyUnrolledAdditionMatchesFrozenVector() throws {
        let left = [Float](repeating: 0, count: 512).enumerated().map { index, _ in index < 2 ? Float(1) : 0 }
        let right = [Float](repeating: 0, count: 512)
        try withTemporaryDataBank(name: "assets", left: left, right: right) { _, dataRoot in
            let first = [
                0xc00e2c31, 0x3e1c77e0, 0xbd0920c6, 0xbb2780f3,
                0xc41a3f7d, 0xc4f2b7ac, 0xc97ee3b1, 0x416dd1cb,
            ].map { Float(bitPattern: UInt32($0)) }
            let second = [
                0x43bd2201, 0x3a5551f9, 0x3c7d51e3, 0x43f35bb3,
                0xbbbc947f, 0x4780f8fd, 0x40044032, 0xbd7061c9,
            ].map { Float(bitPattern: UInt32($0)) }
            var source = Array(repeating: Array(repeating: Float(0), count: 2), count: 8)
            for publicChannel in 0..<8 {
                let internalChannel = Self.publicToInternal[publicChannel]
                source[publicChannel][0] = first[internalChannel]
                source[publicChannel][1] = second[internalChannel]
            }
            let library = try FIRTestLibrary()
            defer { withExtendedLifetime(library) {} }
            let instance = try FIRTestInstance(library: library, descriptor: 6, dataRoot: dataRoot)
            let output = try instance.render(source: source, blocks: [1], inPlace: false).output[0]
            XCTAssertEqual(output.map(\.bitPattern), [0xc97f82d1, 0xc96f2d82])
        }
    }

    func testPersonalDescriptorLoadsTemporaryHomeBank() throws {
        var left = [Float](repeating: 0, count: 512)
        var right = [Float](repeating: 0, count: 512)
        left[0] = 0.25
        right[0] = -0.5
        try withTemporaryDataBank(name: "personal", left: left, right: right) { _, dataRoot in
            var source = Array(repeating: Array(repeating: Float(0), count: 1), count: 8)
            source[2][0] = 1
            let library = try FIRTestLibrary()
            defer { withExtendedLifetime(library) {} }
            let instance = try FIRTestInstance(library: library, descriptor: 7, dataRoot: dataRoot)
            let output = try instance.render(source: source, blocks: [1], inPlace: false).output
            XCTAssertEqual(output[0][0].bitPattern, Float(0.25).bitPattern)
            XCTAssertEqual(output[1][0].bitPattern, Float(-0.5).bitPattern)
        }
    }

    func testPersonalLoaderRejectsDigestMismatchAndSymlink() throws {
        var left = [Float](repeating: 0, count: 512)
        let right = [Float](repeating: 0, count: 512)
        left[0] = 1
        try withTemporaryDataBank(name: "personal", left: left, right: right) { directory, dataRoot in
            let file = directory.appendingPathComponent("FL.wav")
            var data = try Data(contentsOf: file)
            data[56] ^= 1
            try data.write(to: file)
            try assertInstantiationFails(descriptor: 7, dataRoot: dataRoot)
        }
        try withTemporaryDataBank(name: "personal", left: left, right: right) { directory, dataRoot in
            let file = directory.appendingPathComponent("FL.wav")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(
                at: file, withDestinationURL: directory.appendingPathComponent("FR.wav")
            )
            try assertInstantiationFails(descriptor: 7, dataRoot: dataRoot)
        }
    }

    func testExplicitDataRootDoesNotFallBackAfterWholeBankRejection() throws {
        var left = [Float](repeating: 0, count: 512)
        let right = [Float](repeating: 0, count: 512)
        left[0] = 1
        try withTemporaryDataBank(name: "assets", left: left, right: right) { directory, dataRoot in
            let file = directory.appendingPathComponent("SR.wav")
            var data = try Data(contentsOf: file)
            data[56] ^= 1
            try data.write(to: file)

            try assertInstantiationFails(descriptor: 6, dataRoot: dataRoot)
        }
    }

    func testUnconnectedLayoutInputsAreExactZero() throws {
        let root = repositoryRoot()
        try requireVendorBank(root.appendingPathComponent("assets"))
        let coefficients = try loadCoefficients(root.appendingPathComponent("assets"))
        let source = finiteSource(frames: 24)
        let layouts: [[Int]] = [
            [0, 1],
            [0, 1, 2, 3, 6, 7],
            Array(0..<8),
        ]
        let library = try FIRTestLibrary()
        defer { withExtendedLifetime(library) {} }
        for layout in layouts {
            var expectedSource = Array(repeating: Array(repeating: Float(0), count: 24), count: 8)
            for channel in layout { expectedSource[channel] = source[channel] }
            let expected = disassemblyOracle(source: expectedSource, coefficients: coefficients)
            let instance = try FIRTestInstance(library: library, descriptor: 6, dataRoot: root)
            let observed = try instance.render(
                source: source, blocks: [1, 7, 16], inPlace: false, connectedInputs: Set(layout)
            ).output
            assertExact(observed, expected)
        }
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func finiteSource(frames: Int) -> [[Float]] {
        (0..<8).map { channel in
            (0..<frames).map { frame in
                let numerator = Float(((channel + 3) * (frame % 29)) - 31)
                return numerator / Float(64 + channel * 7)
            }
        }
    }

    private func loadCoefficients(_ directory: URL) throws -> [Float] {
        var coefficients = Array(repeating: Float(0), count: 8192)
        for publicChannel in 0..<8 {
            let filename = Self.filenames[publicChannel]
            let data = try Data(contentsOf: directory.appendingPathComponent(filename))
            guard data.count == 4152 else { throw FIRTestError("Invalid FIR WAV size: \(filename)") }
            for tap in 0..<512 {
                for ear in 0..<2 {
                    let offset = 56 + (tap * 2 + ear) * 4
                    let bits = UInt32(data[offset]) | UInt32(data[offset + 1]) << 8
                        | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
                    let internalChannel = Self.publicToInternal[publicChannel]
                    coefficients[(ear * 8 + internalChannel) * 512 + tap] = Float(bitPattern: bits)
                }
            }
        }
        return coefficients
    }

    private func disassemblyOracle(source: [[Float]], coefficients: [Float]) -> [[Float]] {
        let frames = source[0].count
        var history = Array(repeating: Float(0), count: 4096)
        var result = Array(repeating: Array(repeating: Float(0), count: frames), count: 2)
        let threshold = Float(bitPattern: 0x2f80_0000)
        var position = 0
        for frame in 0..<frames {
            position = (position + 511) & 511
            for publicChannel in 0..<8 {
                let input = source[publicChannel][frame]
                let sample: Float = abs(input) < threshold ? 0 : input
                let internalChannel = Self.publicToInternal[publicChannel]
                history[internalChannel * 512 + position] = sample
            }
            for ear in 0..<2 {
                var accumulator: Float = 0
                for base in stride(from: 0, to: 512, by: 8) {
                    var values = products(base, ear: ear, position: position,
                                          history: history, coefficients: coefficients)
                    let first = (values[0] + values[1]) + (values[2] + values[3])
                    let second = (values[4] + values[5]) + (values[6] + values[7])
                    accumulator = (first + second) + accumulator
                    for lane in 1..<8 {
                        values = products(base + lane, ear: ear, position: position,
                                          history: history, coefficients: coefficients)
                        accumulator += values[7]
                        accumulator += values[6]
                        accumulator += lane == 2 || lane == 7
                            ? values[5] + values[4] : values[4] + values[5]
                        let firstPair = values[0] + values[1]
                        let secondPair = values[2] + values[3]
                        accumulator += lane == 1 || lane == 3 || lane == 6
                            ? firstPair + secondPair : secondPair + firstPair
                    }
                }
                result[ear][frame] = accumulator
            }
        }
        return result
    }

    private func products(
        _ tap: Int, ear: Int, position: Int, history: [Float], coefficients: [Float]
    ) -> [Float] {
        let historyIndex = (position + tap) & 511
        return (0..<8).map {
            history[$0 * 512 + historyIndex] * coefficients[(ear * 8 + $0) * 512 + tap]
        }
    }

    private func withTemporaryDataBank(
        name: String, left: [Float], right: [Float], body: (URL, URL) throws -> Void
    ) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = Data("IZFB".utf8)
        manifest.append(contentsOf: [1, 0, 0, 0])
        for filename in Self.filenames {
            let wave = try FilterBank.floatWAV(left: left, right: right)
            try wave.write(to: directory.appendingPathComponent(filename))
            manifest.append(FilterCrypto.sha256(wave))
        }
        try manifest.write(to: directory.appendingPathComponent("fir-bank.bin"))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(directory, temporary)
    }

    private func assertInstantiationFails(descriptor index: UInt, dataRoot: URL) throws {
        let library = try FIRTestLibrary()
        defer { withExtendedLifetime(library) {} }
        let pointer = try XCTUnwrap(library.descriptor(index))
        let instantiate = try XCTUnwrap(pointer.pointee.instantiate)
        XCTAssertNil(try withFIRDataRoot(dataRoot) { instantiate(pointer, 48_000) })
    }

    private func requireVendorBank(_ directory: URL) throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("fir-bank.bin").path) else {
            throw XCTSkip("Run make assets to execute the vendor FIR integration cases.")
        }
    }

    private func assertExact(
        _ observed: [[Float]], _ expected: [[Float]], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(observed.count, expected.count, file: file, line: line)
        for channel in observed.indices {
            XCTAssertEqual(observed[channel].count, expected[channel].count, file: file, line: line)
            for frame in observed[channel].indices where observed[channel][frame].bitPattern != expected[channel][frame].bitPattern {
                XCTFail("FIR mismatch at channel \(channel), frame \(frame): \(String(observed[channel][frame].bitPattern, radix: 16)) != \(String(expected[channel][frame].bitPattern, radix: 16))", file: file, line: line)
                return
            }
        }
    }
}

private struct FIRTestError: Error {
    let description: String
    init(_ description: String) { self.description = description }
}

private final class FIRTestLibrary {
    typealias DescriptorFunction = @convention(c) (UInt) -> UnsafePointer<LADSPA_Descriptor>?
    let descriptor: DescriptorFunction
    private let handle: UnsafeMutableRawPointer

    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plugin = root.appendingPathComponent("native/inzone_dsp.so")
        guard let handle = dlopen(plugin.path, RTLD_NOW | RTLD_LOCAL) else {
            throw FIRTestError(dlerror().map { String(cString: $0) } ?? "Unable to load FIR plugin.")
        }
        guard let symbol = dlsym(handle, "ladspa_descriptor") else {
            dlclose(handle)
            throw FIRTestError("Missing ladspa_descriptor.")
        }
        self.handle = handle
        descriptor = unsafeBitCast(symbol, to: DescriptorFunction.self)
    }

    deinit { dlclose(handle) }
}

private final class FIRTestInstance {
    private let descriptor: LADSPA_Descriptor
    private let handle: LADSPA_Handle

    init(library: FIRTestLibrary, descriptor index: UInt, dataRoot: URL) throws {
        let pointer = try XCTUnwrap(library.descriptor(index))
        descriptor = pointer.pointee
        let instantiate = try XCTUnwrap(pointer.pointee.instantiate)
        handle = try XCTUnwrap(try withFIRDataRoot(dataRoot) { instantiate(pointer, 48_000) })
    }

    deinit { descriptor.cleanup?(handle) }

    func render(
        source: [[Float]], blocks: [Int], inPlace: Bool, connectedInputs: Set<Int> = Set(0..<8)
    ) throws -> (output: [[Float]], latency: Float) {
        let frames = source[0].count
        let connect = try XCTUnwrap(descriptor.connect_port)
        let run = try XCTUnwrap(descriptor.run)
        try XCTUnwrap(descriptor.activate)(handle)
        let inputs = source.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            channel.withUnsafeBufferPointer { if let base = $0.baseAddress { pointer.update(from: base, count: frames) } }
            return pointer
        }
        let outputs: [UnsafeMutablePointer<Float>] = inPlace ? Array(inputs.prefix(2)) : (0..<2).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(repeating: 0, count: frames)
            return pointer
        }
        let latency = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        latency.initialize(to: -1)
        defer {
            latency.deinitialize(count: 1)
            latency.deallocate()
            for pointer in inputs { pointer.deinitialize(count: frames); pointer.deallocate() }
            if !inPlace { for pointer in outputs { pointer.deinitialize(count: frames); pointer.deallocate() } }
        }
        var position = 0
        var block = 0
        while position < frames {
            let count = min(blocks[block % blocks.count], frames - position)
            for channel in 0..<8 {
                connect(handle, UInt(channel), connectedInputs.contains(channel) ? inputs[channel].advanced(by: position) : nil)
            }
            connect(handle, 8, outputs[0].advanced(by: position))
            connect(handle, 9, outputs[1].advanced(by: position))
            connect(handle, 10, latency)
            run(handle, UInt(count))
            position += count
            block += 1
        }
        return (outputs.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }, latency.pointee)
    }
}

private let firEnvironmentLock = NSLock()

private func withFIRDataRoot<T>(_ root: URL, _ body: () throws -> T) rethrows -> T {
    firEnvironmentLock.lock()
    defer { firEnvironmentLock.unlock() }
    let previous = ProcessInfo.processInfo.environment["INZONE_DSP_DATA_DIR"]
    setenv("INZONE_DSP_DATA_DIR", root.path, 1)
    defer {
        if let previous { setenv("INZONE_DSP_DATA_DIR", previous, 1) }
        else { unsetenv("INZONE_DSP_DATA_DIR") }
    }
    return try body()
}
