import CoreFoundation
import Foundation

public struct ProfileOptions: Codable, Equatable, Sendable {
    public var drc: Int
    public var outputALC: Bool
    public var microphoneAGC: Bool
    public var hrtf: String
    public var equalizer: [Double]
    public var equalizerEnabled: Bool
    public var soundMode: String
    public var baseEqualizer: Bool

    public init(
        drc: Int = 0, outputALC: Bool = false, microphoneAGC: Bool = false,
        hrtf: String = "standard", equalizer: [Double] = Array(repeating: 0, count: 10),
        equalizerEnabled: Bool = false, soundMode: String = "standard", baseEqualizer: Bool = true
    ) {
        self.drc = drc
        self.outputALC = outputALC
        self.microphoneAGC = microphoneAGC
        self.hrtf = hrtf
        self.equalizer = equalizer
        self.equalizerEnabled = equalizerEnabled
        self.soundMode = soundMode
        self.baseEqualizer = baseEqualizer
    }

    enum CodingKeys: String, CodingKey {
        case drc, hrtf
        case outputALC = "output_alc"
        case microphoneAGC = "mic_agc"
        case equalizer = "eq"
        case equalizerEnabled = "eq_enable"
        case soundMode = "sound_mode"
        case baseEqualizer = "base_eq"
    }

    public var hasEqualizer: Bool { equalizerEnabled || equalizer.contains(where: { $0 != 0 }) }
}

public struct SoundProfileRecord: Codable, Equatable, Sendable {
    public let identifier: String
    public var name: String
    public let templateProfile: String
    public var options: ProfileOptions
    public var windowsSource: Data?

    public init(
        identifier: String, name: String, templateProfile: String,
        options: ProfileOptions, windowsSource: Data? = nil
    ) {
        self.identifier = identifier
        self.name = name
        self.templateProfile = templateProfile
        self.options = options
        self.windowsSource = windowsSource
    }
}

public struct ResolvedProfile: Equatable, Sendable {
    public let identifier: String
    public let name: String
    public let templateProfile: String
    public let options: ProfileOptions
    public let isBuiltIn: Bool

    public var isSurround: Bool { templateProfile == "surround" }
    public var isVoice: Bool { templateProfile == "voice" }
}

public struct SoundProfileStore: Sendable {
    public static let maximumProfileCount = 256
    public static let maximumEncodedSize = 24 * 1024 * 1024
    public let paths: InzonePaths
    public var fileURL: URL { paths.configDirectory.appendingPathComponent("sound-profiles.json") }

    public init(paths: InzonePaths) { self.paths = paths }

    public func load() throws -> [SoundProfileRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= UInt64(Self.maximumEncodedSize) else {
            throw InzoneError.message("The sound profile collection must be a regular file no larger than 24 MiB.")
        }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumEncodedSize {
            let chunk = try handle.read(upToCount: Self.maximumEncodedSize + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumEncodedSize else {
            throw InzoneError.message("The sound profile collection must be a regular file no larger than 24 MiB.")
        }
        let records = try JSONDecoder().decode([SoundProfileRecord].self, from: data)
        return try Self.validate(records)
    }

    func save(_ records: [SoundProfileRecord]) throws {
        let lock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("sound-profiles.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(lock) {} }
        try saveUnlocked(records)
    }

    private func saveUnlocked(_ records: [SoundProfileRecord]) throws {
        let records = try Self.validate(records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(records)
        data.append(0x0A)
        guard data.count <= Self.maximumEncodedSize else {
            throw InzoneError.message("The encoded sound profile collection must be no larger than 24 MiB.")
        }
        try AtomicFile.write(data, to: fileURL)
    }

    public func profile(_ identifier: String) throws -> SoundProfileRecord? {
        try load().first { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    @discardableResult
    func create(name: String? = nil, basedOn base: ResolvedProfile) throws -> SoundProfileRecord {
        return try mutate { records in
            guard records.count < Self.maximumProfileCount else {
                throw InzoneError.message("At most 256 custom sound profiles are supported.")
            }
            let selectedName = name ?? Self.nextName(in: records)
            try Self.validateName(selectedName)
            let record = SoundProfileRecord(
                identifier: UUID().uuidString.lowercased(), name: selectedName,
                templateProfile: base.templateProfile, options: base.options
            )
            records.append(record)
            return record
        }
    }

    @discardableResult
    func clone(_ identifier: String, name: String? = nil) throws -> SoundProfileRecord {
        return try mutate { records in
            guard records.count < Self.maximumProfileCount else {
                throw InzoneError.message("At most 256 custom sound profiles are supported.")
            }
            let settings = SettingsStore(paths: paths)
            let source: ResolvedProfile
            let preserved: Data?
            if let record = records.first(where: {
                $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
            }) {
                source = ResolvedProfile(
                    identifier: record.identifier, name: record.name,
                    templateProfile: record.templateProfile, options: record.options,
                    isBuiltIn: false
                )
                preserved = record.windowsSource
            } else {
                guard SettingsStore.profiles.contains(identifier) else {
                    throw InzoneError.message("Invalid DSP profile: \(identifier)")
                }
                source = try settings.resolvedProfile(identifier)
                preserved = nil
            }
            let cloneName = name ?? source.name
            try Self.validateName(cloneName)
            let record = SoundProfileRecord(
                identifier: UUID().uuidString.lowercased(), name: cloneName,
                templateProfile: source.templateProfile, options: source.options,
                windowsSource: preserved
            )
            records.append(record)
            return record
        }
    }

    func rename(_ identifier: String, to name: String) throws {
        try Self.validateName(name)
        try mutate { records in
            guard let index = Self.index(of: identifier, in: records) else {
                throw InzoneError.message("Unknown custom sound profile: \(identifier)")
            }
            records[index].name = name
        }
    }

    func replaceOptions(_ identifier: String, with options: ProfileOptions) throws {
        let validated = try SettingsStore(paths: paths).updated(options, with: [:])
        try mutate { records in
            guard let index = Self.index(of: identifier, in: records) else {
                throw InzoneError.message("Unknown custom sound profile: \(identifier)")
            }
            records[index].options = validated
        }
    }

    func delete(_ identifier: String) throws {
        try mutate { records in
            guard let index = Self.index(of: identifier, in: records) else {
                throw InzoneError.message("Unknown custom sound profile: \(identifier)")
            }
            records.remove(at: index)
        }
    }

    func replace(with records: [SoundProfileRecord]) throws {
        let records = try Self.validate(records)
        let lock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("sound-profiles.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(lock) {} }
        try saveUnlocked(records)
    }

    private func mutate<Result>(_ body: (inout [SoundProfileRecord]) throws -> Result) throws -> Result {
        let lock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("sound-profiles.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(lock) {} }
        var records = try load()
        let result = try body(&records)
        try saveUnlocked(records)
        return result
    }

    public static func validate(_ records: [SoundProfileRecord]) throws -> [SoundProfileRecord] {
        guard records.count <= maximumProfileCount else {
            throw InzoneError.message("At most 256 custom sound profiles are supported.")
        }
        var identifiers = Set<String>()
        let settings = SettingsStore(paths: InzonePaths(home: URL(fileURLWithPath: "/")))
        for record in records {
            guard UUID(uuidString: record.identifier) != nil,
                  identifiers.insert(record.identifier.lowercased()).inserted else {
                throw InzoneError.message("Sound profile identifiers must be unique UUIDs.")
            }
            try validateName(record.name)
            guard SettingsStore.profiles.contains(record.templateProfile) else {
                throw InzoneError.message("Unknown sound profile template: \(record.templateProfile)")
            }
            _ = try settings.updated(record.options, with: [:])
            if let source = record.windowsSource {
                guard source.count <= SonyPresets.maximumWindowsCollectionSize else {
                    throw InzoneError.message("A preserved Windows profile must be a JSON object no larger than 16 MiB.")
                }
                try SonyPresets.validateRecognizedFieldKeys(in: source)
                guard (try JSONSupport.decode(source)) is [String: Any] else {
                    throw InzoneError.message("A preserved Windows profile must be a JSON object no larger than 16 MiB.")
                }
            }
        }
        return records
    }

    static func validateName(_ name: String) throws {
        let unsafeScalar = name.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                true
            default:
                false
            }
        }
        guard (1...256).contains(name.utf16.count), !unsafeScalar else {
            throw InzoneError.message(
                "Sound profile names must contain 1 to 256 UTF-16 code units and no control or format characters."
            )
        }
    }

    private static func index(of identifier: String, in records: [SoundProfileRecord]) -> Int? {
        records.firstIndex { $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame }
    }

    private static func nextName(in records: [SoundProfileRecord]) -> String {
        let names = Set(records.map(\.name))
        if !names.contains("Sound Profile") { return "Sound Profile" }
        var suffix = 2
        while names.contains("Sound Profile \(suffix)") { suffix += 1 }
        return "Sound Profile \(suffix)"
    }
}

public struct SettingsStore: Sendable {
    public static let profiles = ["fps", "music", "voice", "balanced", "surround"]
    public static let profileNames = [
        "fps": "FPS", "music": "Music", "voice": "Voice",
        "balanced": "Balanced", "surround": "Surround",
    ]
    public static let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public let paths: InzonePaths

    public init(paths: InzonePaths) { self.paths = paths }

    public func load() throws -> [String: ProfileOptions] {
        let file = paths.configDirectory.appendingPathComponent("profile-settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try decode(Data(contentsOf: file))
    }

    public func options(_ name: String) throws -> ProfileOptions {
        try resolvedProfile(name).options
    }

    public func profileIfAvailable(_ identifier: String) throws -> ResolvedProfile? {
        if Self.profiles.contains(identifier) {
            return ResolvedProfile(
                identifier: identifier, name: Self.profileNames[identifier] ?? identifier,
                templateProfile: identifier, options: try load()[identifier] ?? ProfileOptions(), isBuiltIn: true
            )
        }
        guard let record = try SoundProfileStore(paths: paths).profile(identifier) else { return nil }
        return ResolvedProfile(
            identifier: record.identifier, name: record.name, templateProfile: record.templateProfile,
            options: record.options, isBuiltIn: false
        )
    }

    public func resolvedProfile(_ identifier: String) throws -> ResolvedProfile {
        guard let profile = try profileIfAvailable(identifier) else {
            throw InzoneError.message("Invalid DSP profile: \(identifier)")
        }
        return profile
    }

    public func availableProfiles() throws -> [ResolvedProfile] {
        let builtIn = try Self.profiles.map { try resolvedProfile($0) }
        let custom = try SoundProfileStore(paths: paths).load().map {
            ResolvedProfile(
                identifier: $0.identifier, name: $0.name, templateProfile: $0.templateProfile,
                options: $0.options, isBuiltIn: false
            )
        }
        return builtIn + custom
    }

    public func save(_ settings: [String: ProfileOptions]) throws {
        let content = try encode(settings) + "\n"
        try AtomicFile.write(Data(content.utf8), to: paths.configDirectory.appendingPathComponent("profile-settings.json"))
    }

    public func decode(_ data: Data) throws -> [String: ProfileOptions] {
        guard let values = try JSONSupport.decode(data) as? [String: Any],
              Set(values.keys).isSubset(of: Set(Self.profiles)) else {
            throw InzoneError.message("Invalid profile settings")
        }
        return try values.mapValues { value in
            guard let updates = value as? [String: Any] else {
                throw InzoneError.message("DSP settings must be an object")
            }
            return try updated(ProfileOptions(), with: updates)
        }
    }

    public func dictionary(_ options: ProfileOptions) -> [String: Any] {
        [
            "drc": options.drc, "output_alc": options.outputALC, "mic_agc": options.microphoneAGC,
            "hrtf": options.hrtf, "eq": options.equalizer, "eq_enable": options.equalizerEnabled,
            "sound_mode": options.soundMode, "base_eq": options.baseEqualizer,
        ]
    }

    public func encode(_ settings: [String: ProfileOptions], pretty: Bool = true) throws -> String {
        guard Set(settings.keys).isSubset(of: Set(Self.profiles)) else {
            throw InzoneError.message("Invalid profile settings")
        }
        let values = try settings.mapValues { try dictionary(updated($0, with: [:])) }
        return try JSONSupport.encode(values, pretty: pretty)
    }

    public func updated(_ options: ProfileOptions, with updates: [String: Any]) throws -> ProfileOptions {
        var value = dictionary(options)
        guard Set(updates.keys).isSubset(of: Set(value.keys)) else {
            throw InzoneError.message("Unknown DSP setting")
        }
        value.merge(updates) { _, replacement in replacement }
        guard let drc = value["drc"] as? NSNumber, !Self.isBoolean(drc),
              !["f", "d"].contains(String(cString: drc.objCType)), (0...2).contains(drc.intValue) else {
            throw InzoneError.message("DRC mode must be an integer from 0 to 2")
        }
        func boolean(_ key: String) throws -> Bool {
            guard let number = value[key] as? NSNumber, Self.isBoolean(number) else {
                throw InzoneError.message("\(key) must be a boolean")
            }
            return number.boolValue
        }
        guard let hrtf = value["hrtf"] as? String, ["standard", "personal"].contains(hrtf) else {
            throw InzoneError.message("HRTF must be standard or personal")
        }
        guard let mode = value["sound_mode"] as? String, ["standard", "immersive"].contains(mode) else {
            throw InzoneError.message("Sound mode must be standard or immersive")
        }
        guard let bands = value["eq"] as? [Any], bands.count == 10 else {
            throw InzoneError.message("EQ requires 10 bands from -12 to +12 dB in 1 dB steps")
        }
        let equalizer = try bands.map { band -> Double in
            guard let number = band as? NSNumber, !Self.isBoolean(number) else {
                throw InzoneError.message("EQ gains must be numbers")
            }
            let gain = number.doubleValue
            guard gain.isFinite, (-12...12).contains(gain), gain.rounded() == gain else {
                throw InzoneError.message("EQ requires 10 bands from -12 to +12 dB in 1 dB steps")
            }
            return gain
        }
        return try ProfileOptions(
            drc: drc.intValue, outputALC: boolean("output_alc"), microphoneAGC: boolean("mic_agc"),
            hrtf: hrtf, equalizer: equalizer, equalizerEnabled: boolean("eq_enable"),
            soundMode: mode, baseEqualizer: boolean("base_eq")
        )
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
