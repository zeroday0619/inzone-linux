import Foundation
import Observation
import SwiftTUI
import InzoneCore

public enum InzoneTerminal {
    @MainActor
    public static func run(controller: ProfileController) {
        let monitor = MicrophoneMonitor()
        let worker = TerminalWorker(controller: controller, monitor: monitor)
        TerminalApplication.model = TerminalModel(worker: worker)
        defer {
            monitor.stop()
            TerminalApplication.model = nil
        }
        TerminalApplication.main()
    }

    /// Renders the initial screen without device access or a terminal session.
    @MainActor
    public static func preview(columns: Int = 80, rows: Int = 24, touchOptimized: Bool = true) -> String {
        ViewRenderer.render(
            TerminalRoot(model: TerminalModel(worker: nil), touchOptimized: touchOptimized)
                .frame(width: columns, height: rows),
            proposedSize: ProposedViewSize(columns: columns, rows: rows)
        ).text
    }
}

private let builtInProfileDescriptions = [
    "fps": "Less bass. Clearer footsteps.",
    "music": "Original sound. Stability first.",
    "voice": "Clearer voices. Less microphone rumble.",
    "balanced": "Neutral sound without extra EQ.",
    "surround": "Spatial sound with Sony HRTF.",
]
private let restoreDescription = "Restores saved tone and latency. Game/Chat balance stays unchanged."
private let equalizerFrequencies = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]

func terminalText(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        switch scalar.properties.generalCategory {
        case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate:
            return Unicode.Scalar(32)!
        default:
            return scalar
        }
    }))
}

private struct DisplayOptions: Sendable {
    var drc = 0
    var outputALC = false
    var microphoneAGC = false
    var hrtf = "standard"
    var equalizer = Array(repeating: 0.0, count: 10)
    var equalizerEnabled = false
    var soundMode = "standard"
    var baseEqualizer = true

    init() {}
    init(_ options: ProfileOptions) {
        drc = options.drc
        outputALC = options.outputALC
        microphoneAGC = options.microphoneAGC
        hrtf = options.hrtf
        equalizer = options.equalizer
        equalizerEnabled = options.equalizerEnabled
        soundMode = options.soundMode
        baseEqualizer = options.baseEqualizer
    }
}

struct TerminalProfilePreview: Sendable {
    let identifier: String
    let title: String
    let templateProfile: String
    let isBuiltIn: Bool

    init(identifier: String, title: String, templateProfile: String, isBuiltIn: Bool = false) {
        self.identifier = identifier
        self.title = title
        self.templateProfile = templateProfile
        self.isBuiltIn = isBuiltIn
    }
}

private struct TerminalProfileItem: Sendable {
    let identifier: String
    var title: String
    let templateProfile: String
    let isBuiltIn: Bool
    var options: DisplayOptions

    var isRestore: Bool { identifier == "restore" }
    var isSurround: Bool { templateProfile == "surround" }

    init(_ profile: ResolvedProfile) {
        identifier = profile.identifier
        title = profile.name
        templateProfile = profile.templateProfile
        isBuiltIn = profile.isBuiltIn
        options = DisplayOptions(profile.options)
    }

    init(identifier: String, title: String, templateProfile: String, isBuiltIn: Bool, options: ProfileOptions = ProfileOptions()) {
        self.identifier = identifier
        self.title = title
        self.templateProfile = templateProfile
        self.isBuiltIn = isBuiltIn
        self.options = DisplayOptions(options)
    }

    init(_ preview: TerminalProfilePreview) {
        self.init(
            identifier: preview.identifier, title: preview.title,
            templateProfile: preview.templateProfile, isBuiltIn: preview.isBuiltIn
        )
    }

    static let restore = TerminalProfileItem(
        identifier: "restore", title: "Restore Defaults", templateProfile: "restore", isBuiltIn: true
    )
}

private let previewProfiles = [
    TerminalProfileItem(identifier: "fps", title: "FPS", templateProfile: "fps", isBuiltIn: true),
    TerminalProfileItem(identifier: "music", title: "Music", templateProfile: "music", isBuiltIn: true),
    TerminalProfileItem(identifier: "voice", title: "Voice", templateProfile: "voice", isBuiltIn: true),
    TerminalProfileItem(identifier: "balanced", title: "Balanced", templateProfile: "balanced", isBuiltIn: true),
    TerminalProfileItem(identifier: "surround", title: "Surround", templateProfile: "surround", isBuiltIn: true),
    .restore,
]

private struct ProfileScreenState: Sendable {
    var current = "original"
    var profiles = previewProfiles
    var details: [String: [String]] = [:]
    var personalizationInstalled = false
    var personalizationCleanupPending: [String] = []
}

private struct DeviceRow: Sendable {
    var key: String
    var label: String
    var value: Int
    var values: [Int]
    var labels: [String] = []
    var host = false

    func display(_ pending: Int? = nil) -> String {
        let value = pending ?? value
        if let index = values.firstIndex(of: value), index < labels.count { return labels[index] }
        return String(value) + (host && key != "mic_mute" ? "%" : "")
    }
}

private struct DeviceScreenState: Sendable {
    var rows: [DeviceRow] = []
    var status = TerminalDeviceStatus()
    var battery: String { status.batteryLine }
    var firmware: String { status.firmwareLine }
    var message = "Reading device status..."
    var hasIssue = false
    var monitoring = false
}

private struct TerminalDeviceObservation: Sendable {
    let state: DeviceScreenState
    let watermarks: [String: UInt64]
    let notifications: AsyncStream<DeviceNotification>

    func shouldApply(_ notification: DeviceNotification) -> Bool {
        shouldApplyDeviceNotification(
            revision: notification.revision, eventName: notification.eventName, watermarks: watermarks
        )
    }
}

func shouldApplyDeviceNotification(
    revision: UInt64, eventName: String, watermarks: [String: UInt64]
) -> Bool {
    revision > (watermarks[eventName] ?? 0)
}

func personalizationResultMessage(success: String, cleanupPending: [String]) -> String {
    cleanupPending.isEmpty ? success
        : "\(success) Cleanup pending for \(cleanupPending.count) retired bank(s). Use K: Retry cleanup."
}

func soundProfileImportMessage(_ outcome: SoundProfileImportOutcome, mode: SoundProfileImportMode) -> String {
    let action = mode == .append ? "appended" : "replaced"
    let base = "Sound profiles \(action): \(outcome.importedCount)."
    return outcome.skippedCount == 0 ? base
        : base + " Skipped \(outcome.skippedCount) because the 256-profile limit was reached."
}

private struct AutomationDisplayRule: Sendable {
    var app: String
    var profile: String
    var priority: Int
}

private struct AutomationScreenState: Sendable {
    var rules: [AutomationDisplayRule] = []
    var active = false
}

private enum OptionChange: Sendable {
    case drc(Int), outputALC(Bool), microphoneAGC(Bool), hrtf(String), equalizer([Double])
}

private enum TerminalFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

private actor TerminalWorker {
    let controller: ProfileController
    let monitor: MicrophoneMonitor
    var device: InzoneDevice?

    init(controller: ProfileController, monitor: MicrophoneMonitor) {
        self.controller = controller
        self.monitor = monitor
    }

    func profiles() throws -> ProfileScreenState {
        var state = ProfileScreenState()
        state.current = try controller.status()
        state.profiles = try controller.availableProfiles().map(TerminalProfileItem.init) + [.restore]
        for profile in state.profiles where !profile.isRestore {
            state.details[profile.identifier] = configurationDetails(profile.templateProfile)
        }
        state.personalizationInstalled = FileManager.default.fileExists(
            atPath: controller.paths.shareDirectory.appendingPathComponent("personal/manifest.json").path
        )
        state.personalizationCleanupPending = try controller.personalizationCleanupPending()
        return state
    }

    func configurationDetails(_ name: String) -> [String] {
        do {
            let path = controller.paths.configDirectory.appendingPathComponent(name + ".conf")
            let raw = try String(contentsOf: path, encoding: .utf8).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
            let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            let rules = object?["monitor.alsa.rules"] as? [[String: Any]]
            let actions = rules?.first?["actions"] as? [String: Any]
            let properties = actions?["update-props"] as? [String: Any]
            let latency = (properties?["node.latency"] as? String ?? "").split(separator: "/")
            var result = ["Output: 48 kHz / 16 bit · Stereo"]
            if latency.count == 2, let samples = Double(latency[0]), let rate = Double(latency[1]), rate > 0 {
                result.append(String(format: "Latency request: %.0f samples (%.2f ms)", samples, samples / rate * 1000))
            }
            let suspend = properties?["session.suspend-timeout-seconds"] as? Int ?? 5
            result.append(suspend == 0 ? "Output suspend: Disabled" : "Output suspend: \(suspend)s")
            return result
        } catch { return ["Failed to read config file: \(error.localizedDescription)"] }
    }

    func activate(_ name: String) throws { try controller.activate(name) }

    func change(_ name: String, _ change: OptionChange) throws {
        let updates: [String: Any]
        switch change {
        case .drc(let value): updates = ["drc": value]
        case .outputALC(let value): updates = ["output_alc": value]
        case .microphoneAGC(let value): updates = ["mic_agc": value]
        case .hrtf(let value): updates = ["hrtf": value]
        case .equalizer(let value): updates = ["eq": value, "eq_enable": true]
        }
        try controller.changeOptions(name, updates: updates)
    }

    func preset(_ profile: String, name: String) throws {
        try controller.changeOptions(profile, updates: SonyPresets(paths: controller.paths).preset(name))
    }

    func personalize(hki: String, ba: String, allowReplacing: Bool) throws -> [String] {
        let hkiURL = URL(fileURLWithPath: (hki as NSString).expandingTildeInPath)
        let baURL = URL(fileURLWithPath: (ba as NSString).expandingTildeInPath)
        return try controller.importPersonalizationResult(
            hki: hkiURL, ba: baURL, allowReplacing: allowReplacing
        ).cleanupPending
    }

    func createProfile(name: String, basedOn identifier: String) throws -> String {
        try controller.createProfile(
            name: name, basedOn: identifier == "restore" ? "balanced" : identifier
        ).identifier
    }

    func cloneProfile(_ identifier: String, name: String) throws -> String {
        guard identifier != "restore" else { throw TerminalFailure.invalid("Restore Defaults cannot be duplicated.") }
        return try controller.cloneProfile(identifier, name: name).identifier
    }

    func renameProfile(_ identifier: String, name: String) throws {
        try controller.renameProfile(identifier, to: name)
    }

    func deleteProfile(_ identifier: String) throws {
        try controller.deleteProfile(identifier)
    }

    func importProfiles(path: String, mode: SoundProfileImportMode) throws -> SoundProfileImportOutcome {
        try controller.importWindowsCollection(
            URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            mode: mode
        )
    }

    func exportProfiles(path: String, allowOverwrite: Bool) throws {
        let destination = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try controller.exportWindowsCollection(destination, allowOverwrite: allowOverwrite)
    }

    func resetPersonalization() throws -> [String] {
        try controller.resetPersonalizationResult().cleanupPending
    }

    func retryPersonalizationCleanup() throws -> [String] {
        try controller.retryPersonalizationCleanup()
    }

    func automation() throws -> AutomationScreenState {
        let profileTitles = Dictionary(uniqueKeysWithValues: try controller.availableProfiles().map {
            ($0.identifier.lowercased(), $0.name)
        })
        let rules = try AutomationStore(paths: controller.paths).load().map {
            AutomationDisplayRule(
                app: $0.app, profile: profileTitles[$0.profile.lowercased()] ?? $0.profile, priority: $0.priority
            )
        }
        let active = (try? controller.runner.run(["systemctl", "--user", "is-active", "--quiet", "inzone-profile-auto.service"], input: nil, timeout: 5)) != nil
        return AutomationScreenState(rules: rules, active: active)
    }

    func editRule(app: String, profile: String?, priority: Int = 0) throws {
        var identifier = profile
        if let profile {
            let candidates = try controller.availableProfiles().filter {
                $0.identifier.caseInsensitiveCompare(profile) == .orderedSame
                    || $0.name.caseInsensitiveCompare(profile) == .orderedSame
            }
            guard candidates.count == 1 else {
                throw TerminalFailure.invalid(candidates.isEmpty
                    ? "No sound profile matches that name or identifier."
                    : "Multiple sound profiles have that name. Enter the profile identifier.")
            }
            identifier = candidates[0].identifier
        }
        try AutomationStore(paths: controller.paths).edit(app: app, profile: identifier, priority: priority)
    }

    func automationService(enable: Bool) throws {
        try AutomationStore(paths: controller.paths).service(enable ? "enable" : "disable", runner: controller.runner)
    }

    func hostRows() throws -> [DeviceRow] {
        let levels = try InzoneDevice.hostLevels(runner: controller.runner)
        return [("game_volume", "Game output volume"), ("chat_volume", "Chat output volume"),
                ("mic_volume", "Microphone input volume"), ("mic_mute", "Microphone mute")].compactMap { key, label in
            guard let value = levels[key] else { return nil }
            return DeviceRow(key: key, label: label, value: value,
                             values: key == "mic_mute" ? [0, 1] : Array(0...100),
                             labels: key == "mic_mute" ? ["Off", "On"] : [], host: true)
        }
    }

    func setDevice(_ row: DeviceRow, value: Int) throws {
        if row.host {
            try InzoneDevice.setHostField(row.key, value: value, runner: controller.runner)
            guard try hostRows().first(where: { $0.key == row.key })?.value == value else {
                throw TerminalFailure.invalid("Audio server did not apply the requested value.")
            }
        } else {
            guard let device else { throw TerminalFailure.invalid("Refresh device status first.") }
            try device.setField(row.key, value: value)
        }
    }

    func deviceObservation() throws -> TerminalDeviceObservation {
        if device == nil { device = try InzoneDevice(home: controller.paths.home) }
        let observation = try device!.observe()
        let snapshot = observation.snapshot.status
        var result = DeviceScreenState()
        var messages: [String] = []
        result.status = TerminalDeviceStatus(snapshot: snapshot)
        let fields = snapshot["fields"] as? [String: Int] ?? [:]
        result.rows = InzoneDevice.fields.compactMap { field in
            guard let value = fields[field.name] else { return nil }
            return DeviceRow(
                key: field.name, label: field.label, value: value,
                values: field.values, labels: field.labels
            )
        }
        if snapshot["connected"] as? Bool != true { messages.append("Waiting for headset connection...") }
        do { result.rows += try hostRows() } catch { messages.append(error.localizedDescription) }
        result.hasIssue = !messages.isEmpty
        result.message = messages.isEmpty ? "←→: Select value, press Enter to apply." : messages.joined(separator: " · ")
        result.monitoring = monitor.isRunning
        return TerminalDeviceObservation(
            state: result, watermarks: observation.snapshot.watermarks,
            notifications: observation.notifications
        )
    }

    nonisolated func toggleMonitor() async throws -> Bool {
        let monitor = monitor
        return try await Task.detached {
            if monitor.isRunning { monitor.stop() } else { try monitor.start() }
            return monitor.isRunning
        }.value
    }
    nonisolated func monitoring() -> Bool { monitor.isRunning }
    nonisolated func stopMonitor() async {
        let monitor = monitor
        await Task.detached { monitor.stop() }.value
    }
    func closeDevice() { monitor.stop(); device?.close(); device = nil }


}

enum TerminalScreen: Equatable {
    case profiles, profileManager, equalizer, presets, device, automation, automationProfilePicker, prompt
}
private struct TerminalTaskIdentity: Equatable {
    let screen: TerminalScreen
    let revision: Int
}
private enum PromptPurpose {
    case hki, ba(String), confirmPersonalization(String, String)
    case ruleApp, rulePriority(String, String)
    case createProfile(String), cloneProfile(String), renameProfile(String)
    case deleteProfile(String, String), importProfiles, replaceProfiles, confirmImportProfiles(String)
    case exportProfiles, confirmExportProfiles(String), resetPersonalization, deleteAutomationRule(String)
}

@MainActor
@Observable
final class TerminalModel {
    private let worker: TerminalWorker?
    var screen = TerminalScreen.profiles
    var showsProfileControls = false
    var showsSystemControls = false
    var selected = 0
    var message = "Ready"
    var busy = false
    var equalizer = Array(repeating: 0.0, count: 10)
    var equalizerIndex = 0
    var presetIndex = 0
    var deviceIndex = 0
    var deviceSection = TerminalDeviceSection.noise
    private var pendingDeviceValues: [String: Int] = [:]
    var devicePending: Int? { pendingDeviceValue(at: deviceIndex) }
    var pendingDeviceCount: Int { pendingDeviceValues.count }
    var canApplyDeviceChanges: Bool {
        !pendingDeviceValues.isEmpty && pendingDeviceValues.allSatisfy { key, value in
            deviceRows.contains { $0.key == key && $0.values.contains(value) }
        }
    }
    var automationIndex = 0
    var promptText = ""
    var promptTitle = ""
    var promptActionTitle: String {
        switch promptPurpose {
        case .ba(_), .rulePriority(_, _), .createProfile(_), .cloneProfile(_), .renameProfile(_): "Save"
        case .deleteProfile(_, _), .confirmImportProfiles(_), .confirmPersonalization(_, _),
             .confirmExportProfiles(_), .resetPersonalization, .deleteAutomationRule(_): "Confirm"
        case .importProfiles: "Import"
        case .replaceProfiles: "Continue"
        case .exportProfiles: "Export"
        default: "Continue"
        }
    }
    private var promptPurpose = PromptPurpose.hki
    private var promptReturn = TerminalScreen.profiles
    private var profileState = ProfileScreenState()
    private var deviceState = DeviceScreenState()
    private var automationState = AutomationScreenState()
    private var pendingRuleApp = ""
    private var initialSelection = true
    private var deviceObservationRevision = 0
    private var idleTermination: (@MainActor () -> Void)?

    fileprivate init(worker: TerminalWorker?) { self.worker = worker }
    init() { worker = nil }
    init(previewProfiles profiles: [TerminalProfilePreview]) {
        worker = nil
        profileState.profiles = profiles.map(TerminalProfileItem.init) + [.restore]
    }
    init(previewDeviceSnapshot snapshot: [String: Any], hostLevels: [String: Int] = [:]) {
        worker = nil
        screen = .device
        deviceState.status = TerminalDeviceStatus(snapshot: snapshot)
        let fields = snapshot["fields"] as? [String: Int] ?? [:]
        deviceState.rows = InzoneDevice.fields.compactMap { field in
            guard let value = fields[field.name] else { return nil }
            return DeviceRow(key: field.name, label: field.label, value: value,
                             values: field.values, labels: field.labels)
        }
        deviceState.rows += [("game_volume", "Game output volume"), ("chat_volume", "Chat output volume"),
                             ("mic_volume", "Microphone input volume"), ("mic_mute", "Microphone mute")].compactMap { key, label in
            guard let value = hostLevels[key] else { return nil }
            return DeviceRow(key: key, label: label, value: value,
                             values: key == "mic_mute" ? [0, 1] : Array(0...100),
                             labels: key == "mic_mute" ? ["Off", "On"] : [], host: true)
        }
        deviceState.message = ""
    }
    private var selectedProfile: TerminalProfileItem {
        profileState.profiles.indices.contains(selected) ? profileState.profiles[selected] : .restore
    }
    var profile: String { selectedProfile.identifier }
    var title: String { selectedProfile.title }
    var profileCount: Int { profileState.profiles.count }
    var profileIdentifiers: [String] { profileState.profiles.map(\.identifier) }
    var profileIsBuiltIn: Bool { selectedProfile.isBuiltIn }
    var profileIsSurround: Bool { selectedProfile.isSurround }
    var canRenameOrDeleteProfile: Bool { !selectedProfile.isBuiltIn && !selectedProfile.isRestore }
    var canCreateProfile: Bool {
        profileState.profiles.lazy.filter { !$0.isBuiltIn && !$0.isRestore }.count
            < SoundProfileStore.maximumProfileCount
    }

    func actionAvailable(_ characters: String) -> Bool {
        if screen == .profiles, ["d", "a", "m", "p", "e", "s"].contains(characters) {
            return canEditProfile && (characters != "p" || profileIsSurround)
        }
        if screen == .profileManager {
            if ["n", "d"].contains(characters) { return canRenameOrDeleteProfile }
            if ["c", "o"].contains(characters), !canCreateProfile { return false }
            if characters == "o", profile == "restore" { return false }
            if characters == "k", personalizationCleanupPendingCount == 0 { return false }
        }
        return true
    }
    var personalizationInstalled: Bool { profileState.personalizationInstalled }
    var personalizationCleanupPendingCount: Int { profileState.personalizationCleanupPending.count }
    fileprivate var options: DisplayOptions { selectedProfile.options }
    fileprivate var deviceRows: [DeviceRow] { deviceState.rows }
    fileprivate var deviceSummary: DeviceScreenState { deviceState }
    var deviceStatus: TerminalDeviceStatus { deviceState.status }
    fileprivate var automationRules: [AutomationDisplayRule] { automationState.rules }
    var automationActive: Bool { automationState.active }
    var pendingAutomationApplication: String { pendingRuleApp }
    fileprivate var taskIdentity: TerminalTaskIdentity {
        TerminalTaskIdentity(screen: screen, revision: deviceObservationRevision)
    }
    var automationTargetIdentifier: String? {
        if case .rulePriority(_, let identifier) = promptPurpose { return identifier }
        return nil
    }
    var deviceSectionIndices: [Int] {
        deviceRows.indices.filter { TerminalDeviceSection.section(for: deviceRows[$0].key) == deviceSection }
    }

    func selectDeviceSection(_ section: TerminalDeviceSection) {
        guard !busy else { return }
        deviceSection = section
        if let index = deviceSectionIndices.first { deviceIndex = index }
    }

    func moveDeviceSection(by direction: Int) {
        guard !busy, screen == .device, direction != 0,
              let index = TerminalDeviceSection.allCases.firstIndex(of: deviceSection) else { return }
        let next = min(TerminalDeviceSection.allCases.count - 1, max(0, index + (direction > 0 ? 1 : -1)))
        if next != index { selectDeviceSection(TerminalDeviceSection.allCases[next]) }
    }
    var canEditProfile: Bool { !selectedProfile.isRestore }

    func profilePage(capacity: Int) -> [(Int, String)] {
        guard capacity > 0, !profileState.profiles.isEmpty else { return [] }
        let first = selected / capacity * capacity
        return profileState.profiles.enumerated().dropFirst(first).prefix(capacity).map { ($0.offset, $0.element.title) }
    }

    func automationProfilePage(capacity: Int) -> [(Int, String)] {
        let available = profileState.profiles.enumerated().filter { !$0.element.isRestore }
        guard capacity > 0, !available.isEmpty else { return [] }
        let selectedPosition = available.firstIndex { $0.offset == selected } ?? 0
        let first = selectedPosition / capacity * capacity
        return available.dropFirst(first).prefix(capacity).map {
            ($0.offset, $0.element.title + " · " + shortProfileIdentifier($0.element.identifier))
        }
    }

    func shortProfileIdentifier(_ identifier: String) -> String {
        identifier.count > 12 ? String(identifier.prefix(8)) : identifier
    }

    private func moveAutomationProfile(by direction: Int) {
        let indices = profileState.profiles.indices.filter { !profileState.profiles[$0].isRestore }
        guard !busy, direction != 0, !indices.isEmpty else { return }
        let position = indices.firstIndex(of: selected) ?? 0
        selected = indices[(position + (direction > 0 ? 1 : indices.count - 1)) % indices.count]
        initialSelection = false
    }

    func moveAutomationProfilePage(by direction: Int, capacity: Int) {
        let indices = profileState.profiles.indices.filter { !profileState.profiles[$0].isRestore }
        guard !busy, direction != 0, capacity > 0, !indices.isEmpty else { return }
        let position = indices.firstIndex(of: selected) ?? 0
        let target = min(indices.count - 1, max(0, position + (direction > 0 ? capacity : -capacity)))
        selected = indices[target]
        initialSelection = false
    }

    func moveProfile(by direction: Int) {
        guard !busy, direction != 0, !profileState.profiles.isEmpty else { return }
        selected = (selected + (direction > 0 ? 1 : profileState.profiles.count - 1)) % profileState.profiles.count
        initialSelection = false
    }

    func replacePreviewProfiles(_ profiles: [TerminalProfilePreview]) {
        guard worker == nil else { return }
        let previousIdentifier = profile
        profileState.profiles = profiles.map(TerminalProfileItem.init) + [.restore]
        if let index = profileState.profiles.firstIndex(where: {
            $0.identifier.caseInsensitiveCompare(previousIdentifier) == .orderedSame
        }) {
            selected = index
        } else {
            selected = min(selected, max(0, profileState.profiles.count - 1))
        }
    }

    func setPreviewPersonalizationInstalled(_ installed: Bool) {
        guard worker == nil else { return }
        profileState.personalizationInstalled = installed
    }

    func setPreviewPersonalizationCleanupPending(_ paths: [String]) {
        guard worker == nil else { return }
        profileState.personalizationCleanupPending = paths
    }

    func setPreviewAutomationRule(app: String, profile: String, priority: Int = 0) {
        guard worker == nil else { return }
        automationState.rules = [AutomationDisplayRule(app: app, profile: profile, priority: priority)]
        automationIndex = 0
    }

    /// Workspace navigation is unavailable while an editor owns an unsaved draft.
    func navigate(to destination: TerminalScreen) {
        guard !busy, screen != .prompt, screen != .equalizer, screen != .presets,
              [.profiles, .device, .automation].contains(destination), screen != destination else { return }
        for _ in 0..<2 where screen != .profiles {
            _ = handle(KeyPress(key: .escape, characters: ""), terminate: {})
        }
        if destination == .device { _ = handle(KeyPress(key: "h", characters: "h"), terminate: {}) }
        if destination == .automation { _ = handle(KeyPress(key: "u", characters: "u"), terminate: {}) }
    }

    /// Selection remains separate from applying settings to prevent accidental writes.
    func selectRow(_ index: Int) {
        guard !busy else { return }
        switch screen {
        case .profiles:
            guard profileState.profiles.indices.contains(index) else { return }
            selected = index
            initialSelection = false
        case .profileManager:
            guard profileState.profiles.indices.contains(index) else { return }
            selected = index
            initialSelection = false
        case .automationProfilePicker:
            guard profileState.profiles.indices.contains(index), !profileState.profiles[index].isRestore else { return }
            selected = index
            initialSelection = false
        case .equalizer:
            guard equalizer.indices.contains(index) else { return }
            equalizerIndex = index
        case .presets:
            guard SonyPresets.names.indices.contains(index) else { return }
            presetIndex = index
        case .device:
            guard deviceRows.indices.contains(index) else { return }
            deviceIndex = index
            deviceSection = TerminalDeviceSection.section(for: deviceRows[index].key)
        case .automation:
            guard automationRules.indices.contains(index) else { return }
            automationIndex = index
        case .prompt: break
        }
    }

    func adjustEqualizer(_ index: Int, by amount: Double) {
        guard !busy, screen == .equalizer, equalizer.indices.contains(index) else { return }
        equalizerIndex = index
        equalizer[index] = min(12, max(-12, equalizer[index] + amount))
    }

    func setEqualizerGain(at index: Int, to value: Double) {
        guard !busy, screen == .equalizer, equalizer.indices.contains(index), value.isFinite else { return }
        equalizerIndex = index
        equalizer[index] = min(12, max(-12, value.rounded()))
    }

    func pendingDeviceValue(at index: Int) -> Int? {
        guard deviceRows.indices.contains(index) else { return nil }
        return pendingDeviceValues[deviceRows[index].key]
    }

    func resetDeviceChanges() {
        guard !busy else { return }
        pendingDeviceValues.removeAll()
        message = "Changes discarded."
    }

    func adjustDeviceValue(at index: Int, direction: Int) {
        guard !busy, screen == .device, deviceRows.indices.contains(index), direction != 0 else { return }
        let row = deviceRows[index]
        guard !row.values.isEmpty else { return }
        deviceIndex = index
        deviceSection = TerminalDeviceSection.section(for: row.key)
        let current = pendingDeviceValues[row.key] ?? row.value
        let position = row.values.indices.min(by: { abs(row.values[$0] - current) < abs(row.values[$1] - current) }) ?? 0
        let value = row.values[min(row.values.count - 1, max(0, position + (direction > 0 ? 1 : -1)))]
        pendingDeviceValues[row.key] = value == row.value ? nil : value
    }

    func applyDeviceChanges() {
        guard !busy, screen == .device, !pendingDeviceValues.isEmpty else { return }
        guard canApplyDeviceChanges else {
            message = "Some settings are unavailable. Refresh before applying."
            return
        }
        let changes = orderedDeviceChanges()
        guard !changes.isEmpty else { return }
        perform("Device settings updated.") { worker in
            for (row, value) in changes { try await worker.setDevice(row, value: value) }
        }
    }

    var pendingDeviceApplicationOrder: [String] {
        orderedDeviceChanges().map { $0.0.key }
    }

    private func orderedDeviceChanges() -> [(DeviceRow, Int)] {
        deviceRows.compactMap { row -> (DeviceRow, Int)? in
            guard let value = pendingDeviceValues[row.key] else { return nil }
            return (row, value)
        }.sorted { left, right in
            func priority(_ change: (DeviceRow, Int)) -> Int {
                guard ["toggle_off", "toggle_nc", "toggle_ambient"].contains(change.0.key) else { return 1 }
                return change.1 == 1 ? 0 : 2
            }
            return priority(left) < priority(right)
        }
    }

    func cancelPrompt() {
        guard !busy, screen == .prompt else { return }
        screen = promptReturn
    }

    fileprivate var details: [String] {
        if selectedProfile.isRestore { return ["Tone correction: None", "Output: 48 kHz / 16 bit"] }
        var lines = profileState.details[profile] ?? ["Output: 48 kHz / 16 bit · Stereo"]
        if selectedProfile.isSurround { lines[0] = "7.1 Input → " + (options.hrtf == "personal" ? "Personalized HRTF" : "Sony Default HRTF") + " → Game Output" }
        var sound = options.soundMode == "immersive" ? "Sony Immersive Soundstage" : (options.baseEqualizer ? profileDescription : "Base Output EQ Disabled")
        if options.equalizerEnabled || options.equalizer.contains(where: { $0 != 0 }) { sound += " · Sony 10-band EQ" }
        lines.append(sound)
        lines.append("DRC: \(["Off", "Low", "High"][min(2, max(0, options.drc))]) · Output ALC: \(options.outputALC ? "On" : "Off") · Mic AGC: \(options.microphoneAGC ? "On" : "Off")")
        return lines
    }

    fileprivate var profileDescription: String {
        if selectedProfile.isRestore { return restoreDescription }
        return builtInProfileDescriptions[selectedProfile.templateProfile]
            ?? "Custom sound profile based on \(selectedProfile.templateProfile)."
    }

    func refresh(force: Bool = false) async {
        guard let worker, !busy || force else { return }
        do {
            switch screen {
            case .profiles, .profileManager, .automationProfilePicker:
                let previousIdentifier = profile
                let state = try await worker.profiles()
                guard screen == .profiles || screen == .profileManager || screen == .automationProfilePicker else { return }
                profileState = state
                if initialSelection {
                    selected = state.profiles.firstIndex {
                        $0.identifier.caseInsensitiveCompare(state.current == "original" ? "restore" : state.current) == .orderedSame
                    } ?? 0
                    initialSelection = false
                } else if let index = state.profiles.firstIndex(where: {
                    $0.identifier.caseInsensitiveCompare(previousIdentifier) == .orderedSame
                }) {
                    selected = index
                } else {
                    selected = min(selected, max(0, state.profiles.count - 1))
                }
            case .device:
                restartDeviceObservation()
            case .automation:
                let state = try await worker.automation()
                guard screen == .automation else { return }
                automationState = state
                automationIndex = min(automationIndex, max(0, state.rules.count - 1))
            default: break
            }
        } catch { message = "Failed: \(error.localizedDescription)" }
    }

    func tick() async {
        guard let worker, screen == .device else { return }
        deviceState.monitoring = worker.monitoring()
        if let hostRows = try? await worker.hostRows() {
            let selectedKey = deviceRows.indices.contains(deviceIndex) ? deviceRows[deviceIndex].key : nil
            deviceState.rows.removeAll { $0.host }
            deviceState.rows.append(contentsOf: hostRows)
            if let index = deviceState.rows.firstIndex(where: { $0.key == selectedKey }) {
                deviceIndex = index
            } else {
                deviceIndex = min(deviceIndex, max(0, deviceState.rows.count - 1))
            }
        }
    }

    func observeDeviceNotifications() async {
        guard let worker else { return }
        while screen == .device, !Task.isCancelled {
            do {
                let observation = try await worker.deviceObservation()
                installDeviceState(observation.state)
                var reconnect = false
                for await notification in observation.notifications {
                    guard screen == .device, !Task.isCancelled else { return }
                    guard observation.shouldApply(notification) else { continue }
                    if notification.values["connected"] == 1 {
                        reconnect = true
                        break
                    }
                    applyDeviceNotification(notification)
                }
                if reconnect { continue }
            } catch {
                if screen == .device { message = "Failed: \(error.localizedDescription)" }
            }
            guard screen == .device, !Task.isCancelled else { return }
            await worker.closeDevice()
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func installDeviceState(_ state: DeviceScreenState) {
        let previousKey = deviceRows.indices.contains(deviceIndex) ? deviceRows[deviceIndex].key : nil
        deviceState = state
        // Readback clears confirmed changes while preserving unavailable or failed settings.
        for row in state.rows where pendingDeviceValues[row.key] == row.value {
            pendingDeviceValues.removeValue(forKey: row.key)
        }
        if let index = state.rows.firstIndex(where: { $0.key == previousKey }) {
            deviceIndex = index
        } else {
            deviceIndex = min(deviceIndex, max(0, state.rows.count - 1))
        }
    }

    func restartDeviceObservation() {
        guard screen == .device else { return }
        deviceObservationRevision &+= 1
    }

    private func applyDeviceNotification(_ notification: DeviceNotification) {
        if deviceState.status.connection == .disconnected,
           notification.values["connected"] == nil {
            return
        }
        deviceState.status.apply(notification)
        if notification.values["connected"] == 0 {
            deviceState.rows.removeAll { !$0.host }
            deviceIndex = min(deviceIndex, max(0, deviceState.rows.count - 1))
        }
        for index in deviceState.rows.indices {
            let key = deviceState.rows[index].key
            guard let value = notification.values[key] else { continue }
            deviceState.rows[index].value = value
            if pendingDeviceValues[key] == value { pendingDeviceValues.removeValue(forKey: key) }
        }
        message = "Device status updated."
    }

    func applyPreviewDeviceNotification(_ notification: DeviceNotification) {
        guard worker == nil, screen == .device else { return }
        applyDeviceNotification(notification)
    }

    func applyPreviewDeviceSnapshot(_ snapshot: [String: Any], hostLevels: [String: Int] = [:]) {
        guard worker == nil, screen == .device else { return }
        var state = DeviceScreenState()
        state.status = TerminalDeviceStatus(snapshot: snapshot)
        let fields = snapshot["fields"] as? [String: Int] ?? [:]
        state.rows = InzoneDevice.fields.compactMap { field in
            guard let value = fields[field.name] else { return nil }
            return DeviceRow(
                key: field.name, label: field.label, value: value,
                values: field.values, labels: field.labels
            )
        }
        state.rows += [("game_volume", "Game output volume"), ("chat_volume", "Chat output volume"),
                       ("mic_volume", "Microphone input volume"), ("mic_mute", "Microphone mute")].compactMap {
            key, label in
            guard let value = hostLevels[key] else { return nil }
            return DeviceRow(
                key: key, label: label, value: value,
                values: key == "mic_mute" ? [0, 1] : Array(0...100),
                labels: key == "mic_mute" ? ["Off", "On"] : [], host: true
            )
        }
        installDeviceState(state)
    }

    func requestTermination(_ terminate: @escaping @MainActor () -> Void) {
        if busy {
            idleTermination = terminate
            message = "Exiting after completing the current task..."
        } else { terminate() }
    }

    private func perform(
        _ success: String,
        onSuccess: @escaping @MainActor () -> Void = {},
        refreshAfter: Bool = true,
        operation: @escaping @Sendable (TerminalWorker) async throws -> Void
    ) {
        guard !busy, let worker else { return }
        busy = true
        message = "Processing..."
        Task {
            do { try await operation(worker); onSuccess(); message = success }
            catch { message = "Failed: \(error.localizedDescription)" }
            if refreshAfter {
                if screen == .device { restartDeviceObservation() }
                else { await refresh(force: true) }
            }
            busy = false
            let terminate = idleTermination
            idleTermination = nil
            terminate?()
        }
    }

    private func performProfileInsertion(
        _ success: String,
        operation: @escaping @Sendable (TerminalWorker) async throws -> String
    ) {
        guard !busy, let worker else { return }
        busy = true
        message = "Processing..."
        Task {
            do {
                let identifier = try await operation(worker)
                await refresh(force: true)
                if let index = profileState.profiles.firstIndex(where: {
                    $0.identifier.caseInsensitiveCompare(identifier) == .orderedSame
                }) {
                    selected = index
                }
                message = success
            } catch {
                message = "Failed: \(error.localizedDescription)"
            }
            busy = false
            let terminate = idleTermination
            idleTermination = nil
            terminate?()
        }
    }

    private func performPersonalization(
        _ success: String,
        operation: @escaping @Sendable (TerminalWorker) async throws -> [String]
    ) {
        guard !busy, let worker else { return }
        busy = true
        message = "Processing..."
        Task {
            do {
                let pending = try await operation(worker)
                await refresh(force: true)
                message = personalizationResultMessage(success: success, cleanupPending: pending)
            } catch {
                await refresh(force: true)
                message = "Failed: \(error.localizedDescription)"
            }
            busy = false
            let terminate = idleTermination
            idleTermination = nil
            terminate?()
        }
    }

    private func performProfileImport(
        mode: SoundProfileImportMode,
        operation: @escaping @Sendable (TerminalWorker) async throws -> SoundProfileImportOutcome
    ) {
        guard !busy, let worker else { return }
        busy = true
        message = "Processing..."
        Task {
            do {
                let outcome = try await operation(worker)
                await refresh(force: true)
                message = soundProfileImportMessage(outcome, mode: mode)
            } catch {
                message = "Failed: \(error.localizedDescription)"
            }
            busy = false
            let terminate = idleTermination
            idleTermination = nil
            terminate?()
        }
    }

    private func change(_ change: OptionChange) {
        let name = profile
        perform("Settings applied successfully") { try await $0.change(name, change) }
    }

    private func openPrompt(_ purpose: PromptPurpose, title: String, value: String = "") {
        if screen != .prompt { promptReturn = screen }
        promptPurpose = purpose
        promptTitle = title
        promptText = value
        screen = .prompt
    }

    func submitPrompt() {
        guard !busy, screen == .prompt else { return }
        var value = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .rulePriority = promptPurpose, value.isEmpty { value = "0" }
        guard !value.isEmpty else { screen = promptReturn; return }
        let submittedValue = value
        switch promptPurpose {
        case .hki: openPrompt(.ba(value), title: "Path to H9 II personalized YY2987.ba file")
        case .ba(let hki):
            let ba = value
            if personalizationInstalled {
                openPrompt(
                    .confirmPersonalization(hki, ba),
                    title: "Type REPLACE to overwrite the installed personal HRTF"
                )
            } else {
                screen = .profiles
                performPersonalization("Personalization files imported successfully.") {
                    try await $0.personalize(hki: hki, ba: ba, allowReplacing: false)
                }
            }
        case .confirmPersonalization(let hki, let ba):
            guard value == "REPLACE" else {
                message = "Enter REPLACE to overwrite the installed personal HRTF."
                return
            }
            screen = .profiles
            performPersonalization("Personalization files imported successfully.") {
                try await $0.personalize(hki: hki, ba: ba, allowReplacing: true)
            }
        case .ruleApp:
            pendingRuleApp = value
            if selectedProfile.isRestore { selected = 0 }
            screen = .automationProfilePicker
        case .rulePriority(let app, let profile):
            guard let priority = Int(value), (-1000...1000).contains(priority) else { message = "Priority range: -1000 to 1000"; return }
            screen = .automation
            perform("Auto-switching rule saved successfully") { try await $0.editRule(app: app, profile: profile, priority: priority) }
        case .createProfile(let base):
            screen = .profileManager
            performProfileInsertion("Sound profile created.") {
                try await $0.createProfile(name: submittedValue, basedOn: base)
            }
        case .cloneProfile(let identifier):
            screen = .profileManager
            performProfileInsertion("Sound profile duplicated.") {
                try await $0.cloneProfile(identifier, name: submittedValue)
            }
        case .renameProfile(let identifier):
            screen = .profileManager
            perform("Sound profile renamed.") { try await $0.renameProfile(identifier, name: submittedValue) }
        case .deleteProfile(let identifier, let title):
            guard value == "DELETE" else {
                message = "Enter DELETE to remove \(title)."
                return
            }
            screen = .profileManager
            perform("Sound profile deleted.") { try await $0.deleteProfile(identifier) }
        case .importProfiles:
            screen = .profileManager
            performProfileImport(mode: .append) {
                try await $0.importProfiles(path: submittedValue, mode: .append)
            }
        case .replaceProfiles:
            openPrompt(.confirmImportProfiles(submittedValue),
                title: "Type IMPORT to replace the custom sound profile collection")
        case .confirmImportProfiles(let path):
            guard value == "IMPORT" else {
                message = "Enter IMPORT to replace the custom sound profile collection."
                return
            }
            screen = .profileManager
            performProfileImport(mode: .replace) {
                try await $0.importProfiles(path: path, mode: .replace)
            }
        case .exportProfiles:
            let destination = URL(fileURLWithPath: (submittedValue as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: destination.path) {
                openPrompt(
                    .confirmExportProfiles(submittedValue),
                    title: "Type OVERWRITE to replace the export destination"
                )
            } else {
                screen = .profileManager
                perform("Windows sound profile collection exported.", refreshAfter: false) {
                    try await $0.exportProfiles(path: submittedValue, allowOverwrite: false)
                }
            }
        case .confirmExportProfiles(let path):
            guard value == "OVERWRITE" else {
                message = "Enter OVERWRITE to replace the export destination."
                return
            }
            screen = .profileManager
            perform("Windows sound profile collection exported.", refreshAfter: false) {
                try await $0.exportProfiles(path: path, allowOverwrite: true)
            }
        case .resetPersonalization:
            guard value == "RESET" else {
                message = "Enter RESET to remove the installed personal HRTF."
                return
            }
            screen = .profileManager
            performPersonalization("Personal HRTF reset.") { try await $0.resetPersonalization() }
        case .deleteAutomationRule(let app):
            guard value == "DELETE" else {
                message = "Enter DELETE to remove the automation rule."
                return
            }
            screen = .automation
            perform("Auto-switching rule deleted successfully") {
                try await $0.editRule(app: app, profile: nil)
            }
        }
    }

    func handle(_ key: KeyPress, terminate: () -> Void) -> InputEventResult {
        let character = key.characters.lowercased()
        if screen == .prompt {
            if key.key == .escape { screen = promptReturn; return .handled }
            return .ignored
        }
        if screen == .device, character == "t", busy, let worker, worker.monitoring() {
            Task { await worker.stopMonitor(); deviceState.monitoring = false }
            return .handled
        }
        if busy { return .handled }
        if key.key == .escape || character == "q" {
            if screen == .automationProfilePicker {
                screen = .automation
                message = "Ready"
                return .handled
            }
            if screen == .profiles, showsProfileControls {
                if showsSystemControls { showsSystemControls = false; return .handled }
                showsProfileControls = false
                return .handled
            }
            if screen == .profiles { terminate() }
            else {
                if screen == .device, let worker {
                    Task { await worker.stopMonitor(); await worker.closeDevice() }
                }
                screen = .profiles
                message = "Ready"
            }
            return .handled
        }
        let up = key.key == .upArrow || character == "k"
        let down = key.key == .downArrow || character == "j"
        let enter = key.key == .return
        switch screen {
        case .profiles:
            if up { moveProfile(by: -1) }
            else if down { moveProfile(by: 1) }
            else if let number = Int(character), (1...9).contains(number), number <= profileCount {
                selected = number - 1
                initialSelection = false
            }
            else if enter {
                let name = profile
                perform("Applied: \(title)") { try await $0.activate(name) }
            } else if character == "h" {
                screen = .device
            } else if character == "u" {
                screen = .automation
            } else if character == "g" {
                screen = .profileManager
            } else if character == "i" { openPrompt(.hki, title: "Path to personalized HKI file (empty to cancel)") }
            else if ["d", "a", "m", "p", "e", "s"].contains(character) {
                guard profile != "restore" else { message = "Select a profile to edit."; return .handled }
                switch character {
                case "d": change(.drc((options.drc + 1) % 3))
                case "a": change(.outputALC(!options.outputALC))
                case "m": change(.microphoneAGC(!options.microphoneAGC))
                case "p":
                    if profileIsSurround { change(.hrtf(options.hrtf == "standard" ? "personal" : "standard")) }
                    else { message = "Select HRTF in the surround profile." }
                case "e": equalizer = options.equalizer; equalizerIndex = 0; screen = .equalizer
                case "s": presetIndex = 0; screen = .presets
                default: break
                }
            } else { return .ignored }
        case .profileManager:
            if character == "k", personalizationCleanupPendingCount > 0 {
                performPersonalization("Personalization cleanup completed.") {
                    try await $0.retryPersonalizationCleanup()
                }
            } else if up { moveProfile(by: -1) }
            else if down { moveProfile(by: 1) }
            else if character == "c", canCreateProfile {
                openPrompt(.createProfile(profile), title: "New sound profile name", value: "Sound Profile")
            } else if character == "o", profile != "restore", canCreateProfile {
                openPrompt(.cloneProfile(profile), title: "Duplicate sound profile name", value: title + " Copy")
            } else if character == "n", canRenameOrDeleteProfile {
                openPrompt(.renameProfile(profile), title: "Rename sound profile", value: title)
            } else if character == "d", canRenameOrDeleteProfile {
                openPrompt(.deleteProfile(profile, title), title: "Type DELETE to remove \(title)")
            } else if character == "i" {
                openPrompt(.importProfiles, title: "Windows SoundProfile.json path to append")
            } else if character == "w" {
                openPrompt(.replaceProfiles, title: "Windows SoundProfile.json path to replace the custom collection")
            } else if character == "x" {
                openPrompt(.exportProfiles, title: "Export path for Windows SoundProfile.json")
            } else if character == "r" {
                openPrompt(
                    .resetPersonalization,
                    title: "Type RESET to switch all personal HRTF profiles to Standard and remove their data"
                )
            } else { return .ignored }
        case .equalizer:
            if up { equalizerIndex = (equalizerIndex + 9) % 10 }
            else if down { equalizerIndex = (equalizerIndex + 1) % 10 }
            else if key.key == .leftArrow { equalizer[equalizerIndex] = max(-12, equalizer[equalizerIndex] - 1) }
            else if key.key == .rightArrow { equalizer[equalizerIndex] = min(12, equalizer[equalizerIndex] + 1) }
            else if character == "0" { equalizer = Array(repeating: 0, count: 10) }
            else if enter { screen = .profiles; change(.equalizer(equalizer)) }
            else { return .ignored }
        case .presets:
            if up { presetIndex = (presetIndex + SonyPresets.names.count - 1) % SonyPresets.names.count }
            else if down { presetIndex = (presetIndex + 1) % SonyPresets.names.count }
            else if enter {
                let name = profile, preset = SonyPresets.names[presetIndex]
                screen = .profiles
                perform("Sony preset applied successfully") { try await $0.preset(name, name: preset) }
            } else { return .ignored }
        case .device:
            if character == "r" { restartDeviceObservation() }
            else if character == "t" {
                perform("Microphone test state changed", onSuccess: {
                    self.deviceState.monitoring = self.worker?.monitoring() ?? false
                }, refreshAfter: false) { _ = try await $0.toggleMonitor() }
            } else if !deviceRows.isEmpty {
                if up { selectRow((deviceIndex + deviceRows.count - 1) % deviceRows.count) }
                else if down { selectRow((deviceIndex + 1) % deviceRows.count) }
                else if key.key == .leftArrow || key.key == .rightArrow {
                    adjustDeviceValue(at: deviceIndex, direction: key.key == .rightArrow ? 1 : -1)
                } else if enter {
                    applyDeviceChanges()
                } else { return .ignored }
            }
        case .automation:
            if up { automationIndex = max(0, automationIndex - 1) }
            else if down { automationIndex = min(max(0, automationRules.count - 1), automationIndex + 1) }
            else if character == "a" { openPrompt(.ruleApp, title: "Executable name/path (e.g. game.exe, empty to cancel)") }
            else if character == "d", !automationRules.isEmpty {
                let app = automationRules[automationIndex].app
                openPrompt(
                    .deleteAutomationRule(app),
                    title: "Type DELETE to remove the automation rule for \(app)"
                )
            } else if character == " " {
                let enable = !automationActive
                perform(enable ? "Auto-switching started" : "Auto-switching stopped") { try await $0.automationService(enable: enable) }
            } else { return .ignored }
        case .automationProfilePicker:
            if up { moveAutomationProfile(by: -1) }
            else if down { moveAutomationProfile(by: 1) }
            else if enter, !selectedProfile.isRestore {
                openPrompt(
                    .rulePriority(pendingRuleApp, profile),
                    title: "Priority -1000 to 1000 (default 0)", value: "0"
                )
            } else { return .ignored }
        case .prompt: return .ignored
        }
        return .handled
    }
}

@MainActor
private struct TerminalApplication: App {
    static var model: TerminalModel?
    var body: some Scene { WindowGroup { TerminalRoot(model: Self.model!) } }
}

@MainActor
struct TerminalRoot: View {
    @Environment(\.terminate) private var terminate
    @FocusState private var contentFocused: Bool
    @State private var touchOptimized: Bool
    let model: TerminalModel

    init(model: TerminalModel, touchOptimized: Bool = true) {
        self.model = model
        _touchOptimized = State(initialValue: touchOptimized)
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                if geometry.columns < 72 || geometry.rows < 24 {
                    Text("INZONE H9 II").bold()
                    Text("Please resize terminal to at least 72 columns × 24 rows.")
                    Text("Q / Esc: Quit")
                    TerminalAction(title: "Quit", width: 8) { model.requestTermination { terminate() } }
                } else {
                    header(columns: geometry.columns - 2)
                    VStack(alignment: .leading, spacing: 0) {
                        if touchOptimized {
                            HStack(alignment: .top, spacing: 2) {
                                if geometry.columns >= 110 {
                                    TerminalSidebar(model: model, rows: geometry.rows - 7)
                                }
                                TouchTerminalScreen(model: model,
                                    columns: geometry.columns - (geometry.columns >= 110 ? 32 : 2), rows: geometry.rows - 7)
                            }
                        } else {
                            screen(rows: geometry.rows - 7)
                        }
                    }
                    .frame(width: geometry.columns - 2, height: geometry.rows - 7, alignment: .topLeading)
                    .padding(.vertical, 1)
                    footer(columns: geometry.columns - 2)
                }
            }
            .padding(.horizontal, 1)
            .frame(width: geometry.columns, height: geometry.rows, alignment: .topLeading)
            .foregroundStyle(TerminalTheme.text)
            .background(TerminalTheme.background)
        }
        .focused($contentFocused)
        .onAppear { contentFocused = true }
        .onChange(of: model.screen) { _, screen in
            model.showsProfileControls = false
            model.showsSystemControls = false
            if screen != .prompt { contentFocused = true }
        }
        .onKeyPress { key in model.handle(key, terminate: { terminate() }) }
        .inputEvent(PointerScrollEvent(.vertical).onRecognized { scroll in
            guard model.screen != .prompt else { return .ignored }
            return model.handle(
                KeyPress(key: scroll.delta.rows < 0 ? .upArrow : .downArrow, characters: ""),
                terminate: { terminate() }
            )
        })
        .onTerminate { model.requestTermination { terminate() } }
        .task(id: model.taskIdentity) {
            if model.screen == .device { await model.observeDeviceNotifications() }
            else { await model.refresh() }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                await model.tick()
            }
        }
    }

    private var screenTitle: String {
        switch model.screen {
        case .profiles: "INZONE H9 II / " + (touchOptimized && model.showsProfileControls
            ? (model.showsSystemControls ? "Device & apps" : "Controls") : "Profiles")
        case .profileManager: "Sound Profile Collection"
        case .equalizer: "10-band EQ / " + model.title
        case .presets: "Sony EQ Presets / " + model.title
        case .device: "INZONE H9 II / Device Settings"
        case .automation: "Auto Profiles / " + (model.automationActive ? "Running" : "Stopped")
        case .automationProfilePicker: "Choose Automation Profile"
        case .prompt: "INZONE H9 II / Input"
        }
    }

    private func header(columns: Int) -> some View {
        let showsQuit = touchOptimized && model.screen == .profiles && !model.showsProfileControls
        return HStack(spacing: 2) {
            Text(screenTitle).bold().lineLimit(1)
                .padding(.leading, 1)
                .frame(width: columns - (showsQuit ? 28 : 18), height: 3, alignment: .leading)
                .foregroundStyle(TerminalTheme.text)
            if showsQuit {
                TerminalAction(title: "Quit", width: 10, enabled: !model.busy, role: .plain) {
                    model.requestTermination { terminate() }
                }
            }
            TerminalAction(title: touchOptimized ? "Compact" : "Touch layout", width: showsQuit ? 14 : 16, role: .plain) {
                touchOptimized.toggle()
            }
        }
        .frame(width: columns, height: 3)
        .background(TerminalTheme.background)
    }

    private var footerMessage: String {
        if model.busy { return model.message }
        if model.screen == .profiles, model.showsProfileControls {
            return model.showsSystemControls ? "Device settings and application rules."
                : "Changes apply immediately to " + model.title + "."
        }
        if model.screen == .equalizer { return "Unsaved EQ draft · Save & Apply commits changes." }
        if model.screen == .profileManager { return model.message }
        if model.screen == .device, model.deviceSummary.monitoring { return "Microphone monitor playing · Tap Stop mic to end." }
        if model.screen == .device, model.message.hasPrefix("Failed:") { return model.message }
        if model.screen == .device, model.pendingDeviceCount > 0 {
            if !model.canApplyDeviceChanges { return "Some settings are unavailable. Refresh or discard your changes." }
            return "\(model.pendingDeviceCount) unsaved change\(model.pendingDeviceCount == 1 ? "" : "s"). Apply or discard when ready."
        }
        if model.screen == .device, model.deviceSummary.hasIssue { return model.deviceSummary.message }
        return model.message
    }

    private var shortcuts: String {
        switch model.screen {
        case .profiles: model.showsProfileControls
            ? (model.showsSystemControls ? "H Device · U Automation · I Import · Q / Esc Back"
                : "Tap a value to change · E Equalizer · S Presets · Q / Esc Back")
            : "↑↓ Select · Enter Apply · G Manage · Q / Esc Quit"
        case .profileManager: "↑↓ Profile · C Create · O Duplicate · N Rename · D Delete · Esc Back"
        case .equalizer: "↑↓ Band · ←→ Gain · Enter Save & Apply · Q / Esc Cancel"
        case .presets: "Tap / ↑↓ Select · Enter Apply · Q / Esc Cancel"
        case .device: "Swipe ←→ Tabs · ↑↓ Item · ←→ Value · Enter Apply · Esc Back"
        case .automation: "A Add/Edit · D Delete · Space Toggle · Q / Esc Back"
        case .automationProfilePicker: "↑↓ Profile · Enter Select · Q / Esc Cancel"
        case .prompt: "Enter " + model.promptActionTitle + " · Esc Cancel"
        }
    }

    private func footer(columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text((model.busy ? "Working  " : "") + terminalText(footerMessage)).lineLimit(1)
                .foregroundStyle(footerMessage.hasPrefix("Failed:") ? TerminalTheme.danger : TerminalTheme.muted)
            Text(shortcuts).lineLimit(1).foregroundStyle(TerminalTheme.muted)
        }
        .frame(width: columns, height: 2, alignment: .leading)
        .background(TerminalTheme.background)
    }

    @ViewBuilder
    private func screen(rows: Int) -> some View {
        switch model.screen {
        case .profiles:
            Divider()
            let capacity = max(1, rows - 10)
            ForEach(model.profilePage(capacity: capacity), id: \.0) { index, title in
                row(title, selected: index == model.selected)
                    .onTapGesture { model.selectRow(index) }
            }
            Divider()
            ProfileSummary(model: model)
            ForEach(Array((model.profile == "restore" ? model.details : Array(model.details.dropLast(2))).enumerated()), id: \.offset) { _, detail in line(detail) }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                action("D: DRC", character: "d")
                action("A: Output ALC", character: "a")
                action("M: Mic AGC", character: "m")
                action("P: HRTF", character: "p")
            }
            HStack(spacing: 1) {
                action("E: EQ", character: "e")
                action("S: Presets", character: "s")
                action("H: Device", character: "h")
                action("U: Automation", character: "u")
                action("I: Import", character: "i")
                action("G: Manage", character: "g")
            }
            HStack(spacing: 1) {
                action("Apply", key: .return)
                action("Quit", character: "q")
            }
        case .profileManager:
            Divider()
            line("Selected: \(model.title)")
            line("Profile \(model.selected + 1) of \(model.profileCount) · \(model.profileIsBuiltIn ? "Built-in" : "Custom") · ID " + model.profile)
            line(model.profileDescription)
            line("Personal HRTF: " + (model.personalizationInstalled ? "Installed" : "Not installed")
                + " · Cleanup pending: \(model.personalizationCleanupPendingCount)")
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                action("↑ Previous", key: .upArrow)
                action("↓ Next", key: .downArrow)
                action("C: Create", character: "c")
                action("O: Duplicate", character: "o")
            }
            HStack(spacing: 1) {
                action("N: Rename", character: "n")
                action("D: Delete", character: "d")
                action("I: Import", character: "i")
                action("W: Replace", character: "w")
                action("X: Export", character: "x")
            }
            HStack(spacing: 1) {
                action("R: Reset HRTF", character: "r")
                action("K: Retry cleanup", character: "k")
                action("Back", key: .escape)
            }
        case .equalizer:
            Divider()
            ForEach(0..<10) { index in
                HStack(spacing: 1) {
                    row(String(format: "%5@ Hz   %+5.1f dB", equalizerFrequencies[index], model.equalizer[index]), selected: index == model.equalizerIndex)
                        .frame(width: 24, alignment: .leading)
                        .onTapGesture { model.selectRow(index) }
                    control("−") { model.adjustEqualizer(index, by: -1) }
                    Text(equalizerMeter(model.equalizer[index])).foregroundStyle(.cyan)
                    control("+") { model.adjustEqualizer(index, by: 1) }
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                action("Save & Apply", key: .return)
                action("Reset", character: "0")
                action("Cancel", key: .escape)
            }
        case .presets:
            Divider()
            ForEach(Array(SonyPresets.names.enumerated()), id: \.offset) { index, name in
                row(SonyPresets.labels[name] ?? name, selected: index == model.presetIndex)
                    .onTapGesture { model.selectRow(index) }
            }
            Spacer(minLength: 0)
            line("Sony presets replace existing Linux tone EQ.")
            HStack(spacing: 1) {
                action("Apply preset", key: .return)
                action("Cancel", key: .escape)
            }
        case .device:
            line(model.deviceSummary.battery)
            line(model.deviceSummary.firmware)
            line("Device settings apply globally across all profiles.")
            Divider()
            let count = max(1, rows - 6)
            let first = max(0, min(model.deviceIndex - count + 1, max(0, model.deviceRows.count - count)))
            ForEach(Array(model.deviceRows.enumerated().dropFirst(first).prefix(count)), id: \.element.key) { index, item in
                row(item.label + ": " + item.display(model.pendingDeviceValue(at: index))
                    + (model.pendingDeviceValue(at: index) != nil ? " *" : ""), selected: index == model.deviceIndex)
                    .onTapGesture { model.selectRow(index) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                action("↑", key: .upArrow)
                action("↓", key: .downArrow)
                action("−", key: .leftArrow)
                action("+", key: .rightArrow)
                action("Apply", key: .return)
                action("R: Refresh", character: "r")
            }
            HStack(spacing: 1) {
                action(model.deviceSummary.monitoring ? "T: Stop monitor" : "T: Test microphone", character: "t")
                action("Back", key: .escape)
            }
        case .automation:
            Divider()
            let count = max(1, rows - 3)
            let first = max(0, model.automationIndex - count + 1)
            if model.automationRules.isEmpty { line("No registered rules.") }
            ForEach(Array(model.automationRules.enumerated().dropFirst(first).prefix(count)), id: \.element.app) { index, rule in
                row("\(rule.priority)  \(rule.app) → \(rule.profile)", selected: index == model.automationIndex)
                    .onTapGesture { model.selectRow(index) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                action("↑", key: .upArrow)
                action("↓", key: .downArrow)
                action("A: Add/Edit", character: "a")
                action("D: Delete", character: "d")
            }
            HStack(spacing: 1) {
                action(model.automationActive ? "Stop automation" : "Start automation", character: " ")
                action("Back", key: .escape)
            }
        case .automationProfilePicker:
            line("Application: " + model.pendingAutomationApplication)
            Divider()
            let capacity = max(1, rows - 5)
            ForEach(model.automationProfilePage(capacity: capacity), id: \.0) { index, title in
                row(title, selected: index == model.selected)
                    .onTapGesture { model.selectRow(index) }
            }
            Spacer(minLength: 0)
            HStack(spacing: 1) {
                action("Select", key: .return)
                action("Cancel", key: .escape)
            }
        case .prompt:
            PromptView(model: model)
        }
    }

    private func line(_ value: String) -> some View {
        Text(terminalText(value)).lineLimit(1)
    }

    private func action(_ title: String, character: Character) -> some View {
        action(title, key: KeyEquivalent(character), characters: String(character))
    }

    private func action(_ title: String, key: KeyEquivalent, characters: String = "") -> some View {
        TerminalAction(
            title: title, width: RunGroup(title).measure().maximumContentColumns + 4,
            height: 1, enabled: model.actionAvailable(characters) && !model.busy,
            role: key == .return ? .primary : (key == .escape ? .plain
                : (model.screen == .profileManager && characters == "d" ? .destructive : .normal))
        ) {
            _ = model.handle(KeyPress(key: key, characters: characters), terminate: { terminate() })
        }
    }

    private func control(_ title: String, action: @escaping () -> Void) -> some View {
        TerminalAction(title: title, width: RunGroup(title).measure().maximumContentColumns + 4,
            height: 1, action: action)
    }

    private func equalizerMeter(_ value: Double) -> String {
        let position = Int(value.rounded()) + 12
        return String((0...24).map { index -> Character in
            if index == position { return "●" }
            return index == 12 ? "│" : "─"
        })
    }

    private func row(_ value: String, selected: Bool) -> some View {
        HStack(spacing: 0) {
            Text(terminalText(value)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? TerminalTheme.background : TerminalTheme.text)
        .background(selected ? TerminalTheme.accent : TerminalTheme.background)
    }
}

@MainActor
private struct TouchTerminalScreen: View {
    @Environment(\.terminate) private var terminate
    let model: TerminalModel
    let columns: Int
    let rows: Int


    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(width: columns, height: rows, alignment: .topLeading)
    }

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .profiles:
            if model.showsProfileControls, model.showsSystemControls {
                Text("Device and application settings").foregroundStyle(TerminalTheme.muted)
                Spacer(minLength: 0)
                target("Device", width: columns, role: .plain, leadingAligned: true) { dispatch("h", characters: "h") }
                target("Automation", width: columns, role: .plain, leadingAligned: true) { dispatch("u", characters: "u") }
                target("Personal HRTF import", width: columns, role: .plain, leadingAligned: true) { dispatch("i", characters: "i") }
                target("Manage sound profiles", width: columns, role: .plain, leadingAligned: true) { dispatch("g", characters: "g") }
                Spacer(minLength: 0)
                TerminalAction(title: "Back", width: 12, height: 2, role: .plain) { model.showsSystemControls = false }
            } else if model.showsProfileControls {
                Text(model.title).bold()
                setting("Dynamic range", value: ["Off", "Low", "High"][min(2, max(0, model.options.drc))], character: "d")
                setting("Output leveling", value: model.options.outputALC ? "On" : "Off", character: "a")
                setting("Microphone gain", value: model.options.microphoneAGC ? "On" : "Off", character: "m")
                if model.profileIsSurround {
                    setting("Spatial filter", value: model.options.hrtf == "personal" ? "Personal" : "Standard", character: "p")
                }
                Spacer(minLength: 0)
                TerminalEqualColumns(spacing: 2) {
                    key("Equalizer", "e")
                    key("Presets", "s")
                }
                Spacer(minLength: 1)
                HStack(spacing: 2) {
                    TerminalAction(title: "Back", width: 12, height: 2, role: .plain) { model.showsProfileControls = false }
                    Spacer(minLength: 0)
                    TerminalAction(title: "Device & apps", width: 20, height: 2) { model.showsSystemControls = true }
                }
            } else {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 0) {
                        let rowHeight = rows >= 23 ? 3 : 2
                        let capacity = max(1, (rows - 4) / rowHeight)
                        ForEach(model.profilePage(capacity: capacity), id: \.0) { index, title in
                            TerminalAction(title: title, width: 22, height: rowHeight,
                                selected: index == model.selected, enabled: !model.busy, role: .plain,
                                leadingAligned: true) { model.selectRow(index) }
                        }
                    }
                    TerminalProfileDetails(title: model.title,
                        description: model.profileDescription,
                        drc: model.options.drc, outputALC: model.options.outputALC,
                        microphoneAGC: model.options.microphoneAGC, available: model.canEditProfile)
                        .frame(width: min(columns - 26, 52), alignment: .topLeading)
                }
                Spacer(minLength: 1)
                HStack(spacing: 2) {
                    target("Device", width: 12, role: .plain) { model.navigate(to: .device) }
                    target("Automation", width: 16, role: .plain) { model.navigate(to: .automation) }
                    Spacer(minLength: 0)
                    target("Controls", width: 16) { model.showsProfileControls = true }
                    key("Apply", key: .return, width: 16)
                }
            }
        case .profileManager:
            Text(model.title).bold()
            Text("Profile \(model.selected + 1) of \(model.profileCount) · \(model.profileIsBuiltIn ? "Built-in" : "Custom") · ID " + terminalText(model.profile))
                .foregroundStyle(TerminalTheme.muted)
            Text(model.profileDescription).lineLimit(2).foregroundStyle(TerminalTheme.muted)
            Text("Personal HRTF: " + (model.personalizationInstalled ? "Installed" : "Not installed")
                + " · Cleanup pending: \(model.personalizationCleanupPendingCount)")
                .foregroundStyle(TerminalTheme.muted)
            Spacer(minLength: 0)
            TerminalEqualColumns(spacing: 2) {
                key("Previous", key: .upArrow)
                key("Next", key: .downArrow)
            }
            TerminalEqualColumns(spacing: 2) {
                key("Create", "c")
                key("Duplicate", "o")
                key("Rename", "n")
                key("Delete", "d")
            }
            TerminalEqualColumns(spacing: 2) {
                key("Import", "i")
                key("Replace", "w")
                key("Export", "x")
                key("Reset", "r")
                key("Retry", "k")
            }
            Spacer(minLength: 1)
            key("Back", key: .escape, width: 12)
        case .equalizer:
            TerminalEqualizerGraph(values: model.equalizer, selected: model.equalizerIndex,
                columns: columns, rows: rows - 7, enabled: !model.busy,
                onSelect: { model.selectRow($0) },
                onChange: { model.setEqualizerGain(at: $0, to: $1) })
            HStack(spacing: 1) {
                key("‹", key: .upArrow, width: 5)
                Text(String(format: "%@ Hz  %+.1f dB", equalizerFrequencies[model.equalizerIndex], model.equalizer[model.equalizerIndex]))
                    .bold().frame(width: 22, height: 3)
                key("›", key: .downArrow, width: 5)
                Spacer(minLength: 0)
                target("− 1 dB", width: 10) { model.adjustEqualizer(model.equalizerIndex, by: -1) }
                target("+ 1 dB", width: 10) { model.adjustEqualizer(model.equalizerIndex, by: 1) }
            }
            Spacer(minLength: 1)
            HStack(spacing: 2) {
                key("Cancel", key: .escape, width: 12)
                Spacer(minLength: 0)
                key("Reset all", "0", width: 14)
                key("Save & Apply", key: .return, width: 20)
            }
        case .presets:
            let count = max(1, (rows - 8) / 3)
            let first = model.presetIndex / count * count
            ForEach(Array(SonyPresets.names.enumerated().dropFirst(first).prefix(count)), id: \.offset) { index, name in
                target(SonyPresets.labels[name] ?? name, width: columns, selected: index == model.presetIndex, role: .plain, leadingAligned: true) {
                    model.selectRow(index)
                }
            }
            Spacer(minLength: 0)
            text("Sony presets replace tone EQ.")
            HStack(spacing: 2) {
                key("Previous", key: .upArrow, width: 14)
                key("Next", key: .downArrow, width: 14)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 1)
            HStack(spacing: 2) {
                key("Cancel", key: .escape, width: 12)
                Spacer(minLength: 0)
                key("Apply preset", key: .return, width: 20)
            }
        case .device:
            TerminalDeviceOverview(status: model.deviceSummary.status)
            TerminalDeviceTabs(selected: model.deviceSection, columns: columns, enabled: !model.busy,
                onSelect: { model.selectDeviceSection($0) })
            VStack(alignment: .leading, spacing: 0) {
                if model.deviceSection == .info {
                    deviceInformation
                } else {
                    let indices = model.deviceSectionIndices
                    let rowHeight = 3
                    let fullCount = max(1, (rows - 8) / rowHeight)
                    let count = indices.count > fullCount ? max(1, (rows - 10) / rowHeight) : fullCount
                    let selected = indices.firstIndex(of: model.deviceIndex) ?? 0
                    let first = selected / count * count
                    if indices.isEmpty {
                        Text(model.deviceSummary.status.connection == .reading ? "Reading device status…" : "No headset settings available.")
                            .bold().padding(.bottom, 1)
                        Text("Connect the headset, then refresh.").foregroundStyle(TerminalTheme.muted)
                    }
                    ForEach(Array(indices.dropFirst(first).prefix(count)), id: \.self) { index in
                        deviceSetting(model.deviceRows[index], index: index, height: rowHeight)
                    }
                    Spacer(minLength: 0)
                    if indices.count > count {
                        HStack(spacing: 2) {
                            TerminalAction(title: "Previous", width: 14, height: 2, enabled: first > 0 && !model.busy, role: .plain) {
                                model.selectRow(indices[max(0, first - count)])
                            }
                            Spacer(minLength: 0)
                            TerminalAction(title: "More settings", width: 18, height: 2,
                                enabled: first + count < indices.count && !model.busy, role: .plain) {
                                model.selectRow(indices[min(indices.count - 1, first + count)])
                            }
                        }
                    }
                }
            }
            .frame(width: columns, alignment: .topLeading)
            .highPriorityGesture(
                DragGesture(minimumDistance: 4).onEnded { value in
                    if let next = model.deviceSection.swiped(columns: value.translation.columns, rows: value.translation.rows) {
                        model.selectDeviceSection(next)
                    }
                }, isEnabled: !model.busy
            )
            HStack(spacing: 2) {
                key("Back", key: .escape, width: 10)
                TerminalAction(title: "Discard", width: 12, enabled: model.pendingDeviceCount > 0 && !model.busy, role: .plain) {
                    model.resetDeviceChanges()
                }
                key("Refresh", "r", width: 12)
                if model.deviceSection == .microphone || model.deviceSummary.monitoring {
                    key(model.deviceSummary.monitoring ? "Stop mic" : "Test mic", "t", width: 14)
                } else {
                    Spacer(minLength: 0)
                }
                key("Apply", key: .return, width: 14)
            }
        case .automation:
            let count = max(1, (rows - 7) / 3)
            let first = model.automationIndex / count * count
            if model.automationRules.isEmpty {
                Text("No automation rules").bold().padding(.bottom, 1)
                Text("Choose a sound profile for each application.").foregroundStyle(TerminalTheme.muted)
                    .padding(.bottom, 1)
                target("Add rule", width: 16, role: .primary) { dispatch("a", characters: "a") }
            }
            ForEach(Array(model.automationRules.enumerated().dropFirst(first).prefix(count)), id: \.element.app) { index, rule in
                target("\(rule.priority)  \(rule.app) → \(rule.profile)", width: columns, selected: index == model.automationIndex, role: .plain, leadingAligned: true) {
                    model.selectRow(index)
                }
            }
            Spacer(minLength: 0)
            if !model.automationRules.isEmpty {
                HStack(spacing: 2) {
                    key("Previous", key: .upArrow, width: 14)
                    key("Next", key: .downArrow, width: 14)
                    Spacer(minLength: 0)
                    key(model.automationActive ? "Stop" : "Start", " ", width: 14)
                }
                .padding(.bottom, 1)
            }
            HStack(spacing: 2) {
                key("Back", key: .escape, width: 12)
                if !model.automationRules.isEmpty { key("Delete", "d", width: 12) }
                Spacer(minLength: 0)
                if model.automationRules.isEmpty {
                    key(model.automationActive ? "Stop" : "Start", " ", width: 14)
                } else {
                    target("Add rule", width: 16, role: .primary) { dispatch("a", characters: "a") }
                }
            }

        case .automationProfilePicker:
            Text("Application: " + terminalText(model.pendingAutomationApplication)).foregroundStyle(TerminalTheme.muted)
            let rowHeight = 2
            let capacity = max(1, (rows - 8) / rowHeight)
            ForEach(model.automationProfilePage(capacity: capacity), id: \.0) { index, title in
                TerminalAction(
                    title: title, width: columns, height: rowHeight,
                    selected: index == model.selected, enabled: !model.busy,
                    role: .plain, leadingAligned: true
                ) { model.selectRow(index) }
            }
            Spacer(minLength: 0)
            TerminalEqualColumns(spacing: 2) {
                TerminalAction(title: "Previous page", height: 2, enabled: !model.busy, role: .plain) {
                    model.moveAutomationProfilePage(by: -1, capacity: capacity)
                }
                TerminalAction(title: "Next page", height: 2, enabled: !model.busy, role: .plain) {
                    model.moveAutomationProfilePage(by: 1, capacity: capacity)
                }
            }
            HStack(spacing: 2) {
                key("Cancel", key: .escape, width: 12)
                Spacer(minLength: 0)
                key("Select", key: .return, width: 16)
            }

        case .prompt:
            PromptView(model: model, touchOptimized: true)
            Spacer(minLength: 0)
        }
    }

    private func setting(_ title: String, value: String, character: Character) -> some View {
        HStack(spacing: 2) {
            Text(title).foregroundStyle(TerminalTheme.muted)
            Spacer(minLength: 0)
            TerminalAction(title: model.canEditProfile ? value : "—", width: 16, height: 2,
                enabled: model.canEditProfile && !model.busy, role: .value) {
                dispatch(KeyEquivalent(character), characters: String(character))
            }
        }
    }

    private var deviceInformation: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Headset information").bold()
            Text("Connection    " + model.deviceSummary.status.connectionLabel)
            Text("Hardware volume  " + model.deviceSummary.status.hardwareVolumeLabel)
            Text("Bluetooth     " + model.deviceSummary.status.bluetoothPowerLabel
                + " · " + model.deviceSummary.status.bluetoothConnectionLabel)
            Text("Boom mic      " + model.deviceSummary.status.microphoneAttachmentLabel
                + " · " + model.deviceSummary.status.microphoneMuteLabel)
            Text("Headset       " + terminalText(model.deviceSummary.status.headsetFirmware ?? "Not reported"))
            Text("USB adapter   " + terminalText(model.deviceSummary.status.dongleFirmware ?? "Not reported"))
            Text("Device settings apply to every sound profile.").foregroundStyle(TerminalTheme.muted)
            Spacer(minLength: 0)
        }
    }

    private func deviceSetting(_ item: DeviceRow, index: Int, height: Int) -> some View {
        let pending = model.pendingDeviceValue(at: index)
        let value = pending ?? item.value
        let selected = index == model.deviceIndex
        let display = deviceValue(item, value: value) + (pending == nil ? "" : " *")
        return HStack(spacing: 1) {
            Text(deviceLabel(item)).lineLimit(1).bold(selected)
            Spacer(minLength: 0)
            if item.values.count == 2 {
                TerminalAction(title: display, width: 30, height: height, enabled: !model.busy, role: .value,
                    baseBackground: selected ? TerminalTheme.surface : TerminalTheme.background) {
                    model.adjustDeviceValue(at: index, direction: value == item.values.last ? -1 : 1)
                }
            } else {
                TerminalAction(title: "−", width: 5, height: height, enabled: !model.busy && value > (item.values.first ?? value), role: .plain,
                    baseBackground: selected ? TerminalTheme.surface : TerminalTheme.background) {
                    model.adjustDeviceValue(at: index, direction: -1)
                }
                Text(display).lineLimit(1).frame(width: 18, height: height)
                    .foregroundStyle(pending == nil ? TerminalTheme.text : TerminalTheme.accent)
                TerminalAction(title: "+", width: 5, height: height, enabled: !model.busy && value < (item.values.last ?? value), role: .plain,
                    baseBackground: selected ? TerminalTheme.surface : TerminalTheme.background) {
                    model.adjustDeviceValue(at: index, direction: 1)
                }
            }
        }
        .padding(.horizontal, 1)
        .frame(height: height)
        .foregroundStyle(TerminalTheme.text)
        .background(selected ? TerminalTheme.surface : TerminalTheme.background)
        .onTapGesture { model.selectRow(index) }
    }

    private func deviceLabel(_ row: DeviceRow) -> String {
        switch row.key {
        case "game_chat": "Game/chat balance"
        case "game_volume": "PipeWire game volume"
        case "chat_volume": "PipeWire chat volume"
        case "mic_volume": "PipeWire microphone volume"
        case "mic_mute": "PipeWire microphone mute"
        case "auto_power": "Auto power off"
        case "toggle_off": "Button cycle: off"
        case "toggle_nc": "Button cycle: noise cancel"
        case "toggle_ambient": "Button cycle: ambient"
        case "nc_startup": "Noise mode at startup"
        case "bt_startup": "Bluetooth at startup"
        case "language": "Guidance language"
        case "guidance": "Voice guidance"
        default: row.label
        }
    }

    private func deviceValue(_ row: DeviceRow, value: Int) -> String {
        if row.key == "auto_power" { return value == 0 ? "Off" : "\(value) min" }
        if row.key == "headphone_volume" {
            return "\(value) / 30 · \(Int((Double(value) / 30 * 100).rounded()))%"
        }
        if row.key == "game_chat", value == 50 { return "50 · center" }
        if row.key == "ambient_level" { return "\(value) / 20" }
        return row.display(value)
    }

    private func text(_ value: String) -> some View {
        Text(terminalText(value)).lineLimit(1)
    }

    private func key(_ title: String, _ character: Character, width: Int? = nil) -> some View {
        key(title, key: KeyEquivalent(character), characters: String(character), width: width)
    }

    private func key(_ title: String, key: KeyEquivalent, characters: String = "", width: Int? = nil) -> some View {
        let available = model.actionAvailable(characters)
        let deviceAction = model.screen == .device && [KeyEquivalent.upArrow, .downArrow, .leftArrow, .rightArrow, .return].contains(key)
        let hasDeviceValue = !deviceAction || (key == .return ? model.canApplyDeviceChanges : !model.deviceRows.isEmpty)
        return target(title, width: width,
            enabled: available && hasDeviceValue && (!model.busy || (characters == "t" && model.deviceSummary.monitoring)),
            role: key == .return ? .primary : (key == .escape ? .plain
                : ((model.screen == .automation || model.screen == .profileManager) && characters == "d"
                    ? .destructive : .normal))) {
            dispatch(key, characters: characters)
        }
    }

    private func dispatch(_ key: KeyEquivalent, characters: String = "") {
        _ = model.handle(KeyPress(key: key, characters: characters), terminate: { terminate() })
    }

    private func target(_ title: String, width: Int? = nil, selected: Bool = false, enabled: Bool? = nil,
                        role: TerminalActionRole = .normal, leadingAligned: Bool = false,
                        action: @escaping () -> Void) -> some View {
        TerminalAction(title: title, width: width, selected: selected, enabled: enabled ?? !model.busy,
            role: role, leadingAligned: leadingAligned, action: action)
    }
}

@MainActor
private struct ProfileSummary: View {
    let model: TerminalModel

    var body: some View {
        TerminalProfileSummary(
            description: model.profileDescription,
            drc: model.options.drc, outputALC: model.options.outputALC,
            microphoneAGC: model.options.microphoneAGC, available: model.canEditProfile
        )
    }
}

@MainActor
private struct TerminalSidebar: View {
    let model: TerminalModel
    let rows: Int

    private var navigationEnabled: Bool {
        !model.busy && [.profiles, .device, .automation].contains(model.screen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Browse").foregroundStyle(TerminalTheme.muted)
                .frame(width: 26, height: 1, alignment: .leading)
                .padding(.bottom, 1)
            navigation("Profiles", .profiles)
            navigation("Device", .device)
            navigation("Automation", .automation)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1)
        .frame(width: 28, height: rows, alignment: .topLeading)
        .background(TerminalTheme.surface)
    }

    private func navigation(_ title: String, _ screen: TerminalScreen) -> some View {
        TerminalAction(title: title, width: 26, selected: model.screen == screen, enabled: navigationEnabled,
            role: .plain, leadingAligned: true, baseBackground: TerminalTheme.surface) {
            model.navigate(to: screen)
        }
        .padding(.bottom, 1)
    }
}

@MainActor
private struct PromptView: View {
    let model: TerminalModel
    var touchOptimized = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text(terminalText(model.promptTitle)).bold()
            TextField("Value", text: Binding(get: { model.promptText }, set: { model.promptText = terminalText($0) }))
                .frame(height: touchOptimized ? 3 : 1)
                .foregroundStyle(TerminalTheme.text)
                .background(TerminalTheme.surface)
                .focused($focused)
                .onSubmit { model.submitPrompt() }
            HStack(spacing: 2) {
                TerminalAction(title: "Cancel", width: 12,
                    height: touchOptimized ? 3 : 1, enabled: !model.busy, role: .plain) { model.cancelPrompt() }
                Spacer(minLength: 0)
                TerminalAction(title: model.promptActionTitle, width: 18,
                    height: touchOptimized ? 3 : 1, enabled: !model.busy, role: .primary) { model.submitPrompt() }
            }
        }
        .onAppear { focused = true }
        .onChange(of: model.promptTitle) { _, _ in focused = true }
    }
}
