import Foundation
import Testing
import SwiftTUI
import InzoneCore
@testable import InzoneTUI

@MainActor
struct ProfileManagementTests {
    private let builtIns = [
        TerminalProfilePreview(identifier: "fps", title: "FPS", templateProfile: "fps", isBuiltIn: true),
        TerminalProfilePreview(identifier: "music", title: "Music", templateProfile: "music", isBuiltIn: true),
        TerminalProfilePreview(identifier: "voice", title: "Voice", templateProfile: "voice", isBuiltIn: true),
        TerminalProfilePreview(identifier: "balanced", title: "Balanced", templateProfile: "balanced", isBuiltIn: true),
        TerminalProfilePreview(identifier: "surround", title: "Surround", templateProfile: "surround", isBuiltIn: true),
    ]

    private func press(_ model: TerminalModel, _ character: String) {
        _ = model.handle(
            KeyPress(key: KeyEquivalent(Character(character)), characters: character), terminate: {}
        )
    }

    @Test func maximumCollectionPagesWithoutDroppingStableIdentifiers() {
        let custom = (0..<256).map {
            TerminalProfilePreview(
                identifier: String(format: "00000000-0000-4000-8000-%012d", $0),
                title: "Custom \($0)", templateProfile: $0.isMultiple(of: 2) ? "balanced" : "surround"
            )
        }
        let model = TerminalModel(previewProfiles: builtIns + custom)
        #expect(model.profileCount == 262)
        #expect(Set(model.profileIdentifiers).count == 262)
        #expect(!model.canCreateProfile)

        var visited = Set<String>()
        for index in 0..<model.profileCount {
            model.selectRow(index)
            visited.insert(model.profile)
            let page = model.profilePage(capacity: 6)
            #expect(page.contains { $0.0 == index })
            #expect(page.count <= 6)
        }
        #expect(visited == Set(model.profileIdentifiers))
    }

    @Test func selectionSurvivesRenameAndReorderByIdentifier() {
        let first = TerminalProfilePreview(
            identifier: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Same", templateProfile: "balanced"
        )
        let second = TerminalProfilePreview(
            identifier: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Same", templateProfile: "surround"
        )
        let model = TerminalModel(previewProfiles: builtIns + [first, second])
        model.selectRow(6)
        #expect(model.profile == second.identifier)

        model.replacePreviewProfiles(builtIns + [
            TerminalProfilePreview(identifier: second.identifier, title: "Renamed", templateProfile: "surround"),
            first,
        ])
        #expect(model.profile == second.identifier)
        #expect(model.title == "Renamed")
        model.screen = .profileManager
        let manager = ViewRenderer.render(
            TerminalRoot(model: model).frame(width: 72, height: 24),
            proposedSize: ProposedViewSize(columns: 72, rows: 24)
        )
        #expect(manager.text.contains(second.identifier))

        model.screen = .profiles
        model.replacePreviewProfiles(builtIns + [first])
        #expect(model.profileIdentifiers.contains(model.profile))
    }

    @Test func automationPickerDisambiguatesDuplicateNamesWithStableIdentifiers() {
        let first = TerminalProfilePreview(
            identifier: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", title: "Duplicate", templateProfile: "balanced"
        )
        let second = TerminalProfilePreview(
            identifier: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", title: "Duplicate", templateProfile: "surround"
        )
        let model = TerminalModel(previewProfiles: builtIns + [first, second])
        model.screen = .automation
        press(model, "a")
        model.promptText = "game.exe"
        model.submitPrompt()
        #expect(model.screen == .automationProfilePicker)
        model.moveAutomationProfilePage(by: 1, capacity: 4)

        let picker = ViewRenderer.render(
            TerminalRoot(model: model).frame(width: 72, height: 24),
            proposedSize: ProposedViewSize(columns: 72, rows: 24)
        )
        #expect(picker.text.contains("Duplicate · aaaaaaaa"))
        #expect(picker.text.contains("Duplicate · bbbbbbbb"))
        #expect(picker.text.contains("Previous page"))
        #expect(picker.text.contains("Next page"))

        model.selectRow(6)
        _ = model.handle(KeyPress(key: .return, characters: ""), terminate: {})
        #expect(model.screen == .prompt)
        #expect(model.automationTargetIdentifier == second.identifier)
    }

    @Test func managementGuardsBuiltInsRestoreAndMaximumCollection() {
        let model = TerminalModel(previewProfiles: builtIns)
        model.screen = .profileManager
        press(model, "n")
        #expect(model.screen == .profileManager)
        press(model, "d")
        #expect(model.screen == .profileManager)

        model.selectRow(model.profileCount - 1)
        press(model, "o")
        #expect(model.screen == .profileManager)

        let custom = (0..<256).map {
            TerminalProfilePreview(
                identifier: String(format: "10000000-0000-4000-8000-%012d", $0),
                title: "Custom \($0)", templateProfile: "balanced"
            )
        }
        let full = TerminalModel(previewProfiles: builtIns + custom)
        full.screen = .profileManager
        press(full, "c")
        #expect(full.screen == .profileManager)
    }

    @Test func importExportAndResetUseExplicitPrompts() {
        let model = TerminalModel(previewProfiles: builtIns)
        model.screen = .profileManager
        press(model, "i")
        #expect(model.screen == .prompt)
        #expect(model.promptTitle.contains("append"))
        model.promptText = "/tmp/SoundProfile.json"
        model.submitPrompt()
        #expect(model.screen == .profileManager)

        press(model, "w")
        #expect(model.screen == .prompt)
        #expect(model.promptTitle.contains("replace"))
        model.promptText = "/tmp/SoundProfile.json"
        model.submitPrompt()
        #expect(model.promptActionTitle == "Confirm")
        #expect(model.promptTitle.contains("IMPORT"))
        model.cancelPrompt()

        press(model, "x")
        #expect(model.promptActionTitle == "Export")
        model.cancelPrompt()

        press(model, "r")
        #expect(model.promptActionTitle == "Confirm")
        #expect(model.promptTitle.contains("all personal HRTF profiles"))
        #expect(model.promptTitle.contains("Standard"))
        model.promptText = "wrong"
        model.submitPrompt()
        #expect(model.screen == .prompt)
        #expect(model.message.contains("RESET"))
    }

    @Test func existingPersonalizationRequiresExplicitReplacementConfirmation() {
        let model = TerminalModel(previewProfiles: builtIns)
        model.setPreviewPersonalizationInstalled(true)
        press(model, "i")
        model.promptText = "/tmp/personalized_hrtf.hki"
        model.submitPrompt()
        model.promptText = "/tmp/YY2987.ba"
        model.submitPrompt()
        #expect(model.screen == .prompt)
        #expect(model.promptActionTitle == "Confirm")
        #expect(model.promptTitle.contains("REPLACE"))
        model.promptText = "wrong"
        model.submitPrompt()
        #expect(model.message.contains("REPLACE"))
    }

    @Test func existingExportDestinationRequiresExplicitOverwriteConfirmation() throws {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("inzone-profile-export-\(UUID().uuidString).json")
        try Data("preserve".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        let model = TerminalModel(previewProfiles: builtIns)
        model.screen = .profileManager
        press(model, "x")
        model.promptText = destination.path
        model.submitPrompt()
        #expect(model.screen == .prompt)
        #expect(model.promptActionTitle == "Confirm")
        #expect(model.promptTitle.contains("OVERWRITE"))
        #expect(try Data(contentsOf: destination) == Data("preserve".utf8))
    }

    @Test func managementScreenFitsMinimumViewportAtCollectionEdges() {
        let custom = (0..<20).map {
            TerminalProfilePreview(
                identifier: String(format: "20000000-0000-4000-8000-%012d", $0),
                title: "Custom sound profile \($0)", templateProfile: "balanced"
            )
        }
        let model = TerminalModel(previewProfiles: builtIns + custom)
        model.screen = .profileManager
        for index in [0, 12, model.profileCount - 1] {
            model.selectRow(index)
            let rendered = ViewRenderer.render(
                TerminalRoot(model: model).frame(width: 72, height: 24),
                proposedSize: ProposedViewSize(columns: 72, rows: 24)
            )
            #expect(rendered.size.columns == 72)
            #expect(rendered.size.rows == 24)
            for label in ["Sound Profile Collection", "Previous", "Next", "Create", "Import", "Replace", "Export", "Reset", "Retry", "Back"] {
                #expect(rendered.text.contains(label), "Missing \(label) at index \(index)")
            }
            for line in rendered.lines {
                #expect(RunGroup(line).measure().maximumContentColumns <= 72)
            }
        }
    }

    @Test func pendingPersonalizationCleanupIsVisibleAndRetryable() {
        let model = TerminalModel(previewProfiles: builtIns)
        model.setPreviewPersonalizationInstalled(true)
        model.setPreviewPersonalizationCleanupPending(["first", "second"])
        model.screen = .profileManager
        let rendered = ViewRenderer.render(
            TerminalRoot(model: model).frame(width: 72, height: 24),
            proposedSize: ProposedViewSize(columns: 72, rows: 24)
        )
        #expect(rendered.text.contains("Cleanup pending: 2"))
        #expect(rendered.text.contains("Retry"))
        #expect(model.actionAvailable("k"))
        #expect(personalizationResultMessage(
            success: "Personalization imported.", cleanupPending: ["first", "second"]
        ).contains("Cleanup pending for 2 retired bank(s). Use K: Retry cleanup."))
    }

    @Test func appendOutcomeReportsSkippedProfilesAtCollectionLimit() {
        let message = soundProfileImportMessage(
            SoundProfileImportOutcome(importedCount: 2, skippedCount: 3), mode: .append
        )
        #expect(message.contains("appended: 2"))
        #expect(message.contains("Skipped 3"))
        #expect(message.contains("256-profile limit"))
        #expect(soundProfileImportMessage(
            SoundProfileImportOutcome(importedCount: 4, skippedCount: 0), mode: .replace
        ) == "Sound profiles replaced: 4.")
    }
}
