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

public struct SettingsStore: Sendable {
    public static let profiles = ["fps", "music", "voice", "balanced", "surround"]
    public static let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public let paths: InzonePaths

    public init(paths: InzonePaths) { self.paths = paths }

    public func load() throws -> [String: ProfileOptions] {
        let file = paths.configDirectory.appendingPathComponent("profile-settings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try decode(Data(contentsOf: file))
    }

    public func options(_ name: String) throws -> ProfileOptions {
        guard Self.profiles.contains(name) else { throw InzoneError.message("Invalid DSP profile: \(name)") }
        return try load()[name] ?? ProfileOptions()
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
