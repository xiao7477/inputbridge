import AppKit
import CryptoKit
import Foundation

@MainActor
final class GitHubUpdater: ObservableObject {
    @Published private(set) var status = "尚未检查更新"
    @Published private(set) var isRunning = false

    private let repository = "xiao7477/inputbridge"
    private let assetName = "inputbridge-macOS14-arm64.zip"

    func checkAndInstall() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            status = "正在检查 GitHub 最新版本…"
            let release = try await latestRelease()
            let newest = try versionComponents(release.tagName)
            let currentName = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
            let current = try versionComponents(currentName)
            guard compare(newest, current) == .orderedDescending else {
                status = "已是最新版本（\(currentName)）"
                return
            }
            guard let asset = release.assets.first(where: { $0.name == assetName }) else {
                throw UpdateFailure("GitHub 最新版本尚未附带 macOS 安装包。")
            }
            guard asset.url.host == "github.com",
                  asset.url.path.hasPrefix("/\(repository)/releases/download/") else {
                throw UpdateFailure("更新包地址不属于项目的 GitHub Release。")
            }
            guard let digest = asset.digest?.lowercased(),
                  digest.hasPrefix("sha256:"), digest.count == 71 else {
                throw UpdateFailure("更新包缺少 SHA-256 校验值。")
            }

            status = "正在下载 \(release.tagName)…"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("InputBridge-Update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            let archive = directory.appendingPathComponent(assetName)
            var request = URLRequest(url: asset.url)
            request.setValue("InputBridge-Updater", forHTTPHeaderField: "User-Agent")
            let (downloaded, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateFailure("GitHub 更新包下载失败。")
            }
            try FileManager.default.moveItem(at: downloaded, to: archive)
            status = "正在校验安装包…"
            let actualDigest = SHA256.hash(data: try Data(contentsOf: archive))
                .map { String(format: "%02x", $0) }.joined()
            guard digest == "sha256:\(actualDigest)" else {
                throw UpdateFailure("下载包的 SHA-256 与 GitHub 发布信息不一致。")
            }
            try run("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
            let replacement = directory.appendingPathComponent("语音输入共享.app", isDirectory: true)
            guard let bundle = Bundle(url: replacement),
                  bundle.bundleIdentifier == "com.inputbridge.macos",
                  bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ==
                    release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
                  bundle.executableURL != nil else {
                throw UpdateFailure("安装包中的 App 名称或版本不匹配。")
            }
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", replacement.path])
            let currentApp = Bundle.main.bundleURL.standardizedFileURL
            guard currentApp.pathExtension == "app" else {
                throw UpdateFailure("无法确定当前 App 的安装位置。")
            }
            let destination: URL
            if FileManager.default.isWritableFile(atPath: currentApp.deletingLastPathComponent().path) {
                destination = currentApp
            } else {
                let applications = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true)
                try FileManager.default.createDirectory(at: applications,
                                                        withIntermediateDirectories: true)
                destination = applications.appendingPathComponent("语音输入共享.app", isDirectory: true)
            }
            guard let bundledHelper = Bundle.main.url(forResource: "install-update", withExtension: "sh") else {
                throw UpdateFailure("当前 App 缺少更新安装程序，请手动安装这个版本。")
            }
            let helper = directory.appendingPathComponent("install-update.sh")
            try FileManager.default.copyItem(at: bundledHelper, to: helper)
            let agent = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.inputbridge.macos.autostart.plist")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [helper.path, replacement.path, destination.path,
                                 String(ProcessInfo.processInfo.processIdentifier), agent.path]
            try process.run()
            status = "更新已校验，正在重启 App…"
            NSApp.terminate(nil)
        } catch {
            status = "更新失败：\(error.localizedDescription)"
        }
    }

    private func latestRelease() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateFailure("GitHub 地址无效。")
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("InputBridge-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateFailure("未能读取 GitHub 最新发布版本。")
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    private func versionComponents(_ raw: String) throws -> [Int] {
        let version = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        let components = version.split(separator: ".")
        guard (2...4).contains(components.count),
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              components.allSatisfy({ Int($0) != nil }) else {
            throw UpdateFailure("GitHub 发布版本号格式无效。")
        }
        return components.compactMap { Int($0) }
    }

    private func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right { return .orderedAscending }
            if left > right { return .orderedDescending }
        }
        return .orderedSame
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateFailure("安装包展开或签名校验失败。")
        }
    }
}

private struct Release: Decodable {
    let tagName: String
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", assets
    }
}

private struct ReleaseAsset: Decodable {
    let name: String
    let url: URL
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, digest
        case url = "browser_download_url"
    }
}

private struct UpdateFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
