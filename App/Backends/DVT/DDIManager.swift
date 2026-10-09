import CryptoKit
import Foundation

/// Apple's personalized Developer Disk Image — the developer-tools package the
/// location-simulation service lives in. Downloaded once from a pinned commit
/// of doronz88/DeveloperDiskImage, checksum-verified, then cached. The phone
/// asks Apple's signing server to personalize it at mount time.
enum DDIManager {
    struct Asset {
        let name: String
        let sha256: String
    }

    static let commit = "a719045a6470a8db988235230f6430b2b7df51fe"
    static let assets = [
        Asset(name: "BuildManifest.plist", sha256: "8edd4a2f4f4ef1fbd7bfe49785d8badc673d1395d1d94d85b132ca8ab5ecaf54"),
        Asset(name: "Image.dmg", sha256: "05fd807da5e19f030fa4941f24800c965c6c77982ab572dd5d1ef778fb69f9ca"),
        Asset(name: "Image.dmg.trustcache", sha256: "36af60889ff5a737874a26daeb8e1a0139ebfebec6ec2e4d8f6a3c1bf1dce35c"),
    ]

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Elsewhere/DDI-\(commit.prefix(8))", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func file(_ name: String) -> URL { directory.appending(path: name) }

    static var isCached: Bool {
        assets.allSatisfy { FileManager.default.fileExists(atPath: file($0.name).path) }
    }

    /// Downloads any missing file, verifying each against its pinned SHA-256.
    static func ensureDownloaded() async throws {
        for asset in assets where !FileManager.default.fileExists(atPath: file(asset.name).path) {
            let remote = URL(string: "https://raw.githubusercontent.com/doronz88/DeveloperDiskImage/\(commit)/PersonalizedImages/Xcode_iOS_DDI_Personalized/\(asset.name)")!
            let data: Data
            do {
                let (d, response) = try await URLSession.shared.data(from: remote)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                data = d
            } catch {
                throw BackendError("Couldn't download Apple's developer files. This needs internet once.")
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == asset.sha256 else {
                throw BackendError("Downloaded developer file failed its integrity check (\(asset.name)). Try again later.")
            }
            var url = file(asset.name)
            try data.write(to: url, options: .atomic)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
