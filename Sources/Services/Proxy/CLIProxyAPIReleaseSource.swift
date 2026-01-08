import Foundation

/// CLIProxyAPI 发布源定义
/// 作为单一来源管理 GitHub 仓库地址
struct CLIProxyAPIReleaseSource: Codable, Sendable {
    let owner: String
    let name: String
    let host: String

    /// 官方发布源
    static let official = CLIProxyAPIReleaseSource(
        owner: "router-for-me",
        name: "CLIProxyAPI"
    )

    init(owner: String, name: String, host: String = "github.com") {
        // 规范化 host：移除 scheme 和尾部斜杠
        var normalized = host
        if normalized.hasPrefix("https://") {
            normalized = String(normalized.dropFirst(8))
        } else if normalized.hasPrefix("http://") {
            normalized = String(normalized.dropFirst(7))
        }
        if normalized.hasSuffix("/") {
            normalized = String(normalized.dropLast())
        }
        self.owner = owner
        self.name = name
        self.host = normalized
    }

    /// GitHub Release 页面 URL
    var releasesPageURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/\(owner)/\(name)/releases"
        return components.url!
    }

    /// GitHub API releases URL
    var apiReleasesURL: URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.\(host)"
        components.path = "/repos/\(owner)/\(name)/releases"
        return components.url!
    }
}
