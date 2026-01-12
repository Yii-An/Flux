import SwiftUI

struct AgentListCard: View {
    let items: [AgentIntegrationItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Agent Integrations".localizedStatic())
                    .font(.headline)
                Spacer()
                Text("\(installedCount)/\(items.count)")
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
            }

            if items.isEmpty {
                Text("No CLI agents detected".localizedStatic())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(items) { item in
                        AgentRow(item: item)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fluxCardStyle()
    }

    private var installedCount: Int {
        items.filter(\.isInstalled).count
    }
}

private struct AgentRow: View {
    let item: AgentIntegrationItem

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(item.isInstalled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)

            Text(item.agentID.displayName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer()

            if let version = item.version, !version.isEmpty {
                Text(version)
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Text(item.isInstalled ? "Installed".localizedStatic() : "Not installed".localizedStatic())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: UITokens.Radius.small))
    }
}
