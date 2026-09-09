import Foundation
import XCTest
@testable import InzoneCore

final class FilterTests: XCTestCase {
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
        }
    }

    func testExportReplacesOutputSymlinksWithoutChangingTheirTargets() throws {
        let payload = try asset("inzonevirtualizer.dll").deletingLastPathComponent()
        _ = try asset("shp_for_game_v2.0_512tap.hki")
        _ = try asset("wh_g910n_standard.ba")
        let outputNames = FilterBank.channels.map { $0.name + ".wav" } + ["h9-ii-biquads.json", "manifest.json"]
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
        XCTAssertThrowsError(try FilterBank.floatWAV(left: [1], right: []))
    }

    func testNontrivialFFTNormalizationMatchesPythonFloatRounding() throws {
        let left = (0..<512).map { Float(($0 * 37) % 257 - 128) / 8 }
        let right = (0..<512).map { Float(($0 * 73) % 251 - 125) / 16 }
        let result = try FilterBank.normalize([
            HRTFRecord(azimuth: 0, polar: 90, ear: 0, samples: left),
            HRTFRecord(azimuth: 0, polar: 90, ear: 1, samples: right),
        ])
        var samples = Data()
        for record in result.records {
            for sample in record.samples { FilterBinary.append32(sample.bitPattern, to: &samples) }
        }
        // The existing Python implementation supplies this independent synthetic-bank reference.
        XCTAssertEqual(result.gain.bitPattern, 0x3bed0f58)
        XCTAssertEqual(FilterBinary.hex(FilterCrypto.sha256(samples)), "6ed777b190975bece5af98f4bcc7911c2ff26e4c95548182f7c532a0692b4c47")
    }

    func testPersonalizationImportIsPrivateAtomicAndPreservesBackup() throws {
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
            let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)
            XCTAssertEqual(mode.intValue & 0o777, 0o700)
            let files = try FileManager.default.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, 12)
            for file in files {
                let permissions = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
                XCTAssertEqual(permissions.intValue & 0o777, 0o600, file.lastPathComponent)
            }
            try Data("corrupt".utf8).write(to: hki)
            XCTAssertThrowsError(try Personalization.importFiles(paths: paths, hki: hki, ba: ba))
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("manifest.json")), oldManifest)
            try versionSeven.write(to: hki)
            XCTAssertEqual(try Personalization.importFiles(paths: paths, hki: hki, ba: ba), destination)
            let contents = try FileManager.default.contentsOfDirectory(at: paths.shareDirectory, includingPropertiesForKeys: nil)
            let backups = contents.filter { $0.lastPathComponent.hasPrefix(".personal-backup-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first).appendingPathComponent("manifest.json")), oldManifest)
            XCTAssertFalse(contents.contains { $0.lastPathComponent.hasPrefix(".personal-") && !$0.lastPathComponent.hasPrefix(".personal-backup-") })
        }
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
            XCTAssertEqual(contents, ["decoder"])
        }
    }
}
