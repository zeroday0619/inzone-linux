import SwiftTUI

enum TerminalTheme {
    static let background = TrueColor(red: 18, green: 18, blue: 20)
    static let surface = TrueColor(red: 26, green: 26, blue: 28)
    static let raised = TrueColor(red: 44, green: 44, blue: 46)
    static let accent = TrueColor(red: 55, green: 125, blue: 235)
    static let text = TrueColor(red: 242, green: 242, blue: 247)
    static let muted = TrueColor(red: 155, green: 155, blue: 162)
    static let success = TrueColor(red: 104, green: 196, blue: 135)
    static let danger = TrueColor(red: 255, green: 116, blue: 116)
    static let pressed = TrueColor(red: 64, green: 64, blue: 68)
    static let accentPressed = TrueColor(red: 40, green: 99, blue: 195)
}

enum TerminalActionRole {
    case normal
    case plain
    case value
    case primary
    case destructive
}

@MainActor
struct TerminalAction: View {
    let title: String
    let width: Int?
    var height = 3
    var selected = false
    var enabled = true
    var role: TerminalActionRole = .normal
    var leadingAligned = false
    var baseBackground: TrueColor?
    let action: () -> Void

    @State private var hovered = false
    @GestureState private var pressed = false

    init(title: String, width: Int? = nil, height: Int = 3, selected: Bool = false,
         enabled: Bool = true, role: TerminalActionRole = .normal,
         leadingAligned: Bool = false,
         baseBackground: TrueColor? = nil,
         action: @escaping () -> Void) {
        self.title = title
        self.width = width
        self.height = height
        self.selected = selected
        self.enabled = enabled
        self.role = role
        self.leadingAligned = leadingAligned
        self.baseBackground = baseBackground
        self.action = action
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if !leadingAligned { Spacer(minLength: 0) }
                Text(terminalText(title)).lineLimit(1).bold(selected || role == .primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .frame(width: geometry.columns, height: height)
            .foregroundStyle(foreground)
            .background(background)
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { value, state, _ in
                        state = contains(value.location, columns: geometry.columns)
                    }
                    .onEnded { value in
                        if enabled && contains(value.location, columns: geometry.columns) { action() }
                    },
                isEnabled: enabled
            )
        }
        .frame(width: width, height: height)
    }

    private func contains(_ point: Point, columns: Int) -> Bool {
        point.column >= 0 && point.column < columns && point.row >= 0 && point.row < height
    }

    private var foreground: TrueColor {
        guard enabled else { return TerminalTheme.muted }
        switch role {
        case .normal, .plain, .primary: return TerminalTheme.text
        case .value: return TerminalTheme.accent
        case .destructive: return TerminalTheme.danger
        }
    }

    private var background: TrueColor {
        guard enabled else {
            return baseBackground ?? ((role == .plain || role == .value) ? TerminalTheme.background : TerminalTheme.surface)
        }
        if role == .primary {
            return pressed ? TerminalTheme.accentPressed : TerminalTheme.accent
        }
        if pressed { return TerminalTheme.pressed }
        if hovered || selected { return TerminalTheme.raised }
        return baseBackground ?? ((role == .plain || role == .value) ? TerminalTheme.background : TerminalTheme.surface)
    }
}
