import SwiftUI
import AppKit

/// minds dark palette (wood/fire tints, kept in sync with the web version)
enum Theme {
    static let bg = NSColor(srgbRed: 0x0d/255.0, green: 0x12/255.0, blue: 0x10/255.0, alpha: 1)
    static let panel = NSColor(srgbRed: 0x0b/255.0, green: 0x10/255.0, blue: 0x0e/255.0, alpha: 1)
    static let card = NSColor(srgbRed: 0x15/255.0, green: 0x1b/255.0, blue: 0x18/255.0, alpha: 1)
    static let card2 = NSColor(srgbRed: 0x1a/255.0, green: 0x21/255.0, blue: 0x1e/255.0, alpha: 1)
    static let border = NSColor(srgbRed: 0x23/255.0, green: 0x2b/255.0, blue: 0x27/255.0, alpha: 1)
    static let fg = NSColor(srgbRed: 0xe6/255.0, green: 0xe9/255.0, blue: 0xe5/255.0, alpha: 1)
    static let dim = NSColor(srgbRed: 0x8f/255.0, green: 0x9a/255.0, blue: 0x94/255.0, alpha: 1)
    static let dim2 = NSColor(srgbRed: 0x6b/255.0, green: 0x76/255.0, blue: 0x71/255.0, alpha: 1)
    static let gutter = NSColor(srgbRed: 0x46/255.0, green: 0x50/255.0, blue: 0x49/255.0, alpha: 1)
    static let accent = NSColor(srgbRed: 0x4a/255.0, green: 0xc4/255.0, blue: 0x9b/255.0, alpha: 1)
    static let fire = NSColor(srgbRed: 0xd2/255.0, green: 0x60/255.0, blue: 0x3f/255.0, alpha: 1)
    static let adoptFg = NSColor(srgbRed: 0x9f/255.0, green: 0xe6/255.0, blue: 0xcb/255.0, alpha: 1)
    static let adoptBg = NSColor(srgbRed: 0x1c/255.0, green: 0x33/255.0, blue: 0x30/255.0, alpha: 1)
    static let adoptBorder = NSColor(srgbRed: 0x2d/255.0, green: 0x5a/255.0, blue: 0x4c/255.0, alpha: 1)

    // SwiftUI side
    static let sBg = Color(nsColor: bg)
    static let sPanel = Color(nsColor: panel)
    static let sCard = Color(nsColor: card)
    static let sCard2 = Color(nsColor: card2)
    static let sBorder = Color(nsColor: border)
    static let sFg = Color(nsColor: fg)
    static let sDim = Color(nsColor: dim)
    static let sDim2 = Color(nsColor: dim2)
    static let sAccent = Color(nsColor: accent)
    static let sFire = Color(nsColor: fire)
}

/// Footer button style: one accent colour, disabled state greys out automatically
/// (driven by @Environment(\.isEnabled)).
struct VoxButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, adopt }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        VoxButtonBody(config: configuration, kind: kind)
    }

    private struct VoxButtonBody: View {
        let config: ButtonStyleConfiguration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled

        private var colors: (fg: Color, bg: Color, stroke: Color) {
            switch kind {
            case .primary:
                return (enabled ? Theme.sBg : Theme.sDim2,
                        enabled ? Theme.sAccent : Theme.sCard,
                        enabled ? Theme.sAccent : Theme.sBorder)
            case .adopt:
                return (enabled ? Color(nsColor: Theme.adoptFg) : Theme.sDim2,
                        enabled ? Color(nsColor: Theme.adoptBg) : Theme.sCard,
                        enabled ? Color(nsColor: Theme.adoptBorder) : Theme.sBorder)
            case .normal:
                return (enabled ? Theme.sFg : Theme.sDim2,
                        enabled ? Theme.sCard2 : Theme.sCard,
                        Theme.sBorder)
            }
        }

        var body: some View {
            let fg = colors.fg
            let bg = colors.bg
            let stroke = colors.stroke
            config.label
                .font(.system(size: 12.5))
                .foregroundStyle(fg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(bg)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(stroke, lineWidth: 1))
                .contentShape(Rectangle())
                .opacity(config.isPressed && enabled ? 0.82 : 1)
        }
    }
}
