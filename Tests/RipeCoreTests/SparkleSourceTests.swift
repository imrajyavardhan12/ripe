import Foundation
import Testing

@testable import RipeCore

/// Serves one body after a short delay and records the peak number of requests in flight.
actor ConcurrencyProbe: HTTPClient {
    let body: Data
    private var inFlight = 0
    private(set) var peak = 0

    init(body: Data) { self.body = body }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        inFlight += 1
        peak = max(peak, inFlight)
        try? await Task.sleep(for: .milliseconds(20))
        inFlight -= 1
        return HTTPResponse(url: request.url, status: 200, body: body)
    }
}

struct SparkleSourceTests {
    @Test func parsesElementsAndEnclosureAttributes() throws {
        let obs = try AppcastParser.parse(Fixture.data("obs-appcast.xml"))
        #expect(obs.map(\.channel) == ["beta", "stable", nil])
        #expect(obs[1].version == "31845296735")
        #expect(obs[1].shortVersion == "32.2.2")
        #expect(obs[1].hardwareRequirements == ["arm64"])
        #expect(obs[1].minimumSystemVersion == "13.0")
        #expect(obs[1].publishedAt != nil)

        // Flux keeps its version on the enclosure, the older appcast style.
        let flux = try #require(try AppcastParser.parse(Fixture.data("flux-appcast.xml")).first)
        #expect(flux.version == "42.2")
        #expect(flux.enclosureURL?.lastPathComponent == "Flux42.2.zip")
    }

    @Test func rejectsMalformedFeeds() {
        #expect(throws: AppcastParser.ParseError.self) {
            try AppcastParser.parse(Data("<rss><channel><item><title>x</title></channel>".utf8))
        }
    }

    /// OBS lists a beta first and labels stable items `stable`. The regression this guards:
    /// accepting only unlabeled items skipped 32.2.2 and fell back to 29.0.2.
    @Test func picksNewestStableItemForThisMac() throws {
        let items = try AppcastParser.parse(Fixture.data("obs-appcast.xml"))
        let item = try #require(SparkleSource.newestEligible(items, on: .test()))
        #expect(item.shortVersion == "32.2.2")
    }

    @Test func honorsHardwareAndMinimumOS() throws {
        let items = try AppcastParser.parse(Fixture.data("obs-appcast.xml"))
        // 32.2.2 is arm64-only and needs macOS 13: neither an Intel Mac nor macOS 12 gets it.
        let intel = SparkleSource.newestEligible(items, on: .test(architecture: .intel))
        let monterey = SparkleSource.newestEligible(items, on: .test(macOS: "12.7"))
        #expect(intel?.title == "OBS Studio 29.0.2")
        #expect(monterey?.title == "OBS Studio 29.0.2")
        #expect(SparkleSource.newestEligible(items, on: .test(macOS: "10.15")) == nil)
    }

    @Test func skipsOptInChannelsAndInformationalItems() {
        let items = [
            AppcastItem(version: "300", channel: "nightly"),
            AppcastItem(version: "250", channel: "internal-dogfood"),
            AppcastItem(version: "200", isInformational: true),
            AppcastItem(version: "100", channel: "Release"),
            AppcastItem(version: "50"),
        ]
        #expect(SparkleSource.newestEligible(items, on: .test())?.version == "100")
    }

    @Test func ignoresDeltaUpdates() throws {
        // Rectangle's feed (2026-10-03, trimmed): the full DMG, then delta patches, each with its
        // own signature. Ripe used to keep the last enclosure, downloaded a 136 KB delta, verified
        // its genuine signature and then couldn't unpack it.
        let feed = """
            <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
              <title>2.0.2</title>
              <sparkle:version>109</sparkle:version>
              <sparkle:shortVersionString>2.0.2</sparkle:shortVersionString>
              <enclosure url="https://github.com/rxhanson/Rectangle/releases/download/v2.0.2/Rectangle2.0.2.dmg"
                length="4679140" type="application/octet-stream" sparkle:edSignature="FULL"/>
              <sparkle:deltas>
                <enclosure url="https://github.com/rxhanson/Rectangle/releases/download/v2.0.2/Rectangle109-108.delta"
                  sparkle:deltaFrom="108" length="136362" sparkle:edSignature="DELTA1"/>
                <enclosure url="https://github.com/rxhanson/Rectangle/releases/download/v2.0.2/Rectangle109-107.delta"
                  sparkle:deltaFrom="107" length="163162" sparkle:edSignature="DELTA2"/>
              </sparkle:deltas>
            </item></channel></rss>
            """
        let item = try #require(try AppcastParser.parse(Data(feed.utf8)).first)
        #expect(item.enclosureURL?.lastPathComponent == "Rectangle2.0.2.dmg")
        #expect(item.edSignature == "FULL")
        #expect(item.length == 4_679_140)
        #expect(item.version == "109")
    }

    @Test func prefersTheMacEnclosureInCrossPlatformItems() throws {
        let feed = """
            <rss><channel><item>
              <enclosure url="https://example.com/app.dmg" sparkle:os="macos" sparkle:version="5" sparkle:edSignature="MAC"/>
              <enclosure url="https://example.com/app.exe" sparkle:os="windows" sparkle:version="5" sparkle:edSignature="WIN"/>
            </item></channel></rss>
            """
        let item = try #require(try AppcastParser.parse(Data(feed.utf8)).first)
        #expect(item.enclosureURL?.lastPathComponent == "app.dmg")
        #expect(item.edSignature == "MAC")
        #expect(item.operatingSystem == "macos")
    }

    @Test func doesNotTrustFeedOrder() {
        let items = [AppcastItem(version: "10"), AppcastItem(version: "12"), AppcastItem(version: "11")]
        #expect(SparkleSource.newestEligible(items, on: .test())?.version == "12")
    }

    @Test func skipsWindowsEnclosures() {
        let items = [
            AppcastItem(version: "9", operatingSystem: "windows"), AppcastItem(version: "8", operatingSystem: "macos"),
        ]
        #expect(SparkleSource.newestEligible(items, on: .test())?.version == "8")
    }

    @Test func reportsBuildForSparkleComparison() async throws {
        let feed = URL(staticString: "https://obsproject.com/osx_update/updates_arm64_v2.xml")
        let context = SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test())
        let outcome = await SparkleSource.check(feed: feed, context: context)
        guard case .found(let release, let confidence, _) = outcome else {
            Issue.record("expected a release, got \(outcome)")
            return
        }
        #expect(release.version == "32.2.2")
        #expect(release.build == "31845296735")
        #expect(release.comparison == .bundleVersion)
        #expect(confidence == .high)
    }

    @Test func seededFeedsAreCrossCheckedWithMediumConfidence() async throws {
        let feed = URL(staticString: "https://obsproject.com/osx_update/updates_arm64_v2.xml")
        let context = SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test())
        let outcome = await SparkleSource.check(feed: feed, catalogFeed: .fallback, context: context)
        guard case .found(let release, let confidence, let note) = outcome else {
            Issue.record("expected a release, got \(outcome)")
            return
        }
        #expect(release.comparison == .crossChecked)
        #expect(confidence == .medium)
        #expect(note?.contains("Homebrew's livecheck") == true)
    }

    @Test func checksBareFeedsForOrchardTooling() async throws {
        let good = URL(staticString: "https://obsproject.com/osx_update/updates_arm64_v2.xml")
        let missing = URL(staticString: "https://example.com/appcast.xml")
        let context = SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test())
        let outcomes = await Ripe.checkFeeds([good, missing, good], context: context)
        #expect(outcomes.count == 2)
        guard case .found(let release, _, _) = outcomes[good], case .failed = outcomes[missing] else {
            Issue.record("unexpected outcomes \(outcomes)")
            return
        }
        #expect(release.version == "32.2.2")
        #expect(release.comparison == .bundleVersion, "a bare feed is checked like the app's own")
    }

    @Test func limitsConcurrentFeedRequests() async throws {
        let probe = ConcurrencyProbe(body: try Fixture.data("flux-appcast.xml"))
        let apps = (0..<40).map { index in
            InstalledApp.test(
                "App\(index).app", bundleID: "dev.example.app\(index)", version: "1.0",
                signals: .init(sparkleFeedURL: URL(string: "https://host\(index).example.com/appcast.xml")))
        }
        let outcomes = await SparkleSource().check(apps, context: SourceContext(http: probe, machine: .test()))
        #expect(outcomes.count == 40)
        let peak = await probe.peak
        #expect(peak <= SparkleSource.maxConcurrentFeeds)
        #expect(peak > 1, "feeds still run in parallel")
    }

    @Test func feedFailureBecomesOutcome() async {
        let feed = URL(staticString: "https://example.com/appcast.xml")
        let context = SourceContext(http: FakeHTTPClient([]), machine: .test())
        guard case .failed(let message) = await SparkleSource.check(feed: feed, context: context) else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("HTTP 404"))
    }
}
