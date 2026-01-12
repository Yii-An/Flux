import AppKit
import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        @Bindable var viewModel = viewModel

        Form {
            Section {
                HStack {
                    Spacer()

                    VStack(spacing: 12) {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 80, height: 80)
                            .shadow(radius: 4, x: 0, y: 2)

                        VStack(spacing: 4) {
                            Text("app_name".localizedStatic())
                                .font(.title2)
                                .fontWeight(.bold)

                            Text("version_format".localizedStatic()
                                .replacingOccurrences(of: "{version}", with: Bundle.main.appVersion)
                                .replacingOccurrences(of: "{build}", with: Bundle.main.buildNumber))
                                .font(.dinNumber(.callout))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 16) {
                            Button("Check for Updates".localizedStatic()) {
                                Task { await viewModel.checkForUpdates() }
                            }

                            Link("GitHub".localizedStatic(), destination: URL(string: "https://github.com/example/flux")!)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                    }

                    Spacer()
                }
                .padding(.vertical, 12)
            }
            .listRowBackground(Color.clear)

            Section {
                Picker("Language".localizedStatic(), selection: $viewModel.settings.language) {
                    Text("System".localizedStatic()).tag(AppLanguage.system)
                    Text("Simplified Chinese".localizedStatic()).tag(AppLanguage.zhHans)
                    Text("English".localizedStatic()).tag(AppLanguage.en)
                }
                .pickerStyle(.menu)

                Toggle("Launch at Login".localizedStatic(), isOn: $viewModel.launchAtLogin)
                Toggle("Auto Check Updates".localizedStatic(), isOn: $viewModel.settings.automaticallyChecksForUpdates)
            } header: {
                Text("General".localizedStatic())
            } footer: {
                Text("settings_core_description".localizedStatic())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("Core Version".localizedStatic()) {
                    Text(viewModel.coreVersion ?? "Not installed".localizedStatic())
                        .foregroundStyle(.secondary)
                        .font(.dinNumber(.body))
                }

                LabeledContent("Core Path".localizedStatic()) {
                    Text(viewModel.corePath)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .textSelection(.enabled)
                        .truncationMode(.middle)
                        .lineLimit(1)
                }

                NavigationLink {
                    CoreVersionsView()
                } label: {
                    Label("Manage Core Versions".localizedStatic(), systemImage: "arrow.down.circle")
                }

                Toggle("Auto Restart Core on Error".localizedStatic(), isOn: $viewModel.settings.autoRestartCore)

                Button("Restart Core".localizedStatic()) {
                    Task { await viewModel.restartCore() }
                }
                .controlSize(.small)
            } header: {
                Text("Flux Core".localizedStatic())
            }

            Section {
                Button("Open Logs Directory...".localizedStatic()) {
                    viewModel.openLogsDirectory()
                }

                Button("Reset All Settings...".localizedStatic(), role: .destructive) {
                    Task { await viewModel.resetSettings() }
                }
            } header: {
                Text("Maintenance".localizedStatic())
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings".localizedStatic())
        .task {
            await viewModel.load()
        }
    }
}

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }
}
