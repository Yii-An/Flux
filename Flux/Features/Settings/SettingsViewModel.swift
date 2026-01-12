import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class SettingsViewModel {
    var settings: AppSettings = .default {
        didSet {
            scheduleAutosaveIfNeeded()
        }
    }

    var launchAtLogin: Bool = false {
        didSet {
            scheduleAutosaveIfNeeded()
        }
    }

    var coreVersion: String?
    var corePath: String = ""
    var isLoading: Bool = false
    var isSaving: Bool = false
    var errorMessage: String?

    private let settingsStore: SettingsStore
    private let launchAtLoginManager: LaunchAtLoginManager
    private let coreManager: CoreManager
    private let versionManager: CoreVersionManager

    private var autosaveTask: Task<Void, Never>?
    private var suppressAutosave: Bool = false

    init(
        settingsStore: SettingsStore = .shared,
        launchAtLoginManager: LaunchAtLoginManager = .shared,
        coreManager: CoreManager = .shared,
        versionManager: CoreVersionManager = .shared
    ) {
        self.settingsStore = settingsStore
        self.launchAtLoginManager = launchAtLoginManager
        self.coreManager = coreManager
        self.versionManager = versionManager
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        suppressAutosave = true
        defer {
            isLoading = false
            suppressAutosave = false
        }

        errorMessage = nil

        do {
            settings = try await settingsStore.load()
            launchAtLogin = await launchAtLoginManager.isEnabled()
            settings.startAtLogin = launchAtLogin
            await refreshCoreInfo()
        } catch {
            settings = .default
            launchAtLogin = await launchAtLoginManager.isEnabled()
            settings.startAtLogin = launchAtLogin
            await refreshCoreInfo()
            errorMessage = String(describing: error)
        }

        LanguageManager.shared.setLanguage(settings.language)
        await UpdateService.shared.applySettings(settings)
    }

    func checkForUpdates() async {
        await UpdateService.shared.checkForUpdates()
    }

    func restartCore() async {
        await coreManager.restart()
        await refreshCoreInfo()
    }

    func openLogsDirectory() {
        errorMessage = nil

        do {
            try FluxPaths.ensureConfigDirExists()
            NSWorkspace.shared.open(FluxPaths.coreDir())
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func resetSettings() async {
        guard !isSaving else { return }
        isSaving = true
        suppressAutosave = true
        defer {
            isSaving = false
            suppressAutosave = false
        }

        errorMessage = nil

        settings = .default
        launchAtLogin = false
        settings.startAtLogin = launchAtLogin

        do {
            try await settingsStore.save(settings)
            LanguageManager.shared.setLanguage(settings.language)
            await UpdateService.shared.applySettings(settings)
            try await launchAtLoginManager.setEnabled(false)
        } catch {
            errorMessage = String(describing: error)
        }

        let actual = await launchAtLoginManager.isEnabled()
        if launchAtLogin != actual {
            launchAtLogin = actual
            settings.startAtLogin = launchAtLogin
            try? await settingsStore.save(settings)
        }

        await refreshCoreInfo()
    }

    private func scheduleAutosaveIfNeeded() {
        guard !suppressAutosave else { return }
        guard !isLoading else { return }

        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard let self else { return }
            await self.persistSettings()
        }
    }

    private func persistSettings() async {
        guard !suppressAutosave else { return }
        guard !isSaving else { return }

        isSaving = true
        defer { isSaving = false }

        errorMessage = nil

        settings.startAtLogin = launchAtLogin
        settings.refreshIntervalSeconds = max(5, settings.refreshIntervalSeconds)
        settings.keepCoreVersions = min(2, max(1, settings.keepCoreVersions))

        do {
            try await settingsStore.save(settings)
            LanguageManager.shared.setLanguage(settings.language)
            await UpdateService.shared.applySettings(settings)

            try await launchAtLoginManager.setEnabled(launchAtLogin)
        } catch {
            errorMessage = String(describing: error)
        }

        let actual = await launchAtLoginManager.isEnabled()
        if launchAtLogin != actual {
            suppressAutosave = true
            launchAtLogin = actual
            settings.startAtLogin = actual
            suppressAutosave = false
            try? await settingsStore.save(settings)
        }
    }

    private func refreshCoreInfo() async {
        do {
            coreVersion = (try await versionManager.activeVersion())?.version
        } catch {
            coreVersion = nil
        }

        do {
            corePath = (try await versionManager.activeBinaryURL())?.path ?? FluxPaths.coreDir().path
        } catch {
            corePath = FluxPaths.coreDir().path
        }
    }
}
