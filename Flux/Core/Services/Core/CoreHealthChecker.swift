import Foundation

actor CoreHealthChecker {
    static let shared = CoreHealthChecker()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config)
    }

    func isHealthy(host: String = "127.0.0.1", port: UInt16) async -> Bool {
        let baseURL = "http://\(host):\(port)"
        guard let url = URL(string: "\(baseURL)/v0/management/debug") else {
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return false
            }

            // Any response (even 401/403) means the core is running.
            return (200...499).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

