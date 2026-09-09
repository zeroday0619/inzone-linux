import Foundation
import Glibc

public struct AutomationRule: Codable, Equatable, Sendable {
    public let app: String
    public let profile: String
    public let priority: Int

    public init(app: String, profile: String, priority: Int = 0) {
        self.app = app
        self.profile = profile
        self.priority = priority
    }
}

private func normalizedProfileIdentifier(_ identifier: String) -> String {
    UUID(uuidString: identifier)?.uuidString.lowercased() ?? identifier
}

private func profileIdentifiersEqual(_ left: String, _ right: String) -> Bool {
    normalizedProfileIdentifier(left) == normalizedProfileIdentifier(right)
}

private func normalizedWindowsApplication(_ application: String) -> String? {
    let normalized = application.replacingOccurrences(of: "\\", with: "/")
    guard normalized.lowercased().hasSuffix(".exe") else { return nil }
    return normalized.lowercased()
}

private func applicationIdentity(_ application: String) -> String {
    if let normalized = normalizedWindowsApplication(application) {
        return "windows:\(normalized)"
    }
    return "native:\(application)"
}

public struct AutomationDecision: Sendable {
    public private(set) var baseline: String
    public private(set) var applied: String?
    public private(set) var token: String
    public private(set) var group: [AutomationRule] = []
    public private(set) var hold = false
    private var candidate: [AutomationRule]?
    private var since: TimeInterval = 0

    public init(current: String, token: String) {
        baseline = normalizedProfileIdentifier(current)
        self.token = token
    }

    init(baseline: String, applied: String, token: String) {
        self.baseline = normalizedProfileIdentifier(baseline)
        self.applied = normalizedProfileIdentifier(applied)
        self.token = token
    }

    public mutating func step(group: [AutomationRule], current: String, token: String, now: TimeInterval) -> String? {
        let current = normalizedProfileIdentifier(current)
        let group = group.map {
            AutomationRule(app: $0.app, profile: normalizedProfileIdentifier($0.profile), priority: $0.priority)
        }
        if token != self.token || (applied != nil && !profileIdentifiersEqual(current, applied!)) {
            self.token = token
            baseline = current
            applied = nil
            hold = true
            // A manual selection also owns a match set still within its debounce interval.
            self.group = group
            candidate = group
            since = now
        }
        if group != candidate { candidate = group; since = now }
        if now - since < 2 { return nil }
        if group != self.group { self.group = group; hold = false }
        if hold { return nil }
        let target = group.first?.profile ?? baseline
        return profileIdentifiersEqual(target, current) ? nil : target
    }

    public mutating func committed(_ target: String) { applied = normalizedProfileIdentifier(target) }
}

struct AutomationOwnership: Codable, Equatable, Sendable {
    let baseline: String?
    let applied: String?
    let pending: String?
    let token: String

    static func inactive(token: String) -> AutomationOwnership {
        AutomationOwnership(baseline: nil, applied: nil, pending: nil, token: token)
    }

    var isInactive: Bool { baseline == nil && applied == nil && pending == nil }
}

private func normalizedOwnership(_ ownership: AutomationOwnership) -> AutomationOwnership {
    AutomationOwnership(
        baseline: ownership.baseline.map(normalizedProfileIdentifier),
        applied: ownership.applied.map(normalizedProfileIdentifier),
        pending: ownership.pending.map(normalizedProfileIdentifier), token: ownership.token
    )
}

nonisolated(unsafe) private var automationStopping: sig_atomic_t = 0
private func automationSignalHandler(_ signal: Int32) { automationStopping = 1 }

public struct AutomationStore: Sendable {
    public static let unit = "inzone-profile-auto.service"
    public static let profiles = SettingsStore.profiles
    public let paths: InzonePaths
    public var fileURL: URL { paths.configDirectory.appendingPathComponent("auto-profiles.json") }
    var ownershipURL: URL { paths.configDirectory.appendingPathComponent("auto-profile-ownership.json") }

    public init(paths: InzonePaths) { self.paths = paths }

    public static func validate(_ rules: [AutomationRule]) throws -> [AutomationRule] {
        try validate(rules, availableProfiles: Set(profiles), allowUnregisteredUUIDs: true)
    }

    public static func validate(
        _ rules: [AutomationRule], availableProfiles: Set<String>
    ) throws -> [AutomationRule] {
        try validate(rules, availableProfiles: availableProfiles, allowUnregisteredUUIDs: false)
    }

    private static func validate(
        _ rules: [AutomationRule], availableProfiles: Set<String>, allowUnregisteredUUIDs: Bool
    ) throws -> [AutomationRule] {
        guard rules.count <= 128 else { throw InzoneError.message("At most 128 automatic profile rules are supported.") }
        let availableIdentifiers = Set(availableProfiles.map(normalizedProfileIdentifier))
        var seen = Set<String>()
        var validated: [AutomationRule] = []
        validated.reserveCapacity(rules.count)
        for rule in rules {
            guard !rule.app.isEmpty, rule.app.unicodeScalars.count <= 1024,
                  !rule.app.unicodeScalars.contains(where: { $0.value < 32 }),
                  seen.insert(applicationIdentity(rule.app)).inserted else {
                throw InzoneError.message("Executable names or paths must be nonempty, unique strings without control characters.")
            }
            let profile = normalizedProfileIdentifier(rule.profile)
            let isUUID = UUID(uuidString: rule.profile) != nil
            let validProfile = availableIdentifiers.contains(profile) || (allowUnregisteredUUIDs && isUUID)
            guard validProfile else {
                throw InzoneError.message("Invalid automatic profile: \(rule.profile)")
            }
            guard (-1000...1000).contains(rule.priority) else { throw InzoneError.message("Automatic profile priority must be between -1000 and 1000.") }
            validated.append(AutomationRule(app: rule.app, profile: profile, priority: rule.priority))
        }
        return validated
    }

    public static func decode(_ data: Data) throws -> [AutomationRule] {
        try validate(decodeSchema(data))
    }

    private static func decodeSchema(_ data: Data) throws -> [AutomationRule] {
        guard let objects = try JSONSupport.decode(data) as? [[String: Any]], objects.count <= 128 else {
            throw InzoneError.message("Automatic profiles must be an array of at most 128 rules.")
        }
        for object in objects {
            guard Set(object.keys) == Set(["app", "profile", "priority"]),
                  let priority = object["priority"] as? NSNumber,
                  !["c", "f", "d"].contains(String(cString: priority.objCType)) else {
                throw InzoneError.message("Each automatic rule requires app, profile, and an integer priority.")
            }
        }
        return try JSONDecoder().decode([AutomationRule].self, from: data)
    }

    public func load() throws -> [AutomationRule] {
        let rulesLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(rulesLock) {} }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> [AutomationRule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let rules = try Self.decodeSchema(Data(contentsOf: fileURL))
        let identifiers = Set(try SettingsStore(paths: paths).availableProfiles().map(\.identifier))
        return try Self.validate(rules, availableProfiles: identifiers)
    }

    public func save(_ rules: [AutomationRule]) throws {
        let switchLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("switch.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(switchLock) {} }
        let rulesLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(rulesLock) {} }
        try saveUnlocked(rules)
    }

    private func saveUnlocked(_ rules: [AutomationRule]) throws {
        let identifiers = Set(try SettingsStore(paths: paths).availableProfiles().map(\.identifier))
        let validated = try Self.validate(rules, availableProfiles: identifiers)
        try prepareDirectory()
        let objects = validated.map { ["app": $0.app, "profile": $0.profile, "priority": $0.priority] as [String: Any] }
        let text = try JSONSupport.encode(objects, pretty: true)
        try AtomicFile.write(Data((text + (text.hasSuffix("\n") ? "" : "\n")).utf8), to: fileURL)
    }

    public func edit(app: String, profile: String?, priority: Int = 0) throws {
        try prepareDirectory()
        let switchLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("switch.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(switchLock) {} }
        let rulesLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(rulesLock) {} }
        let existing: [AutomationRule]
        if FileManager.default.fileExists(atPath: fileURL.path) {
            existing = try Self.decodeSchema(Data(contentsOf: fileURL))
        } else {
            existing = []
        }
        let editedIdentity = applicationIdentity(app)
        var rules = existing.filter { applicationIdentity($0.app) != editedIdentity }
        if let profile { rules.append(AutomationRule(app: app, profile: profile, priority: priority)) }
        try saveUnlocked(rules)
    }

    public func references(profile identifier: String) throws -> Bool {
        try referencedProfileIdentifiers().contains(normalizedProfileIdentifier(identifier))
    }

    /// Returns profile identifiers retained by rules or a live watcher transaction.
    public func referencedProfileIdentifiers() throws -> Set<String> {
        let rulesLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(rulesLock) {} }
        var identifiers = Set<String>()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let rules = try Self.decodeSchema(Data(contentsOf: fileURL))
            identifiers.formUnion(rules.map { normalizedProfileIdentifier($0.profile) })
        }
        if let ownership = try loadOwnershipUnlocked() {
            identifiers.formUnion([ownership.baseline, ownership.applied, ownership.pending]
                .compactMap { $0 }.map(normalizedProfileIdentifier))
        }
        return identifiers
    }

    public func manualToken() -> String {
        (try? String(contentsOf: paths.configDirectory.appendingPathComponent("manual-switch"), encoding: .utf8)) ?? ""
    }

    public func markManual() throws {
        try prepareDirectory()
        var now = timespec()
        guard clock_gettime(CLOCK_REALTIME, &now) == 0 else { throw fileError("Read manual selection timestamp") }
        let token = String(UInt64(now.tv_sec) * 1_000_000_000 + UInt64(now.tv_nsec))
        try AtomicFile.write(Data(token.utf8), to: paths.configDirectory.appendingPathComponent("manual-switch"))
    }

    public static func matching(_ rules: [AutomationRule], names: Set<String>) -> [AutomationRule] {
        let windowsNames = Set(names.compactMap(normalizedWindowsApplication))
        return rules.enumerated().sorted {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority > $1.element.priority
        }.map(\.element).filter {
            if let application = normalizedWindowsApplication($0.app) {
                return windowsNames.contains(application)
            }
            return names.contains($0.app)
        }
    }

    public static func processNames(procDirectory: URL = URL(fileURLWithPath: "/proc"), uid: uid_t = getuid()) -> Set<String> {
        var result = Set<String>()
        let entries = (try? FileManager.default.contentsOfDirectory(at: procDirectory, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            guard !entry.lastPathComponent.isEmpty, entry.lastPathComponent.utf8.allSatisfy({ (48...57).contains($0) }) else { continue }
            var info = stat()
            guard fstatat(AT_FDCWD, entry.path, &info, 0) == 0, info.st_uid == uid,
                  let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.appendingPathComponent("exe").path) else { continue }
            result.insert(executable)
            result.insert(URL(fileURLWithPath: executable).lastPathComponent)
            guard let stream = try? FileHandle(forReadingFrom: entry.appendingPathComponent("cmdline")) else { continue }
            defer { try? stream.close() }
            guard let data = try? stream.read(upToCount: 4096) else { continue }
            let first = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
            if let application = normalizedWindowsApplication(first) {
                result.insert(application)
                result.insert(application.components(separatedBy: "/").last ?? application)
            }
        }
        return result
    }

    public func service(_ action: String, runner: any CommandRunning) throws {
        guard ["enable", "disable"].contains(action) else { throw InzoneError.message("Automatic profile service action must be enable or disable.") }
        _ = try runner.run(["systemctl", "--user", "daemon-reload"], input: nil, timeout: 15)
        _ = try runner.run(["systemctl", "--user", action, "--now", Self.unit], input: nil, timeout: 20)
    }

    public func watch(controller: ProfileController) throws {
        try prepareDirectory()
        let lock = try FileLock(url: paths.configDirectory.appendingPathComponent("auto-watch.lock"), nonblocking: true)
        defer { withExtendedLifetime(lock) {} }
        automationStopping = 0
        let previousTerm = Glibc.signal(SIGTERM, automationSignalHandler)
        let previousInterrupt = Glibc.signal(SIGINT, automationSignalHandler)
        defer {
            _ = Glibc.signal(SIGTERM, previousTerm)
            _ = Glibc.signal(SIGINT, previousInterrupt)
        }
        let currentStatus = try controller.status()
        let current = currentStatus == "original" ? "restore" : normalizedProfileIdentifier(currentStatus)
        let token = manualToken()
        var decision = try resumedDecision(current: current, token: token)
        var persistedOwnership = ownership(for: decision)
        var retry: TimeInterval = 0
        var lastError: String?
        while automationStopping == 0 {
            do {
                let now = ProcessInfo.processInfo.systemUptime
                let group = Self.matching(try load(), names: Self.processNames())
                let activeStatus = try controller.status()
                let active = activeStatus == "original" ? "restore" : activeStatus
                let target = decision.step(
                    group: group, current: active, token: manualToken(), now: now
                )
                let nextOwnership = ownership(for: decision)
                if nextOwnership != persistedOwnership {
                    try saveOwnership(nextOwnership)
                    persistedOwnership = nextOwnership
                }
                if let target, now >= retry, try controller.isConnected() {
                    let previous = persistedOwnership
                    let pending = AutomationOwnership(
                        baseline: decision.baseline, applied: decision.applied,
                        pending: normalizedProfileIdentifier(target), token: decision.token
                    )
                    try saveOwnership(pending)
                    persistedOwnership = pending
                    do {
                        try controller.activate(target, automatic: true, autoToken: decision.token)
                    } catch {
                        try saveOwnership(previous)
                        persistedOwnership = previous
                        throw error
                    }
                    decision.committed(target)
                    let committed = ownership(for: decision)
                    try saveOwnership(committed)
                    persistedOwnership = committed
                    writeStatus("Automatic profile: \(target)")
                }
                lastError = nil
            } catch {
                let message = String(describing: error)
                if message != lastError { writeStatus("Automatic profile waiting: \(message)") }
                lastError = message
                retry = ProcessInfo.processInfo.systemUptime + 15
            }
            _ = Glibc.sleep(1)
        }
        // Restore only the profile still owned by this watcher at shutdown.
        if let applied = decision.applied, manualToken() == decision.token,
           profileIdentifiersEqual(try controller.status(), applied),
           !profileIdentifiersEqual(decision.baseline, applied) {
            try saveOwnership(AutomationOwnership(
                baseline: decision.baseline, applied: applied,
                pending: decision.baseline, token: decision.token
            ))
            try controller.activate(decision.baseline, automatic: true, autoToken: decision.token)
        }
        try saveOwnership(.inactive(token: decision.token))
    }

    func resumedDecision(current: String, token: String) throws -> AutomationDecision {
        let current = normalizedProfileIdentifier(current)
        if let ownership = try loadOwnership(), ownership.token == token,
           let baseline = ownership.baseline,
           [ownership.applied, ownership.pending].compactMap({ $0 }).contains(where: {
               profileIdentifiersEqual($0, current)
           }), !(ownership.pending.map { profileIdentifiersEqual($0, baseline) } == true
                  && profileIdentifiersEqual(current, baseline)) {
            let decision = AutomationDecision(baseline: baseline, applied: current, token: token)
            try saveOwnership(decision: decision)
            return decision
        }
        let decision = AutomationDecision(current: current, token: token)
        try saveOwnership(.inactive(token: token))
        return decision
    }

    func loadOwnership() throws -> AutomationOwnership? {
        let rulesLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(rulesLock) {} }
        return try loadOwnershipUnlocked()
    }

    private func loadOwnershipUnlocked() throws -> AutomationOwnership? {
        guard let ownership = try decodeOwnershipUnlocked(),
              let baseline = ownership.baseline,
              ownership.applied != nil || ownership.pending != nil else { return nil }
        return AutomationOwnership(
            baseline: baseline, applied: ownership.applied,
            pending: ownership.pending, token: ownership.token
        )
    }

    private func decodeOwnershipUnlocked() throws -> AutomationOwnership? {
        guard FileManager.default.fileExists(atPath: ownershipURL.path) else { return nil }
        let ownership = try JSONDecoder().decode(
            AutomationOwnership.self, from: Data(contentsOf: ownershipURL)
        )
        return normalizedOwnership(ownership)
    }

    func saveOwnership(decision: AutomationDecision) throws {
        try saveOwnership(ownership(for: decision))
    }

    private func ownership(for decision: AutomationDecision) -> AutomationOwnership {
        if decision.applied == nil {
            return .inactive(token: decision.token)
        }
        return AutomationOwnership(
                baseline: decision.baseline, applied: decision.applied,
                pending: nil, token: decision.token
        )
    }

    func saveOwnership(_ ownership: AutomationOwnership) throws {
        let switchLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("switch.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(switchLock) {} }
        let rulesLock = try FileLock(
            url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false
        )
        defer { withExtendedLifetime(rulesLock) {} }
        try prepareDirectory()
        let normalized = normalizedOwnership(ownership)
        let existing = try decodeOwnershipUnlocked()
        if existing == normalized || (existing?.isInactive ?? true) && normalized.isInactive {
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(normalized) + Data("\n".utf8), to: ownershipURL)
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: paths.configDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
    }

    private func fileError(_ operation: String) -> InzoneError {
        .message("\(operation): \(String(cString: strerror(errno)))")
    }

    static func statusLine(_ text: String) -> String {
        TerminalOutput.escaped(text, preservingNewlines: false) + "\n"
    }

    private func writeStatus(_ text: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data(Self.statusLine(text).utf8))
    }
}
