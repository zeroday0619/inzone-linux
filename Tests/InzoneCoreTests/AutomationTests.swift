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
