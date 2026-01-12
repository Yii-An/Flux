import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class AgentsViewModel {
    var coreState: CoreRuntimeState = .stopped
    var enabledAgents: Set<AgentID> = Set(AgentID.allCases)
    var statuses: [AgentID: AgentStatus] = [:]

    var isRefreshing: Bool = false
    var errorMessage: String?

    private let coreManager: CoreManager
    private let settingsStore: SettingsStore
    private let discoveryService: AgentDiscoveryService
    private let cliExecutor: CLIExecutor

    init(
        coreManager: CoreManager = .shared,
        settingsStore: SettingsStore = .shared,
        discoveryService: AgentDiscoveryService = .shared,
        cliExecutor: CLIExecutor = .shared
    ) {
        self.coreManager = coreManager
        self.settingsStore = settingsStore
        self.discoveryService = discoveryService
        self.cliExecutor = cliExecutor
    }

    func refresh(forceRefresh: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        errorMessage = nil

        coreState = await coreManager.state()
        let settings: AppSettings
        do {
            settings = try await settingsStore.load()
        } catch {
            errorMessage = error.localizedDescription
            settings = .default
        }
        enabledAgents = settings.enabledAgents

        statuses = await discoveryService.detectAll(forceRefresh: forceRefresh)
    }

    func startCore() async {
        await coreManager.start()
        await refresh(forceRefresh: true)
    }

    func setEnabled(_ enabled: Bool, for agent: AgentID) async {
        if enabled {
            enabledAgents.insert(agent)
        } else {
            enabledAgents.remove(agent)
        }

        do {
            var settings = try await settingsStore.load()
            if enabled {
                settings.enabledAgents.insert(agent)
            } else {
                settings.enabledAgents.remove(agent)
            }
            try await settingsStore.save(settings)
        } catch {
            if enabled {
                enabledAgents.remove(agent)
            } else {
                enabledAgents.insert(agent)
            }
            errorMessage = error.localizedDescription
        }
    }

    func status(for agent: AgentID) -> AgentStatus {
        statuses[agent] ?? AgentStatus(isInstalled: false, version: nil, lastCheckedAt: nil)
    }

    func openInFinder(_ agent: AgentID) async {
        errorMessage = nil

        guard let binaryURL = await cliExecutor.findBinary(names: agent.binaryNames) else {
            errorMessage = String(format: "Binary not found for %@".localizedStatic(), agent.displayName)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([binaryURL])
    }
}
