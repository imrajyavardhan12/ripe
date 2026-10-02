import Foundation
import Testing

@testable import RipeCore

struct CatalogTests {
    static let catalogJSON = """
        {
          "schemaVersion": 1,
          "generatedAt": "2026-09-28T12:00:00Z",
          "apps": {
            "com.brave.Browser": {
              "name": "Brave Browser",
              "sparkleFeed": {
                "arm64": "https://updates.example.com/stable-arm64/appcast.xml",
                "x86_64": "https://updates.example.com/stable/appcast.xml"
              }
            },
            "md.obsidian": {
              "name": "Obsidian",
              "installedVersion": { "glob": "~/Library/Application Support/obsidian/obsidian-*.asar" },
              "notes": "Updates in place."
            },
            "com.1password.1password": { "name": "1Password", "homebrewCask": "1password@beta" },
            "net.matthewpalmer.Rocket": {
              "name": "Rocket",
              "fallbackSparkleFeed": {
                "arm64": "https://macrelease.matthewpalmer.net/distribution/appcasts/rocket.xml",
                "x86_64": "https://macrelease.matthewpalmer.net/distribution/appcasts/rocket.xml"
              }
            }
          }
        }
        """

    static func catalog() throws -> Catalog {
        try #require(
            CatalogLoader(url: CatalogLoader.defaultURL, refresh: false).decode(Data(catalogJSON.utf8), log: .silent))
    }

    // MARK: Loading

    @Test func decodesAndLooksUpCaseInsensitively() throws {
        let catalog = try Self.catalog()
        #expect(catalog.count == 4)
        #expect(catalog.entry(for: "COM.BRAVE.BROWSER")?.name == "Brave Browser")
        #expect(catalog.entry(for: "md.obsidian")?.notes == "Updates in place.")
    }

    @Test func ignoresNewerSchemasAndMalformedCatalogs() {
        let loader = CatalogLoader(url: CatalogLoader.defaultURL, refresh: false)
        #expect(loader.decode(Data(#"{"schemaVersion": 2, "apps": {}}"#.utf8), log: .silent) == nil)
        #expect(loader.decode(Data("not json".utf8), log: .silent) == nil)
        #expect(loader.decode(Data(#"{"schemaVersion": 1, "apps": {"x": {}}}"#.utf8), log: .silent) == nil)
    }

    @Test func readsLocalFilesForContributors() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "orchard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(Self.catalogJSON.utf8).write(to: file)
        let catalog = await CatalogLoader(url: file, refresh: false)
            .load(context: SourceContext(http: FakeHTTPClient([]), machine: .test()))
        #expect(catalog?.count == 4)
    }

    @Test func remembersAnUnavailableCatalogForAnHour() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ripe-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = FakeHTTPClient([])  // every request 404s
        let context = SourceContext(http: http, machine: .test(), cache: DiskCache(directory: directory))
        let clock = TestClock()
        let loader = CatalogLoader(url: CatalogLoader.defaultURL, refresh: false) { clock.now }

        #expect(await loader.load(context: context) == nil)
        #expect(await loader.load(context: context) == nil)
        #expect(await http.requests.all.count == 1, "second run skipped the known-unavailable catalog")

        clock.advance(3601)
        _ = await loader.load(context: context)
        #expect(await http.requests.all.count == 2)

        _ = await CatalogLoader(url: CatalogLoader.defaultURL, refresh: true) { clock.now }.load(context: context)
        #expect(await http.requests.all.count == 3, "--refresh retries immediately")
    }

    // MARK: Applying

    @Test func feedFollowsThisMacsArchitecture() throws {
        let brave = InstalledApp.test("Brave Browser.app", bundleID: "com.brave.Browser", version: "154.1.96.59")
        let appleSilicon = CatalogEnricher(catalog: try Self.catalog(), machine: .test()).apply(to: brave)
        let intel = CatalogEnricher(catalog: try Self.catalog(), machine: .test(architecture: .intel)).apply(to: brave)
        #expect(appleSilicon.signals.sparkleFeedURL?.path() == "/stable-arm64/appcast.xml")
        #expect(intel.signals.sparkleFeedURL?.path() == "/stable/appcast.xml")
        #expect(appleSilicon.catalog?.changes.first?.hasPrefix("Sparkle feed") == true)
    }

    @Test func fallbackFeedFillsInOnlyWhenTheAppDeclaresNone() throws {
        let enricher = CatalogEnricher(catalog: try Self.catalog(), machine: .test())
        let bare = InstalledApp.test("Rocket.app", bundleID: "net.matthewpalmer.Rocket", version: "1.9")
        let enriched = enricher.apply(to: bare)
        #expect(enriched.signals.sparkleFeedURL?.host() == "macrelease.matthewpalmer.net")
        #expect(enriched.catalog?.sparkleFeed == .fallback)

        // The app's own feed is what its updater reads; a seeded guess never replaces it.
        let own = URL(staticString: "https://example.com/own-appcast.xml")
        let declaring = InstalledApp.test(
            "Rocket.app", bundleID: "net.matthewpalmer.Rocket", version: "1.9", signals: .init(sparkleFeedURL: own))
        let untouched = enricher.apply(to: declaring)
        #expect(untouched.signals.sparkleFeedURL == own)
        #expect(untouched.catalog?.sparkleFeed == nil)
        #expect(untouched.catalog?.changes.isEmpty == true)
    }

    @Test func fallbackFeedNeedsTheFinderNameToMatch() throws {
        let enricher = CatalogEnricher(catalog: try Self.catalog(), machine: .test())
        let renamed = InstalledApp.test("Rocket Typist.app", bundleID: "net.matthewpalmer.Rocket", version: "1.9")
        #expect(enricher.apply(to: renamed).signals.sparkleFeedURL == nil)
        let otherCase = InstalledApp.test("rocket.app", bundleID: "net.matthewpalmer.Rocket", version: "1.9")
        #expect(enricher.apply(to: otherCase).signals.sparkleFeedURL != nil)
    }

    @Test func correctionFeedsAreMarkedAsSuch() throws {
        let brave = InstalledApp.test("Brave Browser.app", bundleID: "com.brave.Browser", version: "154.1.96.59")
        #expect(
            CatalogEnricher(catalog: try Self.catalog(), machine: .test()).apply(to: brave).catalog?.sparkleFeed
                == .correction)
    }

    @Test func appsWithoutEntriesAreUntouched() throws {
        let app = InstalledApp.test("Other.app", bundleID: "dev.example.other", version: "1.0")
        #expect(CatalogEnricher(catalog: try Self.catalog(), machine: .test()).apply(to: app) == app)
    }

    @Test func readsTheRealVersionOfInPlaceUpdaters() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appending(path: "Library/Application Support/obsidian")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["obsidian-1.12.7.asar", "obsidian-1.13.4.asar", "obsidian-latest.asar", "obsidian-1.99.0.zip"] {
            try Data().write(to: folder.appending(path: name))
        }
        let obsidian = InstalledApp.test("Obsidian.app", bundleID: "md.obsidian", version: "1.12.4", build: "0.14.8")
        let enriched = CatalogEnricher(catalog: try Self.catalog(), machine: .test(), home: home).apply(to: obsidian)

        #expect(enriched.version == AppVersion(short: "1.13.4", build: nil))
        #expect(
            enriched.catalog?.changes == [
                "installed version 1.13.4 read from ~/Library/Application Support/obsidian/obsidian-1.13.4.asar"
            ])
    }

    @Test func keepsBundleVersionWhenNothingMatches() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "home-\(UUID().uuidString)")
        let obsidian = InstalledApp.test("Obsidian.app", bundleID: "md.obsidian", version: "1.12.4")
        let enriched = CatalogEnricher(catalog: try Self.catalog(), machine: .test(), home: home).apply(to: obsidian)
        #expect(enriched.version.short == "1.12.4")
        #expect(enriched.catalog?.changes.first?.hasPrefix("no files match") == true)
    }

    /// The catalog is untrusted: the client enforces the same path rules as orchard's CI.
    @Test(arguments: ["/etc/passwd-*", "~/Library/../../*.txt", "~/Library/x/*-*.asar", "~/Documents/app-*.zip"])
    func refusesVersionGlobsOutsideAllowedFolders(_ glob: String) {
        #expect(InstalledVersionLocator.locate(glob: glob, home: URL(filePath: "/Users/test")) == nil)
    }

    @Test func pinnedCaskBeatsHeuristics() throws {
        let index = try CaskIndex.build(fromAPI: Fixture.data("cask-sample.json"))
        let app = CatalogEnricher(catalog: try Self.catalog(), machine: .test())
            .apply(to: .test("1Password.app", bundleID: "com.1password.1password", version: "8.12"))
        let match = try #require(HomebrewCaskSource.match(app, in: index, installedTokens: []))
        #expect(match.cask.token == "1password@beta")
        #expect(match.reason == "pinned by orchard")
    }

    // MARK: End to end

    @Test func catalogFeedMakesSparkleAuthoritative() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        // No SUFeedURL in the bundle, like OBS if it set its feed in code.
        try fixture.app(
            "OBS.app",
            info: [
                "CFBundleIdentifier": "com.obsproject.obs-studio", "CFBundleShortVersionString": "32.2.1",
                "CFBundleVersion": "31000000000",
            ])
        let catalogFile = fixture.root.appending(path: "index.json")
        try Data(
            #"{"schemaVersion":1,"apps":{"com.obsproject.obs-studio":{"name":"OBS","sparkleFeed":{"arm64":"https://obsproject.com/osx_update/updates_arm64_v2.xml"}}}}"#
                .utf8
        ).write(to: catalogFile)

        let environment = Ripe.Environment(
            scanner: AppScanner(roots: [fixture.root]),
            sources: [SparkleSource(), HomebrewCaskSource()],
            context: SourceContext(http: try FakeHTTPClient.fixtures(), machine: .test()),
            catalogURL: catalogFile
        )
        let report = try #require(await Ripe.check(environment).apps.first)
        guard case .outdated(let release) = report.verdict, case .found(_, _, let note) = report.evidence[0].outcome
        else {
            Issue.record("expected an update from the orchard feed, got \(report.verdict)")
            return
        }
        #expect(release.source == .sparkle && release.build == "31845296735")
        #expect(note == "feed from orchard")
        #expect(report.managedBy == .selfUpdating)
    }

    @Test func catalogURLFromEnvironment() {
        #expect(Ripe.Environment.catalogURL(environment: [:]) == CatalogLoader.defaultURL)
        #expect(Ripe.Environment.catalogURL(environment: ["RIPE_CATALOG_URL": "none"]) == nil)
        #expect(Ripe.Environment.catalogURL(environment: ["RIPE_CATALOG_URL": "file:///tmp/i.json"])?.isFileURL == true)
    }
}
