import Foundation
import os.log

@MainActor
final class OverviewViewModel: ObservableObject {
    @Published var healthState: LoadState<HealthResponse> = .idle
    @Published var apiKeysState: LoadState<[String]> = .idle
    @Published var dashboardStatsState: LoadState<DashboardStats> = .idle
    @Published var serverVersion: String?

    private let client = ManagementAPIClient()
    private let logger = Logger(subsystem: "com.flux.app", category: "OverviewVM")

    func refresh(baseURL: URL, password: String?) async {
        // 先刷新 apiKeys，因为后面 models 需要用
        await refreshApiKeys(baseURL: baseURL, password: password)

        // 并发获取 health 和 dashboard stats
        async let healthTask: () = checkHealth(baseURL: baseURL, password: password)
        async let statsTask: () = refreshDashboardStats(baseURL: baseURL, password: password)
        _ = await (healthTask, statsTask)
    }

    private func checkHealth(baseURL: URL, password: String?) async {
        healthState = .loading
        do {
            let (response, version) = try await client.checkHealthWithVersion(baseURL: baseURL, password: password)
            healthState = .loaded(response)
            serverVersion = version
        } catch {
            healthState = .error(error.localizedDescription)
            serverVersion = nil
        }
    }

    private func refreshApiKeys(baseURL: URL, password: String?) async {
        apiKeysState = .loading
        do {
            let keys = try await client.listAccounts(baseURL: baseURL, password: password)
            apiKeysState = .loaded(keys)
        } catch {
            apiKeysState = .error(error.localizedDescription)
        }
    }

    private func refreshDashboardStats(baseURL: URL, password: String?) async {
        dashboardStatsState = .loading
        var stats = DashboardStats()

        // 从 apiKeysState 获取 API Keys 数量
        if case .loaded(let keys) = apiKeysState {
            stats.apiKeysCount = keys.count
        }

        // 获取所有 AI 供应商数量 (gemini + codex + claude + openai-compatibility)
        // Gemini API Keys
        do {
            let response = try await client.getGeminiApiKeys(baseURL: baseURL, password: password)
            stats.geminiCount = response.count
        } catch {
            logger.error("Failed to load gemini-api-key: \(error.localizedDescription)")
        }

        // Codex API Keys
        do {
            let response = try await client.getCodexApiKeys(baseURL: baseURL, password: password)
            stats.codexCount = response.count
        } catch {
            logger.error("Failed to load codex-api-key: \(error.localizedDescription)")
        }

        // Claude API Keys
        do {
            let response = try await client.getClaudeApiKeys(baseURL: baseURL, password: password)
            stats.claudeCount = response.count
        } catch {
            logger.error("Failed to load claude-api-key: \(error.localizedDescription)")
        }

        // OpenAI Compatibility
        do {
            let response = try await client.getOpenAICompatibility(baseURL: baseURL, password: password)
            stats.openaiCompatCount = response.count
        } catch {
            logger.error("Failed to load openai-compatibility: \(error.localizedDescription)")
        }

        // 计算总供应商数量
        stats.providersCount = stats.geminiCount + stats.codexCount + stats.claudeCount + stats.openaiCompatCount

        // 获取 Auth Files
        do {
            let response = try await client.getAuthFiles(baseURL: baseURL, password: password)
            stats.authFilesCount = response.count
        } catch {
            logger.error("Failed to load auth-files: \(error.localizedDescription)")
        }

        // 获取 Models (需要 apiKey)
        if case .loaded(let keys) = apiKeysState, let firstKey = keys.first, !firstKey.isEmpty {
            do {
                let openAIBaseURL = await client.derivedOpenAIBaseURL(from: baseURL)
                let response = try await client.getModels(openAIBaseURL: openAIBaseURL, apiKey: firstKey)
                stats.modelsCount = response.count
            } catch {
                logger.error("Failed to load /v1/models: \(error.localizedDescription)")
                stats.modelsCount = 0
            }
        }

        dashboardStatsState = .loaded(stats)
    }
}
