import SwiftUI

struct ProviderIcon: View {
    let providerID: ProviderID
    let size: CGFloat

    init(_ providerID: ProviderID, size: CGFloat = 24) {
        self.providerID = providerID
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(brandColor.opacity(0.1))
                .frame(width: size, height: size)

            Image(systemName: iconName)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.6, height: size * 0.6)
                .foregroundStyle(brandColor)
        }
    }

    private var brandColor: Color {
        switch providerID {
        case .gemini: return Color(hex: 0x4285F4)
        case .claude: return Color(hex: 0xD97757)
        case .codex: return Color(hex: 0x10A37F)
        case .qwen: return Color(hex: 0x1E40AF)
        case .copilot: return Color(hex: 0x1F2328)
        case .cursor: return Color(hex: 0xA855F7)
        case .vertexAI: return Color(hex: 0x4285F4)
        case .iFlow, .antigravity, .kiro, .trae, .glm: return .secondary
        }
    }

    private var iconName: String {
        switch providerID {
        case .gemini, .vertexAI: return "sparkles"
        case .claude: return "brain.head.profile"
        case .codex: return "terminal.fill"
        case .qwen: return "globe.asia.australia.fill"
        case .copilot: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        default: return "questionmark.circle"
        }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 08) & 0xff) / 255,
            blue: Double((hex >> 00) & 0xff) / 255,
            opacity: alpha
        )
    }
}
