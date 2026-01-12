import SwiftUI

struct FluxCardModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(UITokens.Radius.medium)
            .overlay(
                RoundedRectangle(cornerRadius: UITokens.Radius.medium)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 0.5)
            )
            .shadow(
                color: Color.black.opacity(isHovering ? 0.08 : 0),
                radius: 4, x: 0, y: 2
            )
            .onHover { hovering in
                withAnimation(UITokens.Animation.hover) {
                    self.isHovering = hovering
                }
            }
    }
}

extension View {
    func fluxCardStyle() -> some View {
        self.modifier(FluxCardModifier())
    }
}

