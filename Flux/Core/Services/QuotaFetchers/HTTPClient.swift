import Foundation

actor HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get(url: URL, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request)
    }

    func post(url: URL, body: Data? = nil, headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw FluxError(code: .networkError, message: "Invalid HTTP response")
            }

            guard (200...299).contains(http.statusCode) else {
                let bodySnippet: String? = {
                    guard data.isEmpty == false else { return nil }
                    let capped = data.prefix(4096)
                    return String(data: capped, encoding: .utf8)
                }()

                let detailsBase = "HTTP \(http.statusCode) \(request.httpMethod ?? "") \(request.url?.absoluteString ?? "")"
                let details = bodySnippet.map { "\(detailsBase) body=\($0)" } ?? detailsBase

                switch http.statusCode {
                case 401, 403:
                    throw FluxError(
                        code: .authError,
                        message: "Request unauthorized",
                        details: details
                    )
                case 429:
                    throw FluxError(
                        code: .rateLimited,
                        message: "Request rate limited",
                        details: details
                    )
                default:
                    throw FluxError(
                        code: .networkError,
                        message: "HTTP request failed",
                        details: details
                    )
                }
            }

            return data
        } catch let error as FluxError {
            throw error
        } catch let urlError as URLError {
            throw FluxError(
                code: .networkError,
                message: "Network request failed",
                details: "\(urlError.code) \(urlError.localizedDescription)"
            )
        } catch {
            throw FluxError(
                code: .networkError,
                message: "Network request failed",
                details: String(describing: error)
            )
        }
    }
}
