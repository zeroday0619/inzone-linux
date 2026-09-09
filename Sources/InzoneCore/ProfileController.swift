import Foundation

public enum SoundProfileImportMode: Equatable, Sendable {
    case append
    case replace
}

public struct SoundProfileImportOutcome: Equatable, Sendable {
    public let importedCount: Int
    public let skippedCount: Int

    public init(importedCount: Int, skippedCount: Int) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
    }
}

/// Applies profiles and verifies that their requested routing and DSP are available.
public final class ProfileController: Sendable {
    public static let game = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-game"
    public static let chat = "alsa_output.usb-Sony_INZONE_H9_II-00.stereo-chat"
    public static let surround = "inzone.sony-surround"
    public static let card = "alsa_card.usb-Sony_INZONE_H9_II-00"
    public static let cardProfile = "output:stereo-game+output:stereo-chat+input:mono-chat"
    public static let profiles = ["fps", "music", "voice", "balanced", "surround"]

    public let paths: InzonePaths
    public let runner: any CommandRunning
    private let logger: any DiagnosticLogging
    private let dspDebugLog: URL?

    public init(
        paths: InzonePaths, runner: any CommandRunning = SystemCommandRunner(),
        logger: any DiagnosticLogging = DisabledDiagnosticLogger(), dspDebugLog: URL? = nil
    ) {
        self.paths = paths
        self.runner = runner
        self.logger = logger
        self.dspDebugLog = dspDebugLog
    }

    public func status() throws -> String {
        let text = try String(contentsOf: paths.activeProfile, encoding: .utf8)
        let first = text.components(separatedBy: .newlines).first ?? ""
        let prefix = "# INZONE profile: "
        return first.hasPrefix(prefix) ? String(first.dropFirst(prefix.count)) : "original"
    }

    public func isConnected() throws -> Bool {
        try snapshot().nodes.contains { $0.name.contains("Sony_INZONE_H9_II") }
    }

    public func activate(
        _ name: String,
        automatic: Bool = false,
        autoToken: String? = nil
    ) throws {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let identifier = try validatedProfile(name)
        let automation = AutomationStore(paths: paths)
        if automatic, automation.manualToken() != autoToken {
            throw InzoneError.message("Automatic switching was cancelled because the manual selection changed.")
        }
        let previous = try apply(identifier)
        if !automatic {
            do {
                try automation.markManual()
            } catch {
                let manualError = error
                try completeRollback(original: manualError, actions: [
                    {
                        try self.restore(
                            wirePlumber: previous.wirePlumberConfiguration,
                            pipeWire: previous.pipeWireConfiguration,
                            defaultSink: previous.defaultSink
                        )
                    },
                ])
                throw manualError
            }
        }
    }

    public func changeOptions(_ name: String, updates: [String: Any]) throws {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let settings = SettingsStore(paths: paths)
        let profile = try settings.resolvedProfile(name)
        let nextOptions = try settings.updated(profile.options, with: updates)
        let previousSettings = try settings.load()
        let profiles = SoundProfileStore(paths: paths)
        let previousProfiles = try profiles.load()
        if profile.isBuiltIn {
            var next = previousSettings
            next[profile.identifier] = nextOptions
            try settings.save(next)
        } else {
            try profiles.replaceOptions(profile.identifier, with: nextOptions)
        }
        var liveState: AppliedProfileState?
        do {
            liveState = try apply(profile.identifier)
            try AutomationStore(paths: paths).markManual()
        } catch {
            let changeError = error
            var actions: [() throws -> Void] = [
                {
                    if profile.isBuiltIn {
                        try settings.save(previousSettings)
                    } else {
                        try profiles.replace(with: previousProfiles)
                    }
                },
            ]
            if let liveState {
                actions.append {
                    try self.restore(
                        wirePlumber: liveState.wirePlumberConfiguration,
                        pipeWire: liveState.pipeWireConfiguration, defaultSink: liveState.defaultSink
                    )
                }
            }
            try completeRollback(original: changeError, actions: actions)
            throw changeError
        }
    }

    public func importSettings(_ data: Data) throws {
        let settings = SettingsStore(paths: paths)
        let next = try settings.decode(data)
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let previous = try settings.load()
        var liveState: AppliedProfileState?
        do {
            try settings.save(next)
            let current = try status()
            if Self.profiles.contains(current) {
                liveState = try apply(current)
                try AutomationStore(paths: paths).markManual()
            }
        } catch {
            let importError = error
            var actions: [() throws -> Void] = [{ try settings.save(previous) }]
            if let liveState {
                actions.append {
                    try self.restore(
                        wirePlumber: liveState.wirePlumberConfiguration,
                        pipeWire: liveState.pipeWireConfiguration, defaultSink: liveState.defaultSink
                    )
                }
            }
            try completeRollback(original: importError, actions: actions)
            throw importError
        }
    }

    public func availableProfiles() throws -> [ResolvedProfile] {
        try SettingsStore(paths: paths).availableProfiles()
    }

    @discardableResult
    public func createProfile(name: String? = nil, basedOn identifier: String = "balanced") throws -> SoundProfileRecord {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let base = try SettingsStore(paths: paths).resolvedProfile(identifier)
        return try SoundProfileStore(paths: paths).create(name: name, basedOn: base)
    }

    @discardableResult
    public func cloneProfile(_ identifier: String, name: String? = nil) throws -> SoundProfileRecord {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        return try SoundProfileStore(paths: paths).clone(identifier, name: name)
    }

    public func renameProfile(_ identifier: String, to name: String) throws {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        try SoundProfileStore(paths: paths).rename(identifier, to: name)
    }

    public func deleteProfile(_ identifier: String) throws {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        guard try statusIfConfigured()?.caseInsensitiveCompare(identifier) != .orderedSame else {
            throw InzoneError.message("The active sound profile cannot be deleted.")
        }
        guard !(try AutomationStore(paths: paths).references(profile: identifier)) else {
            throw InzoneError.message("Remove automatic rules for this sound profile before deleting it.")
        }
        try SoundProfileStore(paths: paths).delete(identifier)
    }

    public func importWindowsCollection(
        _ path: URL, mode: SoundProfileImportMode = .append
    ) throws -> SoundProfileImportOutcome {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let store = SoundProfileStore(paths: paths)
        let previous = try store.load()
        let records = try SonyPresets(paths: paths).importWindowsCollection(
            path, existingRecords: previous
        )
        if mode == .append {
            let available = max(0, SoundProfileStore.maximumProfileCount - previous.count)
            let appended = records.prefix(available).map { record in
                SoundProfileRecord(
                    identifier: UUID().uuidString.lowercased(), name: record.name,
                    templateProfile: record.templateProfile, options: record.options,
                    windowsSource: record.windowsSource
                )
            }
            if !appended.isEmpty { try store.replace(with: previous + appended) }
            return SoundProfileImportOutcome(
                importedCount: appended.count, skippedCount: records.count - appended.count
            )
        }
        let active = try statusIfConfigured()
        let retained = Set(records.map { $0.identifier.lowercased() })
        let activeIsCustom = active.map {
            !Self.profiles.contains($0) && $0 != "original" && $0 != "restore"
        } ?? false
        if activeIsCustom, let active, !retained.contains(active.lowercased()) {
            throw InzoneError.message("The imported collection must retain the active custom sound profile identifier.")
        }
        let protected = try AutomationStore(paths: paths).referencedProfileIdentifiers()
        let removesProtectedProfile = protected.contains {
            !Self.profiles.contains($0) && !["restore", "original"].contains($0)
                && !retained.contains($0.lowercased())
        }
        guard !removesProtectedProfile else {
            throw InzoneError.message(
                "Automatic switching still owns a profile omitted from the imported collection."
            )
        }
        try store.replace(with: records)
        do {
            if activeIsCustom, let active { try apply(active) }
        } catch {
            do {
                try store.replace(with: previous)
            } catch let restorationError {
                throw rollbackError(original: error, restoration: restorationError)
            }
            throw error
        }
        return SoundProfileImportOutcome(importedCount: records.count, skippedCount: 0)
    }

    public func exportWindowsCollection(
        _ path: URL, allowOverwrite: Bool = false
    ) throws {
        let records = try SoundProfileStore(paths: paths).load()
        try SonyPresets(paths: paths).exportWindowsCollection(
            records, to: path, allowOverwrite: allowOverwrite
        )
    }

    @discardableResult
    @available(*, deprecated, message: "Use importPersonalizationResult(hki:ba:) to inspect cleanupPending.")
    public func importPersonalization(
        hki: URL, ba: URL
    ) throws -> URL {
        try importPersonalizationResult(hki: hki, ba: ba).destination
    }

    public func importPersonalizationResult(
        hki: URL, ba: URL, allowReplacing: Bool = false
    ) throws -> PersonalizationImportOutcome {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let active = try activeProfileForAssetMutation()
        let reapply = active?.isSurround == true && active?.options.hrtf == "personal"
        let destination = paths.shareDirectory.appendingPathComponent("personal", isDirectory: true)
        if reapply, !FileManager.default.fileExists(atPath: destination.path) {
            throw InzoneError.message("The active personal HRTF profile has no installed personalization to replace.")
        }
        var previousLiveState: AppliedProfileState?
        var activationAttempted = false
        do {
            return try Personalization.importFilesOutcome(
                paths: paths, hki: hki, ba: ba, allowReplacing: allowReplacing
            ) {
                if reapply, let active {
                    activationAttempted = true
                    let state = try self.apply(
                        active.identifier,
                        capturePrevious: { previousLiveState = $0 }
                    )
                    try self.restoreDefaultSink(state.defaultSink)
                }
            }
        } catch let assetError as PersonalizationAssetRollbackError {
            do {
                try Personalization.retryAssetRollback(paths: paths, error: assetError)
            } catch let retryError {
                throw rollbackError(original: assetError, restoration: retryError)
            }
            do {
                if activationAttempted, let previousLiveState {
                    try restorePersonalizationLiveState(previousLiveState)
                } else {
                    _ = try Personalization.cleanupRetired(paths: paths)
                }
            } catch let restorationError {
                throw rollbackError(original: assetError.original, restoration: restorationError)
            }
            throw assetError.original
        } catch {
            let importError = error
            if activationAttempted, let previousLiveState {
                do {
                    try restorePersonalizationLiveState(previousLiveState)
                } catch let restorationError {
                    throw rollbackError(original: importError, restoration: restorationError)
                }
            }
            throw importError
        }
    }

    private func restorePersonalizationLiveState(_ state: AppliedProfileState) throws {
        try restore(
            wirePlumber: state.wirePlumberConfiguration,
            pipeWire: state.pipeWireConfiguration, defaultSink: state.defaultSink
        )
        _ = try Personalization.cleanupRetired(paths: paths)
    }

    @discardableResult
    @available(*, deprecated, message: "Use resetPersonalizationResult() to inspect cleanupPending.")
    public func resetPersonalization() throws -> Bool {
        try resetPersonalizationResult().removed
    }

    public func resetPersonalizationResult() throws -> PersonalizationResetOutcome {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        let settings = SettingsStore(paths: paths)
        let profiles = SoundProfileStore(paths: paths)
        let previousSettings = try settings.load()
        let previousProfiles = try profiles.load()
        var nextSettings = previousSettings
        for identifier in Self.profiles {
            var options = previousSettings[identifier] ?? ProfileOptions()
            if options.hrtf == "personal" {
                options.hrtf = "standard"
                nextSettings[identifier] = options
            }
        }
        var nextProfiles = previousProfiles
        for index in nextProfiles.indices where nextProfiles[index].options.hrtf == "personal" {
            nextProfiles[index].options.hrtf = "standard"
        }
        let activeBefore = try activeProfileForAssetMutation()
        let reapply = activeBefore?.isSurround == true && activeBefore?.options.hrtf == "personal"
        var activatedState: AppliedProfileState?
        do {
            try settings.save(nextSettings)
            try profiles.replace(with: nextProfiles)
            if reapply, let activeBefore {
                let state = try apply(activeBefore.identifier)
                activatedState = state
                try restoreDefaultSink(state.defaultSink)
            }
            return try Personalization.resetOutcome(paths: paths)
        } catch {
            let resetError = error
            var actions: [() throws -> Void] = [
                { try settings.save(previousSettings) },
                { try profiles.replace(with: previousProfiles) },
            ]
            if let activatedState {
                actions.append {
                    try self.restore(
                        wirePlumber: activatedState.wirePlumberConfiguration,
                        pipeWire: activatedState.pipeWireConfiguration,
                        defaultSink: activatedState.defaultSink
                    )
                }
            }
            try completeRollback(original: resetError, actions: actions)
            throw resetError
        }
    }

    public func personalizationCleanupPending() throws -> [String] {
        try Personalization.cleanupState(paths: paths)
    }

    @discardableResult
    public func retryPersonalizationCleanup() throws -> [String] {
        let lock = try switchLock()
        defer { withExtendedLifetime(lock) {} }
        _ = try Personalization.cleanupRetired(paths: paths)
        return try Personalization.cleanupState(paths: paths)
    }

    private func validatedProfile(_ name: String) throws -> String {
        if name == "restore" { return name }
        guard let profile = try SettingsStore(paths: paths).profileIfAvailable(name) else {
            throw InzoneError.message("Unknown profile: \(name)")
        }
        return profile.identifier
    }

    private func statusIfConfigured() throws -> String? {
        guard FileManager.default.fileExists(atPath: paths.activeProfile.path) else { return nil }
        return try status()
    }

    private func activeProfileForAssetMutation() throws -> ResolvedProfile? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: paths.activeProfile.path) else { return nil }
        let activeData = try Data(contentsOf: paths.activeProfile)
        guard let activeText = String(data: activeData, encoding: .utf8) else {
            throw InzoneError.message("The active WirePlumber configuration is not UTF-8.")
        }
        let first = activeText.components(separatedBy: .newlines).first ?? ""
        let prefix = "# INZONE profile: "
        let activeIdentifier = first.hasPrefix(prefix) ? String(first.dropFirst(prefix.count)) : "original"
        if activeIdentifier == "original" || activeIdentifier == "restore" {
            let original = paths.configDirectory.appendingPathComponent("original.conf")
            guard fileManager.fileExists(atPath: original.path) else {
                throw InzoneError.message("The managed restore configuration is missing.")
            }
            let originalData = try Data(contentsOf: original)
            let headerlessData: Data?
            if activeIdentifier == "restore", let newline = activeData.firstIndex(of: 0x0A) {
                headerlessData = Data(activeData[activeData.index(after: newline)...])
            } else {
                headerlessData = nil
            }
            guard activeData == originalData || headerlessData == originalData else {
                throw InzoneError.message(
                    "The active WirePlumber configuration is not a managed INZONE profile."
                )
            }
            return nil
        }
        guard let profile = try SettingsStore(paths: paths).profileIfAvailable(activeIdentifier) else {
            throw InzoneError.message("The active INZONE profile is not registered: \(activeIdentifier)")
        }
        return profile
    }

    private func switchLock() throws -> FileLock {
        try FileLock(url: paths.configDirectory.appendingPathComponent("switch.lock"))
    }

    private func writeActive(wirePlumber: String, pipeWire: String) throws {
        try AtomicFile.write(Data(pipeWire.utf8), to: paths.activeDSPProfile, permissions: 0o644)
        do {
            try AtomicFile.write(Data(wirePlumber.utf8), to: paths.activeProfile, permissions: 0o644)
        } catch {
            try? AtomicFile.write(Data("{}\n".utf8), to: paths.activeDSPProfile, permissions: 0o644)
            throw error
        }
    }

    private func restartAudioServices() throws {
        let restart = [
            "systemctl", "--user", "restart", "pipewire.service", "wireplumber.service",
            "pipewire-pulse.service",
        ]
        do {
            _ = try runner.run(restart)
        } catch let error as CommandError where !error.timedOut {
            let result = try runner.run([
                "systemctl", "--user", "show", "wireplumber.service", "-p", "Result", "--value",
            ])
            guard result.trimmingCharacters(in: .whitespacesAndNewlines) == "start-limit-hit" else {
                throw error
            }
            _ = try runner.run(["systemctl", "--user", "reset-failed", "wireplumber.service"])
            _ = try runner.run(restart)
        }
    }

    private struct AppliedProfileState {
        let wirePlumberConfiguration: String
        let pipeWireConfiguration: String
        let defaultSink: String
    }

    @discardableResult
    private func apply(
        _ name: String,
        capturePrevious: ((AppliedProfileState) -> Void)? = nil
    ) throws -> AppliedProfileState {
        let resolved = name == "restore" ? nil : try SettingsStore(paths: paths).resolvedProfile(name)
        let identifier = resolved?.identifier ?? "restore"
        let candidate = paths.configDirectory.appendingPathComponent(
            identifier == "restore" ? "original.conf" : resolved!.templateProfile + ".conf"
        )
        let previous = try String(contentsOf: paths.activeProfile, encoding: .utf8)
        let previousDSP = (try? String(contentsOf: paths.activeDSPProfile, encoding: .utf8)) ?? "{}\n"
        let wasConnected = try isConnected()
        let previousDefault = try runner.run(["pactl", "get-default-sink"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let previousState = AppliedProfileState(
            wirePlumberConfiguration: previous, pipeWireConfiguration: previousDSP,
            defaultSink: previousDefault
        )
        capturePrevious?(previousState)
        let template = try String(contentsOf: candidate, encoding: .utf8)
        let rendered = try GraphRenderer(paths: paths).renderConfigurations(
            profile: identifier, template: template
        )
        try writeActive(wirePlumber: rendered.wirePlumber, pipeWire: rendered.pipeWire)
        var dspDebugEnvironmentSet = false
        if let dspDebugLog {
            _ = try runner.run([
                "systemctl", "--user", "set-environment", "INZONE_DSP_DEBUG_LOG=\(dspDebugLog.path)",
            ])
            dspDebugEnvironmentSet = true
        }
        defer {
            if dspDebugEnvironmentSet {
                do {
                    _ = try runner.run([
                        "systemctl", "--user", "unset-environment", "INZONE_DSP_DEBUG_LOG",
                    ])
                } catch {
                    logger.log("DSP debug environment cleanup failed: \(error.localizedDescription)")
                }
            }
        }
        do {
            try restartAudioServices()
            _ = try runner.run([
                "systemctl", "--user", "is-active", "pipewire.service", "wireplumber.service",
                "pipewire-pulse.service",
            ])
            if dspDebugEnvironmentSet {
                _ = try runner.run([
                    "systemctl", "--user", "unset-environment", "INZONE_DSP_DEBUG_LOG",
                ])
                dspDebugEnvironmentSet = false
            }
            if wasConnected {
                try verifyConnectedProfile(identifier)
            }
            return previousState
        } catch {
            do {
                try restore(wirePlumber: previous, pipeWire: previousDSP, defaultSink: previousDefault)
            } catch let restorationError {
                throw rollbackError(original: error, restoration: restorationError)
            }
            throw error
        }
    }

    private func restore(wirePlumber: String, pipeWire: String, defaultSink: String) throws {
        try writeActive(wirePlumber: wirePlumber, pipeWire: pipeWire)
        try restartAudioServices()
        try restoreDefaultSink(defaultSink)
    }

    private func restoreDefaultSink(_ defaultSink: String) throws {
        for attempt in 0..<40 {
            do {
                _ = try runner.run(["pactl", "set-default-sink", defaultSink])
                return
            } catch let error as CommandError where !error.timedOut {
                guard attempt < 39 else { throw error }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
    }

    private func rollbackError(original: any Error, restoration: any Error) -> InzoneError {
        .message("\(original.localizedDescription) Rollback also failed: \(restoration.localizedDescription)")
    }

    private func completeRollback(
        original: any Error, actions: [() throws -> Void]
    ) throws {
        var failures: [String] = []
        for action in actions {
            do {
                try action()
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty {
            throw InzoneError.message(
                "\(original.localizedDescription) Rollback also failed: \(failures.joined(separator: " "))"
            )
        }
    }

    private func verifyConnectedProfile(_ name: String) throws {
        let profile = name == "restore" ? nil : try SettingsStore(paths: paths).resolvedProfile(name)
        let template = profile?.templateProfile ?? "restore"
        let expected = [
            "fps": 128, "music": 512, "voice": 256,
            "balanced": 256, "restore": 256, "surround": 256,
        ][template]!
        let surroundFamily = Set([
            GraphRenderer.surroundStereoSink,
            GraphRenderer.surroundFivePointOneSink,
            GraphRenderer.sink,
        ])
        let downmixFamily = Set([
            GraphRenderer.downmixSink,
            GraphRenderer.downmixFivePointOneSink,
            GraphRenderer.downmixSevenPointOneSink,
        ])
        var outputs: [Node] = []
        var available = false
        var lastDiagnostic = "no PipeWire snapshot was received"
        logger.log("profile verification started: profile=\(name); template=\(template); expected_latency=\(expected)/48000")
        for attempt in 1...40 {
            let current = try snapshot()
            let nodes = current.nodes
            outputs = nodes.filter { $0.name == Self.game || $0.name == Self.chat }
            let names = Set(nodes.map(\.name))
            let correctLatency = outputs.count == 2
                && outputs.allSatisfy { $0.latency == "\(expected)/48000" }
            let expectsDownmix = profile != nil && profile?.isVoice != true && profile?.isSurround != true
            let familyAvailable: Bool
            if profile?.isSurround == true {
                familyAvailable = surroundFamily.isSubset(of: names) && names.isDisjoint(with: downmixFamily)
            } else if expectsDownmix {
                familyAvailable = downmixFamily.isSubset(of: names) && names.isDisjoint(with: surroundFamily)
            } else {
                familyAvailable = names.isDisjoint(with: surroundFamily)
                    && names.isDisjoint(with: downmixFamily)
            }
            let observedLatencies = outputs
                .map { "\($0.name)=\($0.latency ?? "missing")" }
                .sorted().joined(separator: ",")
            let expectedFamily: Set<String>
            let forbiddenFamily: Set<String>
            if profile?.isSurround == true {
                expectedFamily = surroundFamily
                forbiddenFamily = downmixFamily
            } else if expectsDownmix {
                expectedFamily = downmixFamily
                forbiddenFamily = surroundFamily
            } else {
                expectedFamily = []
                forbiddenFamily = surroundFamily.union(downmixFamily)
            }
            let missingNodes = expectedFamily.subtracting(names).sorted().joined(separator: ",")
            let unexpectedNodes = forbiddenFamily.intersection(names).sorted().joined(separator: ",")
            lastDiagnostic = "outputs=\(outputs.count), latencies=[\(observedLatencies)], "
                + "missing DSP nodes=[\(missingNodes)], unexpected DSP nodes=[\(unexpectedNodes)]"
            logger.log(
                "profile verification attempt \(attempt)/40: outputs=\(outputs.count); latencies=[\(observedLatencies)]; "
                    + "correct_latency=\(correctLatency); family_available=\(familyAvailable); "
                    + "missing_dsp_nodes=[\(missingNodes)]; unexpected_dsp_nodes=[\(unexpectedNodes)]"
            )
            if correctLatency && familyAvailable {
                available = true
                logger.log("profile verification succeeded on attempt \(attempt)/40")
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard available else {
            logger.log("profile verification failed after 40 attempts")
            throw InzoneError.message(
                "H9 II Game/Chat output latency or DSP availability verification failed: \(lastDiagnostic). "
                    + "Run with --debug and inspect \(paths.debugLog.path)."
            )
        }

        let target = profile?.isSurround == true ? Self.surround : (
            profile?.isVoice == true || profile == nil ? Self.chat : GraphRenderer.downmixSink
        )
        let selectedTarget = profile == nil ? Self.game : target
        _ = try runner.run(["pactl", "set-default-sink", selectedTarget])
        let options = profile?.options ?? ProfileOptions()
        let hasEqualizer = options.equalizerEnabled || options.equalizer.contains { $0 != 0 }
        let hasAdditionalDSP = options.drc != 0 || options.outputALC || hasEqualizer
            || options.soundMode == "immersive"
        let usesVirtualOutput = profile != nil && profile?.isVoice != true
        if usesVirtualOutput || ["fps", "voice", "surround"].contains(template)
            || hasAdditionalDSP || options.microphoneAGC {
            // Silence starts the filters without producing an audible verification signal.
            _ = try runner.run([
                "pw-cat", "-p", "--raw", "--format", "f32", "--rate", "48000",
                "--channels", "2", "--latency", "256", "--target", selectedTarget, "-",
            ], input: Data(count: 4096 * 8), timeout: 8)
        }

        if ["fps", "voice"].contains(template), options.baseEqualizer {
            let properties = try outputProperties(profile?.isVoice == true ? Self.chat : Self.game, outputs: outputs)
            guard properties.contains("eq0:") else {
                throw InzoneError.message("Base equalizer loading verification failed.")
            }
        }
        if hasAdditionalDSP {
            let sink = profile?.isVoice == true ? Self.chat : Self.game
            let properties = try outputProperties(sink, outputs: outputs)
            var required: [String] = []
            if options.drc != 0 { required.append("game_drc:") }
            if options.outputALC { required.append("output_alc:") }
            if hasEqualizer { required.append("custom") }
            if options.soundMode == "immersive" { required.append("immersive") }
            guard required.allSatisfy(properties.contains) else {
                throw InzoneError.message("Additional output DSP loading verification failed.")
            }
        }
        if options.microphoneAGC {
            let current = try snapshot()
            let input = current.nodes.first { $0.name.contains("alsa_input.usb-Sony_INZONE_H9_II-00") }
            guard let input else {
                throw InzoneError.message("H9 II microphone DSP node was not found.")
            }
            let properties = try runner.run(["pw-cli", "enum-params", input.identifier, "Props"])
            guard properties.contains("mic_agc:") else {
                throw InzoneError.message("Microphone AGC loading verification failed.")
            }
        }
        if profile?.isSurround == true {
            let current = try snapshot()
            let names = Dictionary(current.nodes.map { ($0.identifier, $0.name) }, uniquingKeysWith: { _, latest in latest })
            let linked = current.links.contains {
                names[$0.output] == "inzone.sony-surround.output" && names[$0.input] == Self.game
            }
            guard linked else {
                throw InzoneError.message("Surround output is not linked to the H9 II Game output.")
            }
        } else if profile != nil, profile?.isVoice != true {
            let current = try snapshot()
            let names = Dictionary(
                current.nodes.map { ($0.identifier, $0.name) }, uniquingKeysWith: { _, latest in latest }
            )
            let linked = current.links.contains {
                names[$0.output] == "inzone.sony-downmix.output" && names[$0.input] == Self.game
            }
            guard linked else {
                throw InzoneError.message("Downmix output is not linked to the H9 II Game output.")
            }
        }
    }

    private func outputProperties(_ name: String, outputs: [Node]) throws -> String {
        guard let output = outputs.first(where: { $0.name == name }) else {
            throw InzoneError.message("The H9 II output node was not found.")
        }
        return try runner.run(["pw-cli", "enum-params", output.identifier, "Props"])
    }

    private struct Node {
        let identifier: String
        let name: String
        let latency: String?
    }

    private struct Link {
        let output: String
        let input: String
    }

    private struct Snapshot {
        var nodes: [Node] = []
        var links: [Link] = []
    }

    private func snapshot() throws -> Snapshot {
        let text = try runner.run(["pw-dump"])
        guard let objects = try JSONSupport.decode(Data(text.utf8)) as? [[String: Any]] else {
            throw InzoneError.message("The PipeWire status response must be a JSON array.")
        }
        var result = Snapshot()
        for object in objects {
            guard let information = object["info"] as? [String: Any] else { continue }
            switch object["type"] as? String {
            case "PipeWire:Interface:Node":
                guard let properties = information["props"] as? [String: Any],
                      let name = properties["node.name"] as? String,
                      let identifier = identifier(object["id"]) else { continue }
                result.nodes.append(Node(
                    identifier: identifier, name: name, latency: properties["node.latency"] as? String
                ))
            case "PipeWire:Interface:Link":
                guard let output = identifier(information["output-node-id"]),
                      let input = identifier(information["input-node-id"]) else { continue }
                result.links.append(Link(output: output, input: input))
            default:
                continue
            }
        }
        return result
    }

    private func identifier(_ value: Any?) -> String? {
        if let number = value as? NSNumber { return number.stringValue }
        return value as? String
    }
}
