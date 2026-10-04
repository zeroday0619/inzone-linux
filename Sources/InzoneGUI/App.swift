import CInzoneGuiRuntime
import Foundation
import Glibc
import QtBridge

@main
struct InzoneApplication: QApp {
    let qmlFileName: String = "Main"
    let initialProperties: [String: QObjectBuildable]

    init() {
        let arguments = CommandLine.arguments
        if arguments.contains("--help") {
            print("""
            Usage: inzone-gui [--smoke-test] [--screenshot PATH] [--diagnostics PATH]
            --smoke-test validates a visible window and exits after two seconds.
            --screenshot saves the application window without capturing other applications.
            --diagnostics writes Qt platform, application identity, screen, and rendering metadata.
            Use - as the diagnostics path to write JSON to standard output.
            Native Wayland is selected automatically in Wayland sessions.
            QT_QPA_PLATFORM and Qt's -platform option override automatic platform selection.
            """)
            exit(0)
        }
        let smokeTest = arguments.contains("--smoke-test")
        let screenshotPath = Self.argumentValue("--screenshot", in: arguments)
        let diagnosticsPath = Self.argumentValue("--diagnostics", in: arguments)
        let platformArgument = arguments.contains("-platform") || arguments.contains("--platform")
        screenshotPath.withCString { screenshot in
            diagnosticsPath.withCString { diagnostics in
                inzone_gui_configure(smokeTest, screenshot, diagnostics, platformArgument)
            }
        }
        initialProperties = ["backend": GuiModel()]
    }

    private static func argumentValue(_ option: String, in arguments: [String]) -> String {
        guard let index = arguments.firstIndex(of: option) else { return "" }
        guard arguments.indices.contains(index + 1), !arguments[index + 1].isEmpty,
              !arguments[index + 1].hasPrefix("--") else {
            FileHandle.standardError.write(Data("\(option) requires an output path.\n".utf8))
            exit(2)
        }
        return arguments[index + 1]
    }

    var bundle: Bundle {
        let executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let executableDirectory = executableURL.resolvingSymlinksInPath().deletingLastPathComponent()
        let candidates = [
            executableDirectory,
            executableDirectory.appendingPathComponent("../share/inzone-linux/gui").standardizedFileURL,
        ]
        for directory in candidates {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Main.qml").path),
               let resourceBundle = Bundle(path: directory.path) {
                return resourceBundle
            }
        }
        fatalError("The INZONE QML resources were not found beside the executable or in share/inzone-linux/gui.")
    }
}
