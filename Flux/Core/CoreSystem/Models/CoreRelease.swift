import Foundation

struct CoreRelease: Codable, Sendable, Equatable {
    var tagName: String
    var name: String?
    var publishedAt: Date?
    var assets: [CoreAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case assets
    }

    /// Strips leading `v` from Git tags like `v6.6.103-0`.
    var versionString: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

struct CoreAsset: Codable, Sendable, Equatable {
    var name: String
    var browserDownloadURL: URL
    var size: Int
    var digest: String?
    var contentType: String?

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
        case digest
        case contentType = "content_type"
    }
}

extension CoreAsset {
    var sha256Digest: String? {
        guard let digest, digest.hasPrefix("sha256:") else { return nil }
        return String(digest.dropFirst("sha256:".count))
    }

    var lowercasedName: String { name.lowercased() }

    var isTarGz: Bool {
        lowercasedName.hasSuffix(".tar.gz") || lowercasedName.hasSuffix(".tgz")
    }

    var isZip: Bool {
        lowercasedName.hasSuffix(".zip")
    }
}

