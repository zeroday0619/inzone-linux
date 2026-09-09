import Foundation

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
            records.append(HRTFRecord(azimuth: azimuth, polar: polar, kind: kind, ear: ear, samples: samples))
        }
        let paired = addresses.allSatisfy {
            addresses.contains(FilterAddress(azimuth: $0.azimuth, polar: $0.polar, ear: 1 - $0.ear))
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

    public static func normalize(_ records: [HRTFRecord]) throws -> (records: [HRTFRecord], gain: Float) {
        guard !records.isEmpty, records.allSatisfy({ $0.samples.count == 512 && $0.samples.allSatisfy(\.isFinite) }) else {
            throw InzoneError.message("Invalid HRTF samples")
        }
        var peak = 0.0
        for record in records {
            let values = record.samples.map { Complex(real: Double($0), imaginary: 0) }
                + Array(repeating: Complex(real: 0, imaginary: 0), count: 512)
            for value in fft(values) { peak = max(peak, hypot(value.real, value.imaginary)) }
        }
        guard peak.isFinite, peak <= 3.4e38 else { throw InzoneError.message("HRTF magnitude is out of range") }
        // The reference rounds the peak and gain to float while retaining double FFT arithmetic.
        let gain: Float = peak > 18 ? Float(18 / Double(Float(peak))) : 1
        guard gain != 1 else { return (records, gain) }
        return (records.map {
            HRTFRecord(azimuth: $0.azimuth, polar: $0.polar, kind: $0.kind, ear: $0.ear,
                       samples: $0.samples.map { Float(Double($0) * Double(gain)) })
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

    static func writeAssets(records: [HRTFRecord], coefficients: [[Float]], destination: URL) throws {
        var indexed = [FilterAddress: [Float]]()
        for record in records {
            indexed[FilterAddress(azimuth: record.azimuth, polar: record.polar, ear: record.ear)] = record.samples
        }
        for channel in channels {
            guard let left = indexed[FilterAddress(azimuth: channel.azimuth, polar: channel.polar, ear: 0)],
                  let right = indexed[FilterAddress(azimuth: channel.azimuth, polar: channel.polar, ear: 1)] else {
                throw InzoneError.message("Personalized HKI is missing required 7.1 directions")
            }
            try AtomicFile.write(
                floatWAV(left: left, right: right),
                to: destination.appendingPathComponent(channel.name + ".wav"), permissions: 0o644
            )
        }
        let json = try JSONSupport.encode(coefficients.map { $0.map(Double.init) }) + "\n"
        try AtomicFile.write(
            Data(json.utf8), to: destination.appendingPathComponent("h9-ii-biquads.json"), permissions: 0o644
        )
    }

    public static func export(payload: URL, destination: URL) throws {
        let decoder = try FilterDecoder(dll: payload.appendingPathComponent("inzonevirtualizer.dll"))
        let hki = try Data(contentsOf: payload.appendingPathComponent("shp_for_game_v2.0_512tap.hki"))
        let ba = try Data(contentsOf: payload.appendingPathComponent("wh_g910n_standard.ba"))
        let normalized = try normalize(decoder.hki(hki))
        let coefficients = try decoder.ba(ba)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try writeAssets(records: normalized.records, coefficients: coefficients, destination: destination)
        let manifest: [String: Any] = [
            "hrtf_normalization_gain": Double(normalized.gain), "dll_sha256": FilterDecoder.dllSHA256,
            "rate": 48000, "taps": 512,
            "channels": Dictionary(uniqueKeysWithValues: channels.map { ($0.name, [$0.azimuth, $0.polar]) }),
            "assets": ["shp_for_game_v2.0_512tap.hki": FilterBinary.hex(FilterCrypto.sha256(hki)),
                       "wh_g910n_standard.ba": FilterBinary.hex(FilterCrypto.sha256(ba))],
            "limitations": ["Personalized filters require local HKI/BA files supplied by the user."],
        ]
        try AtomicFile.write(
            Data((JSONSupport.encode(manifest) + "\n").utf8),
            to: destination.appendingPathComponent("manifest.json"), permissions: 0o644
        )
    }
}

public enum Personalization {
    public static let maximumInputSize = 16 * 1024 * 1024

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

    public static func importFiles(paths: InzonePaths, hki: URL, ba: URL) throws -> URL {
        let fileManager = FileManager.default
        let root = paths.shareDirectory
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        var raw = try readFile(hki)
        let model = try readFile(ba)
        if !raw.starts(with: Data("hki2".utf8)), raw.count >= 56,
           raw.subdata(in: 52..<56) == Data("hki2".utf8) {
            raw = Data(raw.dropFirst(52))
        }
        let decoder = try FilterDecoder(dll: root.appendingPathComponent("decoder/inzonevirtualizer.dll"))
        let normalized = try FilterBank.normalize(decoder.hki(raw))
        let coefficients = try decoder.ba(model)
        let addresses = Set(normalized.records.map { FilterAddress(azimuth: $0.azimuth, polar: $0.polar, ear: $0.ear) })
        guard FilterBank.channels.allSatisfy({ channel in
            (0...1).allSatisfy { addresses.contains(FilterAddress(azimuth: channel.azimuth, polar: channel.polar, ear: $0)) }
        }) else { throw InzoneError.message("Personalized HKI is missing required 7.1 directions") }
        let stage = root.appendingPathComponent(".personal-" + UUID().uuidString.lowercased(), isDirectory: true)
        let destination = root.appendingPathComponent("personal", isDirectory: true)
        try fileManager.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { if fileManager.fileExists(atPath: stage.path) { try? fileManager.removeItem(at: stage) } }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stage.path)
        try FilterBank.writeAssets(records: normalized.records, coefficients: coefficients, destination: stage)
        try raw.write(to: stage.appendingPathComponent("personalized_hrtf.hki"))
        try model.write(to: stage.appendingPathComponent("YY2987.ba"))
        let manifest: [String: Any] = [
            "kind": "personal", "hrtf_normalization_gain": Double(normalized.gain),
            "rate": 48000, "taps": 512, "model": "YY2987",
            "hki_sha256": FilterBinary.hex(FilterCrypto.sha256(raw)),
            "ba_sha256": FilterBinary.hex(FilterCrypto.sha256(model)),
            "imported_at": Int(Date().timeIntervalSince1970),
        ]
        try Data((JSONSupport.encode(manifest) + "\n").utf8).write(to: stage.appendingPathComponent("manifest.json"))
        for file in try fileManager.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        var previous: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let backup = root.appendingPathComponent(".personal-backup-" + UUID().uuidString.lowercased(), isDirectory: true)
            try fileManager.moveItem(at: destination, to: backup)
            previous = backup
        }
        do {
            try fileManager.moveItem(at: stage, to: destination)
        } catch {
            let installationError = error
            if let previous {
                do { try fileManager.moveItem(at: previous, to: destination) }
                catch {
                    throw InzoneError.message("Personalization installation failed: \(installationError). Restore \(previous.path) manually after rollback failed: \(error)")
                }
            }
            throw installationError
        }
        // Previous assets remain in the backup directory for manual recovery.
        return destination
    }
}
