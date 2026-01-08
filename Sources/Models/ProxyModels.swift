import Foundation

/// CLIProxyAPI 版本信息
struct ProxyVersion: Codable, Equatable, Identifiable {
    let version: String
    let downloadURL: URL?
    let sha256: String?
    let releaseDate: Date?

    var id: String { version }

    /// 是否为旧版迁移
    var isLegacy: Bool {
        version == "legacy"
    }
}

/// GitHub Release Asset
struct GitHubReleaseAsset: Codable {
    let name: String
    let browserDownloadUrl: String
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

/// GitHub Release
struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let publishedAt: String?
    let body: String?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case publishedAt = "published_at"
        case body
        case assets
    }

    /// 获取适用于当前平台的下载 URL
    var macOSAssetURL: URL? {
        // 查找 macOS 相关的 asset
        let macAsset = assets.first { asset in
            let name = asset.name.lowercased()
            return name.contains("macos") || name.contains("darwin") || name.contains("mac")
        }

        // 如果没有特定平台标记，尝试找通用的
        let fallbackAsset = macAsset ?? assets.first { asset in
            let name = asset.name.lowercased()
            return !name.contains("windows") && !name.contains("linux") &&
                   (name.hasSuffix(".zip") || name.hasSuffix(".tar.gz") || !name.contains("."))
        }

        guard let asset = fallbackAsset else { return nil }
        return URL(string: asset.browserDownloadUrl)
    }

    /// 版本号（去除 v 前缀）
    var versionNumber: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

/// 下载进度
struct DownloadProgress: Sendable {
    let bytesWritten: Int64
    let totalBytes: Int64

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(bytesWritten) / Double(totalBytes)
    }

    var formattedProgress: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let written = formatter.string(fromByteCount: bytesWritten)
        let total = formatter.string(fromByteCount: totalBytes)
        return "\(written) / \(total)"
    }
}
