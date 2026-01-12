import SwiftUI

struct ShortcutButton: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        tint: Color = .accentColor,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                icon

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(.headline, design: .rounded))
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(UITokens.Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.55 : 1)
        .fluxCardStyle()
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: UITokens.Radius.small)
                .fill(tint.opacity(0.12))
                .frame(width: 32, height: 32)

            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

