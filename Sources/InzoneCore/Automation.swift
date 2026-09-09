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

public struct AutomationDecision: Sendable {
    public private(set) var baseline: String
    public private(set) var applied: String?
    public private(set) var token: String
    public private(set) var group: [AutomationRule] = []
    public private(set) var hold = false
    private var candidate: [AutomationRule]?
    private var since: TimeInterval = 0

    public init(current: String, token: String) {
        baseline = current
        self.token = token
    }

    public mutating func step(group: [AutomationRule], current: String, token: String, now: TimeInterval) -> String? {
        if token != self.token || (applied != nil && current != applied) {
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
        return target == current ? nil : target
    }

    public mutating func committed(_ target: String) { applied = target }
}

nonisolated(unsafe) private var automationStopping: sig_atomic_t = 0
private func automationSignalHandler(_ signal: Int32) { automationStopping = 1 }

public struct AutomationStore {
    public static let unit = "inzone-profile-auto.service"
    public static let profiles = ["fps", "music", "voice", "balanced", "surround"]
    public let paths: InzonePaths
    public var fileURL: URL { paths.configDirectory.appendingPathComponent("auto-profiles.json") }

    public init(paths: InzonePaths) { self.paths = paths }

    public static func validate(_ rules: [AutomationRule]) throws -> [AutomationRule] {
        guard rules.count <= 128 else { throw InzoneError.message("At most 128 automatic profile rules are supported.") }
        var seen = Set<String>()
        for rule in rules {
            guard !rule.app.isEmpty, rule.app.unicodeScalars.count <= 1024,
                  !rule.app.unicodeScalars.contains(where: { $0.value < 32 }), seen.insert(rule.app).inserted else {
                throw InzoneError.message("Executable names or paths must be nonempty, unique strings without control characters.")
            }
            guard profiles.contains(rule.profile) else { throw InzoneError.message("Invalid automatic profile: \(rule.profile)") }
            guard (-1000...1000).contains(rule.priority) else { throw InzoneError.message("Automatic profile priority must be between -1000 and 1000.") }
        }
        return rules
    }

    public static func decode(_ data: Data) throws -> [AutomationRule] {
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
        return try validate(JSONDecoder().decode([AutomationRule].self, from: data))
    }

    public func load() throws -> [AutomationRule] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try Self.decode(Data(contentsOf: fileURL))
    }

    public func save(_ rules: [AutomationRule]) throws {
        let validated = try Self.validate(rules)
        try prepareDirectory()
        let objects = validated.map { ["app": $0.app, "profile": $0.profile, "priority": $0.priority] as [String: Any] }
        let text = try JSONSupport.encode(objects, pretty: true)
        try AtomicFile.write(Data((text + (text.hasSuffix("\n") ? "" : "\n")).utf8), to: fileURL)
    }

    public func edit(app: String, profile: String?, priority: Int = 0) throws {
        try prepareDirectory()
        let lock = try FileLock(url: paths.configDirectory.appendingPathComponent("auto-rules.lock"), nonblocking: false)
        defer { withExtendedLifetime(lock) {} }
        var rules = try load().filter { $0.app != app }
        if let profile { rules.append(AutomationRule(app: app, profile: profile, priority: priority)) }
        try save(rules)
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
        rules.enumerated().sorted {
            $0.element.priority == $1.element.priority ? $0.offset < $1.offset : $0.element.priority > $1.element.priority
        }.map(\.element).filter { names.contains($0.app) }
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
            if first.lowercased().hasSuffix(".exe") {
                result.insert(first)
                result.insert(first.replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/").last ?? first)
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
        let current = try controller.status()
        var decision = AutomationDecision(current: current == "original" ? "restore" : current, token: manualToken())
        var retry: TimeInterval = 0
        var lastError: String?
        while automationStopping == 0 {
            do {
                let now = ProcessInfo.processInfo.systemUptime
                let group = Self.matching(try load(), names: Self.processNames())
                if let target = decision.step(group: group, current: try controller.status(), token: manualToken(), now: now),
                   now >= retry, try controller.isConnected() {
                    try controller.activate(target, automatic: true, autoToken: decision.token)
                    decision.committed(target)
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
           try controller.status() == applied, decision.baseline != applied {
            try controller.activate(decision.baseline, automatic: true, autoToken: decision.token)
        }
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
