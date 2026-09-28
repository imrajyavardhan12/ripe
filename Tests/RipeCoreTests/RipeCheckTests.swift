import Foundation
import Testing

@testable import RipeCore

/// The whole pipeline: real bundles on disk, fixture-backed network, real sources.
struct RipeCheckTests {
    @Test func endToEnd() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app(
            "OBS.app",
            info: [
                "CFBundleIdentifier": "com.obsproject.obs-studio", "CFBundleShortVersionString": "32.2.1",
                "CFBundleVersion": "31000000000", "SUFeedURL": "https://obsproject.com/osx_update/updates_arm64_v2.xml",
            ])
        try fixture.app(
            "Dropover.app",
            info: ["CFBundleIdentifier": "me.damir.dropover-mac", "CFBundleShortVersionString": "5.3.1"],
            appStoreReceipt: true)
        try fixture.app(
            "Brave Browser.app",
            info: ["CFBundleIdentifier": "com.brave.Browser", "CFBundleShortVersionString": "154.1.96.59"])
        try fixture.app(
            "Mullvad VPN.app", info: ["CFBundleIdentifier": "net.mullvad.vpn", "CFBundleShortVersionString": "2026.3"])
        try fixture.app(
            "Homemade.app", info: ["CFBundleIdentifier": "dev.example.homemade", "CFBundleShortVersionString": "0.1"])

        let environment = Ripe.Environment(
            scanner: AppScanner(roots: [fixture.root]),
            sources: [AppStoreSource(), SparkleSource(), HomebrewCaskSource()],
            context: SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test())
        )
        let report = await Ripe.check(environment)
        let verdicts = Dictionary(uniqueKeysWithValues: report.apps.map { ($0.app.name, $0.verdict) })

        #expect(report.outdated.map(\.app.name) == ["Mullvad VPN", "OBS"])
        guard case .outdated(let obs)? = verdicts["OBS"], case .current(let brave)? = verdicts["Brave Browser"],
            case .current(let dropover)? = verdicts["Dropover"]
        else {
            Issue.record("unexpected verdicts \(verdicts)")
            return
        }
        #expect(obs.source == .sparkle && obs.version == "32.2.2")
        #expect(brave.source == .homebrewCask)
        #expect(dropover.source == .appStore)
        #expect(verdicts["Homemade"] == .unknown(.noSource))
    }

    @Test func slowSourceIsCutOffAtTheDeadline() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app(
            "Tool.app", info: ["CFBundleIdentifier": "dev.example.tool", "CFBundleShortVersionString": "1.0"])

        let environment = Ripe.Environment(
            scanner: AppScanner(roots: [fixture.root]),
            sources: [StuckSource()],
            context: SourceContext(http: FakeHTTPClient([]), machine: .test()),
            deadline: .milliseconds(100)
        )
        let started = ContinuousClock.now
        let report = await Ripe.check(environment)
        #expect(ContinuousClock.now - started < .seconds(2))
        let evidence = try #require(report.apps.first?.evidence.first)
        guard case .failed(let message) = evidence.outcome else {
            Issue.record("expected a timeout, got \(evidence.outcome)")
            return
        }
        #expect(message.contains("no answer within"))
        #expect(report.apps.first?.verdict == .unknown(.sourcesFailed))
    }

    @Test func fastSourcesAreNotMistakenForTimeouts() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app(
            "Tool.app", info: ["CFBundleIdentifier": "dev.example.tool", "CFBundleShortVersionString": "1.0"])
        let environment = Ripe.Environment(
            scanner: AppScanner(roots: [fixture.root]),
            sources: [HomebrewCaskSource()],
            context: SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test())
        )
        // Homebrew answered in time and simply doesn't know this app.
        #expect(await Ripe.check(environment).apps.first?.verdict == .unknown(.noSource))
    }
}

/// Never answers until cancelled, then returns nothing, like a source whose requests were cut off.
struct StuckSource: UpdateSource {
    let id = SourceID.homebrewCask
    func applies(to app: InstalledApp) -> Bool { true }
    func check(_ apps: [InstalledApp], context: SourceContext) async -> [InstalledApp.ID: SourceOutcome] {
        try? await Task.sleep(for: .seconds(30))
        return [:]
    }
}
