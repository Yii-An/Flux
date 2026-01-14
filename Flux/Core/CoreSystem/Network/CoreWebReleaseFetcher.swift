import Foundation

actor CoreWebReleaseFetcher {
    static let shared = CoreWebReleaseFetcher()

    private let session: URLSession

    private let githubBaseURL = URL(string: "https://github.com")!
    private let releasesLatestURL = URL(string: "https://github.com/router-for-me/CLIProxyAPIPlus/releases/latest")!
    private let releasesAtomURL = URL(string: "https://github.com/router-for-me/CLIProxyAPIPlus/releases.atom")!

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public

    /// Fetch latest tag by requesting `.../releases/latest` and reading the `Location` header from 302.
    /// Important: does not automatically follow redirects.
    func fetchLatestTag() async throws -> String {
        var request = URLRequest(url: releasesLatestURL)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await dataWithoutRedirect(for: request)
        _ = data

        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .webFetchFailed, message: "Invalid HTTP response")
        }

        guard (300...399).contains(http.statusCode) else {
            throw CoreError(code: .webFetchFailed, message: "Expected redirect response", details: "HTTP \(http.statusCode) \(releasesLatestURL.absoluteString)")
        }

        guard let location = http.value(forHTTPHeaderField: "Location") ?? http.value(forHTTPHeaderField: "location"),
              let redirectedURL = URL(string: location, relativeTo: releasesLatestURL) else {
            throw CoreError(code: .webFetchFailed, message: "Missing redirect Location header", details: releasesLatestURL.absoluteString)
        }

        return try parseTag(fromReleaseTagURL: redirectedURL)
    }

    /// Fetch recent release tags from GitHub Releases Atom feed.
    func fetchRecentTags(limit: Int = 20) async throws -> [String] {
        guard limit > 0 else { return [] }

        var request = URLRequest(url: releasesAtomURL)
        request.httpMethod = "GET"
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await fetch(request: request)
        guard let xml = String(data: data, encoding: .utf8) else {
            throw CoreError(code: .parseError, message: "Failed to decode Atom feed", details: releasesAtomURL.absoluteString)
        }

        let tags = try parseAtomTags(xml: xml)
        if tags.isEmpty {
            throw CoreError(code: .parseError, message: "No tags found in Atom feed", details: releasesAtomURL.absoluteString)
        }

        var unique: [String] = []
        var seen: Set<String> = []
        for tag in tags {
            if seen.insert(tag).inserted {
                unique.append(tag)
            }
            if unique.count >= max(0, limit) { break }
        }
        return unique
    }

    /// Fetch assets for a given tag by scraping GitHub `expanded_assets` HTML.
    /// Returns darwin assets only (no automatic cross-arch downgrade).
    func fetchAssets(tag: String) async throws -> [CoreAsset] {
        let url = URL(string: "https://github.com/router-for-me/CLIProxyAPIPlus/releases/expanded_assets/\(tag)")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("Flux", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await fetch(request: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw CoreError(code: .parseError, message: "Failed to decode expanded_assets HTML", details: url.absoluteString)
        }

        if html.isEmpty {
            throw CoreError(code: .htmlParseError, message: "Empty expanded_assets HTML", details: url.absoluteString)
        }

        let assets = try parseExpandedAssetsHTML(html, baseURL: githubBaseURL)
            .filter { $0.name.lowercased().contains("darwin") }

        if assets.isEmpty {
            throw CoreError(code: .noCompatibleAsset, message: "No darwin assets found", details: "tag=\(tag)")
        }

        return assets
    }

    func fetchRelease(tag: String) async throws -> CoreRelease {
        let assets = try await fetchAssets(tag: tag)
        return CoreRelease(tagName: tag, name: nil, publishedAt: nil, assets: assets)
    }

    func fetchReleases(limit: Int) async throws -> [CoreRelease] {
        let tags = try await fetchRecentTags(limit: limit)

        return try await withThrowingTaskGroup(of: CoreRelease.self) { group in
            for tag in tags {
                group.addTask {
                    return try await self.fetchRelease(tag: tag)
                }
            }

            var releases: [CoreRelease] = []
            releases.reserveCapacity(tags.count)
            while let next = try await group.next() {
                releases.append(next)
            }

            // Preserve the Atom feed order (newest first).
            let order = Dictionary(uniqueKeysWithValues: tags.enumerated().map { ($0.element, $0.offset) })
            releases.sort { (lhs, rhs) in
                (order[lhs.tagName] ?? Int.max) < (order[rhs.tagName] ?? Int.max)
            }
            return releases
        }
    }

    // MARK: - Private (HTTP)

    private func fetch(request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CoreError(code: .networkError, message: "Invalid HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw CoreError(code: .rateLimited, message: "Request rate limited", details: "HTTP 429 \(request.url?.absoluteString ?? "")")
            }
            if http.statusCode == 403, http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                throw CoreError(code: .rateLimited, message: "Request rate limited", details: "HTTP 403 rate limited \(request.url?.absoluteString ?? "")")
            }
            throw CoreError(code: .networkError, message: "HTTP request failed", details: "HTTP \(http.statusCode) \(request.url?.absoluteString ?? "")")
        }
        return (data, http)
    }

    private func dataWithoutRedirect(for request: URLRequest) async throws -> (Data, URLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30

        let delegate = NoRedirectSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        return try await session.data(for: request)
    }

    private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    // MARK: - Private (Parsing)

    private func parseTag(fromReleaseTagURL url: URL) throws -> String {
        // Expected: .../releases/tag/<tag>
        let components = url.pathComponents
        if let index = components.lastIndex(of: "tag"), index + 1 < components.count {
            let tag = components[index + 1]
            guard !tag.isEmpty else {
                throw CoreError(code: .parseError, message: "Empty tag in redirect URL", details: url.absoluteString)
            }
            return tag
        }

        // Fallback: last path component.
        let tag = url.lastPathComponent
        guard !tag.isEmpty else {
            throw CoreError(code: .parseError, message: "Failed to parse tag", details: url.absoluteString)
        }
        return tag
    }

    private func parseAtomTags(xml: String) throws -> [String] {
        guard let data = xml.data(using: .utf8) else {
            throw CoreError(code: .parseError, message: "Failed to encode Atom XML")
        }

        let parser = XMLParser(data: data)
        let delegate = AtomTagsParserDelegate()
        parser.delegate = delegate

        guard parser.parse() else {
            let error = parser.parserError?.localizedDescription ?? "Unknown XMLParser error"
            throw CoreError(code: .parseError, message: "Failed to parse Atom feed", details: error)
        }

        return delegate.tags
    }

    private final class AtomTagsParserDelegate: NSObject, XMLParserDelegate {
        private var inEntry = false
        private var inTitle = false
        private var currentTitle = ""

        fileprivate var tags: [String] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch elementName {
            case "entry":
                inEntry = true
            case "title":
                if inEntry {
                    inTitle = true
                    currentTitle = ""
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard inEntry, inTitle else { return }
            currentTitle.append(string)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            switch elementName {
            case "title":
                guard inEntry, inTitle else { return }
                inTitle = false
                let raw = currentTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                if let tag = Self.extractTag(from: raw) {
                    tags.append(tag)
                }
            case "entry":
                inEntry = false
                inTitle = false
                currentTitle = ""
            default:
                break
            }
        }

        private static func extractTag(from title: String) -> String? {
            // Typical: "v6.6.103-0"
            if title.hasPrefix("v") { return title }
            if title.first?.isNumber == true { return title }

            // Fallback: find first token like vX.Y.Z...
            if let range = title.range(of: #"v\d+\.\d+\.\d+[0-9A-Za-z.\-]*"#, options: .regularExpression) {
                return String(title[range])
            }

            return nil
        }
    }

    private func parseExpandedAssetsHTML(_ html: String, baseURL: URL) throws -> [CoreAsset] {
        // Extract asset list items by finding download hrefs and reading the surrounding <li>..</li> snippet.
        let pattern = #"href="(?<href>/router-for-me/CLIProxyAPIPlus/releases/download/[^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let ns = html as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: html, options: [], range: fullRange)

        if matches.isEmpty {
            throw CoreError(code: .htmlParseError, message: "No assets found in expanded_assets HTML")
        }

        var assets: [CoreAsset] = []
        assets.reserveCapacity(matches.count)

        for match in matches {
            guard let hrefRange = Range(match.range(withName: "href"), in: html) else { continue }
            let href = String(html[hrefRange])

            let filename = URL(string: href, relativeTo: baseURL)?.lastPathComponent ?? URL(fileURLWithPath: href).lastPathComponent
            if filename.isEmpty { continue }

            // Grab the <li> block for this href to parse digest and size.
            let snippetStart = match.range.location
            let snippetEnd = Self.findEndOfListItem(in: ns, startingAt: snippetStart) ?? ns.length
            let snippet = ns.substring(with: NSRange(location: snippetStart, length: max(0, snippetEnd - snippetStart)))

            let digest = Self.parseDigest(from: snippet)
            let size = Self.parseSizeBytes(from: snippet) ?? 0

            guard let url = URL(string: href, relativeTo: baseURL) else { continue }

            assets.append(
                CoreAsset(
                    name: filename,
                    browserDownloadURL: url,
                    size: size,
                    digest: digest,
                    contentType: nil
                )
            )
        }

        // Deduplicate by name (GitHub can repeat hrefs in some responsive layouts).
        var seen: Set<String> = []
        return assets.filter { seen.insert($0.name).inserted }
    }

    private static func findEndOfListItem(in ns: NSString, startingAt start: Int) -> Int? {
        let searchRange = NSRange(location: start, length: max(0, ns.length - start))
        let closing = ns.range(of: "</li>", options: [], range: searchRange)
        guard closing.location != NSNotFound else { return nil }
        return closing.location + closing.length
    }

    private static func parseDigest(from htmlSnippet: String) -> String? {
        let pattern = #"sha256:([0-9a-fA-F]{64})"#
        if let range = htmlSnippet.range(of: pattern, options: .regularExpression) {
            return String(htmlSnippet[range]).lowercased()
        }
        return nil
    }

    private static func parseSizeBytes(from htmlSnippet: String) -> Int? {
        // Examples: "666 Bytes", "11.1 MB"
        let pattern = #">\s*([0-9.]+)\s*(Bytes|KB|MB|GB)\s*<"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let ns = htmlSnippet as NSString
        let matches = regex.matches(in: htmlSnippet, options: [], range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first, first.numberOfRanges >= 3 else { return nil }

        let number = ns.substring(with: first.range(at: 1))
        let unit = ns.substring(with: first.range(at: 2))

        guard let value = Double(number) else { return nil }

        let multiplier: Double
        switch unit {
        case "Bytes":
            multiplier = 1
        case "KB":
            multiplier = 1024
        case "MB":
            multiplier = 1024 * 1024
        case "GB":
            multiplier = 1024 * 1024 * 1024
        default:
            multiplier = 1
        }

        let bytes = Int((value * multiplier).rounded(.toNearestOrEven))
        return max(0, bytes)
    }
}
