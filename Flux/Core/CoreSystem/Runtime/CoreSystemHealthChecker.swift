import Foundation

actor CoreSystemHealthChecker {
    static let shared = CoreSystemHealthChecker()

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = CoreConfig.healthCheckTimeoutSeconds
        config.timeoutIntervalForResource = CoreConfig.healthCheckTimeoutSeconds
        self.session = URLSession(configuration: config)
    }

    func isHealthy(host: String = "127.0.0.1", port: UInt16, retries: Int = CoreConfig.healthCheckRetries) async -> Bool {
        let url = URL(string: "http://\(host):\(port)/v0/management/debug")
        guard let url else { return false }

        var attempts = 0
        while true {
            attempts += 1

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = CoreConfig.healthCheckTimeoutSeconds

            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    if attempts > retries + 1 { return false }
                    continue
                }
                return (200...499).contains(http.statusCode)
            } catch {
                if attempts > retries + 1 { return false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
}

