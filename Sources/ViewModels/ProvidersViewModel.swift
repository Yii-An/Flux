import Foundation
import os.log

@MainActor
final class ProvidersViewModel: ObservableObject {
    @Published var geminiKeysState: LoadState<[ProviderKeyEntry]> = .idle
    @Published var codexKeysState: LoadState<[ProviderKeyEntry]> = .idle
    @Published var claudeKeysState: LoadState<[ProviderKeyEntry]> = .idle
    @Published var openAICompatState: LoadState<[OpenAICompatibilityEntry]> = .idle

    private let client = ManagementAPIClient()
    private let logger = Logger(subsystem: "com.flux.app", category: "ProvidersVM")

    func refreshAll(baseURL: URL, password: String?) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.refreshGeminiKeys(baseURL: baseURL, password: password)
            }
            group.addTask {
                await self.refreshCodexKeys(baseURL: baseURL, password: password)
            }
            group.addTask {
                await self.refreshClaudeKeys(baseURL: baseURL, password: password)
            }
            group.addTask {
                await self.refreshOpenAICompatibility(baseURL: baseURL, password: password)
            }
        }
    }

    func refreshGeminiKeys(baseURL: URL, password: String?) async {
        geminiKeysState = .loading
        do {
            let response = try await client.getGeminiApiKeys(baseURL: baseURL, password: password)
            geminiKeysState = .loaded(response.keys ?? [])
            logger.info("Gemini keys loaded: \(response.keys?.count ?? 0)")
        } catch {
            geminiKeysState = .error(error.localizedDescription)
            logger.error("Failed to load Gemini keys: \(error.localizedDescription)")
        }
    }

    func refreshCodexKeys(baseURL: URL, password: String?) async {
        codexKeysState = .loading
        do {
            let response = try await client.getCodexApiKeys(baseURL: baseURL, password: password)
            codexKeysState = .loaded(response.keys ?? [])
            logger.info("Codex keys loaded: \(response.keys?.count ?? 0)")
        } catch {
            codexKeysState = .error(error.localizedDescription)
            logger.error("Failed to load Codex keys: \(error.localizedDescription)")
        }
    }

    func refreshClaudeKeys(baseURL: URL, password: String?) async {
        claudeKeysState = .loading
        do {
            let response = try await client.getClaudeApiKeys(baseURL: baseURL, password: password)
            claudeKeysState = .loaded(response.keys ?? [])
            logger.info("Claude keys loaded: \(response.keys?.count ?? 0)")
        } catch {
            claudeKeysState = .error(error.localizedDescription)
            logger.error("Failed to load Claude keys: \(error.localizedDescription)")
        }
    }

    func refreshOpenAICompatibility(baseURL: URL, password: String?) async {
        openAICompatState = .loading
        do {
            let response = try await client.getOpenAICompatibility(baseURL: baseURL, password: password)
            openAICompatState = .loaded(response.entries ?? [])
            logger.info("OpenAI compatibility entries loaded: \(response.entries?.count ?? 0)")
        } catch {
            openAICompatState = .error(error.localizedDescription)
            logger.error("Failed to load OpenAI compatibility: \(error.localizedDescription)")
        }
    }
}
