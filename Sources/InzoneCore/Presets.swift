import CoreFoundation
import Foundation

public struct WindowsSoundProfile {
    public let identifier: String?
    public let name: String
    public let surround: Bool
    public let templateProfile: String?
    public let options: [String: Any]
    public let source: Data

    public init(
        identifier: String? = nil, name: String, surround: Bool,
        templateProfile: String? = nil,
        options: [String: Any], source: Data = Data()
    ) {
        self.identifier = identifier
        self.name = name
        self.surround = surround
        self.templateProfile = templateProfile
        self.options = options
        self.source = source
    }
}

public struct SonyPresets {
    public static let names = [
        "flat", "fps1", "fps2", "fps3", "immersion_flat", "bass_boost", "music_video",
    ]
    public static let labels = [
        "flat": "Flat", "fps1": "FPS 1", "fps2": "FPS 2", "fps3": "FPS 3",
        "immersion_flat": "RPG / Adventure", "bass_boost": "Bass Boost",
        "music_video": "Music / Video",
    ]

    private static let fields = [
        "31_5Hz", "63Hz", "125Hz", "250Hz", "500Hz", "1kHz", "2kHz", "4kHz", "8kHz", "16kHz",
    ]
    private static let presetEnums = [
        "CUSTOM", "FLAT", "BASS_BOOST", "MUSIC_VIDEO", "FPS1", "FPS2", "FPS3", "IMMERSION_FLAT",
    ]
    private static let compressionEnums = ["OFF", "LOW", "HIGH"]
    public static let maximumWindowsCollectionSize = 16 * 1024 * 1024
    private static let templateProfileField = "x-inzone-linux-template-profile"
    private static let recognizedFields = [
        "ProfileID", "ProfileName", "EQPreset", "EQAxis", "Surround",
        "DynamicRangeCompression", templateProfileField,
    ] + fields.map { "EQGain_" + $0 }
    private let paths: InzonePaths

    public init(paths: InzonePaths) {
        self.paths = paths
    }

    public func preset(_ name: String) throws -> [String: Any] {
        guard Self.names.contains(name) else {
            throw InzoneError.message("Preset must be one of: " + Self.names.joined(separator: ", "))
        }
        let data = try Data(contentsOf: paths.assetsDirectory.appendingPathComponent("sony-presets.json"))
        guard let bank = try JSONSupport.decode(data) as? [String: Any],
              let presets = bank["presets"] as? [String: Any],
              let options = presets[name] as? [String: Any]
        else {
            throw InzoneError.message("The Sony preset bank does not contain a valid \(name) preset.")
        }
        _ = try SettingsStore(paths: paths).updated(ProfileOptions(), with: options)
        return options
    }

    public func readWindows(_ path: URL) throws -> [WindowsSoundProfile] {
        let file = path.resolvingSymlinksInPath()
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.uint64Value <= UInt64(Self.maximumWindowsCollectionSize)
        else {
            throw InzoneError.message("A regular Windows JSON file no larger than 16 MiB is required.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumWindowsCollectionSize {
            let chunk = try handle.read(
                upToCount: Self.maximumWindowsCollectionSize + 1 - data.count
            ) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumWindowsCollectionSize else {
            throw InzoneError.message("The Windows JSON file exceeds 16 MiB.")
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw InzoneError.message("The Windows JSON file must use UTF-8 encoding.")
        }
        let json = try Self.removingJSONComments(from: data)
        try Self.validateRecognizedFieldKeys(in: json)
        guard let items = try JSONSupport.decode(json) as? [Any],
              items.count <= 256
        else {
            throw InzoneError.message("A Windows profile array containing at most 256 entries is required.")
        }

        return try items.map { item in
            guard let fields = item as? [String: Any] else {
                throw InzoneError.message("Invalid Windows profile entry.")
            }
            return try decodeWindowsItem(fields)
        }
    }

    /// Files stripped by INZONE Hub retain the local template only when a unique ProfileID
    /// matches the current installation. Cross-install imports fall back to surround or balanced.
    public func importWindowsCollection(
        _ path: URL, existingRecords: [SoundProfileRecord] = []
    ) throws -> [SoundProfileRecord] {
        _ = try SoundProfileStore.validate(existingRecords)
        let imported = try readWindows(path)
        let validIdentifierCounts = Dictionary(
            grouping: imported.compactMap { profile -> String? in
                guard let identifier = profile.identifier, UUID(uuidString: identifier) != nil else { return nil }
                return identifier.lowercased()
            }, by: { $0 }
        ).mapValues(\.count)
        var identifiers = Set(validIdentifierCounts.compactMap { $0.value == 1 ? $0.key : nil })
        var sourceOccurrences: [Data: UInt64] = [:]
        let existingByIdentifier = Dictionary(uniqueKeysWithValues: existingRecords.map {
            ($0.identifier.lowercased(), $0)
        })
        let settings = SettingsStore(paths: paths)
        return try imported.map { profile in
            let identifier: String
            if let existing = profile.identifier,
               UUID(uuidString: existing) != nil,
               validIdentifierCounts[existing.lowercased()] == 1
            {
                identifier = existing
            } else {
                let occurrence = sourceOccurrences[profile.source, default: 0]
                sourceOccurrences[profile.source] = occurrence + 1
                var collision: UInt64 = 0
                var generated: String
                repeat {
                    generated = Self.deterministicIdentifier(
                        for: profile, occurrence: occurrence, collision: collision
                    )
                    collision += 1
                } while !identifiers.insert(generated).inserted
                identifier = generated
            }
            let matchedTemplate = profile.identifier.flatMap { existingIdentifier -> String? in
                let foldedIdentifier = existingIdentifier.lowercased()
                guard validIdentifierCounts[foldedIdentifier] == 1,
                      let existing = existingByIdentifier[foldedIdentifier],
                      (existing.templateProfile == "surround") == profile.surround else { return nil }
                return existing.templateProfile
            }
            return SoundProfileRecord(
                identifier: identifier, name: profile.name,
                templateProfile: profile.templateProfile ?? matchedTemplate
                    ?? (profile.surround ? "surround" : "balanced"),
                options: try settings.updated(ProfileOptions(), with: profile.options),
                windowsSource: profile.source
            )
        }
    }

    private static func deterministicIdentifier(
        for profile: WindowsSoundProfile, occurrence: UInt64, collision: UInt64
    ) -> String {
        var seed = Data("inzone-linux/windows-sound-profile/v1\0".utf8)
        var encodedOccurrence = occurrence.bigEndian
        var encodedCollision = collision.bigEndian
        withUnsafeBytes(of: &encodedOccurrence) { seed.append(contentsOf: $0) }
        withUnsafeBytes(of: &encodedCollision) { seed.append(contentsOf: $0) }
        seed.append(profile.source)
        var bytes = Array(Digests.sha256Bytes(seed).prefix(16))
        // UUIDv8 marks the SHA-256-derived identifier as an application-defined UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString.lowercased()
    }

    public func exportWindowsCollection(
        _ profiles: [SoundProfileRecord], to path: URL,
        allowOverwrite: Bool = true
    ) throws {
        _ = try SoundProfileStore.validate(profiles)
        let items = try profiles.map { try windowsItem(for: $0) }
        try Self.writeWindowsItems(items, to: path, allowOverwrite: allowOverwrite)
    }

    public func exportWindows(
        profile: String, to path: URL,
        allowOverwrite: Bool = true
    ) throws {
        let resolved = try SettingsStore(paths: paths).resolvedProfile(profile)
        let record = try SoundProfileStore(paths: paths).profile(resolved.identifier) ?? SoundProfileRecord(
            identifier: UUID().uuidString.lowercased(),
            name: resolved.isBuiltIn ? resolved.identifier : resolved.name,
            templateProfile: resolved.templateProfile, options: resolved.options
        )
        let item = try windowsItem(for: record)
        try Self.writeWindowsItems([item], to: path, allowOverwrite: allowOverwrite)
    }

    private static func writeWindowsItems(
        _ items: [[String: Any]], to path: URL,
        allowOverwrite: Bool
    ) throws {
        let text = try JSONSupport.encode(items, pretty: true) + "\n"
        let data = Data(text.utf8)
        guard data.count <= Self.maximumWindowsCollectionSize else {
            throw InzoneError.message("The Windows sound profile collection must be no larger than 16 MiB.")
        }
        try AtomicFile.write(data, to: path, replacing: allowOverwrite)
    }

    private func decodeWindowsItem(_ fields: [String: Any]) throws -> WindowsSoundProfile {
        var values: [String: Any] = [:]
        var recognized = Set<String>()
        for key in fields.keys.sorted() {
            guard let canonical = Self.recognizedField(for: key) else { continue }
            let folded = canonical.lowercased()
            guard recognized.insert(folded).inserted else {
                throw InzoneError.message("Duplicate Windows profile field: \(canonical)")
            }
            values[folded] = fields[key]
        }
        let kind = try Self.enumName(values["eqpreset"] ?? "FLAT", names: Self.presetEnums)
        var options: [String: Any]
        if kind == "CUSTOM" {
            let gains = try Self.fields.map { field in
                try Self.equalizerGain(values[("EQGain_" + field).lowercased()] ?? 0)
            }
            let mode = try Self.enumName(values["eqaxis"] ?? "STANDARD", names: ["STANDARD", "IMMERSIVE"])
            options = [
                "eq": gains, "eq_enable": true, "sound_mode": mode.lowercased(),
                "output_alc": true, "base_eq": false,
            ]
        } else {
            options = try preset(kind.lowercased())
        }
        let compression = try Self.enumName(
            values["dynamicrangecompression"] ?? "OFF", names: Self.compressionEnums
        )
        options["drc"] = Self.compressionEnums.firstIndex(of: compression)!
        guard let surround = Self.strictBoolean(values["surround"] ?? false) else {
            throw InzoneError.message("Surround must be a boolean.")
        }
        let nameValue = values["profilename"] ?? "Windows profile"
        guard let name = nameValue as? String else {
            throw InzoneError.message("The Windows profile name must be a string.")
        }
        try SoundProfileStore.validateName(name)
        let identifier: String?
        if let value = values["profileid"] {
            guard let string = value as? String, string.unicodeScalars.count <= 256 else {
                throw InzoneError.message("The Windows profile identifier must be a string of at most 256 characters.")
            }
            identifier = string
        } else {
            identifier = nil
        }
        let templateProfile: String?
        if let value = values[Self.templateProfileField] {
            guard let template = value as? String,
                  SettingsStore.profiles.contains(template),
                  (template == "surround") == surround else {
                throw InzoneError.message("The INZONE Linux template profile is invalid or conflicts with Surround.")
            }
            templateProfile = template
        } else {
            templateProfile = nil
        }
        let settings = SettingsStore(paths: paths)
        _ = try settings.updated(ProfileOptions(), with: options)
        let source = Data(try JSONSupport.encode(fields, pretty: false).utf8)
        return WindowsSoundProfile(
            identifier: identifier, name: name, surround: surround,
            templateProfile: templateProfile,
            options: options, source: source
        )
    }

    private func windowsItem(for profile: SoundProfileRecord) throws -> [String: Any] {
        let canonical = try canonicalWindowsItem(
            identifier: profile.identifier, name: profile.name,
            templateProfile: profile.templateProfile,
            surround: profile.templateProfile == "surround", options: profile.options
        )
        guard let source = profile.windowsSource,
              try Self.validatingRecognizedFieldKeys(in: source),
              var preserved = try JSONSupport.decode(source) as? [String: Any] else {
            return canonical
        }
        let decoded = try decodeWindowsItem(preserved)
        let original = try SettingsStore(paths: paths).updated(ProfileOptions(), with: decoded.options)
        Self.setCaseInsensitive("ProfileID", value: profile.identifier, in: &preserved)
        Self.setCaseInsensitive("ProfileName", value: profile.name, in: &preserved)
        Self.setCaseInsensitive(
            Self.templateProfileField, value: profile.templateProfile, in: &preserved
        )
        if decoded.surround != (profile.templateProfile == "surround") {
            Self.setCaseInsensitive("Surround", value: canonical["Surround"]!, in: &preserved)
        }
        if original.drc != profile.options.drc {
            Self.setCaseInsensitive(
                "DynamicRangeCompression", value: canonical["DynamicRangeCompression"]!, in: &preserved
            )
        }
        let originalEqualizer = (
            original.equalizer, original.equalizerEnabled, original.soundMode,
            original.outputALC, original.baseEqualizer
        )
        let currentEqualizer = (
            profile.options.equalizer, profile.options.equalizerEnabled, profile.options.soundMode,
            profile.options.outputALC, profile.options.baseEqualizer
        )
        if originalEqualizer != currentEqualizer {
            let equalizerKeys = Set((["EQPreset", "EQAxis"] + Self.fields.map { "EQGain_" + $0 })
                .map { $0.lowercased() })
            preserved = preserved.filter { !equalizerKeys.contains($0.key.lowercased()) }
            for key in ["EQPreset", "EQAxis"] + Self.fields.map({ "EQGain_" + $0 }) {
                preserved[key] = canonical[key]
            }
        }
        return preserved
    }

    private func canonicalWindowsItem(
        identifier: String, name: String, templateProfile: String,
        surround: Bool, options: ProfileOptions
    ) throws -> [String: Any] {
        if options.baseEqualizer && ["fps", "voice"].contains(templateProfile) {
            throw InzoneError.message("The Linux base equalizer cannot be represented in a Windows file. Apply a Sony preset first.")
        }
        if options.microphoneAGC || options.hrtf == "personal" {
            throw InzoneError.message("Windows SoundProfile cannot store microphone AGC or personal HRTF selection.")
        }
        let enabled = options.equalizerEnabled || options.equalizer.contains(where: { $0 != 0 })
        guard options.outputALC == (enabled || options.soundMode == "immersive") else {
            throw InzoneError.message("This ALC and equalizer combination cannot be represented in Windows SoundProfile.")
        }
        let kind = try windowsPreset(for: options) ?? (enabled ? "CUSTOM" : (
            options.soundMode == "immersive" ? "IMMERSION_FLAT" : "FLAT"
        ))
        var item: [String: Any] = [
            "ProfileID": identifier, "ProfileName": name, "EQPreset": kind,
            "EQAxis": options.soundMode.uppercased(), "Surround": surround,
            "DynamicRangeCompression": Self.compressionEnums[options.drc],
            Self.templateProfileField: templateProfile,
        ]
        for (field, gain) in zip(Self.fields, options.equalizer) {
            item["EQGain_" + field] = Int(gain)
        }
        return item
    }

    private func windowsPreset(for options: ProfileOptions) throws -> String? {
        for name in Self.names {
            var candidate = try SettingsStore(paths: paths).updated(ProfileOptions(), with: preset(name))
            candidate.drc = options.drc
            if candidate == options { return name.uppercased() }
        }
        return nil
    }

    private static func setCaseInsensitive(_ key: String, value: Any, in fields: inout [String: Any]) {
        let matches = fields.keys.filter { $0.caseInsensitiveCompare(key) == .orderedSame }
        for existing in matches {
            fields.removeValue(forKey: existing)
        }
        fields[key] = value
    }

    private static func recognizedField(for key: String) -> String? {
        recognizedFields.first { $0.caseInsensitiveCompare(key) == .orderedSame }
    }

    private static func validatingRecognizedFieldKeys(in data: Data) throws -> Bool {
        try validateRecognizedFieldKeys(in: data)
        return true
    }

    static func validateRecognizedFieldKeys(in data: Data) throws {
        let bytes = Array(try removingJSONComments(from: data))
        var stack: [UInt8] = []
        var profileObjectDepth: Int?
        var recognized = Set<String>()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                let start = index
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 0x5C {
                        index += 2
                    } else if bytes[index] == 0x22 {
                        index += 1
                        closed = true
                        break
                    } else {
                        index += 1
                    }
                }
                guard closed else { continue }
                var following = index
                while following < bytes.count,
                      [0x09, 0x0A, 0x0D, 0x20].contains(bytes[following]) {
                    following += 1
                }
                if profileObjectDepth == stack.count,
                   following < bytes.count, bytes[following] == 0x3A,
                   let key = try JSONSupport.decode(Data(bytes[start..<index])) as? String,
                   let canonical = recognizedField(for: key),
                   !recognized.insert(canonical.lowercased()).inserted {
                    throw InzoneError.message("Duplicate Windows profile field: \(canonical)")
                }
                continue
            }
            if byte == 0x5B {
                stack.append(byte)
            } else if byte == 0x7B {
                let startsProfile = profileObjectDepth == nil
                    && (stack.isEmpty || stack == [0x5B])
                stack.append(byte)
                if startsProfile {
                    profileObjectDepth = stack.count
                    recognized.removeAll(keepingCapacity: true)
                }
            } else if byte == 0x7D {
                if profileObjectDepth == stack.count {
                    profileObjectDepth = nil
                    recognized.removeAll(keepingCapacity: true)
                }
                if !stack.isEmpty { stack.removeLast() }
            } else if byte == 0x5D {
                if !stack.isEmpty { stack.removeLast() }
            }
            index += 1
        }
    }

    private static func strictBoolean(_ value: Any) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else { return nil }
        return number.boolValue
    }

    private static func enumName(_ value: Any, names: [String]) throws -> String {
        if let text = value as? String {
            let name = text.uppercased()
            if names.contains(name) { return name }
            if !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
               let index = Int(text), names.indices.contains(index)
            {
                return names[index]
            }
        } else if let number = value as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: number.objCType)),
                  number.int64Value >= 0, number.uint64Value < UInt64(names.count)
        {
            return names[number.intValue]
        }
        throw InzoneError.message("Unknown Windows setting value: \(value)")
    }

    private static func equalizerGain(_ value: Any) throws -> Int {
        if let text = value as? String,
           let gain = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           (-12...12).contains(gain)
        {
            return gain
        }
        if let number = value as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID()
        {
            let gain = number.doubleValue
            if gain.isFinite, (-12...12).contains(gain), gain.rounded(.towardZero) == gain {
                return Int(gain)
            }
        }
        throw InzoneError.message("Each equalizer gain must be an integer from -12 to 12 dB.")
    }

    private static func removingJSONComments(from data: Data) throws -> Data {
        var bytes = Array(data)
        var index = 0
        var inString = false
        while index < bytes.count {
            if inString {
                if bytes[index] == 0x5C { index += 2; continue }
                if bytes[index] == 0x22 { inString = false }
                index += 1
                continue
            }
            if bytes[index] == 0x22 {
                inString = true
                index += 1
            } else if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D {
                    bytes[index] = 0x20
                    index += 1
                }
            } else if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                bytes[index] = 0x20
                bytes[index + 1] = 0x20
                index += 2
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 0x2A, index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                        bytes[index] = 0x20
                        bytes[index + 1] = 0x20
                        index += 2
                        closed = true
                        break
                    }
                    if bytes[index] != 0x0A, bytes[index] != 0x0D { bytes[index] = 0x20 }
                    index += 1
                }
                guard closed else { throw InzoneError.message("Unterminated JSON block comment.") }
            } else {
                index += 1
            }
        }

        // Only structural trailing commas are removed, preserving comment-like text inside strings.
        index = 0
        inString = false
        while index < bytes.count {
            if inString {
                if bytes[index] == 0x5C { index += 2; continue }
                if bytes[index] == 0x22 { inString = false }
            } else if bytes[index] == 0x22 {
                inString = true
            } else if bytes[index] == 0x2C {
                var next = index + 1
                while next < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[next]) { next += 1 }
                if next < bytes.count, [0x7D, 0x5D].contains(bytes[next]) { bytes[index] = 0x20 }
            }
            index += 1
        }
        return Data(bytes)
    }
}
