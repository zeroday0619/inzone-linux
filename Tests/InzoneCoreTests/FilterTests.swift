import Foundation
import Dispatch
import Glibc
import XCTest
@testable import InzoneCore

final class FilterTests: XCTestCase {
    private final class ConcurrentReaderState: @unchecked Sendable {
        private let lock = NSLock()
        private var failures = [String]()

        func record(_ failure: String) {
            lock.lock()
            failures.append(failure)
            lock.unlock()
        }

        func recordedFailures() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return failures
        }
    }

    private var repository: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func asset(_ name: String, directory: String = "analysis/payload") throws -> URL {
        let path = repository.appendingPathComponent(directory).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw XCTSkip("Locally acquired asset is absent: \(directory)/\(name)")
        }
        return path
    }

    private func decoder() throws -> FilterDecoder {
        try FilterDecoder(dll: asset("inzonevirtualizer.dll"))
    }

    private func stock() throws -> Data {
        try Data(contentsOf: asset("shp_for_game_v2.0_512tap.hki"))
    }

    private func table(_ decoder: FilterDecoder, ba: Bool = false) throws -> [UInt32] {
        let binary = try FilterBinary(decoder.read(rva: ba ? 0x1f7d80 : 0x1f6a60, length: 80))
        return try (0..<20).map { try binary.unsigned32($0 * 4) }
    }

    private func replace32(_ value: UInt32, at offset: Int, in data: inout Data) {
        var encoded = Data()
        FilterBinary.append32(value, to: &encoded)
        data.replaceSubrange(offset..<(offset + 4), with: encoded)
    }

    private func encrypted(_ plaintext: Data, header: Data, decoder: FilterDecoder, ba: Bool = false) throws -> Data {
        var result = header
        let initializationVector = FilterCrypto.md5(plaintext)
        result.replaceSubrange(8..<24, with: initializationVector)
        let key = try decoder.key(marker: FilterBinary(result).unsigned32(4), table: table(decoder, ba: ba))
        let padding = 16 - plaintext.count % 16
        let padded = plaintext + Data(repeating: UInt8(padding), count: padding)
        result.append(try FilterCrypto.aes128CBCEncrypt(padded, key: key, iv: initializationVector))
        return result
    }

    private func cipherSeven(_ original: Data, decoder: FilterDecoder) throws -> Data {
        let plaintext = try decoder.decrypt(original, offset: 144, table: table(decoder))
        var header = Data(original.prefix(144))
        header[76] = 7
        let checksum = UInt32(0x37290000) | (plaintext.reduce(UInt32(0)) { $0 &+ UInt32($1) } & 255)
        replace32(checksum, at: 80, in: &header)
        var seed = checksum &+ 0x52276af7
        var encoded = Data()
        let binary = FilterBinary(plaintext)
        for offset in stride(from: 0, to: plaintext.count, by: 4) {
            FilterBinary.append32(try binary.unsigned32(offset) ^ (seed &+ (seed >> 24)), to: &encoded)
            seed = seed &* 0x80849 &+ 0x2a3b5
        }
        return try encrypted(encoded, header: header, decoder: decoder)
    }

    private func modifiedStock(_ decoder: FilterDecoder) throws -> Data {
        let original = try stock()
        var plaintext = try decoder.decrypt(original, offset: 144, table: table(decoder))
        let originalSample = Float(bitPattern: try FilterBinary(plaintext).unsigned32(16))
        replace32((originalSample + 0.25).bitPattern, at: 16, in: &plaintext)
        return try encrypted(plaintext, header: Data(original.prefix(144)), decoder: decoder)
    }

    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-filters-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func bytes(_ hex: String) -> Data {
        let characters = Array(hex)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    private func assertFIRBank(at directory: URL) throws {
        let index = try Data(contentsOf: directory.appendingPathComponent("fir-bank.bin"))
        XCTAssertEqual(index.count, 264)
        XCTAssertEqual(index.prefix(4), Data("IZFB".utf8))
        XCTAssertEqual(try FilterBinary(index).unsigned32(4), 1)
        for (channelIndex, channel) in FilterBank.channels.enumerated() {
            let wave = try Data(contentsOf: directory.appendingPathComponent(channel.name + ".wav"))
            XCTAssertEqual(wave.count, 4152, channel.name)
            let digestOffset = 8 + channelIndex * 32
            XCTAssertEqual(index.subdata(in: digestOffset..<(digestOffset + 32)), FilterCrypto.sha256(wave), channel.name)
        }
    }

    func testDigestKnownAnswers() {
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.sha256(Data())), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.sha256(Data("abc".utf8))), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.md5(Data())), "d41d8cd98f00b204e9800998ecf8427e")
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.md5(Data("abc".utf8))), "900150983cd24fb0d6963f7d28e17f72")
        let multiblock = Data("abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz".utf8)
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.sha256(multiblock)), "2f617f4789492c761be62ea114a24952fd681333e9838f2fa85b9d104e326a47")
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.md5(multiblock)), "15061fc3840896c5299a5b8cc1cf5b5f")
    }

    func testAESCBCNISTKnownAnswer() throws {
        let key = bytes("2b7e151628aed2a6abf7158809cf4f3c")
        let initializationVector = bytes("000102030405060708090a0b0c0d0e0f")
        let plaintext = bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710")
        let ciphertext = bytes("7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e222295163ff1caa1681fac09120eca307586e1a7")
        XCTAssertEqual(try FilterCrypto.aes128CBCEncrypt(plaintext, key: key, iv: initializationVector), ciphertext)
        XCTAssertEqual(try FilterCrypto.aes128CBCDecrypt(ciphertext, key: key, iv: initializationVector), plaintext)
        XCTAssertThrowsError(try FilterCrypto.aes128CBCDecrypt(ciphertext.dropLast(), key: key, iv: initializationVector))
        XCTAssertThrowsError(try FilterCrypto.aes128CBCDecrypt(ciphertext, key: key.dropLast(), iv: initializationVector))
        XCTAssertThrowsError(try FilterCrypto.aes128CBCEncrypt(plaintext, key: key, iv: initializationVector.dropLast()))
    }

    func testStockDecodedReferenceHashAndEars() throws {
        let original = try stock()
        let records = try decoder().hki(original)
        XCTAssertEqual(records.count, 28)
        var plaintext = Data()
        for record in records {
            for value in [record.azimuth, record.polar, record.kind, record.ear] { FilterBinary.append32(UInt32(value), to: &plaintext) }
            for value in record.samples { FilterBinary.append32(value.bitPattern, to: &plaintext) }
        }
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.sha256(plaintext)), "626d8ac6b7fa32f5ba97ea19fa87467cbdaeb5873894e37e9690b8c3eb5dc9fe")
        XCTAssertEqual(FilterCrypto.md5(plaintext), original.subdata(in: 8..<24))
    }

    func testDownmixChannelOrientation() throws {
        let records = try decoder().hki(Data(contentsOf: asset("downmix.hki")))
        for channel in FilterBank.channels where ["FL", "SL", "RL", "FR", "SR", "RR"].contains(channel.name) {
            let positiveEar = ["FL", "SL", "RL"].contains(channel.name) ? 0 : 1
            let first = try XCTUnwrap(records.first { $0.azimuth == channel.azimuth && $0.polar == channel.polar && $0.ear == positiveEar })
            let silent = try XCTUnwrap(records.first { $0.azimuth == channel.azimuth && $0.polar == channel.polar && $0.ear != positiveEar })
            XCTAssertGreaterThan(first.samples[0], 0)
            XCTAssertEqual(silent.samples.map { abs($0) }.reduce(0, +), 0)
        }
    }

    func testH9IIStockBankRequiresExactlyFourteenDirectionsAndPreservesEveryTap() throws {
        let stockRecords = try decoder().hki(stock())
        let downmixRecords = try decoder().hki(Data(contentsOf: asset("downmix.hki")))
        XCTAssertNoThrow(try FilterBank.requireH9IIStockBank(stockRecords))
        XCTAssertNoThrow(try FilterBank.requireH9IIStockBank(downmixRecords))
        XCTAssertEqual(stockRecords.count, 28)
        XCTAssertEqual(downmixRecords.count, 28)
        XCTAssertTrue(stockRecords.allSatisfy { $0.samples.count == 512 })
        XCTAssertTrue(downmixRecords.allSatisfy { $0.samples.count == 512 })
        XCTAssertThrowsError(try FilterBank.requireH9IIStockBank(Array(stockRecords.dropLast(2))))
        XCTAssertThrowsError(try FilterBank.requireH9IIStockBank(stockRecords + Array(stockRecords.prefix(2))))
        var unpaired = stockRecords
        let pairedRecord = unpaired[1]
        unpaired[1] = HRTFRecord(
            azimuth: pairedRecord.azimuth, polar: pairedRecord.polar, kind: pairedRecord.kind,
            ear: 0, samples: pairedRecord.samples
        )
        XCTAssertThrowsError(try FilterBank.requireH9IIStockBank(unpaired))
        var truncated = stockRecords
        let record = truncated[0]
        truncated[0] = HRTFRecord(
            azimuth: record.azimuth, polar: record.polar, kind: record.kind,
            ear: record.ear, samples: Array(record.samples.dropLast())
        )
        XCTAssertThrowsError(try FilterBank.requireH9IIStockBank(truncated))
    }

    func testExportMatchesPythonWAVAndCoefficients() throws {
        let payload = try asset("inzonevirtualizer.dll").deletingLastPathComponent()
        _ = try asset("shp_for_game_v2.0_512tap.hki")
        _ = try asset("wh_g910n_standard.ba")
        let expectedWaves = try FilterBank.channels.map { try asset($0.name + ".wav", directory: "assets") }
        let expectedCoefficients = try asset("h9-ii-biquads.json", directory: "assets")
        try withDirectory { destination in
            try FilterBank.export(payload: payload, destination: destination)
            for expected in expectedWaves {
                XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(expected.lastPathComponent)), try Data(contentsOf: expected), expected.lastPathComponent)
            }
            let actual = try JSONSupport.decode(Data(contentsOf: destination.appendingPathComponent("h9-ii-biquads.json"))) as? [[Double]]
            let expected = try JSONSupport.decode(Data(contentsOf: expectedCoefficients)) as? [[Double]]
            XCTAssertEqual(actual, expected)
            let manifest = try XCTUnwrap(JSONSupport.decode(Data(contentsOf: destination.appendingPathComponent("manifest.json"))) as? [String: Any])
            XCTAssertEqual(manifest["dll_sha256"] as? String, FilterDecoder.dllSHA256)
            XCTAssertEqual(manifest["hrtf_normalization_gain"] as? Double, 1)
            XCTAssertEqual(manifest["hrtf_normalization_partition_size"] as? Int, 512)
            let directions = try XCTUnwrap(manifest["directions"] as? [[String: Int]])
            let downmixDirections = try XCTUnwrap(manifest["downmix_directions"] as? [[String: Int]])
            XCTAssertEqual(directions.count, 14)
            XCTAssertEqual(downmixDirections.count, 14)
            XCTAssertEqual(directions.map { $0["kind"] }, Array(repeating: 2, count: 14))
            XCTAssertEqual(downmixDirections.map { $0["kind"] }, Array(repeating: 1, count: 14))
            XCTAssertEqual(manifest["downmix_channels"] as? [String: [Int]], manifest["channels"] as? [String: [Int]])
            let hashes = try XCTUnwrap(manifest["assets"] as? [String: String])
            XCTAssertEqual(hashes["downmix.hki"], "7f4bdc12b3885435a6305c9c138f3d66ee7da00874bdce7b5f0e12c21da9cdac")
            let downmixRecords = try decoder().hki(Data(contentsOf: asset("downmix.hki")))
            for channel in FilterBank.channels {
                let left = try XCTUnwrap(downmixRecords.first { $0.azimuth == channel.azimuth && $0.polar == channel.polar && $0.ear == 0 })
                let right = try XCTUnwrap(downmixRecords.first { $0.azimuth == channel.azimuth && $0.polar == channel.polar && $0.ear == 1 })
                XCTAssertEqual(
                    try Data(contentsOf: destination.appendingPathComponent("downmix/\(channel.name).wav")),
                    try FilterBank.floatWAV(left: left.samples, right: right.samples), channel.name
                )
            }
            try assertFIRBank(at: destination)
            try assertFIRBank(at: destination.appendingPathComponent("downmix", isDirectory: true))
        }
    }

    func testExportRejectsSymbolicLinkIntermediateWithoutChangingTarget() throws {
        let payload = try asset("inzonevirtualizer.dll").deletingLastPathComponent()
        try withDirectory { directory in
            let sentinel = directory.appendingPathComponent("sentinel", isDirectory: true)
            let intermediate = directory.appendingPathComponent("linked", isDirectory: true)
            try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: intermediate, withDestinationURL: sentinel)

            XCTAssertThrowsError(try FilterBank.export(
                payload: payload, destination: intermediate.appendingPathComponent("assets", isDirectory: true)
            ))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sentinel.path), [])
        }
    }

    func testExportRejectsDownmixDirectorySymlinkWithoutChangingTarget() throws {
        let payload = try asset("inzonevirtualizer.dll").deletingLastPathComponent()
        try withDirectory { directory in
            let destination = directory.appendingPathComponent("export")
            let sentinelDirectory = directory.appendingPathComponent("sentinel")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: sentinelDirectory, withIntermediateDirectories: false)
            let sentinel = sentinelDirectory.appendingPathComponent("sentinel")
            try Data("unchanged".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(
                atPath: destination.appendingPathComponent("downmix").path,
                withDestinationPath: sentinelDirectory.path
            )

            XCTAssertThrowsError(try FilterBank.export(payload: payload, destination: destination))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sentinelDirectory.path), ["sentinel"])
        }
    }

    func testExportReplacesOutputSymlinksWithoutChangingTheirTargets() throws {
        let payload = try asset("inzonevirtualizer.dll").deletingLastPathComponent()
        _ = try asset("shp_for_game_v2.0_512tap.hki")
        _ = try asset("wh_g910n_standard.ba")
        let outputNames = FilterBank.channels.map { $0.name + ".wav" }
            + ["fir-bank.bin", "h9-ii-biquads.json", "manifest.json"]
        try withDirectory { directory in
            let destination = directory.appendingPathComponent("export")
            let sentinels = directory.appendingPathComponent("sentinels")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            try FileManager.default.createDirectory(at: sentinels, withIntermediateDirectories: false)
            for name in outputNames {
                let sentinel = sentinels.appendingPathComponent(name)
                try Data(("sentinel:" + name).utf8).write(to: sentinel)
                try FileManager.default.createSymbolicLink(
                    atPath: destination.appendingPathComponent(name).path, withDestinationPath: sentinel.path
                )
            }

            try FilterBank.export(payload: payload, destination: destination)

            for name in outputNames {
                let output = destination.appendingPathComponent(name)
                let sentinel = sentinels.appendingPathComponent(name)
                let sentinelData = Data(("sentinel:" + name).utf8)
                let values = try output.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                XCTAssertEqual(values.isRegularFile, true, name)
                XCTAssertEqual(values.isSymbolicLink, false, name)
                XCTAssertNotEqual(try Data(contentsOf: output), sentinelData, name)
                XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData, name)
            }
        }
    }

    func testHeaderCipherAndIntegrityCorruptionAreRejected() throws {
        let decoder = try decoder()
        let original = try stock()
        for offset in [0, 8, 56, 60, 76, 78, 88, 92, 144, original.count - 1] {
            var corrupted = original
            corrupted[offset] ^= 1
            XCTAssertThrowsError(try decoder.hki(corrupted), "offset \(offset)")
        }
        XCTAssertThrowsError(try decoder.hki(original.dropLast()))
        XCTAssertThrowsError(try decoder.hki(Data()))
        XCTAssertThrowsError(try decoder.read(rva: UInt64.max, length: 4))
        XCTAssertThrowsError(try decoder.key(marker: 0, table: []))
        try withDirectory { directory in
            let path = directory.appendingPathComponent("wrong.dll")
            try Data("MZ unsupported".utf8).write(to: path)
            XCTAssertThrowsError(try FilterDecoder(dll: path))
        }
    }

    func testHKIRejectsDuplicateUnpairedNonfiniteAndMalformedRecords() throws {
        let decoder = try decoder()
        let original = try stock()
        let plaintext = try decoder.decrypt(original, offset: 144, table: table(decoder))
        let header = Data(original.prefix(144))
        let invalidWords: [(Int, UInt32)] = [(0, 123456), (8, 0), (12, 2), (16, Float.nan.bitPattern), (16, Float.infinity.bitPattern)]
        for (offset, value) in invalidWords {
            var corrupted = plaintext
            replace32(value, at: offset, in: &corrupted)
            XCTAssertThrowsError(try decoder.hki(encrypted(corrupted, header: header, decoder: decoder)), "record offset \(offset)")
        }
        var duplicate = plaintext
        duplicate.replaceSubrange(2064..<(2064 + 16), with: plaintext.prefix(16))
        XCTAssertThrowsError(try decoder.hki(encrypted(duplicate, header: header, decoder: decoder)))
        var mismatchedKind = plaintext
        replace32(1, at: 2064 + 8, in: &mismatchedKind)
        XCTAssertThrowsError(try decoder.hki(encrypted(mismatchedKind, header: header, decoder: decoder)))
        XCTAssertThrowsError(try decoder.hki(encrypted(plaintext.dropLast(2064), header: header, decoder: decoder)))
    }

    func testBARejectsUnstableNonfiniteOutOfRangeAndMalformedCoefficients() throws {
        let decoder = try decoder()
        let original = try Data(contentsOf: asset("wh_g910n_standard.ba"))
        XCTAssertEqual(try decoder.ba(original).count, 7)
        let plaintext = try decoder.decrypt(original, offset: 48, table: table(decoder, ba: true))
        let header = Data(original.prefix(48))
        for (offset, value): (Int, Float) in [(0, .nan), (0, .infinity), (0, 65), (16, 1), (12, 4)] {
            var corrupted = plaintext
            replace32(value.bitPattern, at: offset, in: &corrupted)
            XCTAssertThrowsError(try decoder.ba(encrypted(corrupted, header: header, decoder: decoder, ba: true)))
        }
        XCTAssertThrowsError(try decoder.ba(encrypted(plaintext.dropLast(4), header: header, decoder: decoder, ba: true)))
        XCTAssertThrowsError(try decoder.ba(Data()))
    }

    func testCipherSevenMatchesStockAndRejectsInnerChecksumMismatch() throws {
        let decoder = try decoder()
        let original = try stock()
        var versionSeven = try cipherSeven(original, decoder: decoder)
        XCTAssertEqual(try decoder.hki(versionSeven), try decoder.hki(original))
        versionSeven[80] ^= 1
        XCTAssertThrowsError(try decoder.hki(versionSeven))
    }

    func testPaddingAndChecksumAreIndependentlyValidated() throws {
        let decoder = try decoder()
        let original = try stock()
        let table = try table(decoder)
        var header = Data(original.prefix(144))
        let plaintext = Data("integrity".utf8)
        let initializationVector = FilterCrypto.md5(plaintext)
        header.replaceSubrange(8..<24, with: initializationVector)
        let key = try decoder.key(marker: FilterBinary(header).unsigned32(4), table: table)
        var invalidPadding = [Data(repeating: 0, count: 16), Data(repeating: 17, count: 16)]
        var inconsistent = Data(repeating: 1, count: 16)
        inconsistent[15] = 2
        invalidPadding.append(inconsistent)
        for padded in invalidPadding {
            let encrypted = try FilterCrypto.aes128CBCEncrypt(padded, key: key, iv: initializationVector)
            XCTAssertThrowsError(try decoder.decrypt(header + encrypted, offset: 144, table: table)) { error in
                XCTAssertEqual(error.localizedDescription, "Invalid padding")
            }
        }
        let other = Data("different".utf8) + Data(repeating: 7, count: 7)
        let encrypted = try FilterCrypto.aes128CBCEncrypt(other, key: key, iv: initializationVector)
        XCTAssertThrowsError(try decoder.decrypt(header + encrypted, offset: 144, table: table)) { error in
            XCTAssertEqual(error.localizedDescription, "Filter checksum mismatch")
        }
    }

    func testNormalizationUsesFloatGainAndPreservesAnalyticBound() throws {
        let left = HRTFRecord(azimuth: 0, polar: 90, ear: 0, samples: [64] + Array(repeating: 0, count: 511))
        let right = HRTFRecord(azimuth: 0, polar: 90, ear: 1, samples: [32] + Array(repeating: 0, count: 511))
        let result = try FilterBank.normalize([left, right])
        XCTAssertEqual(result.gain, 18.0 / 64)
        XCTAssertEqual(result.records[0].samples, [18] + Array(repeating: 0, count: 511))
        XCTAssertEqual(result.records[1].samples, [9] + Array(repeating: 0, count: 511))
        let unchanged = try FilterBank.normalize(result.records)
        XCTAssertEqual(unchanged.gain, 1)
        XCTAssertEqual(unchanged.records, result.records)
        XCTAssertThrowsError(try FilterBank.normalize([]))
        XCTAssertThrowsError(try FilterBank.normalize([HRTFRecord(azimuth: 0, polar: 90, ear: 0, samples: [.nan])]))
        XCTAssertThrowsError(try FilterBank.normalize([left, right], partitionSize: 3))
        XCTAssertThrowsError(try FilterBank.floatWAV(left: [1], right: []))
    }

    func testNativeFloatNormalizationThresholdEdges() throws {
        XCTAssertEqual(FilterBank.normalizationGain(peak: Float(bitPattern: 0x418fffff)).bitPattern, 0x3f800000)
        XCTAssertEqual(FilterBank.normalizationGain(peak: Float(bitPattern: 0x41900000)).bitPattern, 0x3f800000)
        XCTAssertEqual(FilterBank.normalizationGain(peak: Float(bitPattern: 0x41900001)).bitPattern, 0x3f7ffffe)
        XCTAssertEqual(FilterBank.normalizationGain(peak: .nan).bitPattern, 0x3f800000)
        for (peakBits, gainBits): (UInt32, UInt32) in [
            (0x418fffff, 0x3f800000), (0x41900000, 0x3f800000), (0x41900001, 0x3f7ffffe),
        ] {
            let samples = [Float(bitPattern: peakBits)] + [Float](repeating: 0, count: 511)
            let normalized = try FilterBank.normalize([
                HRTFRecord(azimuth: 0, polar: 90, ear: 0, samples: samples),
            ])
            XCTAssertEqual(normalized.gain.bitPattern, gainBits)
            XCTAssertEqual(normalized.records[0].samples.count, 512)
        }
    }

    func testNativePartitionedNormalizationPreservesAllTaps() throws {
        var thresholdSamples = [Float](repeating: 0, count: 512)
        var scaledSamples = [Float](repeating: 0, count: 512)
        for index in stride(from: 0, to: 512, by: 128) {
            thresholdSamples[index] = 9
            scaledSamples[index] = 10
        }
        let threshold = try FilterBank.normalize([
            HRTFRecord(azimuth: 0, polar: 90, ear: 0, samples: thresholdSamples),
        ], partitionSize: 128)
        XCTAssertEqual(threshold.gain.bitPattern, 0x3f800000)
        XCTAssertEqual(threshold.records[0].samples, thresholdSamples)

        let scaled = try FilterBank.normalize([
            HRTFRecord(azimuth: 0, polar: 90, ear: 0, samples: scaledSamples),
        ], partitionSize: 128)
        XCTAssertEqual(scaled.gain.bitPattern, 0x3f666666)
        XCTAssertEqual(scaled.records[0].samples.count, 512)
        for index in scaled.records[0].samples.indices {
            XCTAssertEqual(scaled.records[0].samples[index], index % 128 == 0 ? 9 : 0)
        }
    }

    func testPersonalizationImportIsPrivateAtomicAndCleansRetiredBank() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        let versionSeven = try cipherSeven(stock(), decoder: decoder)
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try (Data(repeating: 0, count: 52) + versionSeven).write(to: hki)
            let destination = try Personalization.importFiles(paths: paths, hki: hki, ba: ba)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("personalized_hrtf.hki")), versionSeven)
            let oldManifest = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
            let decodedManifest = try XCTUnwrap(JSONSupport.decode(oldManifest) as? [String: Any])
            XCTAssertEqual((decodedManifest["directions"] as? [[String: Int]])?.count, 14)
            XCTAssertEqual(decodedManifest["hrtf_normalization_partition_size"] as? Int, 512)
            let manifestChannels = try XCTUnwrap(decodedManifest["channels"] as? [String: [Int]])
            XCTAssertEqual(Set(manifestChannels.keys), Set(FilterBank.channels.map(\.name)))
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o700)
            let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 13)
            for file in files {
                let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
                XCTAssertEqual(permissions.intValue & 0o777, 0o600, file.lastPathComponent)
            }
            try assertFIRBank(at: destination)
            var activationCalled = false
            XCTAssertThrowsError(try Personalization.importFilesOutcome(paths: paths, hki: hki, ba: ba) {
                activationCalled = true
            }) { error in
                XCTAssertEqual(error.localizedDescription, "Personalization replacement requires explicit confirmation")
            }
            XCTAssertFalse(activationCalled)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")), oldManifest)
            try Data("corrupt".utf8).write(to: hki)
            XCTAssertThrowsError(try Personalization.importFiles(
                paths: paths, hki: hki, ba: ba, allowReplacing: true, activate: {}
            ))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")), oldManifest)
            try versionSeven.write(to: hki)
            let replacement = try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: true, activate: {}
            )
            XCTAssertEqual(replacement.destination, destination)
            XCTAssertEqual(replacement.cleanupPending, [])
            let contents = try FileManager.default.contentsOfDirectory(at: paths.shareDirectory, includingPropertiesForKeys: nil)
            let backups = contents.filter { $0.lastPathComponent.hasPrefix(".personal-retired-") }
            XCTAssertEqual(backups.count, 0)
            XCTAssertFalse(contents.contains {
                $0.lastPathComponent.hasPrefix(".personal-")
                    && !$0.lastPathComponent.hasPrefix(".personal-retired-")
            })
        }
    }

    func testPersonalizationImportRejectsExistingFileAndSymbolicLink() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let hkiData = try stock()
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try hkiData.write(to: hki)
            let lockSentinel = directory.appendingPathComponent("lock-sentinel")
            let lock = paths.shareDirectory.appendingPathComponent(".personalization.lock")
            try Data("unchanged".utf8).write(to: lockSentinel)
            try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: lockSentinel)
            XCTAssertThrowsError(try Personalization.importFiles(paths: paths, hki: hki, ba: ba))
            XCTAssertEqual(try Data(contentsOf: lockSentinel), Data("unchanged".utf8))
            try FileManager.default.removeItem(at: lock)

            let personal = paths.shareDirectory.appendingPathComponent("personal")
            try Data("unexpected".utf8).write(to: personal)
            XCTAssertThrowsError(try Personalization.importFiles(paths: paths, hki: hki, ba: ba))
            XCTAssertEqual(try Data(contentsOf: personal), Data("unexpected".utf8))

            try FileManager.default.removeItem(at: personal)
            let sentinel = directory.appendingPathComponent("sentinel", isDirectory: true)
            try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: personal, withDestinationURL: sentinel)
            XCTAssertThrowsError(try Personalization.importFiles(paths: paths, hki: hki, ba: ba))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: personal.path), sentinel.path)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sentinel.path), [])
        }
    }

    func testPersonalizationImportRejectsSymbolicLinkIntermediate() throws {
        let ba = try asset("wh_g910n_standard.ba")
        try withDirectory { directory in
            let redirected = directory.appendingPathComponent("redirected", isDirectory: true)
            let local = directory.appendingPathComponent(".local", isDirectory: true)
            try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: local, withDestinationURL: redirected)
            let hki = directory.appendingPathComponent("personal.hki")
            try stock().write(to: hki)

            XCTAssertThrowsError(try Personalization.importFiles(
                paths: InzonePaths(home: directory), hki: hki, ba: ba
            ))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: redirected.path), [])
        }
    }

    func testPersonalizationActivationFailureAtomicallyRestoresPreviousBank() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try stock().write(to: hki)
            let destination = try Personalization.importFiles(paths: paths, hki: hki, ba: ba)
            let previousManifest = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
            let previousWave = try Data(contentsOf: destination.appendingPathComponent("FC.wav"))

            try modifiedStock(decoder).write(to: hki)
            XCTAssertThrowsError(try Personalization.importFiles(
                paths: paths, hki: hki, ba: ba, allowReplacing: true,
                activate: { throw InzoneError.message("Synthetic activation failure") }
            )) { error in
                XCTAssertEqual(error.localizedDescription, "Synthetic activation failure")
            }
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")), previousManifest)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("FC.wav")), previousWave)
            try assertFIRBank(at: destination)
            let retired = try FileManager.default.contentsOfDirectory(
                at: paths.shareDirectory, includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".personal-retired-") }
            XCTAssertEqual(retired.count, 1)
            XCTAssertNotEqual(
                try Data(contentsOf: XCTUnwrap(retired.first).appendingPathComponent("manifest.json")),
                previousManifest
            )
            XCTAssertEqual(try Personalization.cleanupRetired(paths: paths), 1)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(
                atPath: paths.shareDirectory.path
            ).contains { $0.hasPrefix(".personal-retired-") })
        }
    }

    func testFailedExchangeRollbackIsTypedAndRetryableBeforeRecovery() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try stock().write(to: hki)
            let personal = try Personalization.importFiles(paths: paths, hki: hki, ba: ba)
            let previousManifest = try Data(contentsOf: personal.appendingPathComponent("manifest.json"))
            try modifiedStock(decoder).write(to: hki)
            var captured: PersonalizationAssetRollbackError?
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.shareDirectory.path) }

            XCTAssertThrowsError(try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: true
            ) {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.shareDirectory.path)
                throw InzoneError.message("Synthetic activation failure")
            }) { error in
                captured = error as? PersonalizationAssetRollbackError
            }
            let rollbackError = try XCTUnwrap(captured)
            XCTAssertTrue(rollbackError.exchange)
            XCTAssertEqual(rollbackError.original.localizedDescription, "Synthetic activation failure")
            XCTAssertTrue(rollbackError.retiredEntry.hasPrefix(".personal-rollback-"))
            XCTAssertNotEqual(try Data(contentsOf: personal.appendingPathComponent("manifest.json")), previousManifest)
            let rollbackPath = paths.shareDirectory.appendingPathComponent(rollbackError.retiredEntry)
            XCTAssertEqual(try Personalization.cleanupState(paths: paths), [rollbackPath.path])
            XCTAssertEqual(try Personalization.cleanupRetired(paths: paths), 0)
            XCTAssertTrue(FileManager.default.fileExists(atPath: rollbackPath.path))
            XCTAssertThrowsError(try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: true, activate: {}
            ))
            XCTAssertThrowsError(try Personalization.resetOutcome(paths: paths))
            XCTAssertTrue(FileManager.default.fileExists(atPath: rollbackPath.path))

            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.shareDirectory.path)
            try Personalization.retryAssetRollback(paths: paths, error: rollbackError)
            XCTAssertEqual(try Data(contentsOf: personal.appendingPathComponent("manifest.json")), previousManifest)
            XCTAssertEqual(try Personalization.cleanupRetired(paths: paths), 1)
            let invalid = PersonalizationAssetRollbackError(
                original: InzoneError.message("original"), rollback: InzoneError.message("rollback"),
                retiredEntry: ".personal-rollback-not-a-uuid", exchange: true
            )
            XCTAssertThrowsError(try Personalization.retryAssetRollback(paths: paths, error: invalid))
        }
    }

    func testFailedInitialRenameRollbackIsTypedAndRetryable() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try stock().write(to: hki)
            let personal = paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
            var captured: PersonalizationAssetRollbackError?
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.shareDirectory.path) }

            XCTAssertThrowsError(try Personalization.importFilesOutcome(paths: paths, hki: hki, ba: ba) {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: paths.shareDirectory.path)
                throw InzoneError.message("Synthetic first activation failure")
            }) { error in
                captured = error as? PersonalizationAssetRollbackError
            }
            let rollbackError = try XCTUnwrap(captured)
            XCTAssertFalse(rollbackError.exchange)
            XCTAssertTrue(FileManager.default.fileExists(atPath: personal.path))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.shareDirectory.path)
            try Personalization.retryAssetRollback(paths: paths, error: rollbackError)
            XCTAssertFalse(FileManager.default.fileExists(atPath: personal.path))
            XCTAssertEqual(try Personalization.cleanupRetired(paths: paths), 1)
        }
    }

    func testPersonalizationCleanupFailureDoesNotFailCommittedReplacement() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try stock().write(to: hki)
            let destination = try Personalization.importFiles(paths: paths, hki: hki, ba: ba)
            let previousManifest = try Data(contentsOf: destination.appendingPathComponent("manifest.json"))
            try modifiedStock(decoder).write(to: hki)
            let cleanupSentinel = directory.appendingPathComponent("cleanup-sentinel")
            let blockedCleanup = paths.shareDirectory.appendingPathComponent(".personal-retired-untrusted")
            try Data("unchanged".utf8).write(to: cleanupSentinel)

            let outcome = try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: true
            ) {
                try FileManager.default.createSymbolicLink(at: blockedCleanup, withDestinationURL: cleanupSentinel)
            }
            XCTAssertEqual(outcome.destination, destination)
            XCTAssertEqual(outcome.cleanupPending, [blockedCleanup.path])
            XCTAssertEqual(try Personalization.cleanupState(paths: paths), outcome.cleanupPending)
            XCTAssertNotEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")), previousManifest)
            XCTAssertEqual(try Data(contentsOf: cleanupSentinel), Data("unchanged".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: blockedCleanup.path), cleanupSentinel.path)
            let retired = try FileManager.default.contentsOfDirectory(at: paths.shareDirectory, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix(".personal-retired-") }
            XCTAssertEqual(retired, [blockedCleanup])
        }
    }

    func testNextImportRetriesPendingRetiredCleanup() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("personal.hki")
            try stock().write(to: hki)
            _ = try Personalization.importFiles(paths: paths, hki: hki, ba: ba)
            try modifiedStock(decoder).write(to: hki)

            let first = try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: true
            ) {
                let retired = try FileManager.default.contentsOfDirectory(
                    at: paths.shareDirectory, includingPropertiesForKeys: nil
                ).first { $0.lastPathComponent.hasPrefix(".personal-rollback-") }
                guard let retired else { throw InzoneError.message("Missing retired test bank") }
                let locked = retired.appendingPathComponent("locked", isDirectory: true)
                try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
                try Data("pending".utf8).write(to: locked.appendingPathComponent("data"))
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
            }
            XCTAssertEqual(first.cleanupPending.count, 1)
            let retired = URL(fileURLWithPath: try XCTUnwrap(first.cleanupPending.first))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: retired.appendingPathComponent("locked").path
            )

            try stock().write(to: hki)
            let retry = try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: true, activate: {}
            )
            XCTAssertEqual(retry.cleanupPending, [])
            XCTAssertEqual(try Personalization.cleanupState(paths: paths), [])
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(
                atPath: paths.shareDirectory.path
            ).contains { $0.hasPrefix(".personal-retired-") })
        }
    }

    func testPersonalizationExchangeHasNoGapForHeldDirectoryReader() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(
                at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: library).write(to: installedLibrary)
            let originalHKI = directory.appendingPathComponent("original.hki")
            let modifiedHKI = directory.appendingPathComponent("modified.hki")
            try stock().write(to: originalHKI)
            try modifiedStock(decoder).write(to: modifiedHKI)
            _ = try Personalization.importFiles(paths: paths, hki: originalHKI, ba: ba)

            let state = ConcurrentReaderState()
            let group = DispatchGroup()
            let readerOpened = DispatchSemaphore(value: 0)
            let exchangePublished = DispatchSemaphore(value: 0)
            let readerFinished = DispatchSemaphore(value: 0)
            let personalPath = paths.shareDirectory.appendingPathComponent("personal").path
            let expectedFiles = [("fir-bank.bin", 264)]
                + FilterBank.channels.map { ($0.name + ".wav", 4152) }
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                let directoryDescriptor = Glibc.open(
                    personalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard directoryDescriptor >= 0 else {
                    state.record("open directory errno=\(errno)")
                    readerOpened.signal()
                    readerFinished.signal()
                    return
                }
                readerOpened.signal()
                guard exchangePublished.wait(timeout: .now() + 5) == .success else {
                    state.record("exchange notification timed out")
                    _ = Glibc.close(directoryDescriptor)
                    readerFinished.signal()
                    return
                }
                for (name, expectedSize) in expectedFiles {
                    let descriptor = name.withCString {
                        Glibc.openat(directoryDescriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
                    }
                    guard descriptor >= 0 else {
                        state.record("openat \(name) errno=\(errno)")
                        continue
                    }
                    var status = stat()
                    if Glibc.fstat(descriptor, &status) != 0 || status.st_size != expectedSize {
                        state.record("fstat \(name)")
                    }
                    _ = Glibc.close(descriptor)
                }
                _ = Glibc.close(directoryDescriptor)
                readerFinished.signal()
            }
            defer {
                exchangePublished.signal()
                group.wait()
            }
            XCTAssertEqual(readerOpened.wait(timeout: .now() + 5), .success)
            let outcome = try Personalization.importFilesOutcome(
                paths: paths, hki: modifiedHKI, ba: ba, allowReplacing: true
            ) {
                let current = Glibc.open(personalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard current >= 0 else {
                    throw InzoneError.message("New personalization directory was unavailable during activation")
                }
                _ = Glibc.close(current)
                exchangePublished.signal()
                guard readerFinished.wait(timeout: .now() + 5) == .success else {
                    throw InzoneError.message("Held personalization reader did not finish")
                }
            }
            XCTAssertEqual(outcome.cleanupPending, [])
            group.wait()
            XCTAssertEqual(state.recordedFailures(), [])
            XCTAssertEqual(try Personalization.cleanupRetired(paths: paths), 0)
        }
    }

    func testPersonalizationResetRemovesOnlyARealPersonalDirectory() throws {
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            try FileManager.default.createDirectory(at: paths.shareDirectory, withIntermediateDirectories: true)
            XCTAssertFalse(try Personalization.reset(paths: paths))

            let personal = paths.shareDirectory.appendingPathComponent("personal")
            let sentinel = directory.appendingPathComponent("sentinel")
            try Data("unchanged".utf8).write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: personal, withDestinationURL: sentinel)
            XCTAssertThrowsError(try Personalization.reset(paths: paths))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: personal.path), sentinel.path)

            try FileManager.default.removeItem(at: personal)
            try Data("unexpected".utf8).write(to: personal)
            XCTAssertThrowsError(try Personalization.reset(paths: paths))
            XCTAssertEqual(try Data(contentsOf: personal), Data("unexpected".utf8))

            try FileManager.default.removeItem(at: personal)
            try FileManager.default.createDirectory(at: personal, withIntermediateDirectories: false)
            try Data("manifest".utf8).write(to: personal.appendingPathComponent("manifest.json"))
            try FileManager.default.createSymbolicLink(
                at: personal.appendingPathComponent("outside"), withDestinationURL: sentinel
            )
            let retiredLink = paths.shareDirectory.appendingPathComponent(".personal-retired-untrusted")
            try FileManager.default.createSymbolicLink(at: retiredLink, withDestinationURL: sentinel)
            XCTAssertThrowsError(try Personalization.reset(paths: paths))
            XCTAssertTrue(FileManager.default.fileExists(atPath: personal.path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
            try FileManager.default.removeItem(at: retiredLink)
            XCTAssertTrue(try Personalization.reset(paths: paths))
            XCTAssertFalse(FileManager.default.fileExists(atPath: personal.path))
            XCTAssertEqual(try Data(contentsOf: sentinel), Data("unchanged".utf8))
            XCTAssertFalse(try Personalization.reset(paths: paths))
            let leftovers = try FileManager.default.contentsOfDirectory(atPath: paths.shareDirectory.path)
            XCTAssertEqual(leftovers.filter { $0.hasPrefix(".personal-retired-reset-") }.count, 0)
        }
    }

    func testResetCleanupFailureCommitsRemovalWithPendingState() throws {
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let personal = paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
            let locked = personal.appendingPathComponent("locked", isDirectory: true)
            try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
            try Data("private".utf8).write(to: locked.appendingPathComponent("data"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)

            let outcome = try Personalization.resetOutcome(paths: paths)
            XCTAssertTrue(outcome.removed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: personal.path))
            XCTAssertEqual(outcome.cleanupPending.count, 1)
            let retired = URL(fileURLWithPath: try XCTUnwrap(outcome.cleanupPending.first))
            XCTAssertTrue(retired.lastPathComponent.hasPrefix(".personal-retired-reset-"))
            XCTAssertEqual(try Personalization.cleanupState(paths: paths), outcome.cleanupPending)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: retired.appendingPathComponent("locked").path
            )
            XCTAssertEqual(try Personalization.cleanupRetired(paths: paths), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: retired.path))
            XCTAssertEqual(try Personalization.cleanupState(paths: paths), [])
        }
    }

    func testLocalYY2987ArtifactUsesCanonicalBAContainer() throws {
        let personal = try asset("YY2987-personal.ba", directory: "analysis")
        let standard = try asset("wh_g910n_standard.ba")
        let personalData = try Data(contentsOf: personal)
        XCTAssertEqual(personalData, try Data(contentsOf: standard))
        XCTAssertTrue(personalData.starts(with: Data("ba00".utf8)))
        XCTAssertEqual(try decoder().ba(personalData).count, 7)
    }

    func testPersonalizationRejectsOversizedAndNonregularFiles() throws {
        try withDirectory { directory in
            let input = directory.appendingPathComponent("large.hki")
            let exact = Data(repeating: 0, count: Personalization.maximumInputSize)
            try exact.write(to: input)
            XCTAssertEqual(try Personalization.readFile(input).count, Personalization.maximumInputSize)
            try (exact + Data([0])).write(to: input)
            XCTAssertThrowsError(try Personalization.readFile(input))
            XCTAssertThrowsError(try Personalization.readFile(directory))
        }
    }

    func testPersonalizationRequiresEveryRendererDirectionBeforeStaging() throws {
        let library = try asset("inzonevirtualizer.dll")
        let ba = try asset("wh_g910n_standard.ba")
        let decoder = try decoder()
        let original = try stock()
        var plaintext = try decoder.decrypt(original, offset: 144, table: table(decoder))
        for offset in stride(from: 0, to: plaintext.count, by: 2064) {
            if try FilterBinary(plaintext).unsigned32(offset) == 330 {
                replace32(331, at: offset, in: &plaintext)
            }
        }
        let missingDirection = try encrypted(plaintext, header: original.prefix(144), decoder: decoder)
        XCTAssertEqual(try decoder.hki(missingDirection).count, 28)
        try withDirectory { directory in
            let paths = InzonePaths(home: directory)
            let installedLibrary = paths.shareDirectory.appendingPathComponent("decoder/inzonevirtualizer.dll")
            try FileManager.default.createDirectory(at: installedLibrary.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: library).write(to: installedLibrary)
            let hki = directory.appendingPathComponent("missing.hki")
            try missingDirection.write(to: hki)
            XCTAssertThrowsError(try Personalization.importFiles(paths: paths, hki: hki, ba: ba)) { error in
                XCTAssertEqual(error.localizedDescription, "Personalized HKI is missing required 7.1 directions")
            }
            let contents = try FileManager.default.contentsOfDirectory(atPath: paths.shareDirectory.path)
            XCTAssertEqual(Set(contents), Set([".personalization.lock", "decoder"]))
        }
    }
}
