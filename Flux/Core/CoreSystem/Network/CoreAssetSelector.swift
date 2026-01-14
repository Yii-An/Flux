import Foundation

actor CoreAssetSelector {
    static let shared = CoreAssetSelector()

    func selectMacOSAsset(from release: CoreRelease, hostArch: HostArch) throws -> CoreAsset {
        let token = hostArch.cliProxyAPIPlusAssetToken
        let expectedSuffix = "_darwin_\(token).tar.gz"

        let candidates = release.assets.filter { asset in
            let name = asset.lowercasedName
            if name == "checksums.txt" { return false }
            if name.contains("windows") { return false }
            if name.contains("linux") { return false }
            return true
        }

        if let matched = candidates.first(where: { $0.lowercasedName.hasSuffix(expectedSuffix) }) {
            return matched
        }

        throw CoreError(
            code: .noCompatibleAsset,
            message: "No compatible macOS asset found",
            details: "tag=\(release.tagName) expectedSuffix=\(expectedSuffix)"
        )
    }
}

