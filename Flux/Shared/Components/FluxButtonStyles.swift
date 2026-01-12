import SwiftUI

struct SubtleButtonStyle: ButtonStyle {
    var hoverColor: Color = .primary.opacity(0.08)
    var cornerRadius: CGFloat = UITokens.Radius.small

    func makeBody(configuration: Configuration) -> some View {
        SubtleButtonContent(configuration: configuration, hoverColor: hoverColor, cornerRadius: cornerRadius)
    }

    private struct SubtleButtonContent: View {
        let configuration: Configuration
        let hoverColor: Color
        let cornerRadius: CGFloat

        @State private var isHovered = false

        var body: some View {
            configuration.label
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(configuration.isPressed ? hoverColor.opacity(1.5) : (isHovered ? hoverColor : .clear))
                )
                .onHover { hovering in
                    withAnimation(UITokens.Animation.hover) {
                        isHovered = hovering
                    }
                }
                .focusEffectDisabled(true)
        }
    }
}

struct ToolbarIconButtonStyle: ButtonStyle {
    var size: CGFloat = 28
    var cornerRadius: CGFloat = UITokens.Radius.small

    func makeBody(configuration: Configuration) -> some View {
        ToolbarIconButtonContent(configuration: configuration, size: size, cornerRadius: cornerRadius)
    }

    private struct ToolbarIconButtonContent: View {
        let configuration: Configuration
        let size: CGFloat
        let cornerRadius: CGFloat

        @State private var isHovered = false

        var body: some View {
            configuration.label
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(configuration.isPressed ? Color.primary.opacity(0.15) : (isHovered ? Color.primary.opacity(0.08) : .clear))
                )
                .onHover { hovering in
                    withAnimation(UITokens.Animation.hover) {
                        isHovered = hovering
                    }
                }
                .focusEffectDisabled(true)
        }
    }
}

extension ButtonStyle where Self == SubtleButtonStyle {
    static var subtle: SubtleButtonStyle { SubtleButtonStyle() }
}

extension ButtonStyle where Self == ToolbarIconButtonStyle {
    static var toolbarIcon: ToolbarIconButtonStyle { ToolbarIconButtonStyle() }
}
