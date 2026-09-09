import Testing
import SwiftTUI
@testable import InzoneTUI

@MainActor
struct TerminalTests {
    private func press(_ model: TerminalModel, _ character: String) {
        _ = model.handle(KeyPress(key: KeyEquivalent(Character(character)), characters: character), terminate: {})
    }

    private func press(_ model: TerminalModel, key: KeyEquivalent) {
        _ = model.handle(KeyPress(key: key, characters: ""), terminate: {})
    }

    @Test func initialScreenRendersWithoutDeviceAccess() {
        let screen = InzoneTerminal.preview()
        for label in ["INZONE H9 II", "FPS", "음악", "통화", "서라운드", "D: DRC", "E: EQ", "H: 장치", "U: 자동", "Q / Esc"] {
            #expect(screen.contains(label))
        }
        #expect(screen.split(separator: "\n", omittingEmptySubsequences: false).count == 24)
    }

    @Test func narrowScreenPreservesExitInstruction() {
        let screen = InzoneTerminal.preview(columns: 60, rows: 18)
        #expect(screen.contains("72열 × 24행"))
        #expect(screen.contains("Q / Esc: 종료"))
    }

    @Test func terminalControlCharactersAreSanitized() {
        #expect(terminalText("안녕\u{1b}[2J\n\u{009b}\u{202e}abc") == "안녕 [2J   abc")
        #expect(terminalText("e\u{301} 한글") == "e\u{301} 한글")
    }

    @Test func profileSelectionWrapsAndAcceptsUppercaseShortcuts() {
        let model = TerminalModel()
        press(model, key: .upArrow)
        #expect(model.selected == 5)
        press(model, "J")
        #expect(model.selected == 0)
        press(model, "5")
        #expect(model.profile == "surround")
        press(model, "E")
        #expect(model.screen == .equalizer)
        press(model, key: .escape)
        #expect(model.screen == .profiles)
        press(model, "S")
        #expect(model.screen == .presets)
    }

    @Test func equalizerBoundsAndCancellationPreserveProfile() {
        let model = TerminalModel()
        press(model, "E")
        for _ in 0..<20 { press(model, key: .rightArrow) }
        #expect(model.equalizer[0] == 12)
        for _ in 0..<30 { press(model, key: .leftArrow) }
        #expect(model.equalizer[0] == -12)
        press(model, "0")
        #expect(model.equalizer == Array(repeating: 0, count: 10))
        press(model, key: .upArrow)
        #expect(model.equalizerIndex == 9)
        press(model, "Q")
        #expect(model.screen == .profiles)
        #expect(model.profile == "fps")
    }

    @Test func restoreRejectsDSPAndPromptDoesNotConsumeTextShortcuts() {
        let model = TerminalModel()
        press(model, "6")
        press(model, "D")
        #expect(model.screen == .profiles)
        #expect(model.message.contains("프로파일"))
        press(model, "I")
        #expect(model.screen == .prompt)
        var terminated = false
        let result = model.handle(KeyPress(key: "q", characters: "q"), terminate: { terminated = true })
        #expect(result == .ignored)
        #expect(!terminated)
        model.promptText = "/tmp/personal.hki"
        model.submitPrompt()
        #expect(model.promptTitle.contains("YY2987.ba"))
        press(model, key: .escape)
        #expect(model.screen == .profiles)
    }

    @Test func automationPromptValidatesProfileAndPriority() {
        let model = TerminalModel()
        press(model, "U")
        press(model, "A")
        model.promptText = "game.exe"
        model.submitPrompt()
        model.promptText = "restore"
        model.submitPrompt()
        #expect(model.screen == .prompt)
        #expect(model.message.contains("대상"))
        model.promptText = "fps"
        model.submitPrompt()
        model.promptText = "1001"
        model.submitPrompt()
        #expect(model.screen == .prompt)
        model.promptText = ""
        model.submitPrompt()
        #expect(model.screen == .automation)
    }

    @Test func terminationDoesNotInterruptAnActiveMutation() {
        let model = TerminalModel()
        var terminated = false
        model.busy = true
        model.requestTermination { terminated = true }
        #expect(!terminated)
        #expect(model.message.contains("작업을 마친 후"))
        model.busy = false
        model.requestTermination { terminated = true }
        #expect(terminated)
    }
}
