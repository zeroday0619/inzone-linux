import Foundation
import XCTest
@testable import InzoneCore

final class RepositoryTests: XCTestCase {
    func testPublicationRulesKeepSourcesAndExcludeVendorArtifacts() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("inzone-publication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = SystemCommandRunner()
        _ = try runner.run(["git", "init", "--quiet", directory.path])
        try Data(contentsOf: repository.appendingPathComponent(".gitignore"))
            .write(to: directory.appendingPathComponent(".gitignore"))
        let included = ["docs/reverse-engineering.md", "analysis/README.md", "analysis/pipewire-sfx-results.json",
                        "evidence/installer.json", "Sources/InzoneCore/Filters.swift", "Tests/InzoneCoreTests/FilterTests.swift",
                        "Sources/InzoneDSP/Plugin.swift", "native/exports.map", "Sources/CLADSPA/module.modulemap",
                        "Package.swift", "Package.resolved", "Vendor/swift-terminal/Sources/Terminal/Terminal.swift",
                        "stale.py", "stale.pyc", "pyproject.toml", "uv.lock"]
        let excluded = ["downloads/installer.exe", "analysis/decompiled/Example.cs", "analysis/new-unreviewed-report.json",
                        "analysis/virtualizer.asm", "analysis/payload/control.yaml", "assets/sony-eq-tables.json", "assets/FL.wav",
                        "tools/ilspycmd", "tools/.store/ilspycmd/tool.nuspec", "evidence/usb-descriptors.bin",
                        "backups/audio-state.json", "native/inzone_dsp.so", "copied.decompiled.cs", ".build/debug/inzone-profile",
                        ".swiftpm/configuration/workspace-state.json", "InzoneCore.swiftmodule", "InzoneCore.swiftdoc",
                        "InzoneCore.swiftsourceinfo", "InzoneCore.abi.json", "compile.dia", "app.dSYM/Contents/Info.plist",
                        "default.profraw", "coverage.profdata", "native/ladspa.d", "native/ladspa.gcda", "native/ladspa.gcno"]
        let output = try runner.run(["git", "-C", directory.path, "check-ignore", "--stdin", "--no-index"],
                                    input: Data(((included + excluded).joined(separator: "\n") + "\n").utf8))
        XCTAssertEqual(Set(output.split(separator: "\n").map(String.init)), Set(excluded))
    }
}
