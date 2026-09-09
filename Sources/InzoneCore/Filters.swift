import Foundation
import Glibc

@_silgen_name("renameat2")
private func systemRenameAt2(
    _ oldDirectory: Int32, _ oldPath: UnsafePointer<CChar>,
    _ newDirectory: Int32, _ newPath: UnsafePointer<CChar>, _ flags: UInt32
) -> Int32

private enum FilterPath {
    static func itemType(at path: URL) throws -> FileAttributeType? {
        do {
            return try FileManager.default.attributesOfItem(atPath: path.path)[.type] as? FileAttributeType
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw error
        }
    }

    static func ensureDirectory(_ directory: URL) throws {
        let descriptor = try openDirectory(directory, createMissing: true)
        _ = Glibc.close(descriptor)
    }

    static func requireDirectory(_ directory: URL) throws {
        let descriptor = try openDirectory(directory, createMissing: false)
        _ = Glibc.close(descriptor)
    }

    static func openDirectory(_ directory: URL, createMissing: Bool) throws -> Int32 {
        let standardized = directory.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw InzoneError.message("Filter directory must use an absolute file path")
        }
        var descriptor = Glibc.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw InzoneError.message("Open root directory failed: \(String(cString: strerror(errno)))")
        }
        var currentPath = ""
        for component in standardized.pathComponents where component != "/" {
            currentPath += "/" + component
            var next = component.withCString {
                Glibc.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0, errno == ENOENT, createMissing {
                let creation = component.withCString { Glibc.mkdirat(descriptor, $0, mode_t(0o755)) }
                if creation != 0, errno != EEXIST {
                    let reason = String(cString: strerror(errno))
                    _ = Glibc.close(descriptor)
                    throw InzoneError.message("Create filter directory failed for \(currentPath): \(reason)")
                }
                next = component.withCString {
                    Glibc.openat(descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            guard next >= 0 else {
                let reason = String(cString: strerror(errno))
                _ = Glibc.close(descriptor)
                throw InzoneError.message(
                    "Filter directory contains a non-directory or symbolic link at \(currentPath): \(reason)"
                )
            }
            _ = Glibc.close(descriptor)
            descriptor = next
        }
        return descriptor
    }
}

/// Reports a committed personalization import and any retired banks that still require cleanup.
public struct PersonalizationImportOutcome: Equatable, Sendable {
    public let destination: URL
    public let cleanupPending: [String]

    public init(destination: URL, cleanupPending: [String]) {
        self.destination = destination
        self.cleanupPending = cleanupPending
    }
}

/// Reports whether personalization was deactivated and any retired data that still requires cleanup.
public struct PersonalizationResetOutcome: Equatable, Sendable {
    public let removed: Bool
    public let cleanupPending: [String]

    public init(removed: Bool, cleanupPending: [String]) {
        self.removed = removed
        self.cleanupPending = cleanupPending
    }
}

struct PersonalizationAssetRollbackError: Error, LocalizedError {
    let original: Error
    let rollback: Error
    let retiredEntry: String
    let exchange: Bool

    var errorDescription: String? {
        "Personalization asset rollback failed after \(original.localizedDescription): \(rollback.localizedDescription)"
    }
}

public struct HRTFRecord: Equatable, Sendable {
    public let azimuth: Int
    public let polar: Int
    public let kind: Int
    public let ear: Int
    public let samples: [Float]

    public init(azimuth: Int, polar: Int, kind: Int = 2, ear: Int, samples: [Float]) {
        self.azimuth = azimuth
        self.polar = polar
        self.kind = kind
        self.ear = ear
        self.samples = samples
    }
}

struct FilterAddress: Hashable {
    let azimuth: Int
    let polar: Int
    let ear: Int
}

private struct FilterDirection: Hashable {
    let azimuth: Int
    let polar: Int
}

struct FilterBinary {
    let bytes: [UInt8]

    init(_ data: Data) { bytes = Array(data) }

    func unsigned16(_ offset: Int) throws -> UInt16 {
        try require(offset, length: 2)
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    func unsigned32(_ offset: Int) throws -> UInt32 {
        try require(offset, length: 4)
        return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
    }

    func unsigned64(_ offset: Int) throws -> UInt64 {
        try require(offset, length: 8)
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[offset + $1]) << ($1 * 8) }
    }

    func require(_ offset: Int, length: Int) throws {
        guard offset >= 0, length >= 0, offset <= bytes.count, length <= bytes.count - offset else {
            throw InzoneError.message("Truncated filter data")
        }
    }

    static func append16(_ value: UInt16, to data: inout Data) {
        for shift in stride(from: 0, to: 16, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    static func append32(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: value >> shift)) }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}

public struct FilterDecoder: Sendable {
    public static let dllSHA256 = "d3fb1a9619335af6f8256029714ac57ba53d643fb4ce9f43d8d50e3a20179860"

    private struct Section: Sendable {
        let address: UInt64
        let size: UInt64
        let offset: UInt64
    }

    private let library: Data
    private let base: UInt64
    private let sections: [Section]

    public init(dll: URL) throws {
        let library = try Data(contentsOf: dll)
        guard FilterBinary.hex(FilterCrypto.sha256(library)) == Self.dllSHA256 else {
            throw InzoneError.message("Unsupported DLL: offsets are pinned to INZONE Hub 1.0.19.0")
        }
        let binary = FilterBinary(library)
        let portableExecutable = Int(try binary.unsigned32(60))
        let optionalHeader = portableExecutable + 24
        self.base = try binary.unsigned64(optionalHeader + 24)
        let sectionOffset = optionalHeader + Int(try binary.unsigned16(portableExecutable + 20))
        let count = Int(try binary.unsigned16(portableExecutable + 6))
        self.sections = try (0..<count).map { index in
            let offset = sectionOffset + index * 40 + 8
            return Section(address: UInt64(try binary.unsigned32(offset + 4)),
                           size: UInt64(try binary.unsigned32(offset + 8)),
                           offset: UInt64(try binary.unsigned32(offset + 12)))
        }
        self.library = library
    }

    func read(rva: UInt64, length: Int) throws -> Data {
        guard length >= 0 else { throw InzoneError.message("Invalid PE address") }
        for section in sections where rva >= section.address {
            let relative = rva - section.address
            guard relative <= section.size, UInt64(length) <= section.size - relative else { continue }
            let offset = section.offset + relative
            guard offset <= UInt64(library.count), UInt64(length) <= UInt64(library.count) - offset else { break }
            return library.subdata(in: Int(offset)..<(Int(offset) + length))
        }
        throw InzoneError.message("Invalid PE address")
    }

    func key(marker: UInt32, table: [UInt32]) throws -> Data {
        guard let index = table.firstIndex(of: marker) else {
            throw InzoneError.message("Unknown filter key marker")
        }
        let seed = table[(index + 7) % table.count] ^ table[(index + 11) % table.count]
        var low = Int(seed & 255)
        var middle = Int((seed >> 8) & 255)
        var high = Int((seed >> 16) & 255)
        var top = Int(seed >> 24)
        var state = marker
        var keyBytes = [UInt8]()
        for iteration in 1...16 {
            let mix = low + 3 * high + 2 * middle + 4 * (top + 1)
            let signed = Int32(bitPattern: state)
            let value = UInt32(truncatingIfNeeded: Int64(signed >> 8) + 10 + Int64(mix * iteration))
            let byte = Int(state & 255)
            (low, middle, high, top) = (byte ^ middle, byte ^ high, byte ^ top, middle)
            state = value
            keyBytes.append(UInt8(truncatingIfNeeded: value))
        }
        return Data(stride(from: 0, to: 16, by: 4).flatMap { Array(keyBytes[$0..<($0 + 4)].reversed()) })
    }

    func decrypt(_ data: Data, offset: Int, table: [UInt32]) throws -> Data {
        guard offset >= 24, data.count > offset, (data.count - offset) % 16 == 0 else {
            throw InzoneError.message("Invalid encrypted body length")
        }
        let binary = FilterBinary(data)
        let initializationVector = Data(binary.bytes[8..<24])
        let key = try key(marker: binary.unsigned32(4), table: table)
        let raw = try FilterCrypto.aes128CBCDecrypt(Data(binary.bytes[offset...]), key: key, iv: initializationVector)
        guard let padding = raw.last, (1...16).contains(Int(padding)),
              raw.suffix(Int(padding)).allSatisfy({ $0 == padding }) else {
            throw InzoneError.message("Invalid padding")
        }
        let plaintext = Data(raw.dropLast(Int(padding)))
        guard FilterCrypto.md5(plaintext) == initializationVector else {
            throw InzoneError.message("Filter checksum mismatch")
        }
        return plaintext
    }

    public func hki(_ data: Data) throws -> [HRTFRecord] {
        let binary = FilterBinary(data)
        guard data.count >= 144, Array(binary.bytes.prefix(4)) == Array("hki2".utf8),
              [5, 7].contains(try binary.unsigned16(76)) else {
            throw InzoneError.message("Unsupported HKI header/cipher")
        }
        let selector = try binary.unsigned16(78)
        guard selector == 1 else { throw InzoneError.message("Unsupported key selector") }
        let count = Int(try FilterBinary(read(rva: 0x1f6ab0 + UInt64(selector) * 4, length: 4)).unsigned32(0))
        let pointer = try FilterBinary(read(rva: 0x1f6ab8 + UInt64(selector) * 8, length: 8)).unsigned64(0)
        guard pointer >= base else { throw InzoneError.message("Invalid PE address") }
        let tableData = try FilterBinary(read(rva: pointer - base, length: count * 4))
        let table = try (0..<count).map { try tableData.unsigned32($0 * 4) }
        var plaintext = try decrypt(data, offset: 144, table: table)
        if binary.bytes[76] == 7 {
            guard plaintext.count % 4 == 0 else { throw InzoneError.message("Invalid HKI inner body length") }
            let checksum = try binary.unsigned32(80)
            var seed = checksum &+ 0x52276af7
            let encoded = FilterBinary(plaintext)
            plaintext = Data()
            plaintext.reserveCapacity(encoded.bytes.count)
            for offset in stride(from: 0, to: encoded.bytes.count, by: 4) {
                let word = try encoded.unsigned32(offset) ^ (seed &+ (seed >> 24))
                FilterBinary.append32(word, to: &plaintext)
                seed = seed &* 0x80849 &+ 0x2a3b5
            }
            guard plaintext.reduce(UInt32(0), { $0 &+ UInt32($1) }) & 255 == checksum & 255 else {
                throw InzoneError.message("HKI inner checksum mismatch")
            }
        }
        let rate = try binary.unsigned32(56)
        let ears = try binary.unsigned32(60)
        let taps = try binary.unsigned32(88)
        let directions = try binary.unsigned32(92)
        guard rate == 48000, ears == 2, taps == 512, (8...1024).contains(directions) else {
            throw InzoneError.message("Unsupported filter dimensions")
        }
        let recordSize = 16 + Int(taps) * 4
        guard plaintext.count == recordSize * Int(ears) * Int(directions) else {
            throw InzoneError.message("Invalid record count")
        }
        let decoded = FilterBinary(plaintext)
        var records = [HRTFRecord]()
        var addresses = Set<FilterAddress>()
        var kinds = [FilterAddress: Int]()
        for offset in stride(from: 0, to: plaintext.count, by: recordSize) {
            let azimuth = Int(try decoded.unsigned32(offset))
            let polar = Int(try decoded.unsigned32(offset + 4))
            let kind = Int(try decoded.unsigned32(offset + 8))
            let ear = Int(try decoded.unsigned32(offset + 12))
            let samples = try (0..<Int(taps)).map { Float(bitPattern: try decoded.unsigned32(offset + 16 + $0 * 4)) }
            let address = FilterAddress(azimuth: azimuth, polar: polar, ear: ear)
            guard (0...1).contains(ear), (1...2).contains(kind), samples.allSatisfy(\.isFinite),
                  addresses.insert(address).inserted else {
                throw InzoneError.message("Invalid or duplicate HRTF record")
            }
            kinds[address] = kind
            records.append(HRTFRecord(azimuth: azimuth, polar: polar, kind: kind, ear: ear, samples: samples))
        }
        let paired = addresses.allSatisfy {
            let counterpart = FilterAddress(azimuth: $0.azimuth, polar: $0.polar, ear: 1 - $0.ear)
            return addresses.contains(counterpart) && kinds[$0] == kinds[counterpart]
        }
        guard paired, Set(addresses.map { FilterAddress(azimuth: $0.azimuth, polar: $0.polar, ear: 0) }).count == Int(directions) else {
            throw InzoneError.message("Unpaired HRTF records")
        }
        return records
    }

    public func ba(_ data: Data) throws -> [[Float]] {
        let binary = FilterBinary(data)
        guard data.count >= 48, Array(binary.bytes.prefix(4)) == Array("ba00".utf8),
              try binary.unsigned32(24) == 48000, try binary.unsigned32(28) == 7,
              try binary.unsigned32(32) == 1 else {
            throw InzoneError.message("Unsupported BA header")
        }
        let tableData = try FilterBinary(read(rva: 0x1f7d80, length: 80))
        let table = try (0..<20).map { try tableData.unsigned32($0 * 4) }
        let plaintext = try decrypt(data, offset: 48, table: table)
        guard plaintext.count == 140 else { throw InzoneError.message("Invalid BA coefficient count") }
        let decoded = FilterBinary(plaintext)
        let coefficients = try (0..<7).map { row in
            try (0..<5).map { Float(bitPattern: try decoded.unsigned32(row * 20 + $0 * 4)) }
        }
        guard coefficients.joined().allSatisfy({ $0.isFinite && abs($0) <= 64 }) else {
            throw InzoneError.message("Non-finite or out-of-range BA coefficients")
        }
        for row in coefficients {
            let first = Double(row[3])
            let second = Double(row[4])
            let discriminant = first * first - 4 * second
            let stable: Bool
            if discriminant >= 0 {
                let root = sqrt(discriminant)
                stable = abs((-first + root) / 2) < 1 && abs((-first - root) / 2) < 1
            } else {
                stable = hypot(-first / 2, sqrt(-discriminant) / 2) < 1
            }
            guard stable else { throw InzoneError.message("Unstable BA filter") }
        }
        return coefficients
    }
}

public enum FilterBank {
    public static let h9IINormalizationPartitionSize = 512

    public static let channels: [(name: String, azimuth: Int, polar: Int)] = [
        ("FL", 330, 90), ("FR", 30, 90), ("FC", 0, 90), ("LFE", 0, 0),
        ("RL", 210, 90), ("RR", 150, 90), ("SL", 250, 90), ("SR", 110, 90),
    ]

    private struct Complex {
        let real: Double
        let imaginary: Double
    }

    private static func fft(_ values: [Complex]) -> [Complex] {
        let count = values.count
        if count == 1 { return values }
        let even = fft(stride(from: 0, to: count, by: 2).map { values[$0] })
        let odd = fft(stride(from: 1, to: count, by: 2).map { values[$0] })
        let products = (0..<(count / 2)).map { index in
            let angle = -2 * Double.pi * Double(index) / Double(count)
            let real = cos(angle)
            let imaginary = sin(angle)
            return Complex(real: real * odd[index].real - imaginary * odd[index].imaginary,
                           imaginary: real * odd[index].imaginary + imaginary * odd[index].real)
        }
        return (0..<(count / 2)).map { Complex(real: even[$0].real + products[$0].real,
                                               imaginary: even[$0].imaginary + products[$0].imaginary) }
            + (0..<(count / 2)).map { Complex(real: even[$0].real - products[$0].real,
                                              imaginary: even[$0].imaginary - products[$0].imaginary) }
    }

    static func requireH9IIStockBank(_ records: [HRTFRecord]) throws {
        let directions = Set(records.map { FilterDirection(azimuth: $0.azimuth, polar: $0.polar) })
        let addresses = Set(records.map { FilterAddress(azimuth: $0.azimuth, polar: $0.polar, ear: $0.ear) })
        let paired = directions.allSatisfy { direction in
            (0...1).allSatisfy { ear in
                addresses.contains(FilterAddress(azimuth: direction.azimuth, polar: direction.polar, ear: ear))
            }
        }
        guard records.count == 28, directions.count == 14, addresses.count == 28, paired,
              records.allSatisfy({ $0.samples.count == 512 }) else {
            throw InzoneError.message("H9 II filters require exactly 14 directions, 2 ears, and 512 taps")
        }
    }

    static func normalizationGain(peak: Float) -> Float {
        peak > 18 ? 18 / peak : 1
    }

    private static func partitionedPeak(_ records: [HRTFRecord], partitionSize: Int) throws -> Float {
        guard partitionSize > 0, partitionSize <= 512, partitionSize.nonzeroBitCount == 1 else {
            throw InzoneError.message("HRTF partition size must be a power of two from 1 through 512")
        }
        var peakPower: Float = 0
        let transformSize = partitionSize * 2
        let partitionCount = (512 + partitionSize - 1) / partitionSize
        for record in records {
            var binPowers = [Float](repeating: 0, count: partitionSize + 1)
            for partition in 0..<partitionCount {
                let start = partition * partitionSize
                let end = min(start + partitionSize, record.samples.count)
                let values = record.samples[start..<end].map { Complex(real: Double($0), imaginary: 0) }
                    + Array(repeating: Complex(real: 0, imaginary: 0), count: transformSize - (end - start))
                let spectrum = fft(values)
                // The native renderer rounds each spectrum value to Float before accumulating frequency-bin power.
                let direct = Float(spectrum[0].real)
                binPowers[0] += direct * direct
                let nyquist = Float(spectrum[partitionSize].real)
                binPowers[partitionSize] += nyquist * nyquist
                if partitionSize > 1 {
                    for bin in 1..<partitionSize {
                        let real = Float(spectrum[bin].real)
                        let imaginary = Float(spectrum[bin].imaginary)
                        binPowers[bin] += real * real + imaginary * imaginary
                    }
                }
            }
            for power in binPowers { peakPower = max(peakPower, power) }
        }
        let peak = peakPower.squareRoot()
        guard peak.isFinite else { throw InzoneError.message("HRTF magnitude is out of range") }
        return peak
    }

    public static func normalize(
        _ records: [HRTFRecord], partitionSize: Int = 512
    ) throws -> (records: [HRTFRecord], gain: Float) {
        guard !records.isEmpty, records.allSatisfy({ $0.samples.count == 512 && $0.samples.allSatisfy(\.isFinite) }) else {
            throw InzoneError.message("Invalid HRTF samples")
        }
        let peak = try partitionedPeak(records, partitionSize: partitionSize)
        let gain = normalizationGain(peak: peak)
        guard gain != 1 else { return (records, gain) }
        return (records.map {
            HRTFRecord(azimuth: $0.azimuth, polar: $0.polar, kind: $0.kind, ear: $0.ear,
                       samples: $0.samples.map { $0 * gain })
        }, gain)
    }

    public static func floatWAV(left: [Float], right: [Float]) throws -> Data {
        guard left.count == right.count else { throw InzoneError.message("Unmatched ear lengths") }
        guard left.count <= (Int(UInt32.max) - 48) / 8 else { throw InzoneError.message("WAV body is too large") }
        var chunks = Data("fmt ".utf8)
        FilterBinary.append32(16, to: &chunks)
        FilterBinary.append16(3, to: &chunks)
        FilterBinary.append16(2, to: &chunks)
        FilterBinary.append32(48000, to: &chunks)
        FilterBinary.append32(48000 * 8, to: &chunks)
        FilterBinary.append16(8, to: &chunks)
        FilterBinary.append16(32, to: &chunks)
        chunks.append(Data("fact".utf8))
        FilterBinary.append32(4, to: &chunks)
        FilterBinary.append32(UInt32(left.count), to: &chunks)
        chunks.append(Data("data".utf8))
        FilterBinary.append32(UInt32(left.count * 8), to: &chunks)
        for index in left.indices {
            FilterBinary.append32(left[index].bitPattern, to: &chunks)
            FilterBinary.append32(right[index].bitPattern, to: &chunks)
        }
        var result = Data("RIFF".utf8)
        FilterBinary.append32(UInt32(chunks.count + 4), to: &result)
        result.append(Data("WAVE".utf8))
        result.append(chunks)
        return result
    }

    static func directionMetadata(_ records: [HRTFRecord]) -> [[String: Int]] {
        var directions = Set<FilterDirection>()
        var result = [[String: Int]]()
        for record in records {
            let direction = FilterDirection(azimuth: record.azimuth, polar: record.polar)
            guard directions.insert(direction).inserted else { continue }
            result.append(["azimuth": record.azimuth, "polar": record.polar, "kind": record.kind])
        }
        return result
    }

    private static func writeWaves(records: [HRTFRecord], destination: URL) throws {
        let directory = try FilterPath.openDirectory(destination, createMissing: false)
        defer { _ = Glibc.close(directory) }
        var indexed = [FilterAddress: [Float]]()
        for record in records {
            indexed[FilterAddress(azimuth: record.azimuth, polar: record.polar, ear: record.ear)] = record.samples
        }
        var bankIndex = Data("IZFB".utf8)
        FilterBinary.append32(1, to: &bankIndex)
        for channel in channels {
            guard let left = indexed[FilterAddress(azimuth: channel.azimuth, polar: channel.polar, ear: 0)],
                  let right = indexed[FilterAddress(azimuth: channel.azimuth, polar: channel.polar, ear: 1)] else {
                throw InzoneError.message("Personalized HKI is missing required 7.1 directions")
            }
            let wave = try floatWAV(left: left, right: right)
            try AtomicFile.write(
                wave, inDirectoryDescriptor: directory,
                name: channel.name + ".wav", permissions: 0o644
            )
            bankIndex.append(FilterCrypto.sha256(wave))
        }
        try AtomicFile.write(
            bankIndex, inDirectoryDescriptor: directory, name: "fir-bank.bin", permissions: 0o644
        )
    }

    static func writeAssets(records: [HRTFRecord], coefficients: [[Float]], destination: URL) throws {
        try writeWaves(records: records, destination: destination)
        let json = try JSONSupport.encode(coefficients.map { $0.map(Double.init) }) + "\n"
        let directory = try FilterPath.openDirectory(destination, createMissing: false)
        defer { _ = Glibc.close(directory) }
        try AtomicFile.write(
            Data(json.utf8), inDirectoryDescriptor: directory,
            name: "h9-ii-biquads.json", permissions: 0o644
        )
    }

    public static func export(payload: URL, destination: URL) throws {
        let decoder = try FilterDecoder(dll: payload.appendingPathComponent("inzonevirtualizer.dll"))
        let hki = try Data(contentsOf: payload.appendingPathComponent("shp_for_game_v2.0_512tap.hki"))
        let downmixHKI = try Data(contentsOf: payload.appendingPathComponent("downmix.hki"))
        let ba = try Data(contentsOf: payload.appendingPathComponent("wh_g910n_standard.ba"))
        let stockRecords = try decoder.hki(hki)
        let downmixRecords = try decoder.hki(downmixHKI)
        try requireH9IIStockBank(stockRecords)
        try requireH9IIStockBank(downmixRecords)
        let normalized = try normalize(stockRecords, partitionSize: h9IINormalizationPartitionSize)
        let coefficients = try decoder.ba(ba)
        try FilterPath.ensureDirectory(destination)
        try writeAssets(records: normalized.records, coefficients: coefficients, destination: destination)
        let downmixDestination = destination.appendingPathComponent("downmix", isDirectory: true)
        try FilterPath.ensureDirectory(downmixDestination)
        try writeWaves(records: downmixRecords, destination: downmixDestination)
        let manifest: [String: Any] = [
            "hrtf_normalization_gain": Double(normalized.gain),
            "hrtf_normalization_partition_size": h9IINormalizationPartitionSize,
            "dll_sha256": FilterDecoder.dllSHA256,
            "rate": 48000, "taps": 512,
            "channels": Dictionary(uniqueKeysWithValues: channels.map { ($0.name, [$0.azimuth, $0.polar]) }),
            "directions": directionMetadata(normalized.records),
            "downmix_channels": Dictionary(uniqueKeysWithValues: channels.map { ($0.name, [$0.azimuth, $0.polar]) }),
            "downmix_directions": directionMetadata(downmixRecords),
            "assets": ["shp_for_game_v2.0_512tap.hki": FilterBinary.hex(FilterCrypto.sha256(hki)),
                       "downmix.hki": FilterBinary.hex(FilterCrypto.sha256(downmixHKI)),
                       "wh_g910n_standard.ba": FilterBinary.hex(FilterCrypto.sha256(ba))],
            "limitations": ["Personalized filters require local HKI/BA files supplied by the user."],
        ]
        let directory = try FilterPath.openDirectory(destination, createMissing: false)
        defer { _ = Glibc.close(directory) }
        try AtomicFile.write(
            Data((JSONSupport.encode(manifest) + "\n").utf8), inDirectoryDescriptor: directory,
            name: "manifest.json", permissions: 0o644
        )
    }
}

public enum Personalization {
    public static let maximumInputSize = 16 * 1024 * 1024
    private static let renameExchange: UInt32 = 2

    private final class MutationLock {
        private let descriptor: Int32

        init(root: URL) throws {
            let directory = try FilterPath.openDirectory(root, createMissing: false)
            descriptor = Glibc.openat(
                directory, ".personalization.lock",
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600)
            )
            _ = Glibc.close(directory)
            guard descriptor >= 0 else {
                throw InzoneError.message("Open personalization lock failed: \(String(cString: strerror(errno)))")
            }
            var status = stat()
            guard Glibc.fstat(descriptor, &status) == 0,
                  status.st_mode & mode_t(0o170000) == mode_t(0o100000) else {
                _ = Glibc.close(descriptor)
                throw InzoneError.message("Personalization lock is not a regular file")
            }
            guard flock(descriptor, LOCK_EX) == 0 else {
                let reason = String(cString: strerror(errno))
                _ = Glibc.close(descriptor)
                throw InzoneError.message("Lock personalization assets failed: \(reason)")
            }
        }

        deinit {
            _ = flock(descriptor, LOCK_UN)
            _ = Glibc.close(descriptor)
        }
    }

    static func readFile(_ path: URL) throws -> Data {
        let resolved = path.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: resolved.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw InzoneError.message("Select a regular filter file")
        }
        let stream = try FileHandle(forReadingFrom: resolved)
        defer { try? stream.close() }
        var data = Data()
        while data.count <= maximumInputSize {
            guard let chunk = try stream.read(upToCount: min(65536, maximumInputSize + 1 - data.count)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maximumInputSize else { throw InzoneError.message("Filter file size limit exceeded") }
        return data
    }

    private static func atomicRename(
        root: URL, source: String, destination: String, exchange: Bool
    ) throws {
        guard !source.isEmpty, !destination.isEmpty,
              !source.contains("/"), !destination.contains("/") else {
            throw InzoneError.message("Invalid personalization entry name")
        }
        let directory = try FilterPath.openDirectory(root, createMissing: false)
        defer { _ = Glibc.close(directory) }
        let result = source.withCString { sourcePath in
            destination.withCString { destinationPath in
                systemRenameAt2(
                    directory, sourcePath, directory, destinationPath,
                    exchange ? renameExchange : 0
                )
            }
        }
        guard result == 0 else {
            throw InzoneError.message("Atomic personalization switch failed: \(String(cString: strerror(errno)))")
        }
    }

    private static func validateGeneratedEntry(_ entry: String, prefix: String) throws {
        guard entry.hasPrefix(prefix) else {
            throw InzoneError.message("Invalid personalization transaction entry")
        }
        let identifier = String(entry.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: identifier),
              identifier == uuid.uuidString.lowercased() else {
            throw InzoneError.message("Invalid personalization transaction entry")
        }
    }

    private static func retireRollbackEntry(root: URL, entry: String) throws -> String {
        let rollbackPrefix = ".personal-rollback-"
        try validateGeneratedEntry(entry, prefix: rollbackPrefix)
        let retiredEntry = ".personal-retired-" + entry.dropFirst(rollbackPrefix.count)
        try atomicRename(root: root, source: entry, destination: retiredEntry, exchange: false)
        return retiredEntry
    }

    static func retryAssetRollback(
        paths: InzonePaths, error rollbackError: PersonalizationAssetRollbackError
    ) throws {
        try validateGeneratedEntry(
            rollbackError.retiredEntry,
            prefix: rollbackError.exchange ? ".personal-rollback-" : ".personal-retired-"
        )
        let root = paths.shareDirectory
        try FilterPath.requireDirectory(root)
        let mutationLock = try MutationLock(root: root)
        defer { withExtendedLifetime(mutationLock) {} }
        let personal = root.appendingPathComponent("personal", isDirectory: true)
        let retired = root.appendingPathComponent(rollbackError.retiredEntry, isDirectory: true)
        guard try FilterPath.itemType(at: personal) == .typeDirectory else {
            throw InzoneError.message("Personalization rollback source is not a directory")
        }
        if rollbackError.exchange {
            guard try FilterPath.itemType(at: retired) == .typeDirectory else {
                throw InzoneError.message("Retired personalization rollback source is not a directory")
            }
            try atomicRename(
                root: root, source: rollbackError.retiredEntry,
                destination: "personal", exchange: true
            )
            _ = try retireRollbackEntry(root: root, entry: rollbackError.retiredEntry)
        } else {
            guard try FilterPath.itemType(at: retired) == nil else {
                throw InzoneError.message("Retired personalization rollback destination already exists")
            }
            try atomicRename(
                root: root, source: "personal",
                destination: rollbackError.retiredEntry, exchange: false
            )
        }
    }

    private static func validatedRetiredPaths(root: URL) throws -> [URL] {
        let fileManager = FileManager.default
        let retired = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".personal-retired-") }
        for path in retired {
            guard try FilterPath.itemType(at: path) == .typeDirectory else {
                throw InzoneError.message("Retired personalization path is not a directory: \(path.lastPathComponent)")
            }
        }
        return retired
    }

    private static func rollbackPaths(root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".personal-rollback-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func cleanupRetiredUnlocked(root: URL) throws -> Int {
        let fileManager = FileManager.default
        let retired = try validatedRetiredPaths(root: root)
        for path in retired { try fileManager.removeItem(at: path) }
        return retired.count
    }

    private static func cleanupRetiredAfterCommit(root: URL) -> [String] {
        let fileManager = FileManager.default
        guard let retired = try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter({ $0.lastPathComponent.hasPrefix(".personal-retired-") }) else {
            return [root.path]
        }
        var pending = [String]()
        for path in retired {
            guard (try? FilterPath.itemType(at: path)) == .typeDirectory else {
                pending.append(path.path)
                continue
            }
            do { try fileManager.removeItem(at: path) }
            catch { pending.append(path.path) }
        }
        return pending.sorted()
    }

    /// Removes immutable retired banks after the controller has confirmed that no FIR loader still uses them.
    @discardableResult
    static func cleanupRetired(paths: InzonePaths) throws -> Int {
        let root = paths.shareDirectory
        guard try FilterPath.itemType(at: root) != nil else { return 0 }
        try FilterPath.requireDirectory(root)
        let mutationLock = try MutationLock(root: root)
        defer { withExtendedLifetime(mutationLock) {} }
        return try cleanupRetiredUnlocked(root: root)
    }

    static func cleanupState(paths: InzonePaths) throws -> [String] {
        let root = paths.shareDirectory
        guard try FilterPath.itemType(at: root) != nil else { return [] }
        try FilterPath.requireDirectory(root)
        let mutationLock = try MutationLock(root: root)
        defer { withExtendedLifetime(mutationLock) {} }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix(".personal-retired-")
                    || $0.lastPathComponent.hasPrefix(".personal-rollback-")
            }
            .map(\.path)
            .sorted()
    }

    /// This controller-gated operation runs only after profiles have switched away from the personal FIR bank.
    static func resetOutcome(paths: InzonePaths) throws -> PersonalizationResetOutcome {
        let root = paths.shareDirectory
        guard let rootType = try FilterPath.itemType(at: root) else {
            return PersonalizationResetOutcome(removed: false, cleanupPending: [])
        }
        guard rootType == .typeDirectory else {
            throw InzoneError.message("Personalization parent path is not a directory")
        }
        try FilterPath.requireDirectory(root)
        let mutationLock = try MutationLock(root: root)
        defer { withExtendedLifetime(mutationLock) {} }
        _ = try cleanupRetiredUnlocked(root: root)
        guard try rollbackPaths(root: root).isEmpty else {
            throw InzoneError.message("Personalization asset rollback recovery is required before reset")
        }
        let destination = paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        guard let type = try FilterPath.itemType(at: destination) else {
            return PersonalizationResetOutcome(removed: false, cleanupPending: [])
        }
        guard type == .typeDirectory else {
            throw InzoneError.message("Personalization path is not a directory")
        }
        let retiredName = ".personal-retired-reset-" + UUID().uuidString.lowercased()
        try atomicRename(root: root, source: "personal", destination: retiredName, exchange: false)
        return PersonalizationResetOutcome(
            removed: true, cleanupPending: cleanupRetiredAfterCommit(root: root)
        )
    }

    static func reset(paths: InzonePaths) throws -> Bool {
        try resetOutcome(paths: paths).removed
    }

    @available(*, deprecated, message: "Use ProfileController.importPersonalizationResult(hki:ba:) for replacement and cleanup status.")
    public static func importFiles(paths: InzonePaths, hki: URL, ba: URL) throws -> URL {
        return try importFilesOutcome(
            paths: paths, hki: hki, ba: ba,
            allowReplacing: false, cleanupRetiredAfterActivation: false, activate: {}
        ).destination
    }

    /// The activation closure must return only after the previous FIR bank has been unloaded.
    static func importFiles(
        paths: InzonePaths, hki: URL, ba: URL,
        allowReplacing: Bool = false,
        cleanupRetiredAfterActivation: Bool = true, activate: () throws -> Void
    ) throws -> URL {
        try importFilesOutcome(
            paths: paths, hki: hki, ba: ba,
            allowReplacing: allowReplacing,
            cleanupRetiredAfterActivation: cleanupRetiredAfterActivation, activate: activate
        ).destination
    }

    /// The activation closure must return only after the previous FIR bank has been unloaded.
    static func importFilesOutcome(
        paths: InzonePaths, hki: URL, ba: URL,
        allowReplacing: Bool = false,
        cleanupRetiredAfterActivation: Bool = true, activate: () throws -> Void
    ) throws -> PersonalizationImportOutcome {
        let fileManager = FileManager.default
        let root = paths.shareDirectory
        try FilterPath.ensureDirectory(root)
        let mutationLock = try MutationLock(root: root)
        defer { withExtendedLifetime(mutationLock) {} }
        let destination = root.appendingPathComponent("personal", isDirectory: true)
        let existingType = try FilterPath.itemType(at: destination)
        guard existingType == nil || existingType == .typeDirectory else {
            throw InzoneError.message("Personalization path is not a directory")
        }
        guard existingType == nil || allowReplacing else {
            throw InzoneError.message("Personalization replacement requires explicit confirmation")
        }
        if cleanupRetiredAfterActivation {
            _ = try cleanupRetiredUnlocked(root: root)
        } else {
            guard try validatedRetiredPaths(root: root).isEmpty else {
                throw InzoneError.message("Retired personalization cleanup is required before initial import")
            }
        }
        guard try rollbackPaths(root: root).isEmpty else {
            throw InzoneError.message("Personalization asset rollback recovery is required before another import")
        }
        try FilterPath.requireDirectory(root.appendingPathComponent("decoder", isDirectory: true))
        var raw = try readFile(hki)
        let model = try readFile(ba)
        if !raw.starts(with: Data("hki2".utf8)), raw.count >= 56,
           raw.subdata(in: 52..<56) == Data("hki2".utf8) {
            raw = Data(raw.dropFirst(52))
        }
        let decoder = try FilterDecoder(dll: root.appendingPathComponent("decoder/inzonevirtualizer.dll"))
        let records = try decoder.hki(raw)
        let normalized = try FilterBank.normalize(records, partitionSize: FilterBank.h9IINormalizationPartitionSize)
        let coefficients = try decoder.ba(model)
        let addresses = Set(normalized.records.map { FilterAddress(azimuth: $0.azimuth, polar: $0.polar, ear: $0.ear) })
        guard FilterBank.channels.allSatisfy({ channel in
            (0...1).allSatisfy { addresses.contains(FilterAddress(azimuth: channel.azimuth, polar: channel.polar, ear: $0)) }
        }) else { throw InzoneError.message("Personalized HKI is missing required 7.1 directions") }
        let transactionIdentifier = UUID().uuidString.lowercased()
        let stageName = (existingType == .typeDirectory ? ".personal-rollback-" : ".personal-retired-")
            + transactionIdentifier
        let stage = root.appendingPathComponent(stageName, isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var removeStage = true
        defer { if removeStage, fileManager.fileExists(atPath: stage.path) { try? fileManager.removeItem(at: stage) } }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        try FilterBank.writeAssets(records: normalized.records, coefficients: coefficients, destination: stage)
        try raw.write(to: stage.appendingPathComponent("personalized_hrtf.hki"))
        try model.write(to: stage.appendingPathComponent("YY2987.ba"))
        let manifest: [String: Any] = [
            "kind": "personal", "hrtf_normalization_gain": Double(normalized.gain),
            "hrtf_normalization_partition_size": FilterBank.h9IINormalizationPartitionSize,
            "rate": 48000, "taps": 512, "model": "YY2987",
            "channels": Dictionary(uniqueKeysWithValues: FilterBank.channels.map { ($0.name, [$0.azimuth, $0.polar]) }),
            "directions": FilterBank.directionMetadata(normalized.records),
            "hki_sha256": FilterBinary.hex(FilterCrypto.sha256(raw)),
            "ba_sha256": FilterBinary.hex(FilterCrypto.sha256(model)),
            "imported_at": Int(Date().timeIntervalSince1970),
        ]
        try Data((JSONSupport.encode(manifest) + "\n").utf8).write(to: stage.appendingPathComponent("manifest.json"))
        for file in try fileManager.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        if existingType == .typeDirectory {
            try atomicRename(root: root, source: stageName, destination: "personal", exchange: true)
            do {
                guard try FilterPath.itemType(at: stage) == .typeDirectory,
                      try FilterPath.itemType(at: destination) == .typeDirectory else {
                    throw InzoneError.message("Personalization path changed during installation")
                }
            } catch {
                let validationError = error
                do { try atomicRename(root: root, source: stageName, destination: "personal", exchange: true) }
                catch {
                    throw PersonalizationAssetRollbackError(
                        original: validationError, rollback: error,
                        retiredEntry: stageName, exchange: true
                    )
                }
                _ = try retireRollbackEntry(root: root, entry: stageName)
                throw validationError
            }
            // Retired banks keep their directory entries valid for FIR loaders that opened them before the exchange.
            removeStage = false
            do {
                try activate()
            } catch {
                let activationError = error
                do { try atomicRename(root: root, source: stageName, destination: "personal", exchange: true) }
                catch {
                    throw PersonalizationAssetRollbackError(
                        original: activationError, rollback: error,
                        retiredEntry: stageName, exchange: true
                    )
                }
                _ = try retireRollbackEntry(root: root, entry: stageName)
                throw activationError
            }
            do { _ = try retireRollbackEntry(root: root, entry: stageName) }
            catch {
                return PersonalizationImportOutcome(destination: destination, cleanupPending: [stage.path])
            }
            let cleanupPending = cleanupRetiredAfterActivation ? cleanupRetiredAfterCommit(root: root) : []
            return PersonalizationImportOutcome(destination: destination, cleanupPending: cleanupPending)
        } else {
            try atomicRename(root: root, source: stageName, destination: "personal", exchange: false)
            removeStage = false
            do {
                try activate()
            } catch {
                let activationError = error
                do { try atomicRename(root: root, source: "personal", destination: stageName, exchange: false) }
                catch {
                    throw PersonalizationAssetRollbackError(
                        original: activationError, rollback: error,
                        retiredEntry: stageName, exchange: false
                    )
                }
                throw activationError
            }
            let cleanupPending = cleanupRetiredAfterActivation ? cleanupRetiredAfterCommit(root: root) : []
            return PersonalizationImportOutcome(destination: destination, cleanupPending: cleanupPending)
        }
    }
}
