import Foundation
import Testing
@testable import ReadingCompanion

@Suite("Application updates")
struct AppUpdateServiceTests {
    @Test func comparesNumericVersions() {
        #expect(AppUpdateService.compareVersions("0.43.12", "0.43.11") == 1)
        #expect(AppUpdateService.compareVersions("0.43.11", "0.43.11") == 0)
        #expect(AppUpdateService.compareVersions("0.43.9", "0.43.11") == -1)
    }

    @Test func selectsOnlyNewerInstallerForCurrentArchitecture() throws {
        let assets = [
            (name: "Reading-Companion-Open-0.43.12-macOS-arm64.dmg", url: try #require(URL(string: "https://example.com/mac")), size: Int64(123), digest: Optional<String>.none),
            (name: "Reading-Companion-Open-0.43.23-Windows-x64-Setup.exe", url: try #require(URL(string: "https://example.com/win")), size: Int64(456), digest: Optional<String>.none)
        ]
        #expect(AppUpdateService.selectUpdate(assets: assets, currentVersion: "0.43.11", architecture: "arm64")?.version == "0.43.12")
        #expect(AppUpdateService.selectUpdate(assets: assets, currentVersion: "0.43.12", architecture: "arm64") == nil)
    }
}
