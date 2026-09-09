import Dispatch
import Foundation
import Glibc
import XCTest
@testable import InzoneCore

final class AutomationTests: XCTestCase {
    func testDebouncePriorityAndBaselineRestore() {
        var decision = AutomationDecision(current: "music", token: "0")
        let low = [AutomationRule(app: "game", profile: "fps", priority: 1)]
        let high = [AutomationRule(app: "chat", profile: "voice", priority: 2)] + low
        XCTAssertNil(decision.step(group: low, current: "music", token: "0", now: 0))
        XCTAssertNil(decision.step(group: low, current: "music", token: "0", now: 1.9))
        XCTAssertEqual(decision.step(group: low, current: "music", token: "0", now: 2), "fps")
        decision.committed("fps")
        XCTAssertNil(decision.step(group: high, current: "fps", token: "0", now: 3))
        XCTAssertEqual(decision.step(group: high, current: "fps", token: "0", now: 5), "voice")
        decision.committed("voice")
        XCTAssertNil(decision.step(group: [], current: "voice", token: "0", now: 6))
        XCTAssertEqual(decision.step(group: [], current: "voice", token: "0", now: 8), "music")
    }

    func testManualChoiceSurvivesSameGameAndStop() {
        var decision = AutomationDecision(current: "music", token: "0")
        let group = [AutomationRule(app: "game", profile: "fps", priority: 1)]
        _ = decision.step(group: group, current: "music", token: "0", now: 0)
        _ = decision.step(group: group, current: "music", token: "0", now: 2)
        decision.committed("fps")
        XCTAssertNil(decision.step(group: group, current: "balanced", token: "1", now: 3))
        XCTAssertNil(decision.step(group: group, current: "balanced", token: "1", now: 30))
        XCTAssertNil(decision.applied)
        _ = decision.step(group: [], current: "balanced", token: "1", now: 31)
        XCTAssertNil(decision.step(group: [], current: "balanced", token: "1", now: 33))
        XCTAssertEqual(decision.baseline, "balanced")
    }

    func testManualSameProfileAndInterruptedDebounceStillOverride() {
        let group = [AutomationRule(app: "game", profile: "fps", priority: 1)]
        var decision = AutomationDecision(current: "music", token: "0")
        _ = decision.step(group: group, current: "music", token: "0", now: 0)
        _ = decision.step(group: group, current: "music", token: "0", now: 2)
        decision.committed("fps")
        _ = decision.step(group: group, current: "fps", token: "1", now: 3)
        XCTAssertTrue(decision.hold)
        XCTAssertEqual(decision.baseline, "fps")
        var interrupted = AutomationDecision(current: "music", token: "0")
        _ = interrupted.step(group: group, current: "music", token: "0", now: 0)
        _ = interrupted.step(group: group, current: "voice", token: "1", now: 1)
        XCTAssertNil(interrupted.step(group: group, current: "voice", token: "1", now: 20))
        XCTAssertEqual(interrupted.baseline, "voice")
    }

    func testExactMatchingAndStablePriority() throws {
        let rules = [AutomationRule(app: "a", profile: "fps", priority: 1),
                     AutomationRule(app: "b", profile: "voice", priority: 2),
                     AutomationRule(app: "c", profile: "surround", priority: 2)]
        XCTAssertEqual(AutomationStore.matching(try AutomationStore.validate(rules), names: ["a", "b", "c", "aaa"]).map(\.app), ["b", "c", "a"])
        XCTAssertTrue(AutomationStore.matching(rules, names: ["aaa"]).isEmpty)
    }

    func testWindowsMatchingNormalizesCaseAndSlashStyleButNativeMatchingRemainsExact() throws {
        let rules = [
            AutomationRule(app: #"C:\Games\MATCH.EXE"#, profile: "fps", priority: 2),
            AutomationRule(app: "NativeGame", profile: "music", priority: 1),
        ]

        XCTAssertEqual(
            AutomationStore.matching(rules, names: ["c:/games/match.exe", "nativegame"]).map(\.app),
            [#"C:\Games\MATCH.EXE"#]
        )
        XCTAssertEqual(
            AutomationStore.matching(rules, names: ["MATCH.EXE", "NativeGame"]).map(\.app),
            ["NativeGame"]
        )
        XCTAssertThrowsError(try AutomationStore.validate([
            AutomationRule(app: #"C:\Games\MATCH.EXE"#, profile: "fps"),
            AutomationRule(app: "c:/games/match.exe", profile: "music"),
        ]))
    }

    func testNativeAndWineIdentityExcludesOtherArguments() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = directory.appendingPathComponent("123")
        try FileManager.default.createDirectory(at: process, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: process.appendingPathComponent("exe").path, withDestinationPath: "/usr/bin/wine-preloader")
        try Data("C:\\Games\\match.exe\0other.exe\0".utf8).write(to: process.appendingPathComponent("cmdline"))
        let names = AutomationStore.processNames(procDirectory: directory)
        XCTAssertTrue(names.contains("match.exe"))
        XCTAssertTrue(names.contains("wine-preloader"))
        XCTAssertTrue(names.contains("/usr/bin/wine-preloader"))
        XCTAssertFalse(names.contains("other.exe"))
        XCTAssertTrue(AutomationStore.processNames(procDirectory: directory, uid: getuid() + 1).isEmpty)
    }

    func testRuleSchemaRejectsInvalidAndAmbiguousValues() throws {
        for text in [
            #"[{"app":"a","profile":"unknown","priority":0}]"#,
            #"[{"app":"a","profile":"FPS","priority":0}]"#,
            #"[{"app":"a","profile":"music","priority":true}]"#,
            #"[{"app":"a","profile":"music","priority":0.5}]"#,
            #"[{"app":"a","profile":"music","priority":1.0}]"#,
            #"[{"app":"a","profile":"music","priority":0,"extra":0}]"#,
            #"[{"app":"a","profile":"music","priority":0},{"app":"a","profile":"fps","priority":1}]"#,
            #"[{"app":"a\nb","profile":"music","priority":0}]"#,
            #"[{"app":"","profile":"music","priority":0}]"#,
            #"[{"app":"a","profile":"restore","priority":0}]"#,
            #"[{"app":"a","profile":"music","priority":1001}]"#,
            #"{}"#,
        ] {
            XCTAssertThrowsError(try AutomationStore.decode(Data(text.utf8)), text)
        }
        XCTAssertEqual(try AutomationStore.decode(Data(#"[{"app":"a","profile":"music","priority":1}]"#.utf8)),
                       [AutomationRule(app: "a", profile: "music", priority: 1)])
    }

    func testPublicDecodeAcceptsAndCanonicalizesCustomUUIDWithoutStorePaths() throws {
        let uppercase = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let lowercase = uppercase.lowercased()
        let data = Data("[{\"app\":\"game\",\"profile\":\"\(uppercase)\",\"priority\":1}]".utf8)

        XCTAssertEqual(
            try AutomationStore.decode(data),
            [AutomationRule(app: "game", profile: lowercase, priority: 1)]
        )
        XCTAssertEqual(
            try AutomationStore.validate(
                [AutomationRule(app: "game", profile: uppercase)],
                availableProfiles: [lowercase]
            ).first?.profile,
            lowercase
        )
    }

    func testStoreEditsPreserveOrderAndPrivateAtomicState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(paths: InzonePaths(home: directory))
        XCTAssertTrue(try store.load().isEmpty)
        try store.edit(app: "game", profile: "fps", priority: 2)
        try store.edit(app: "chat", profile: "voice")
        try store.edit(app: "game", profile: "balanced", priority: 3)
        XCTAssertEqual(try store.load().map(\.app), ["chat", "game"])
        XCTAssertEqual(try store.load().last?.profile, "balanced")
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.edit(app: "bad", profile: "restore"))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
        try store.edit(app: "chat", profile: nil)
        XCTAssertEqual(try store.load().count, 1)
        let permissions = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(store.manualToken(), "")
        try store.markManual()
        let token = store.manualToken()
        XCTAssertFalse(token.isEmpty)
        try store.markManual()
        XCTAssertNotEqual(store.manualToken(), token)
    }

    func testStoreAcceptsStableCustomProfileIdentifiersAcrossRename() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = InzonePaths(home: directory)
        let profiles = SoundProfileStore(paths: paths)
        let base = try SettingsStore(paths: paths).resolvedProfile("balanced")
        let profile = try profiles.create(name: "Game", basedOn: base)
        let automation = AutomationStore(paths: paths)

        try automation.edit(app: "game", profile: profile.identifier, priority: 9)
        try profiles.rename(profile.identifier, to: "Renamed")

        XCTAssertEqual(try automation.load().first?.profile, profile.identifier)
        XCTAssertTrue(try automation.references(profile: profile.identifier.uppercased()))
    }

    func testReferencedProfileIdentifiersIncludeRulesAndCrashSafeWatcherOwnership() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(paths: InzonePaths(home: directory))
        let baseline = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let applied = "11111111-2222-4333-8444-555555555555"
        let pending = "66666666-7777-4888-8999-AAAAAAAAAAAA"
        try store.save([AutomationRule(app: "game", profile: "fps")])
        try store.saveOwnership(AutomationOwnership(
            baseline: baseline, applied: applied, pending: pending, token: "token"
        ))

        XCTAssertEqual(try store.referencedProfileIdentifiers(), [
            "fps", baseline.lowercased(), applied.lowercased(), pending.lowercased(),
        ])
        XCTAssertTrue(try store.references(profile: baseline.lowercased()))
        XCTAssertTrue(try store.references(profile: applied.uppercased()))

        try store.saveOwnership(.inactive(token: "token"))
        XCTAssertEqual(try store.referencedProfileIdentifiers(), ["fps"])
    }

    func testWatcherResumesAppliedOrPendingOwnershipAndClearsCompletedRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(paths: InzonePaths(home: directory))
        let baseline = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let applied = "11111111-2222-4333-8444-555555555555"
        let pending = "66666666-7777-4888-8999-aaaaaaaaaaaa"
        try store.saveOwnership(AutomationOwnership(
            baseline: baseline, applied: applied, pending: pending, token: "token"
        ))

        let resumed = try store.resumedDecision(current: pending.uppercased(), token: "token")
        XCTAssertEqual(resumed.baseline, baseline)
        XCTAssertEqual(resumed.applied, pending)
        XCTAssertEqual(try store.loadOwnership()?.applied, pending)
        XCTAssertNil(try store.loadOwnership()?.pending)

        try store.saveOwnership(AutomationOwnership(
            baseline: baseline, applied: applied, pending: baseline, token: "token"
        ))
        let restored = try store.resumedDecision(current: baseline.uppercased(), token: "token")
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertNil(restored.applied)
        XCTAssertNil(try store.loadOwnership())
    }

    func testWatcherDiscardsOwnershipWhenManualTokenOrActiveProfileChanged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(paths: InzonePaths(home: directory))
        try store.saveOwnership(AutomationOwnership(
            baseline: "music", applied: "fps", pending: nil, token: "old"
        ))

        let decision = try store.resumedDecision(current: "balanced", token: "new")
        XCTAssertEqual(decision.baseline, "balanced")
        XCTAssertNil(decision.applied)
        XCTAssertNil(try store.loadOwnership())
    }

    func testUnchangedWatcherOwnershipDoesNotReplaceTheStateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(paths: InzonePaths(home: directory))
        let applied = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
        let ownership = AutomationOwnership(
            baseline: "music", applied: applied, pending: nil, token: "token"
        )
        try store.saveOwnership(ownership)
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: store.ownershipURL.path)
        let before = beforeAttributes[.systemFileNumber] as? NSNumber

        try store.saveOwnership(ownership)
        let unchangedAttributes = try FileManager.default.attributesOfItem(atPath: store.ownershipURL.path)
        let unchanged = unchangedAttributes[.systemFileNumber] as? NSNumber
        XCTAssertEqual(unchanged, before)

        try store.saveOwnership(AutomationOwnership(
            baseline: "music", applied: "fps", pending: nil, token: "token"
        ))
        let changedAttributes = try FileManager.default.attributesOfItem(atPath: store.ownershipURL.path)
        let changed = changedAttributes[.systemFileNumber] as? NSNumber
        XCTAssertNotEqual(changed, before)
    }

    func testEditCanRemoveAStaleRuleAfterItsProfileDisappears() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationStore(paths: InzonePaths(home: directory))
        try FileManager.default.createDirectory(at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"[{"app":"game","profile":"00000000-0000-0000-0000-000000000001","priority":0}]"#.utf8)
            .write(to: store.fileURL)

        XCTAssertThrowsError(try store.load())
        try store.edit(app: "game", profile: nil)
        XCTAssertTrue(try store.load().isEmpty)
    }

    func testRuleEditUsesTheProfileSwitchTransactionLock() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = InzonePaths(home: directory)
        let store = AutomationStore(paths: paths)
        var switchLock: FileLock? = try FileLock(
            url: paths.configDirectory.appendingPathComponent("switch.lock"), nonblocking: false
        )
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            try? store.edit(app: "game", profile: "fps")
            finished.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(finished.wait(timeout: .now() + 0.05), .timedOut)
        switchLock = nil
        XCTAssertNil(switchLock)
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(try store.load().first?.profile, "fps")
    }

    func testServiceActionsUseOnlyExpectedSystemdUnit() throws {
        let runner = AutomationRunner()
        let store = AutomationStore(paths: InzonePaths(home: URL(fileURLWithPath: "/tmp")))
        try store.service("enable", runner: runner)
        XCTAssertEqual(runner.calls, [["systemctl", "--user", "daemon-reload"],
                                      ["systemctl", "--user", "enable", "--now", "inzone-profile-auto.service"]])
        XCTAssertThrowsError(try store.service("restart", runner: runner))
        XCTAssertEqual(runner.calls.count, 2)
    }

    func testWatcherStatusEscapesUntrustedControlsAndAppendsOneLineFeed() {
        let message = "Automatic profile waiting: bad\u{0000}\u{001B}\u{007F}\u{0085}\u{202E}\u{2028}\u{2029}\nerror"
        let line = AutomationStore.statusLine(message)

        XCTAssertEqual(
            line,
            "Automatic profile waiting: bad\\u{0000}\\u{001B}\\u{007F}\\u{0085}\\u{202E}\\u{2028}\\u{2029}\\u{000A}error\n"
        )
        XCTAssertEqual(line.unicodeScalars.filter { $0.value == 0x0A }.count, 1)
    }
}

private final class AutomationRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
    func run(_ arguments: [String], input: Data?, timeout: TimeInterval) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(arguments)
        return ""
    }
}
