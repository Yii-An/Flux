import Foundation
import os.log

actor ManagementAPIClient {
    private let session: URLSession
    private let logger = Logger(subsystem: "com.flux.app", category: "ManagementAPI")
    private let timeout: TimeInterval = 10

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Health / Config

    func checkHealth(baseURL: URL, password: String? = nil) async throws -> HealthResponse {
        let url = baseURL.appendingPathComponent("config")
        let data = try await performRequest(url: url, method: "GET", password: password)
        return try decode(HealthResponse.self, from: data)
    }

    func checkHealthWithVersion(baseURL: URL, password: String? = nil) async throws -> (HealthResponse, String?) {
        let url = baseURL.appendingPathComponent("config")
        let (data, response) = try await performRequestWithResponse(url: url, method: "GET", password: password)
        let health = try decode(HealthResponse.self, from: data)
        let version = extractVersion(from: response)
        return (health, version)
    }

    // MARK: - API Keys

    func listAccounts(baseURL: URL, password: String? = nil) async throws -> [String] {
        let url = baseURL.appendingPathComponent("api-keys")
        let data = try await performRequest(url: url, method: "GET", password: password)
        let response = try decode(APIKeysResponse.self, from: data)
        return response.keys ?? []
    }

    func updateApiKeys(baseURL: URL, keys: [String], password: String? = nil) async throws {
        let url = baseURL.appendingPathComponent("api-keys")
        let body = try JSONEncoder().encode(keys)
        _ = try await performRequest(url: url, method: "PUT", body: body, password: password)
    }

    func deleteApiKey(baseURL: URL, index: Int, password: String? = nil) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("api-keys"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        _ = try await performRequest(url: components.url!, method: "DELETE", password: password)
    }

    // MARK: - Dashboard Stats

    func getOpenAICompatibility(baseURL: URL, password: String? = nil) async throws -> OpenAICompatibilityResponse {
        let url = baseURL.appendingPathComponent("openai-compatibility")
        let data = try await performRequest(url: url, method: "GET", password: password)
        return try decode(OpenAICompatibilityResponse.self, from: data)
    }

    func getGeminiApiKeys(baseURL: URL, password: String? = nil) async throws -> GeminiApiKeyResponse {
        let url = baseURL.appendingPathComponent("gemini-api-key")
        let data = try await performRequest(url: url, method: "GET", password: password)
        return try decode(GeminiApiKeyResponse.self, from: data)
    }

    func getCodexApiKeys(baseURL: URL, password: String? = nil) async throws -> CodexApiKeyResponse {
        let url = baseURL.appendingPathComponent("codex-api-key")
        let data = try await performRequest(url: url, method: "GET", password: password)
        return try decode(CodexApiKeyResponse.self, from: data)
    }

    func getClaudeApiKeys(baseURL: URL, password: String? = nil) async throws -> ClaudeApiKeyResponse {
        let url = baseURL.appendingPathComponent("claude-api-key")
        let data = try await performRequest(url: url, method: "GET", password: password)
        return try decode(ClaudeApiKeyResponse.self, from: data)
    }

    func getAuthFiles(baseURL: URL, password: String? = nil) async throws -> AuthFilesResponse {
        let url = baseURL.appendingPathComponent("auth-files")
        let data = try await performRequest(url: url, method: "GET", password: password)
        return try decode(AuthFilesResponse.self, from: data)
    }

    // MARK: - API Tools

    func apiCall(baseURL: URL, request: APICallRequest, password: String? = nil) async throws -> APICallResponse {
        let url = baseURL.appendingPathComponent("api-call")
        let body = try JSONEncoder().encode(request)
        let data = try await performRequest(url: url, method: "POST", body: body, password: password)
        return try decode(APICallResponse.self, from: data)
    }

    // MARK: - Provider Keys (Write Operations)

    func putGeminiApiKeys(baseURL: URL, keys: [ProviderKeyPayload], password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("gemini-api-key")
        let body = try JSONEncoder().encode(keys)
        let data = try await performRequest(url: url, method: "PUT", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchGeminiApiKeyByIndex(baseURL: URL, index: Int, value: ProviderKeyPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("gemini-api-key")
        let patch = IndexValuePatch(index: index, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchGeminiApiKeyByMatch(baseURL: URL, match: String, value: ProviderKeyPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("gemini-api-key")
        let patch = MatchValuePatch(match: match, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteGeminiApiKeyByIndex(baseURL: URL, index: Int, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("gemini-api-key"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteGeminiApiKeyByKey(baseURL: URL, apiKey: String, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("gemini-api-key"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-key", value: apiKey)]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func putCodexApiKeys(baseURL: URL, keys: [ProviderKeyPayload], password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("codex-api-key")
        let body = try JSONEncoder().encode(keys)
        let data = try await performRequest(url: url, method: "PUT", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchCodexApiKeyByIndex(baseURL: URL, index: Int, value: ProviderKeyPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("codex-api-key")
        let patch = IndexValuePatch(index: index, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchCodexApiKeyByMatch(baseURL: URL, match: String, value: ProviderKeyPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("codex-api-key")
        let patch = MatchValuePatch(match: match, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteCodexApiKeyByIndex(baseURL: URL, index: Int, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("codex-api-key"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteCodexApiKeyByKey(baseURL: URL, apiKey: String, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("codex-api-key"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-key", value: apiKey)]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func putClaudeApiKeys(baseURL: URL, keys: [ProviderKeyPayload], password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("claude-api-key")
        let body = try JSONEncoder().encode(keys)
        let data = try await performRequest(url: url, method: "PUT", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchClaudeApiKeyByIndex(baseURL: URL, index: Int, value: ProviderKeyPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("claude-api-key")
        let patch = IndexValuePatch(index: index, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchClaudeApiKeyByMatch(baseURL: URL, match: String, value: ProviderKeyPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("claude-api-key")
        let patch = MatchValuePatch(match: match, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteClaudeApiKeyByIndex(baseURL: URL, index: Int, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("claude-api-key"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteClaudeApiKeyByKey(baseURL: URL, apiKey: String, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("claude-api-key"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api-key", value: apiKey)]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func putOpenAICompatibility(baseURL: URL, entries: [OpenAICompatPayload], password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("openai-compatibility")
        let body = try JSONEncoder().encode(entries)
        let data = try await performRequest(url: url, method: "PUT", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchOpenAICompatibilityByIndex(baseURL: URL, index: Int, value: OpenAICompatPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("openai-compatibility")
        let patch = IndexValuePatch(index: index, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func patchOpenAICompatibilityByName(baseURL: URL, name: String, value: OpenAICompatPayload, password: String? = nil) async throws -> StatusOKResponse {
        let url = baseURL.appendingPathComponent("openai-compatibility")
        let patch = NameValuePatch(name: name, value: value)
        let body = try JSONEncoder().encode(patch)
        let data = try await performRequest(url: url, method: "PATCH", body: body, password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteOpenAICompatibilityByIndex(baseURL: URL, index: Int, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("openai-compatibility"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "index", value: String(index))]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func deleteOpenAICompatibilityByName(baseURL: URL, name: String, password: String? = nil) async throws -> StatusOKResponse {
        var components = URLComponents(url: baseURL.appendingPathComponent("openai-compatibility"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        let data = try await performRequest(url: components.url!, method: "DELETE", password: password)
        return try decode(StatusOKResponse.self, from: data)
    }

    func getModels(openAIBaseURL: URL, apiKey: String) async throws -> ModelsResponse {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ManagementAPIError.notConnected
        }
        let url = openAIBaseURL.appendingPathComponent("models")
        let data = try await performRequest(url: url, method: "GET", password: apiKey)
        return try decode(ModelsResponse.self, from: data)
    }

    func derivedOpenAIBaseURL(from managementBaseURL: URL) -> URL {
        var urlString = managementBaseURL.absoluteString

        while urlString.hasSuffix("/") {
            urlString.removeLast()
        }

        let suffix = "/v0/management"
        if urlString.lowercased().hasSuffix(suffix.lowercased()) {
            urlString = String(urlString.dropLast(suffix.count))
        }

        urlString += "/v1"
        return URL(string: urlString) ?? managementBaseURL
    }

    // MARK: - Private

    private func performRequestWithResponse(url: URL, method: String, body: Data? = nil, password: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        request.timeoutInterval = timeout

        if let password = password, !password.isEmpty {
            request.setValue("Bearer \(password)", forHTTPHeaderField: "Authorization")
        }

        logger.debug("\(method) \(url.absoluteString)")

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ManagementAPIError.networkError(URLError(.badServerResponse))
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                logger.error("HTTP \(httpResponse.statusCode): \(body ?? "empty")")

                if httpResponse.statusCode == 401 {
                    throw ManagementAPIError.unauthorized
                }

                throw ManagementAPIError.httpError(statusCode: httpResponse.statusCode, body: body)
            }

            return (data, httpResponse)
        } catch let error as ManagementAPIError {
            throw error
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw ManagementAPIError.networkError(error)
        }
    }

    private func performRequest(url: URL, method: String, body: Data? = nil, password: String? = nil) async throws -> Data {
        let (data, _) = try await performRequestWithResponse(url: url, method: method, body: body, password: password)
        return data
    }

    private func extractVersion(from response: HTTPURLResponse) -> String? {
        let fields = response.allHeaderFields
        // Build normalized dictionary safely (avoid crash on duplicate keys)
        var normalized: [String: String] = [:]
        for (key, value) in fields {
            let keyString = String(describing: key).lowercased()
            let valueString = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !keyString.isEmpty, !valueString.isEmpty else { continue }
            normalized[keyString] = valueString  // last wins if duplicate
        }

        // Return version, stripping 'v' prefix for consistency
        if let version = normalized["x-cpa-version"] ?? normalized["x-server-version"] {
            return version.hasPrefix("v") ? String(version.dropFirst()) : version
        }
        return nil
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            logger.error("Decoding error: \(error.localizedDescription)")
            throw ManagementAPIError.decodingError(error)
        }
    }
}
