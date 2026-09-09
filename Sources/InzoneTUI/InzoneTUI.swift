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
    public static func preview(columns: Int = 80, rows: Int = 24) -> String {
        ViewRenderer.render(
            TerminalRoot(model: TerminalModel(worker: nil))
                .frame(width: columns, height: rows),
            proposedSize: ProposedViewSize(columns: columns, rows: rows)
        ).text
    }
}

private let profileNames = ["fps", "music", "voice", "balanced", "surround", "restore"]
private let profileTitles = ["FPS", "음악", "통화", "기본", "서라운드", "변경 전 설정 복원"]
private let profileDescriptions = [
    "저음 감소 / 발소리 대역 강조", "원음 / 안정성 우선", "말소리 강조 / 마이크 저역 정리",
    "EQ 없음 / 균형 설정", "Sony HRTF / 7.1 입력", "저장된 음색·지연을 복원합니다. Game/Chat은 유지합니다.",
]
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

private struct ProfileScreenState: Sendable {
    var current = "original"
    var options: [String: DisplayOptions] = [:]
    var details: [String: [String]] = [:]
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
    var battery = "배터리: ?"
    var firmware = "펌웨어: ?"
    var message = "장치 상태를 읽고 있습니다."
    var monitoring = false
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
        for name in profileNames where name != "restore" {
            state.options[name] = DisplayOptions(try SettingsStore(paths: controller.paths).options(name))
            state.details[name] = configurationDetails(name)
        }
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
            var result = ["출력: 48 kHz / 16 bit · 스테레오"]
            if latency.count == 2, let samples = Double(latency[0]), let rate = Double(latency[1]), rate > 0 {
                result.append(String(format: "처리 주기 요청: %.0f 샘플 (%.2f ms)", samples, samples / rate * 1000))
            }
            let suspend = properties?["session.suspend-timeout-seconds"] as? Int ?? 5
            result.append(suspend == 0 ? "출력 절전: 해제" : "출력 절전: \(suspend)초 후")
            return result
        } catch { return ["설정 파일 확인 실패: \(error.localizedDescription)"] }
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

    func personalize(hki: String, ba: String) throws {
        let hkiURL = URL(fileURLWithPath: (hki as NSString).expandingTildeInPath)
        let baURL = URL(fileURLWithPath: (ba as NSString).expandingTildeInPath)
        _ = try Personalization.importFiles(paths: controller.paths, hki: hkiURL, ba: baURL)
    }

    func automation() throws -> AutomationScreenState {
        let rules = try AutomationStore(paths: controller.paths).load().map {
            AutomationDisplayRule(app: $0.app, profile: $0.profile, priority: $0.priority)
        }
        let active = (try? controller.runner.run(["systemctl", "--user", "is-active", "--quiet", "inzone-profile-auto.service"], input: nil, timeout: 5)) != nil
        return AutomationScreenState(rules: rules, active: active)
    }

    func editRule(app: String, profile: String?, priority: Int = 0) throws {
        try AutomationStore(paths: controller.paths).edit(app: app, profile: profile, priority: priority)
    }

    func automationService(enable: Bool) throws {
        try AutomationStore(paths: controller.paths).service(enable ? "enable" : "disable", runner: controller.runner)
    }

    func deviceState() -> DeviceScreenState {
        var result = DeviceScreenState()
        var messages: [String] = []
        do {
            if device == nil { device = try InzoneDevice(home: controller.paths.home) }
            let snapshot = try device!.snapshot()
            let fields = snapshot["fields"] as? [String: Int] ?? [:]
            result.rows = InzoneDevice.fields.compactMap { field in
                guard let value = fields[field.name] else { return nil }
                return DeviceRow(key: field.name, label: field.label, value: value,
                                 values: field.values, labels: field.labels)
            }
            if let battery = snapshot["battery"] as? [String: Any] {
                let percent = battery["percent"].map { String(describing: $0) } ?? "?"
                result.battery = "배터리: \(percent)% · " + ((battery["state"] as? String) == "charging" ? "충전 중" : "배터리 사용")
            }
            if let firmware = snapshot["firmware"] as? [String: String] {
                result.firmware = "펌웨어: 헤드셋 \(firmware["headset"] ?? "?") / 동글 \(firmware["dongle"] ?? "?")"
            }
            if snapshot["connected"] as? Bool != true { messages.append("헤드셋 연결을 기다리고 있습니다.") }
        } catch {
            device?.close()
            device = nil
            messages.append(error.localizedDescription)
        }
        do { result.rows += try hostRows() } catch { messages.append(error.localizedDescription) }
        result.message = messages.isEmpty ? "←→: 값 선택 후 Enter로 적용합니다." : messages.joined(separator: " · ")
        result.monitoring = monitor.isRunning
        return result
    }

    func hostRows() throws -> [DeviceRow] {
        let levels = try InzoneDevice.hostLevels(runner: controller.runner)
        return [("game_volume", "게임 출력 음량"), ("chat_volume", "채팅 출력 음량"),
                ("mic_volume", "마이크 입력 음량"), ("mic_mute", "마이크 음소거")].compactMap { key, label in
            guard let value = levels[key] else { return nil }
            return DeviceRow(key: key, label: label, value: value,
                             values: key == "mic_mute" ? [0, 1] : Array(0...100),
                             labels: key == "mic_mute" ? ["끔", "켬"] : [], host: true)
        }
    }

    func setDevice(_ row: DeviceRow, value: Int) throws {
        if row.host {
            try InzoneDevice.setHostField(row.key, value: value, runner: controller.runner)
            guard try hostRows().first(where: { $0.key == row.key })?.value == value else {
                throw TerminalFailure.invalid("오디오 서버가 요청한 값을 적용하지 않았습니다.")
            }
        } else {
            guard let device else { throw TerminalFailure.invalid("장치를 먼저 새로 읽으세요.") }
            try device.setField(row.key, value: value)
        }
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

enum TerminalScreen: Equatable { case profiles, equalizer, presets, device, automation, prompt }
private enum PromptPurpose { case hki, ba(String), ruleApp, ruleProfile(String), rulePriority(String, String) }

@MainActor
@Observable
final class TerminalModel {
    private let worker: TerminalWorker?
    var screen = TerminalScreen.profiles
    var selected = 0
    var message = "선택 후 Enter를 누르면 적용합니다."
    var busy = false
    var equalizer = Array(repeating: 0.0, count: 10)
    var equalizerIndex = 0
    var presetIndex = 0
    var deviceIndex = 0
    var devicePending: Int?
    var automationIndex = 0
    var promptText = ""
    var promptTitle = ""
    private var promptPurpose = PromptPurpose.hki
    private var promptReturn = TerminalScreen.profiles
    private var profileState = ProfileScreenState()
    private var deviceState = DeviceScreenState()
    private var automationState = AutomationScreenState()
    private var initialSelection = true
    private var idleTermination: (@MainActor () -> Void)?

    fileprivate init(worker: TerminalWorker?) { self.worker = worker }
    init() { worker = nil }
    var profile: String { profileNames[selected] }
    var title: String { profileTitles[selected] }
    fileprivate var options: DisplayOptions { profileState.options[profile] ?? DisplayOptions() }
    fileprivate var current: String {
        let name = profileState.current == "original" ? "restore" : profileState.current
        return profileNames.firstIndex(of: name).map { profileTitles[$0] } ?? name
    }
    fileprivate var deviceRows: [DeviceRow] { deviceState.rows }
    fileprivate var deviceSummary: DeviceScreenState { deviceState }
    fileprivate var automationRules: [AutomationDisplayRule] { automationState.rules }
    var automationActive: Bool { automationState.active }

    func isActive(_ index: Int) -> Bool {
        profileState.current == profileNames[index] || (index == 5 && profileState.current == "original")
    }

    fileprivate var details: [String] {
        if profile == "restore" { return ["음색 보정: 없음", "출력: 48 kHz / 16 bit"] }
        var lines = profileState.details[profile] ?? ["출력: 48 kHz / 16 bit · 스테레오"]
        if profile == "surround" { lines[0] = "7.1 입력 → " + (options.hrtf == "personal" ? "개인화 HRTF" : "Sony 기본 HRTF") + " → Game 출력" }
        var sound = options.soundMode == "immersive" ? "Sony 몰입 음장" : (options.baseEqualizer ? profileDescriptions[selected] : "기본 출력 EQ 해제")
        if options.equalizerEnabled || options.equalizer.contains(where: { $0 != 0 }) { sound += " · Sony 10밴드 EQ" }
        lines.append(sound)
        lines.append("DRC: \(["끔", "낮음", "높음"][min(2, max(0, options.drc))]) · 출력 ALC: \(options.outputALC ? "켬" : "끔") · 마이크 AGC: \(options.microphoneAGC ? "켬" : "끔")")
        return lines
    }

    func refresh(force: Bool = false) async {
        guard let worker, !busy || force else { return }
        do {
            switch screen {
            case .profiles:
                let state = try await worker.profiles()
                guard screen == .profiles else { return }
                profileState = state
                if initialSelection {
                    selected = profileNames.firstIndex(of: state.current == "original" ? "restore" : state.current) ?? 0
                    initialSelection = false
                }
            case .device:
                let state = await worker.deviceState()
                guard screen == .device else { return }
                let previousKey = deviceRows.indices.contains(deviceIndex) ? deviceRows[deviceIndex].key : nil
                deviceState = state
                if let index = state.rows.firstIndex(where: { $0.key == previousKey }) {
                    deviceIndex = index
                } else {
                    deviceIndex = min(deviceIndex, max(0, state.rows.count - 1))
                    devicePending = nil
                }
            case .automation:
                let state = try await worker.automation()
                guard screen == .automation else { return }
                automationState = state
                automationIndex = min(automationIndex, max(0, state.rules.count - 1))
            default: break
            }
        } catch { message = "실패: \(error.localizedDescription)" }
    }

    func tick() async {
        guard let worker, screen == .device else { return }
        deviceState.monitoring = worker.monitoring()
    }

    func requestTermination(_ terminate: @escaping @MainActor () -> Void) {
        if busy {
            idleTermination = terminate
            message = "현재 작업을 마친 후 종료합니다."
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
        message = "처리 중…"
        Task {
            do { try await operation(worker); onSuccess(); message = success }
            catch { message = "실패: \(error.localizedDescription)" }
            if refreshAfter { await refresh(force: true) }
            busy = false
            let terminate = idleTermination
            idleTermination = nil
            terminate?()
        }
    }

    private func change(_ change: OptionChange) {
        let name = profile
        perform("설정 적용 완료") { try await $0.change(name, change) }
    }

    private func openPrompt(_ purpose: PromptPurpose, title: String, value: String = "") {
        if screen != .prompt { promptReturn = screen }
        promptPurpose = purpose
        promptTitle = title
        promptText = value
        screen = .prompt
    }

    func submitPrompt() {
        var value = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .rulePriority = promptPurpose, value.isEmpty { value = "0" }
        guard !value.isEmpty else { screen = promptReturn; return }
        switch promptPurpose {
        case .hki: openPrompt(.ba(value), title: "H9 II 개인화용 YY2987.ba 파일 경로")
        case .ba(let hki):
            let ba = value
            screen = .profiles
            perform("개인화 파일 가져오기 완료") { try await $0.personalize(hki: hki, ba: ba) }
        case .ruleApp:
            openPrompt(.ruleProfile(value), title: "대상: fps / music / voice / balanced / surround")
        case .ruleProfile(let app):
            guard profileNames.dropLast().contains(value) else { message = "올바른 대상 프로파일을 입력하세요."; return }
            openPrompt(.rulePriority(app, value), title: "우선순위 −1000~1000 (기본 0)", value: "0")
        case .rulePriority(let app, let profile):
            guard let priority = Int(value), (-1000...1000).contains(priority) else { message = "우선순위 범위: −1000~1000"; return }
            screen = .automation
            perform("자동 전환 규칙 저장 완료") { try await $0.editRule(app: app, profile: profile, priority: priority) }
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
            if screen == .profiles { terminate() }
            else {
                if screen == .device, let worker {
                    Task { await worker.stopMonitor(); await worker.closeDevice() }
                }
                screen = .profiles
                message = "선택 후 Enter를 누르면 적용합니다."
            }
            return .handled
        }
        let up = key.key == .upArrow || character == "k"
        let down = key.key == .downArrow || character == "j"
        let enter = key.key == .return
        switch screen {
        case .profiles:
            if up { selected = (selected + 5) % 6; initialSelection = false }
            else if down { selected = (selected + 1) % 6; initialSelection = false }
            else if let number = Int(character), (1...6).contains(number) { selected = number - 1; initialSelection = false }
            else if enter {
                let name = profile
                perform("적용 완료: \(title)") { try await $0.activate(name) }
            } else if character == "h" {
                screen = .device; devicePending = nil
                Task { await refresh() }
            } else if character == "u" {
                screen = .automation
                Task { await refresh() }
            } else if character == "i" { openPrompt(.hki, title: "개인화 HKI 파일 경로 (빈 입력: 취소)") }
            else if ["d", "a", "m", "p", "e", "s"].contains(character) {
                guard profile != "restore" else { message = "편집할 프로파일을 선택하세요."; return .handled }
                guard worker == nil || profileState.options[profile] != nil else {
                    message = "설정 상태를 먼저 읽어야 합니다."
                    return .handled
                }
                switch character {
                case "d": change(.drc((options.drc + 1) % 3))
                case "a": change(.outputALC(!options.outputALC))
                case "m": change(.microphoneAGC(!options.microphoneAGC))
                case "p":
                    if profile == "surround" { change(.hrtf(options.hrtf == "standard" ? "personal" : "standard")) }
                    else { message = "서라운드 프로파일에서 HRTF를 선택하세요." }
                case "e": equalizer = options.equalizer; equalizerIndex = 0; screen = .equalizer
                case "s": presetIndex = 0; screen = .presets
                default: break
                }
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
                perform("Sony 프리셋 적용 완료") { try await $0.preset(name, name: preset) }
            } else { return .ignored }
        case .device:
            if character == "r" { devicePending = nil; Task { await refresh() } }
            else if character == "t" {
                perform("마이크 테스트 상태 변경 완료", onSuccess: {
                    self.deviceState.monitoring = self.worker?.monitoring() ?? false
                }, refreshAfter: false) { _ = try await $0.toggleMonitor() }
            } else if !deviceRows.isEmpty {
                if up { deviceIndex = (deviceIndex + deviceRows.count - 1) % deviceRows.count; devicePending = nil }
                else if down { deviceIndex = (deviceIndex + 1) % deviceRows.count; devicePending = nil }
                else if key.key == .leftArrow || key.key == .rightArrow {
                    let row = deviceRows[deviceIndex], current = devicePending ?? deviceRows[deviceIndex].value
                    let index = row.values.indices.min(by: { abs(row.values[$0] - current) < abs(row.values[$1] - current) }) ?? 0
                    devicePending = row.values[min(row.values.count - 1, max(0, index + (key.key == .rightArrow ? 1 : -1)))]
                } else if enter, let value = devicePending {
                    let row = deviceRows[deviceIndex]
                    perform("적용·조회 확인 완료", onSuccess: { self.devicePending = nil }) {
                        try await $0.setDevice(row, value: value)
                    }
                } else { return .ignored }
            }
        case .automation:
            if up { automationIndex = max(0, automationIndex - 1) }
            else if down { automationIndex = min(max(0, automationRules.count - 1), automationIndex + 1) }
            else if character == "a" { openPrompt(.ruleApp, title: "실행 파일 이름/경로 (예: game.exe, 빈 입력: 취소)") }
            else if character == "d", !automationRules.isEmpty {
                let app = automationRules[automationIndex].app
                perform("자동 전환 규칙 삭제 완료") { try await $0.editRule(app: app, profile: nil) }
            } else if character == " " {
                let enable = !automationActive
                perform(enable ? "자동 전환 시작 완료" : "자동 전환 중지 완료") { try await $0.automationService(enable: enable) }
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
private struct TerminalRoot: View {
    @Environment(\.terminate) private var terminate
    @FocusState private var contentFocused: Bool
    let model: TerminalModel

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 0) {
                if geometry.columns < 72 || geometry.rows < 24 {
                    Text("INZONE H9 II").bold()
                    Text("터미널을 72열 × 24행 이상으로 넓혀 주세요.")
                    Text("Q / Esc: 종료")
                } else {
                    screen(rows: geometry.rows - 2)
                }
            }
            .padding(.horizontal, 1)
            .frame(width: geometry.columns, height: geometry.rows, alignment: .topLeading)
        }
        .focused($contentFocused)
        .onAppear { contentFocused = true }
        .onChange(of: model.screen) { _, screen in
            if screen != .prompt { contentFocused = true }
        }
        .onKeyPress { key in model.handle(key, terminate: { terminate() }) }
        .onTerminate { model.requestTermination { terminate() } }
        .task {
            var ticks = 0
            await model.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
                ticks += 1
                await model.tick()
                if ticks % 5 == 0 { await model.refresh() }
            }
        }
    }

    @ViewBuilder
    private func screen(rows: Int) -> some View {
        switch model.screen {
        case .profiles:
            Text("INZONE H9 II / 프로파일").bold().foregroundStyle(.cyan)
            line("현재 적용: " + model.current)
            Divider()
            ForEach(0..<6) { index in
                row("\(index + 1)  \(profileTitles[index])" + (model.isActive(index) ? "  [적용 중]" : ""), selected: index == model.selected)
            }
            Divider()
            line(profileDescriptions[model.selected])
            ForEach(Array(model.details.enumerated()), id: \.offset) { _, detail in line(detail) }
            Spacer(minLength: 0)
            line("D: DRC  A: 출력 ALC  M: 마이크 AGC  P: 기본/개인화")
            line("E: EQ  S: 프리셋  H: 장치  U: 자동  I: 개인화 파일")
            line(model.message)
            line("↑↓ / J K: 선택  1–6: 선택  Enter: 적용  Q / Esc: 종료")
        case .equalizer:
            Text("10-band EQ / " + model.title).bold()
            Divider()
            ForEach(0..<10) { index in
                row(String(format: "%5@ Hz   %+5.1f dB", equalizerFrequencies[index], model.equalizer[index]), selected: index == model.equalizerIndex)
            }
            Spacer(minLength: 0)
            line("↑↓: 대역  ←→: 1 dB  0: 초기화")
            line("Enter: 저장·적용  Esc / Q: 취소")
        case .presets:
            Text("Sony EQ 프리셋 / " + model.title).bold()
            Divider()
            ForEach(Array(SonyPresets.names.enumerated()), id: \.offset) { index, name in
                row(SonyPresets.labels[name] ?? name, selected: index == model.presetIndex)
            }
            Spacer(minLength: 0)
            line("Sony 프리셋은 기존 Linux 음색 EQ를 대체합니다.")
            line("↑↓ 선택 · Enter 적용 · Esc / Q 취소")
        case .device:
            Text("INZONE H9 II / 장치 설정").bold()
            line(model.deviceSummary.battery)
            line(model.deviceSummary.firmware)
            line("장치 설정은 모든 프로파일에 공통으로 적용됩니다.")
            Divider()
            let count = max(1, rows - 10)
            let first = max(0, min(model.deviceIndex - count + 1, max(0, model.deviceRows.count - count)))
            ForEach(Array(model.deviceRows.enumerated().dropFirst(first).prefix(count)), id: \.element.key) { index, item in
                row(item.label + ": " + item.display(index == model.deviceIndex ? model.devicePending : nil)
                    + (index == model.deviceIndex && model.devicePending != nil ? " *" : ""), selected: index == model.deviceIndex)
            }
            Spacer(minLength: 0)
            line(model.deviceSummary.monitoring ? "마이크 테스트 재생 중 (최대 30초)" : model.deviceSummary.message)
            line(model.message)
            line("↑↓: 항목  ←→: 값  Enter: 적용  R: 새로 읽기")
            line("T: 마이크 듣기 시작/중지  Esc / Q: 돌아가기")
        case .automation:
            Text("자동 프로파일 / " + (model.automationActive ? "실행 중" : "꺼짐")).bold()
            Divider()
            let count = max(1, rows - 7)
            let first = max(0, model.automationIndex - count + 1)
            if model.automationRules.isEmpty { line("등록된 규칙이 없습니다.") }
            ForEach(Array(model.automationRules.enumerated().dropFirst(first).prefix(count)), id: \.element.app) { index, rule in
                row("\(rule.priority)  \(rule.app) → \(rule.profile)", selected: index == model.automationIndex)
            }
            Spacer(minLength: 0)
            line(model.message)
            line("A: 규칙 추가/수정  D: 삭제  Space: 자동 전환 켜기/끄기")
            line("높은 우선순위 먼저 · 동률은 목록 순서 · Esc / Q: 돌아가기")
        case .prompt:
            PromptView(model: model)
        }
    }

    private func line(_ value: String) -> some View {
        Text(terminalText(value)).lineLimit(1)
    }

    @ViewBuilder
    private func row(_ value: String, selected: Bool) -> some View {
        if selected { Text("> " + terminalText(value)).bold().foregroundStyle(.cyan).lineLimit(1) }
        else { Text("  " + terminalText(value)).lineLimit(1) }
    }
}

@MainActor
private struct PromptView: View {
    let model: TerminalModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading) {
            Text(terminalText(model.promptTitle)).bold()
            TextField(">", text: Binding(get: { model.promptText }, set: { model.promptText = terminalText($0) }))
                .focused($focused)
                .onSubmit { model.submitPrompt() }
            Text(terminalText(model.message)).lineLimit(1)
            Text("Enter: 다음/저장  Esc: 취소")
        }
        .onAppear { focused = true }
        .onChange(of: model.promptTitle) { _, _ in focused = true }
    }
}
