import Foundation
import InzoneCore

public enum ControlMethod: String, CaseIterable {
    case getState = "GetState"
    case activateProfile = "ActivateProfile"
    case setProfileOptions = "SetProfileOptions"
    case setDeviceField = "SetDeviceField"
    case setHostField = "SetHostField"
    case createProfile = "CreateProfile"
    case renameProfile = "RenameProfile"
    case deleteProfile = "DeleteProfile"
    case applyPreset = "ApplyPreset"
    case bindApplication = "BindApplication"
    case removeApplication = "RemoveApplication"
    case setAutomationEnabled = "SetAutomationEnabled"
}

public enum ControlRequestError: Error, LocalizedError {
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        }
    }
}

public struct ControlRequest {
    public let method: ControlMethod
    public let first: String
    public let second: String
    public let value: Int
    public let options: [String: Any]?

    public init(method: String, first: String = "", second: String = "", value: Int = 0) throws {
        guard let method = ControlMethod(rawValue: method) else {
            throw ControlRequestError.invalid("Unknown control method: \(method)")
        }
        guard first.utf8.count <= 4096, second.utf8.count <= 65536 else {
            throw ControlRequestError.invalid("Control arguments exceed the size limit.")
        }
        var options: [String: Any]?
        switch method {
        case .getState:
            guard first.isEmpty, second.isEmpty, value == 0 else {
                throw ControlRequestError.invalid("GetState does not accept arguments.")
            }
        case .setProfileOptions:
            guard !first.isEmpty else { throw ControlRequestError.invalid("A profile identifier is required.") }
            guard let updates = try? JSONSupport.decode(Data(second.utf8)) as? [String: Any] else {
                throw ControlRequestError.invalid("Profile options must be a JSON object.")
            }
            do { _ = try SettingsStore(paths: InzonePaths()).updated(ProfileOptions(), with: updates) }
            catch { throw ControlRequestError.invalid(error.localizedDescription) }
            options = updates
        case .setDeviceField:
            guard let field = InzoneDevice.fields.first(where: { $0.name == first }),
                  field.values.contains(value) else {
                throw ControlRequestError.invalid("Unknown device field or out-of-range value: \(first)")
            }
        case .setHostField:
            let range = first == "mic_mute" ? 0...1 : 0...100
            guard ["game_volume", "chat_volume", "mic_volume", "mic_mute"].contains(first),
                  range.contains(value) else {
                throw ControlRequestError.invalid("Unknown host audio field or out-of-range value: \(first)")
            }
        case .setAutomationEnabled:
            guard (0...1).contains(value) else {
                throw ControlRequestError.invalid("Automation enabled must be a boolean.")
            }
        case .bindApplication:
            guard !first.isEmpty, !second.isEmpty, (-1000...1000).contains(value) else {
                throw ControlRequestError.invalid("An application, profile, and priority from -1000 to 1000 are required.")
            }
        case .createProfile, .renameProfile, .applyPreset:
            guard !first.isEmpty, !second.isEmpty else {
                throw ControlRequestError.invalid("Two nonempty string arguments are required.")
            }
        case .activateProfile, .deleteProfile, .removeApplication:
            guard !first.isEmpty else { throw ControlRequestError.invalid("A nonempty argument is required.") }
        }
        self.method = method
        self.first = first
        self.second = second
        self.value = value
        self.options = options
    }
}

public protocol ControlBackend: AnyObject {
    func state() throws -> [String: Any]
    func apply(_ request: ControlRequest) throws
}

/// The D-Bus loop serializes requests before they reach the existing core controllers.
public final class ControlDispatcher {
    private let backend: any ControlBackend

    public init(backend: any ControlBackend) { self.backend = backend }

    public func handle(method: String, first: String = "", second: String = "", value: Int = 0) throws -> String {
        let request = try ControlRequest(method: method, first: first, second: second, value: value)
        if request.method != .getState { try backend.apply(request) }
        return try JSONSupport.encode(backend.state(), pretty: false)
    }
}

public final class LiveControlBackend: ControlBackend {
    private let paths: InzonePaths
    private let runner: any CommandRunning
    private let controller: ProfileController
    private let offline: Bool

    public init(paths: InzonePaths = InzonePaths(), runner: any CommandRunning = SystemCommandRunner(), offline: Bool = false) {
        self.paths = paths
        self.runner = runner
        self.controller = ProfileController(paths: paths, runner: runner)
        self.offline = offline
    }

    public func state() throws -> [String: Any] {
        let settings = SettingsStore(paths: paths)
        let profiles = try controller.availableProfiles().map { profile -> [String: Any] in
            ["id": profile.identifier, "name": profile.name, "template": profile.templateProfile,
             "built_in": profile.isBuiltIn, "options": settings.dictionary(profile.options)]
        }
        var activeProfile = ""
        var profileError = ""
        do { activeProfile = try controller.status() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            activeProfile = "original"
        } catch { profileError = error.localizedDescription }
        var state: [String: Any] = [
            "version": 1,
            "active_profile": activeProfile,
            "profile_error": profileError,
            "profiles": profiles,
            "presets": SonyPresets.labels,
            "device": ["connected": false],
            "device_fields": InzoneDevice.fields.map { field -> [String: Any] in
                ["name": field.name, "label": field.label, "values": field.values, "labels": field.labels]
            },
            "host_levels": [String: Int](),
            "device_error": "", "audio_error": "", "automation_error": "",
        ]
        var automation: [String: Any] = ["enabled": false, "rules": [[String: Any]]()]
        do {
            automation["rules"] = try AutomationStore(paths: paths).load().map { rule -> [String: Any] in
                ["app": rule.app, "profile": rule.profile, "priority": rule.priority]
            }
            if !offline {
                let status = try runner.run(
                    ["systemctl", "--user", "show", AutomationStore.unit, "--property=UnitFileState", "--value"],
                    input: nil, timeout: 5
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                automation["enabled"] = ["enabled", "enabled-runtime"].contains(status)
            }
        } catch { state["automation_error"] = error.localizedDescription }
        state["automation"] = automation
        if offline {
            state["device_error"] = "Hardware access is disabled in offline mode."
            state["audio_error"] = "Audio access is disabled in offline mode."
            return state
        }
        do {
            // Releasing the device after each request preserves direct CLI and TUI access.
            let device = try InzoneDevice(home: paths.home)
            defer { device.close() }
            state["device"] = try device.snapshot()
        } catch { state["device_error"] = error.localizedDescription }
        do { state["host_levels"] = try InzoneDevice.hostLevels(runner: runner) }
        catch { state["audio_error"] = error.localizedDescription }
        return state
    }

    public func apply(_ request: ControlRequest) throws {
        let automation = AutomationStore(paths: paths)
        switch request.method {
        case .getState:
            break
        case .createProfile:
            _ = try controller.createProfile(name: request.first, basedOn: request.second)
        case .renameProfile:
            try controller.renameProfile(request.first, to: request.second)
        case .deleteProfile:
            try controller.deleteProfile(request.first)
        case .bindApplication:
            try automation.edit(app: request.first, profile: request.second, priority: request.value)
        case .removeApplication:
            try automation.edit(app: request.first, profile: nil)
        case .activateProfile, .setProfileOptions, .setDeviceField, .setHostField, .applyPreset, .setAutomationEnabled:
            guard !offline else {
                throw InzoneError.message("This operation requires hardware and audio access. Restart the service without --offline.")
            }
            switch request.method {
            case .activateProfile:
                try controller.activate(request.first)
            case .setProfileOptions:
                guard let options = request.options else { throw ControlRequestError.invalid("Profile options are missing.") }
                try controller.changeOptions(request.first, updates: options)
            case .setDeviceField:
                let device = try InzoneDevice(home: paths.home)
                defer { device.close() }
                try device.setField(request.first, value: request.value)
            case .setHostField:
                try InzoneDevice.setHostField(request.first, value: request.value, runner: runner)
            case .applyPreset:
                try controller.changeOptions(request.first, updates: SonyPresets(paths: paths).preset(request.second))
            case .setAutomationEnabled:
                try automation.service(request.value == 1 ? "enable" : "disable", runner: runner)
            default:
                break
            }
        }
    }
}
