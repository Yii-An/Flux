import Foundation

actor QuotaService {
    enum QuotaError: LocalizedError {
        case missingBody
        case upstreamFailed(statusCode: Int, body: String)

        var errorDescription: String? {
            switch self {
            case .missingBody:
                return "上游返回为空"
            case .upstreamFailed(let statusCode, let body):
                if body.isEmpty {
                    return "上游请求失败（\(statusCode)）"
                }
                return "上游请求失败（\(statusCode)）：\(body)"
            }
        }
    }

    private let client = ManagementAPIClient()

    private func bodyData(from response: APICallResponse) throws -> Data {
        let trimmed = response.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw QuotaError.missingBody }
        return Data(trimmed.utf8)
    }

    private func decodeBody<T: Decodable>(_ type: T.Type, response: APICallResponse) throws -> T {
        let data = try bodyData(from: response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }

    private func ensureUpstreamSuccess(_ response: APICallResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw QuotaError.upstreamFailed(statusCode: response.statusCode, body: response.body)
        }
    }

    // MARK: - Antigravity

    func fetchAntigravityModels(baseURL: URL, managementKey: String?, authIndex: String) async throws -> AntigravityModelsPayload {
        let urls = [
            "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels",
            "https://daily-cloudcode-pa.sandbox.googleapis.com/v1internal:fetchAvailableModels",
            "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
        ]

        let header = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "antigravity/1.11.5 windows/amd64"
        ]

        var lastError: Error?
        for url in urls {
            do {
                let response = try await client.apiCall(
                    baseURL: baseURL,
                    request: APICallRequest(authIndex: authIndex, method: "POST", url: url, header: header, data: "{}"),
                    password: managementKey
                )
                try ensureUpstreamSuccess(response)
                return try decodeBody(AntigravityModelsPayload.self, response: response)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? QuotaError.upstreamFailed(statusCode: 0, body: "")
    }

    // MARK: - Codex

    func fetchCodexUsage(baseURL: URL, managementKey: String?, authIndex: String) async throws -> CodexUsagePayload {
        let header = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json",
            "User-Agent": "codex_cli_rs/0.76.0 (Debian 13.0.0; x86_64) WindowsTerminal"
        ]

        let response = try await client.apiCall(
            baseURL: baseURL,
            request: APICallRequest(
                authIndex: authIndex,
                method: "GET",
                url: "https://chatgpt.com/backend-api/wham/usage",
                header: header,
                data: nil
            ),
            password: managementKey
        )
        try ensureUpstreamSuccess(response)
        return try decodeBody(CodexUsagePayload.self, response: response)
    }

    // MARK: - Gemini CLI

    func fetchGeminiCliQuota(baseURL: URL, managementKey: String?, authIndex: String, projectId: String?) async throws -> GeminiCliQuotaPayload {
        let header = [
            "Authorization": "Bearer $TOKEN$",
            "Content-Type": "application/json"
        ]

        let url = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota"
        let bodyCandidates: [String] = {
            guard let projectId, !projectId.isEmpty else { return ["{}"] }
            return [
                "{\"projectId\":\"\(projectId)\"}",
                "{\"project_id\":\"\(projectId)\"}",
                "{\"parent\":\"projects/\(projectId)\"}",
                "{}"
            ]
        }()

        var lastError: Error?
        for data in bodyCandidates {
            do {
                let response = try await client.apiCall(
                    baseURL: baseURL,
                    request: APICallRequest(authIndex: authIndex, method: "POST", url: url, header: header, data: data),
                    password: managementKey
                )
                try ensureUpstreamSuccess(response)
                return try decodeBody(GeminiCliQuotaPayload.self, response: response)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? QuotaError.upstreamFailed(statusCode: 0, body: "")
    }
}

