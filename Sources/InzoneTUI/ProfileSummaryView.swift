import SwiftTUI

@MainActor
struct TerminalProfileSummary: View {
    let description: String
    let drc: Int
    let outputALC: Bool
    let microphoneAGC: Bool
    var available = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text(terminalText(description)).lineLimit(1).foregroundStyle(TerminalTheme.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 1)
            TerminalEqualColumns(spacing: 2) {
                setting("DRC", value: ["Off", "Low", "High"][min(2, max(0, drc))], enabled: drc > 0)
                setting("Output ALC", value: outputALC ? "On" : "Off", enabled: outputALC)
                setting("Mic AGC", value: microphoneAGC ? "On" : "Off", enabled: microphoneAGC)
            }
        }
        .frame(height: 3, alignment: .topLeading)
    }

    private func setting(_ title: String, value: String, enabled: Bool) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).foregroundStyle(TerminalTheme.muted)
                Text(available ? value : "—").bold()
                    .foregroundStyle(available ? TerminalTheme.text : TerminalTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 1)
        .frame(height: 2)
    }
}

@MainActor
struct TerminalProfileDetails: View {
    let title: String
    let description: String
    let drc: Int
    let outputALC: Bool
    let microphoneAGC: Bool
    var available = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).bold().padding(.bottom, 1)
            Text(terminalText(description)).foregroundStyle(TerminalTheme.muted).lineLimit(3)
                .padding(.bottom, 2)
            detail("Dynamic range", value: ["Off", "Low", "High"][min(2, max(0, drc))])
            detail("Output leveling", value: outputALC ? "On" : "Off")
            detail("Microphone gain", value: microphoneAGC ? "On" : "Off")
            Spacer(minLength: 0)
        }
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(label).foregroundStyle(TerminalTheme.muted)
            Spacer(minLength: 0)
            Text(available ? value : "—").foregroundStyle(TerminalTheme.text)
        }
        .padding(.bottom, 1)
    }
}
