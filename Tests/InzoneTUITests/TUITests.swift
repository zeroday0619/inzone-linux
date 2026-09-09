import Testing
import SwiftTUI
import InzoneCore
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
        for label in ["INZONE H9 II", "FPS", "Music", "Voice", "Surround", "Restore Defaults", "Controls", "Compact", "Apply", "Quit"] {
            #expect(screen.contains(label))
        }
        #expect(screen.split(separator: "\n", omittingEmptySubsequences: false).count == 24)
    }

    @Test func narrowScreenPreservesExitInstruction() {
        let screen = InzoneTerminal.preview(columns: 60, rows: 18)
        #expect(screen.contains("72 columns × 24 rows"))
        #expect(screen.contains("Q / Esc: Quit"))
    }

    @Test func minimumViewportPreservesMouseControlsOnEveryScreen() {
        let model = TerminalModel()
        let screens: [(TerminalScreen, [String])] = [
            (.profiles, ["Apply", "Quit", "I: Import", "↑↓ Select", "Q / Esc"]),
            (.profileManager, ["C: Create", "O: Duplicate", "I: Import", "W: Replace", "X: Export", "Back"]),
            (.equalizer, ["16k", "−", "+", "Save & Apply", "Cancel"]),
            (.presets, ["Apply preset", "Cancel"]),
            (.device, ["Apply", "R: Refresh", "T: Test microphone", "Back"]),
            (.automation, ["A: Add/Edit", "D: Delete", "Start automation", "Back"]),
            (.automationProfilePicker, ["Application:", "Select", "Cancel"]),
            (.prompt, ["Continue", "Cancel"]),
        ]
        for (screen, labels) in screens {
            model.screen = screen
            let rendered = ViewRenderer.render(TerminalRoot(model: model, touchOptimized: false).frame(width: 72, height: 24),
                proposedSize: ProposedViewSize(columns: 72, rows: 24))
            for label in labels { #expect(rendered.text.contains(label), "\(screen): missing \(label)") }
            #expect(rendered.text.split(separator: "\n", omittingEmptySubsequences: false).count == 24)
        }
    }

    @Test func minimumTouchViewportPreservesActionsOnEveryScreen() {
        let model = TerminalModel()
        let screens: [(TerminalScreen, [String])] = [
            (.profiles, ["Restore Defaults", "Controls", "Apply", "Quit"]),
            (.profileManager, ["Previous", "Next", "Create", "Import", "Replace", "Export", "Retry", "Back"]),
            (.equalizer, ["− 1 dB", "+ 1 dB", "‹", "›", "Save & Apply", "Reset all", "Cancel"]),
            (.presets, ["Previous", "Next", "Apply preset", "Cancel"]),
            (.device, ["Noise", "Sound", "Mic", "System", "Info", "Discard", "Apply", "Refresh", "Back"]),
            (.automation, ["No automation rules", "Add rule", "Start", "Back"]),
            (.automationProfilePicker, ["Application:", "Previous page", "Next page", "Select", "Cancel"]),
            (.prompt, ["Continue", "Cancel"]),
        ]
        for (screen, labels) in screens {
            model.screen = screen
            let rendered = touchScreen(model)
            for label in labels + ["Compact"] {
                #expect(rendered.contains(label), "\(screen): missing \(label)")
            }
        }
    }

    @Test func everyScreenKeepsHeaderAndFooterAtViewportEdges() {
        for touchOptimized in [false, true] {
            for (columns, rows) in [(72, 24), (80, 30), (120, 36)] {
                let model = TerminalModel()
                model.message = "Ready for the next action."
                let screens: [(TerminalScreen, String)] = [
                    (.profiles, "INZONE H9 II / Profiles"),
                    (.profileManager, "Sound Profile Collection"),
                    (.equalizer, "10-band EQ / \(model.title)"),
                    (.presets, "Sony EQ Presets / \(model.title)"),
                    (.device, "INZONE H9 II / Device Settings"),
                    (.automation, "Auto Profiles / Stopped"),
                    (.automationProfilePicker, "Choose Automation Profile"),
                    (.prompt, "INZONE H9 II / Input"),
                ]
                for (screen, title) in screens {
                    model.screen = screen
                    let status = screen == .equalizer
                        ? "Unsaved EQ draft · Save & Apply commits changes."
                        : model.message
                    let rendered = ViewRenderer.render(
                        TerminalRoot(model: model, touchOptimized: touchOptimized).frame(width: columns, height: rows),
                        proposedSize: ProposedViewSize(columns: columns, rows: rows))
                    let lines = rendered.text.split(separator: "\n", omittingEmptySubsequences: false)
                    #expect(lines.count == rows)
                    guard lines.count == rows else { continue }
                    #expect(lines[1].contains(title), "\(columns)x\(rows) \(screen): header moved")
                    #expect(lines[3].allSatisfy { $0.isWhitespace }, "\(screen): missing space below header")
                    #expect(lines[rows - 3].allSatisfy { $0.isWhitespace }, "\(screen): missing space above footer")
                    #expect(!lines[rows - 2].contains("STATUS"))
                    #expect(lines[rows - 2].contains(status))
                    #expect(lines[rows - 1].contains("Esc"), "\(columns)x\(rows) \(screen): shortcuts moved")
                    #expect(lines.filter { $0.contains(status) }.count == 1)
                    for line in lines {
                        #expect(RunGroup(String(line)).measure().maximumContentColumns <= columns)
                    }
                }
            }
        }
    }

    @Test func sharedFooterShowsBusyStatusOnEveryScreen() {
        for touchOptimized in [false, true] {
            let model = TerminalModel()
            model.busy = true
            model.message = "Applying device settings..."
            for screen in [TerminalScreen.profiles, .profileManager, .equalizer, .presets, .device, .automation, .automationProfilePicker, .prompt] {
                model.screen = screen
                let rendered = ViewRenderer.render(
                    TerminalRoot(model: model, touchOptimized: touchOptimized).frame(width: 72, height: 24),
                    proposedSize: ProposedViewSize(columns: 72, rows: 24))
                let lines = rendered.text.split(separator: "\n", omittingEmptySubsequences: false)
                #expect(lines.count == 24)
                guard lines.count == 24 else { continue }
                #expect(lines[22].contains("Working"))
                #expect(lines[22].contains(model.message))
                #expect(lines[23].contains("Esc"))
            }
        }
    }

    @Test func sharedHeaderReflectsProfileControlsAndAutomationState() {
        let model = TerminalModel()
        model.showsProfileControls = true
        let controls = touchScreen(model).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(controls[1].contains("INZONE H9 II / Controls"))
        model.showsProfileControls = false
        let profiles = touchScreen(model).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(profiles[1].contains("INZONE H9 II / Profiles"))
        model.screen = .automation
        let automation = touchScreen(model).split(separator: "\n", omittingEmptySubsequences: false)
        #expect(automation[1].contains("Auto Profiles / Stopped"))
    }

    @Test func everySelectedProfileRetainsItsFullTitleAtMinimumTouchSize() {
        let model = TerminalModel()
        for (index, title) in ["FPS", "Music", "Voice", "Balanced", "Surround", "Restore Defaults"].enumerated() {
            model.selectRow(index)
            let rendered = touchScreen(model)
            #expect(rendered.contains(title))
            #expect(!rendered.contains("\(index + 1)  \(title)"))
            #expect(!rendered.contains("Active"))
            for action in ["Apply", "Controls", "Quit"] {
                #expect(rendered.contains(action))
            }
        }
    }

    @Test func controlsEscapeReturnsToProfilesBeforeTerminating() {
        let model = TerminalModel()
        model.selectRow(1)
        model.showsProfileControls = true
        let rendered = touchScreen(model)
        for label in ["Dynamic range", "Output leveling", "Microphone gain", "Equalizer", "Presets", "Device & apps", "Back"] {
            #expect(rendered.contains(label))
        }
        #expect(rendered.contains("Changes apply immediately to Music."))
        var terminated = false
        model.showsSystemControls = true
        let systemControls = touchScreen(model)
        for label in ["Device", "Automation", "Personal HRTF import", "Manage sound profiles", "Back"] {
            #expect(systemControls.contains(label))
        }
        _ = model.handle(KeyPress(key: .escape, characters: ""), terminate: { terminated = true })
        #expect(!terminated)
        #expect(!model.showsSystemControls)
        #expect(model.showsProfileControls)
        _ = model.handle(KeyPress(key: .escape, characters: ""), terminate: { terminated = true })
        #expect(!terminated)
        #expect(!model.showsProfileControls)
        #expect(model.screen == .profiles)
        #expect(model.profile == "music")
        _ = model.handle(KeyPress(key: .escape, characters: ""), terminate: { terminated = true })
        #expect(terminated)
    }

    @Test func everyPresetRemainsReachableWithActionsAtMinimumTouchSize() {
        let model = TerminalModel()
        model.screen = .presets
        for (index, name) in SonyPresets.names.enumerated() {
            model.selectRow(index)
            let rendered = touchScreen(model)
            #expect(rendered.contains("\(SonyPresets.labels[name] ?? name)"))
            #expect(rendered.contains("Sony presets replace tone EQ."))
            for label in ["Previous", "Next", "Apply preset", "Cancel"] {
                #expect(rendered.contains(label), "Preset \(name): missing \(label)")
            }
        }
    }

    @Test func everyEqualizerBandRetainsItsValueAndActionsAtMinimumTouchSize() {
        let model = TerminalModel()
        model.screen = .equalizer
        let frequencies = ["31.5", "63", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
        for (index, frequency) in frequencies.enumerated() {
            model.selectRow(index)
            let rendered = touchScreen(model)
            #expect(rendered.contains("\(frequency) Hz"))
            #expect(rendered.contains("+12"))
            #expect(rendered.contains("−12"))
            #expect(!rendered.contains("Band \(index + 1) of 10"))
            for label in ["− 1 dB", "+ 1 dB", "‹", "›", "Save & Apply", "Cancel"] {
                #expect(rendered.contains(label), "Band \(index + 1): missing \(label)")
            }
        }
    }

    private func touchScreen(_ model: TerminalModel) -> String {
        let rendered = ViewRenderer.render(TerminalRoot(model: model).frame(width: 72, height: 24),
            proposedSize: ProposedViewSize(columns: 72, rows: 24))
        let lines = rendered.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 24)
        for line in lines {
            #expect(RunGroup(String(line)).measure().maximumContentColumns <= 72)
        }
        return rendered.text
    }

    @Test func pointerSelectionRejectsInvalidRowsAndBusyChanges() {
        let model = TerminalModel()
        model.selectRow(4)
        #expect(model.profile == "surround")
        model.selectRow(-1)
        model.selectRow(6)
        #expect(model.profile == "surround")
        model.busy = true
        model.selectRow(0)
        #expect(model.profile == "surround")
        model.busy = false
        press(model, "E")
        model.adjustEqualizer(9, by: 100)
        #expect(model.equalizerIndex == 9)
        #expect(model.equalizer[9] == 12)
        model.adjustEqualizer(9, by: -100)
        #expect(model.equalizer[9] == -12)
        model.adjustEqualizer(10, by: 1)
        model.busy = true
        model.adjustEqualizer(0, by: 1)
        #expect(model.equalizer[0] == 0)
        #expect(model.equalizerIndex == 9)
    }

    @Test func promptMouseCancellationReturnsToOriginAndHonorsBusyState() {
        let model = TerminalModel()
        press(model, "U")
        press(model, "A")
        model.busy = true
        model.cancelPrompt()
        model.submitPrompt()
        #expect(model.screen == .prompt)
        model.busy = false
        model.cancelPrompt()
        #expect(model.screen == .automation)
    }

    @Test func terminalControlCharactersAreSanitized() {
        #expect(terminalText("\u{C548}\u{B155}\u{1b}[2J\n\u{009b}\u{202e}abc") == "\u{C548}\u{B155} [2J   abc")
        #expect(terminalText("e\u{301} \u{D55C}\u{AE00}") == "e\u{301} \u{D55C}\u{AE00}")
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
        #expect(model.message.contains("profile"))
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
        #expect(model.screen == .automationProfilePicker)
        _ = model.handle(KeyPress(key: .return, characters: ""), terminate: {})
        #expect(model.automationTargetIdentifier == "fps")
        model.promptText = "1001"
        model.submitPrompt()
        #expect(model.screen == .prompt)
        model.promptText = ""
        model.submitPrompt()
        #expect(model.screen == .automation)
    }

    @Test func automationRuleDeletionRequiresExplicitConfirmation() {
        let model = TerminalModel()
        model.screen = .automation
        model.setPreviewAutomationRule(app: "game.exe", profile: "FPS", priority: 10)
        press(model, "d")
        #expect(model.screen == .prompt)
        #expect(model.promptActionTitle == "Confirm")
        #expect(model.promptTitle.contains("game.exe"))
        model.promptText = "wrong"
        model.submitPrompt()
        #expect(model.screen == .prompt)
        #expect(model.message.contains("DELETE"))
    }

    @Test func terminationDoesNotInterruptAnActiveMutation() {
        let model = TerminalModel()
        var terminated = false
        model.busy = true
        model.requestTermination { terminated = true }
        #expect(!terminated)
        #expect(model.message.contains("after completing the current task"))
        model.busy = false
        model.requestTermination { terminated = true }
        #expect(terminated)
    }

    @Test func workspaceNavigationPreservesSelectionAndHonorsEditorBoundaries() {
        let model = TerminalModel()
        model.selectRow(4)
        model.navigate(to: .automation)
        #expect(model.screen == .automation)
        model.navigate(to: .profiles)
        #expect(model.screen == .profiles)
        #expect(model.profile == "surround")

        for editor in [TerminalScreen.equalizer, .presets, .prompt] {
            model.navigate(to: editor)
            #expect(model.screen == .profiles)
            model.screen = editor
            for destination in [TerminalScreen.profiles, .device, .automation] {
                model.navigate(to: destination)
                #expect(model.screen == editor)
            }
            model.screen = .profiles
        }

        model.busy = true
        model.navigate(to: .automation)
        #expect(model.screen == .profiles)
        model.screen = .automation
        model.navigate(to: .profiles)
        #expect(model.screen == .automation)
    }

    @Test func restoreSelectionDisablesProfileEditing() {
        let model = TerminalModel()
        #expect(model.canEditProfile)
        model.selectRow(5)
        #expect(!model.canEditProfile)
        model.selectRow(0)
        #expect(model.canEditProfile)
    }

    @Test func wideWorkspacePreservesNavigationAndActionsOnEveryScreen() {
        let screens: [(TerminalScreen, [String])] = [
            (.profiles, ["Profiles", "Restore Defaults", "Controls", "Apply", "Quit"]),
            (.profileManager, ["Sound Profile Collection", "Previous", "Next", "Create", "Import", "Replace", "Retry", "Back"]),
            (.equalizer, ["− 1 dB", "+ 1 dB", "Save & Apply", "Reset all", "Cancel"]),
            (.presets, ["Previous", "Next", "Apply preset", "Cancel"]),
            (.device, ["Device", "Noise", "Sound", "Mic", "System", "Info", "Discard", "Apply", "Refresh", "Back"]),
            (.automation, ["Automation", "No automation rules", "Add rule", "Start", "Back"]),
            (.automationProfilePicker, ["Choose Automation Profile", "Application:", "Previous page", "Next page", "Select", "Cancel"]),
            (.prompt, ["Continue", "Cancel"]),
        ]
        for (columns, rows) in [(110, 24), (120, 36)] {
            let model = TerminalModel()
            for (screen, labels) in screens {
                model.screen = screen
                let rendered = ViewRenderer.render(
                    TerminalRoot(model: model).frame(width: columns, height: rows),
                    proposedSize: ProposedViewSize(columns: columns, rows: rows))
                for label in labels + ["Browse", "Compact", "Esc"] {
                    #expect(rendered.text.contains(label), "\(columns)x\(rows) \(screen): missing \(label)")
                }
                #expect(!rendered.text.contains("WORKSPACE"))
                #expect(!rendered.text.contains("SELECTED PROFILE"))
                let lines = rendered.text.split(separator: "\n", omittingEmptySubsequences: false)
                #expect(lines.count == rows)
                for line in lines {
                    #expect(RunGroup(String(line)).measure().maximumContentColumns <= columns)
                }
            }
        }
    }

    @Test func actionStatesHaveDistinctStylingAndPreserveTouchDimensions() {
        let normal = ViewRenderer.render(TerminalAction(title: "Apply", width: 20, action: {}))
        let selected = ViewRenderer.render(TerminalAction(title: "Apply", width: 20, selected: true, action: {}))
        let disabled = ViewRenderer.render(TerminalAction(title: "Apply", width: 20, enabled: false, action: {}))
        let destructive = ViewRenderer.render(TerminalAction(title: "Apply", width: 20, role: .destructive, action: {}))
        #expect(normal.text.contains("Apply"))
        #expect(selected.text == normal.text)
        #expect(normal.ansiText != selected.ansiText)
        #expect(normal.text == disabled.text)
        #expect(normal.text == destructive.text)
        #expect(normal.ansiText != disabled.ansiText)
        #expect(normal.ansiText != destructive.ansiText)
        for rendered in [normal, selected, disabled, destructive] {
            #expect(!rendered.text.contains("["))
            #expect(!rendered.text.contains("]"))
            #expect(!rendered.text.contains(">"))
            let lines = rendered.text.split(separator: "\n", omittingEmptySubsequences: false)
            #expect(lines.count == 3)
            for line in lines { #expect(RunGroup(String(line)).measure().maximumContentColumns == 20) }
        }
    }

    @Test func interfaceUsesStylingWithoutDecorativeTextMarkers() {
        for touchOptimized in [false, true] {
            for screen in [TerminalScreen.profiles, .profileManager, .equalizer, .presets, .device, .automation, .automationProfilePicker, .prompt] {
                let model = TerminalModel()
                model.screen = screen
                let rendered = ViewRenderer.render(
                    TerminalRoot(model: model, touchOptimized: touchOptimized).frame(width: 120, height: 36),
                    proposedSize: ProposedViewSize(columns: 120, rows: 36))
                for marker in ["[", "]", ">"] {
                    #expect(!rendered.text.contains(marker), "\(screen): decorative \(marker)")
                }
                #expect(!rendered.text.contains("Active"))
                #expect(!rendered.text.contains("ACTIVE PROFILE"))
                for (index, title) in ["FPS", "Music", "Voice", "Balanced", "Surround", "Restore Defaults"].enumerated() {
                    #expect(!rendered.text.contains("\(index + 1)  \(title)"))
                }
                if screen == .prompt { #expect(rendered.text.contains("Value")) }
            }
        }
        let literal = ViewRenderer.render(TerminalAction(title: "Preset [custom] > default", width: 40, action: {}))
        #expect(literal.text.contains("Preset [custom] > default"))
    }
}
