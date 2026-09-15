import AppKit
import Combine
import CryptoKit
import Foundation

struct AvailableAppUpdate: Identifiable, Equatable, Sendable {
    var id: String { version }
    let version: String
    let assetName: String
    let downloadURL: URL
    let size: Int64
    let digest: String?
}

private struct GitHubRelease: Decodable {
    let assets: [GitHubAsset]
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int64
    let digest: String?

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}

@MainActor
final class AppUpdateService: ObservableObject {
    static let shared = AppUpdateService()
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/fliname/Reading-Companion-Open/releases/latest")!

    @Published var availableUpdate: AvailableAppUpdate?
    private var hasChecked = false

    private init() {}

    func checkForUpdates(manual: Bool = false) async {
        guard manual || !hasChecked else { return }
        guard manual || Bundle.main.bundleURL.pathExtension == "app" else { return }
        hasChecked = true
        do {
            var request = URLRequest(url: Self.latestReleaseURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Reading-Companion-Open/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            guard let update = Self.selectUpdate(
                assets: release.assets.map { ($0.name, $0.browserDownloadURL, $0.size, $0.digest) },
                currentVersion: Self.currentVersion,
                architecture: Self.currentArchitecture
            ) else { return }
            if !manual, UserDefaults.standard.string(forKey: "skippedUpdateVersion") == update.version { return }
            availableUpdate = update
        } catch {
            // Automatic checks are intentionally quiet when the device is
            // offline or GitHub is temporarily unavailable.
        }
    }

    func dismiss() {
        availableUpdate = nil
    }

    func skip(_ update: AvailableAppUpdate) {
        UserDefaults.standard.set(update.version, forKey: "skippedUpdateVersion")
        availableUpdate = nil
    }

    func downloadAndOpen(_ update: AvailableAppUpdate) async throws {
        availableUpdate = nil
        let (temporaryURL, response) = try await URLSession.shared.download(from: update.downloadURL)
        guard let httpResponse = response as? HTTPURLResponse,
              (200 ... 299).contains(httpResponse.statusCode) else {
            throw UpdateError.downloadFailed
        }
        let downloads = try FileManager.default.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let destination = downloads.appendingPathComponent(update.assetName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        do {
            try await Self.validateInstaller(at: destination, update: update)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        guard NSWorkspace.shared.open(destination) else { throw UpdateError.cannotOpenInstaller }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }

    nonisolated static func compareVersions(_ left: String, _ right: String) -> Int {
        let a = left.split(separator: ".").map { Int($0) ?? 0 }
        let b = right.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0 ..< max(a.count, b.count) {
            let difference = (index < a.count ? a[index] : 0) - (index < b.count ? b[index] : 0)
            if difference != 0 { return difference > 0 ? 1 : -1 }
        }
        return 0
    }

    nonisolated static func selectUpdate(
        assets: [(name: String, url: URL, size: Int64, digest: String?)],
        currentVersion: String,
        architecture: String
    ) -> AvailableAppUpdate? {
        let escapedArchitecture = NSRegularExpression.escapedPattern(for: architecture)
        let expression = try? NSRegularExpression(
            pattern: "^Reading-Companion-Open-([0-9]+(?:\\.[0-9]+){2,3})-macOS-\(escapedArchitecture)\\.dmg$",
            options: [.caseInsensitive]
        )
        let matches = assets.compactMap { asset -> AvailableAppUpdate? in
            let range = NSRange(asset.name.startIndex..., in: asset.name)
            guard let match = expression?.firstMatch(in: asset.name, range: range),
                  let versionRange = Range(match.range(at: 1), in: asset.name) else { return nil }
            return AvailableAppUpdate(
                version: String(asset.name[versionRange]),
                assetName: asset.name,
                downloadURL: asset.url,
                size: asset.size,
                digest: asset.digest
            )
        }
        .sorted { compareVersions($0.version, $1.version) > 0 }
        guard let update = matches.first, compareVersions(update.version, currentVersion) > 0 else { return nil }
        return update
    }

    nonisolated private static func validateInstaller(at url: URL, update: AvailableAppUpdate) async throws {
        try await Task.detached {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if update.size > 0, actualSize != update.size { throw UpdateError.integrityFailed }
            guard let digest = update.digest, digest.lowercased().hasPrefix("sha256:") else { return }
            let expected = String(digest.dropFirst(7)).lowercased()
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
            let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if actual != expected { throw UpdateError.integrityFailed }
        }.value
    }
}

private enum UpdateError: LocalizedError, Sendable {
    case downloadFailed
    case integrityFailed
    case cannotOpenInstaller

    var errorDescription: String? {
        switch self {
        case .downloadFailed: "下载安装包失败，请稍后重试。"
        case .integrityFailed: "安装包完整性校验失败，请稍后重试。"
        case .cannotOpenInstaller: "安装包已下载，但无法自动打开。请前往“下载”文件夹手动打开。"
        }
    }
}
