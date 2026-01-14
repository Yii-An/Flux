import SwiftUI

struct CoreVersionsView: View {
    @State private var viewModel = CoreVersionsViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UITokens.Spacing.lg) {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
                    Text("Installed Versions".localizedStatic())
                        .font(.headline)

                    if viewModel.installedVersions.isEmpty {
                        ContentUnavailableView {
                            Label("Installed Versions".localizedStatic(), systemImage: "shippingbox")
                        } description: {
                            Text("Not installed".localizedStatic())
                        }
                    } else {
                        ForEach(viewModel.installedVersions) { version in
                            installedCard(for: version)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: UITokens.Spacing.md) {
                    HStack {
                        Text("Available Downloads".localizedStatic())
                            .font(.headline)

                        Spacer()

                        if viewModel.isLoadingReleases {
                            SmallProgressView()
                                .frame(width: 14, height: 14)
                        }
                    }

                    if viewModel.availableReleases.isEmpty {
                        ContentUnavailableView {
                            Label("Available Downloads".localizedStatic(), systemImage: "arrow.down.circle")
                        } description: {
                            Text("Refresh".localizedStatic())
                        }
                    } else {
                        ForEach(viewModel.availableReleases, id: \.tagName) { release in
                            availableCard(for: release)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle("Manage Core Versions".localizedStatic())
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await viewModel.fetchReleases() }
                } label: {
                    Label("Refresh".localizedStatic(), systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoadingReleases)
            }
        }
        .task {
            await viewModel.load()
        }
    }

    @ViewBuilder
    private func installedCard(for version: InstalledCoreVersion) -> some View {
        VStack(alignment: .leading, spacing: UITokens.Spacing.sm) {
            HStack {
                Text(version.version)
                    .font(.dinNumber(.headline))

                Spacer()

                if version.isCurrent {
                    StatusBadge(text: "Active".localizedStatic(), status: .success)
                }
            }

            Text(version.executableURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .truncationMode(.middle)
                .lineLimit(1)

            HStack {
                Text(version.installedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !version.isCurrent {
                    Button {
                        Task { await viewModel.activateVersion(version) }
                    } label: {
                        Text("Activate".localizedStatic())
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(UITokens.Spacing.md)
        .fluxCardStyle()
    }

    @ViewBuilder
    private func availableCard(for release: CoreRelease) -> some View {
        VStack(alignment: .leading, spacing: UITokens.Spacing.sm) {
            HStack {
                Text((release.name?.isEmpty == false) ? (release.name ?? "") : release.tagName)
                    .font(.headline)

                Spacer()

                Text(release.tagName)
                    .font(.dinNumber(.caption))
                    .foregroundStyle(.secondary)
            }

            if let publishedAt = release.publishedAt {
                Text(publishedAt, style: .date)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Unknown".localizedStatic())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if viewModel.downloadingVersion == release.tagName {
                ProgressView(value: viewModel.downloadProgress)
            } else {
                Button {
                    Task { await viewModel.downloadVersion(release) }
                } label: {
                    Text("Download".localizedStatic())
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.downloadingVersion != nil)
            }
        }
        .padding(UITokens.Spacing.md)
        .fluxCardStyle()
    }
}
