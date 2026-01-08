import Foundation
import os.log

@MainActor
final class AuthFilesViewModel: ObservableObject {
    @Published var authFilesState: LoadState<[AuthFile]> = .idle
    @Published var quotaStateByName: [String: LoadState<String>] = [:]

    private let client = ManagementAPIClient()
    private let quotaService = QuotaService()
    private let logger = Logger(subsystem: "com.flux.app", category: "AuthFilesVM")

    func refresh(baseURL: URL, password: String?) async {
        authFilesState = .loading
        do {
            let response = try await client.getAuthFiles(baseURL: baseURL, password: password)
            authFilesState = .loaded(response.files ?? [])
            logger.info("Auth files loaded: \(response.files?.count ?? 0)")
        } catch {
            authFilesState = .error(error.localizedDescription)
            logger.error("Failed to load auth files: \(error.localizedDescription)")
        }
    }

    func refreshQuota(baseURL: URL, password: String?) async {
        guard case .loaded(let files) = authFilesState else {
            return
        }

        let quotaService = self.quotaService
        let managementKey = password
        let managementBaseURL = baseURL

        let targets: [(key: String, file: AuthFile, provider: String)] = files.compactMap { file in
            let key = (file.name ?? file.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return nil }
            let provider = (file.provider ?? file.type ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard ["antigravity", "codex", "gemini-cli"].contains(provider) else { return nil }
            return (key: key, file: file, provider: provider)
        }

        for target in targets {
            quotaStateByName[target.key] = .loading
        }

        await withTaskGroup(of: (String, String?, String?).self) { group in
            for target in targets {
                group.addTask {
                    let file = target.file
                    let provider = target.provider
                    let key = target.key

                    guard let authIndex = file.authIndex, !authIndex.isEmpty else {
                        return (key, nil, "missing auth_index")
                    }

                    do {
                        switch provider {
                        case "codex":
                            let payload = try await quotaService.fetchCodexUsage(baseURL: managementBaseURL, managementKey: managementKey, authIndex: authIndex)
                            let (remainingText, resetText) = codexSummary(payload: payload)
                            let plan = payload.planType?.lowercased() ?? "-"
                            return (key, "Codex：剩余 \(remainingText) · 重置 \(resetText) · Plan \(plan)", nil)
                        case "gemini-cli":
                            let projectId = extractLastParenthesized(file.account)
                            let payload = try await quotaService.fetchGeminiCliQuota(
                                baseURL: managementBaseURL,
                                managementKey: managementKey,
                                authIndex: authIndex,
                                projectId: projectId
                            )
                            return (key, geminiCliSummary(payload: payload), nil)
                        case "antigravity":
                            let payload = try await quotaService.fetchAntigravityModels(baseURL: managementBaseURL, managementKey: managementKey, authIndex: authIndex)
                            return (key, antigravitySummary(payload: payload), nil)
                        default:
                            return (key, nil, "unsupported provider")
                        }
                    } catch {
                        return (key, nil, error.localizedDescription)
                    }
                }
            }

            for await (key, text, error) in group {
                if let text {
                    self.quotaStateByName[key] = .loaded(text)
                } else if let error {
                    self.quotaStateByName[key] = .error(error)
                } else {
                    self.quotaStateByName[key] = .error("unknown error")
                }
            }
        }
    }
}

private func extractLastParenthesized(_ value: String?) -> String? {
    guard let value else { return nil }
    let matches = value.matches(of: /\(([^()]+)\)/)
    guard let last = matches.last else { return nil }
    let inner = String(last.1).trimmingCharacters(in: .whitespacesAndNewlines)
    return inner.isEmpty ? nil : inner
}

private func codexSummary(payload: CodexUsagePayload) -> (remaining: String, reset: String) {
    let window = payload.rateLimit?.primaryWindow
    if let used = window?.usedPercent {
        let remaining = max(0, min(100, 100 - used))
        let remainingText = "\(Int(remaining.rounded()))%"
        if let resetAfter = window?.resetAfterSeconds {
            return (remainingText, "\(Int(resetAfter.rounded()))s")
        }
        if let resetAt = window?.resetAt {
            let date = Date(timeIntervalSince1970: resetAt)
            let formatter = ISO8601DateFormatter()
            return (remainingText, formatter.string(from: date))
        }
        return (remainingText, "-")
    }
    return ("--", "-")
}

private func geminiCliSummary(payload: GeminiCliQuotaPayload) -> String {
    guard let buckets = payload.buckets, !buckets.isEmpty else {
        return "Gemini CLI：无额度信息"
    }

    let scored = buckets.compactMap { bucket -> (modelId: String, remaining: Double, reset: String?)? in
        guard let remaining = bucket.remainingFraction else { return nil }
        let modelId = (bucket.modelId ?? "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return (modelId.isEmpty ? "-" : modelId, remaining, bucket.resetTime)
    }

    guard let worst = scored.min(by: { $0.remaining < $1.remaining }) else {
        return "Gemini CLI：无额度信息"
    }

    let percent = Int((max(0, min(1, worst.remaining)) * 100).rounded())
    let reset = (worst.reset ?? "-")
    return "Gemini CLI：最低剩余 \(percent)% (\(worst.modelId)) · 重置 \(reset)"
}

private func antigravitySummary(payload: AntigravityModelsPayload) -> String {
    let scored: [(modelId: String, remaining: Double, reset: String?)] = payload.compactMap { modelId, info in
        guard let quota = info.effectiveQuotaInfo, let remaining = quota.remainingFraction else { return nil }
        return (modelId: modelId, remaining: remaining, reset: quota.resetTime)
    }

    guard let worst = scored.min(by: { $0.remaining < $1.remaining }) else {
        return "Antigravity：无额度信息"
    }

    let percent = Int((max(0, min(1, worst.remaining)) * 100).rounded())
    let reset = worst.reset ?? "-"
    return "Antigravity：最低剩余 \(percent)% (\(worst.modelId)) · 重置 \(reset)"
}
