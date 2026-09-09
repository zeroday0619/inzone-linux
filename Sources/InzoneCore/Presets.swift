import CoreFoundation
import Foundation

public struct WindowsSoundProfile {
    public let name: String
    public let surround: Bool
    public let options: [String: Any]

    public init(name: String, surround: Bool, options: [String: Any]) {
        self.name = name
        self.surround = surround
        self.options = options
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
    private static let maximumImportSize = 1024 * 1024
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
              size.uint64Value <= UInt64(Self.maximumImportSize)
        else {
            throw InzoneError.message("A regular Windows JSON file no larger than 1 MiB is required.")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= Self.maximumImportSize {
            let chunk = try handle.read(upToCount: Self.maximumImportSize + 1 - data.count) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= Self.maximumImportSize else {
            throw InzoneError.message("The Windows JSON file exceeds 1 MiB.")
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            data.removeFirst(3)
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw InzoneError.message("The Windows JSON file must use UTF-8 encoding.")
        }
        guard let items = try JSONSupport.decode(Self.removingJSONComments(from: data)) as? [Any],
              (1...256).contains(items.count)
        else {
            throw InzoneError.message("A Windows profile array containing 1 to 256 entries is required.")
        }

        let settings = SettingsStore(paths: paths)
        return try items.map { item in
            guard let fields = item as? [String: Any] else {
                throw InzoneError.message("Invalid Windows profile entry.")
            }
            var values: [String: Any] = [:]
            for (key, value) in fields { values[key.lowercased()] = value }
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
            let surroundValue = values["surround"] ?? false
            guard let surround = Self.strictBoolean(surroundValue) else {
                throw InzoneError.message("Surround must be a boolean.")
            }
            let nameValue = values["profilename"] ?? "Windows profile"
            guard let name = nameValue as? String,
                  name.unicodeScalars.count <= 256
            else {
                throw InzoneError.message("The Windows profile name must be a string of at most 256 characters.")
            }
            _ = try settings.updated(ProfileOptions(), with: options)
            return WindowsSoundProfile(name: name, surround: surround, options: options)
        }
    }

    public func exportWindows(profile: String, to path: URL) throws {
        guard SettingsStore.profiles.contains(profile) else {
            throw InzoneError.message("Select a DSP profile before exporting.")
        }
        let options = try SettingsStore(paths: paths).options(profile)
        if options.baseEqualizer && ["fps", "voice"].contains(profile) {
            throw InzoneError.message("The Linux base equalizer cannot be represented in a Windows file. Apply a Sony preset first.")
        }
        if options.microphoneAGC || options.hrtf == "personal" {
            throw InzoneError.message("Windows SoundProfile cannot store microphone AGC or personal HRTF selection.")
        }
        let enabled = options.equalizerEnabled || options.equalizer.contains(where: { $0 != 0 })
        guard options.outputALC == (enabled || options.soundMode == "immersive") else {
            throw InzoneError.message("This ALC and equalizer combination cannot be represented in Windows SoundProfile.")
        }
        let kind = enabled ? "CUSTOM" : (options.soundMode == "immersive" ? "IMMERSION_FLAT" : "FLAT")
        var item: [String: Any] = [
            "ProfileID": UUID().uuidString.lowercased(), "ProfileName": profile,
            "EQPreset": kind, "EQAxis": options.soundMode.uppercased(),
            "Surround": profile == "surround", "DynamicRangeCompression": Self.compressionEnums[options.drc],
        ]
        for (field, gain) in zip(Self.fields, options.equalizer) {
            item["EQGain_" + field] = Int(gain)
        }
        let text = try JSONSupport.encode([item], pretty: true) + "\n"
        try Data(text.utf8).write(to: path, options: .atomic)
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
