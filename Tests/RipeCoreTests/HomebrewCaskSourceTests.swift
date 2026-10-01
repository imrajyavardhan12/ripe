import Foundation
import Testing

@testable import RipeCore

struct HomebrewCaskSourceTests {
    let index: CaskIndex

    init() throws {
        index = try CaskIndex.build(fromAPI: Fixture.data("cask-sample.json"))
    }

    func match(_ app: InstalledApp, installed: Set<String> = []) -> HomebrewCaskSource.Match? {
        HomebrewCaskSource.match(app, in: index, installedTokens: installed)
    }

    func release(_ app: InstalledApp, machine: Machine = .test()) -> (Release, Confidence)? {
        guard
            case .found(let release, let confidence, _)? = HomebrewCaskSource.outcome(
                for: app, in: index, machine: machine)
        else { return nil }
        return (release, confidence)
    }

    // MARK: Index

    @Test func buildsIndexFromRealCasks() throws {
        let tokens = Set(index.casks.map(\.token))
        #expect(tokens.contains("brave-browser"))
        #expect(!tokens.contains("alex313031-thorium"), "disabled casks are dropped")

        let keepass = try #require(index.casks.first { $0.token == "keepassxc" })
        #expect(keepass.appNames == ["KeePassXC.app"])
        #expect(keepass.quitIDs == ["org.keepassxc.keepassxc"])

        let vscode = try #require(index.casks.first { $0.token == "visual-studio-code" })
        #expect(vscode.variations["arm64_big_sur"]?.version == "1.106.3")
        #expect(vscode.sha256?.count == 64)
        #expect(vscode.url?.host() == "update.code.visualstudio.com")

        let mullvad = try #require(index.casks.first { $0.token == "mullvad-vpn" })
        #expect(mullvad.installsPackage)
        #expect(!keepass.installsPackage)
    }

    @Test func usesInstalledNameWhenACaskRenamesTheApp() throws {
        let json =
            #"[{"token":"t","version":"1","artifacts":[{"app":["Thorium.app",{"target":"Thorium Browser.app"}]}]}]"#
        let index = try CaskIndex.build(fromAPI: Data(json.utf8))
        #expect(index.casks.first?.appNames == ["Thorium Browser.app"])
    }

    @Test(
        arguments: [
            ("~/Library/Preferences/com.obsproject.obs-studio.plist", "com.obsproject.obs-studio"),
            ("~/Library/Saved Application State/com.brave.Browser.savedState", "com.brave.Browser"),
            ("~/Library/Caches/com.brave.Browser", "com.brave.Browser"),
            ("~/Library/Application Support/BraveSoftware/Brave-Browser", nil),
            ("~/Library/Caches/com.google.SoftwareUpdate.*", nil),
            ("~/Library/Caches/BraveSoftware/Brave-Browser", nil),
            ("~/Library/Preferences/com.3dgence.slicer.3DGence Slicer.plist", nil),
        ] as [(String, String?)])
    func extractsBundleIDsFromZapPaths(path: String, expected: String?) {
        #expect(CaskIndex.bundleID(fromZapPath: path) == expected)
    }

    // MARK: Matching

    @Test func nameAndCleanupPathMatchIsHighConfidence() throws {
        let brave = InstalledApp.test("Brave Browser.app", bundleID: "com.brave.Browser", version: "154.1.96.59")
        let found = try #require(match(brave))
        #expect(found.cask.token == "brave-browser")
        #expect(found.confidence == .high)
    }

    @Test func matchesPkgCasksByBundleID() throws {
        // Mullvad VPN installs a .pkg, so there's no app name to match.
        let mullvad = InstalledApp.test("Mullvad VPN.app", bundleID: "net.mullvad.vpn", version: "2026.3")
        let (found, confidence) = try #require(release(mullvad))
        #expect(found.caskToken == "mullvad-vpn")
        #expect(found.version == "2026.5")
        #expect(confidence == .high)
    }

    @Test func rejectsSameNameDifferentApp() {
        let impostor = InstalledApp.test("KeePassXC.app", bundleID: "com.example.not-keepass", version: "1.0")
        #expect(match(impostor) == nil)
    }

    @Test func cleanupPathAloneIsLowConfidence() throws {
        let odd = InstalledApp.test("Something Else.app", bundleID: "com.brave.Browser", version: "1.0")
        #expect(try #require(match(odd)).confidence == .low)
    }

    @Test func prefersStableChannelUnlessAnotherIsInstalled() throws {
        let onePassword = InstalledApp.test("1Password.app", bundleID: "com.1password.1password", version: "8.12.30")
        #expect(match(onePassword)?.cask.token == "1password")
        #expect(match(onePassword, installed: ["1password@beta"])?.cask.token == "1password@beta")
    }

    @Test func unversionedCaskCannotAnswer() {
        let nightly = InstalledApp.test("1Password.app", bundleID: "com.1password.nightly", version: "8.13")
        let outcome = HomebrewCaskSource.outcome(for: nightly, in: index, machine: .test())
        guard case .failed(let message)? = outcome else {
            Issue.record("expected failure, got \(String(describing: outcome))")
            return
        }
        #expect(message.contains("version: latest"))
    }

    @Test func splitsShortAndBuildVersions() throws {
        let box = InstalledApp.test("86Box.app", bundleID: "net.86Box.86Box", version: "5.0")
        let (found, confidence) = try #require(release(box))
        #expect(found.version == "6.0")
        #expect(found.build == "9001")
        #expect(found.comparison == .shortVersion)
        #expect(confidence == .high)  // name + `~/Library/Preferences/net.86Box.86Box.plist`

        let nameOnly = InstalledApp.test("86Box.app", bundleID: "org.example.box", version: "5.0")
        #expect(release(nameOnly)?.1 == .medium)
    }

    @Test func resolvesVariationsForThisMac() throws {
        let code = InstalledApp.test("Visual Studio Code.app", bundleID: "com.microsoft.VSCode", version: "1.100")
        #expect(release(code, machine: .test(macOS: "27.0"))?.0.version == "1.139.1")
        #expect(release(code, machine: .test(macOS: "11.7"))?.0.version == "1.106.3")
        #expect(release(code, machine: .test(macOS: "11.7", architecture: .intel))?.0.version == "1.106.3")
        #expect(release(code, machine: .test(macOS: "15.6", architecture: .intel))?.0.version == "1.139.1")
    }

    // MARK: Loading and caching

    @Test func cachesCompactIndexByETag() async throws {
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "ripe-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheDirectory) }
        let cache = DiskCache(directory: cacheDirectory)
        let context = SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test(), cache: cache)

        let first = try await HomebrewCaskSource.loadIndex(context: context)
        let stored = await cache.load(DiskCache.key(for: HomebrewCaskSource.derivedIndexKey))
        #expect(stored?.metadata.etag == "\"v1\"")

        // Same ETag: the compact index is used even if the raw body is garbage.
        let garbage = FakeHTTPClient([
            ("https://formulae.brew.sh/", .ok(Data("nope".utf8), headers: ["ETag": "\"v1\""]))
        ])
        let second = try await HomebrewCaskSource.loadIndex(
            context: SourceContext(http: garbage, machine: .test(), cache: cache))
        #expect(second.casks == first.casks)

        // New ETag: the raw body is parsed again.
        let changed = FakeHTTPClient([
            ("https://formulae.brew.sh/", .ok(Data("nope".utf8), headers: ["ETag": "\"v2\""]))
        ])
        await #expect(throws: (any Error).self) {
            try await HomebrewCaskSource.loadIndex(
                context: SourceContext(http: changed, machine: .test(), cache: cache))
        }
    }
}
