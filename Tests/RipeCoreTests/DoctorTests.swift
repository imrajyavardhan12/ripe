import Foundation
import Testing

@testable import RipeCore

struct DoctorTests {
    /// Answers every request from the cache as if the network were down.
    struct StaleHTTPClient: HTTPClient {
        func get(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(url: request.url, status: 200, body: Data(CatalogTests.catalogJSON.utf8), cache: .stale)
        }
    }

    struct Setup {
        let fixture: AppFixture
        let support: URL

        init() throws {
            fixture = try AppFixture()
            support = fixture.root.appending(path: "support")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try fixture.app(
                "Apps/Rocket.app",
                info: ["CFBundleIdentifier": "net.matthewpalmer.Rocket", "CFBundleShortVersionString": "1.9.5"])
            try fixture.app(
                "Apps/Safari.app",
                info: ["CFBundleIdentifier": "com.apple.Safari", "CFBundleShortVersionString": "26.0"])
        }

        var catalogFile: URL { support.appending(path: "index.json") }
        var journal: URL { support.appending(path: "journal") }
        var skips: URL { support.appending(path: "skips.json") }

        func doctor(http: any HTTPClient, brew: Bool = true, catalog: URL? = nil) -> Doctor {
            Doctor(
                scanner: AppScanner(roots: [fixture.root.appending(path: "Apps")]),
                context: SourceContext(http: http, machine: .test(homebrewCasks: ["rocket"])),
                catalogURL: catalog,
                tools: HandOffTools(brew: brew ? URL(filePath: "/opt/homebrew/bin/brew") : nil, mas: nil),
                skipsURL: skips, journalDirectory: journal, home: fixture.root.path)
        }
    }

    func check(_ checks: [DoctorCheck], _ name: String) throws -> DoctorCheck {
        try #require(checks.first { $0.name == name })
    }

    @Test func healthyMac() async throws {
        let setup = try Setup()
        defer { setup.fixture.remove() }
        try Data(CatalogTests.catalogJSON.utf8).write(to: setup.catalogFile)
        let checks = await setup.doctor(http: try FakeHTTPClient.fixtures(), catalog: setup.catalogFile).run()

        #expect(
            checks.map(\.name) == [
                "Apps", "Homebrew", "mas", "Homebrew data", "App Store", "orchard", "Skips", "Updates",
            ])
        #expect(try check(checks, "Apps").detail == "1 in ~/Apps (skipped: 1 Apple app)")
        #expect(try check(checks, "Homebrew").detail == "/opt/homebrew/bin/brew, 1 cask installed")
        #expect(try check(checks, "mas").status == .info, "an optional tool is context, not a warning")
        #expect(try check(checks, "orchard").detail == "4 entries from local file ~/support/index.json")
        #expect(!checks.contains { $0.status == .warning || $0.status == .problem })
    }

    @Test func offlineWithoutCacheIsAProblem() async throws {
        let setup = try Setup()
        defer { setup.fixture.remove() }
        let checks = await setup.doctor(http: FakeHTTPClient([]), catalog: CatalogLoader.defaultURL).run()
        #expect(try check(checks, "Homebrew data").status == .problem)
        #expect(try check(checks, "App Store").status == .problem)
        #expect(try check(checks, "Homebrew data").hint?.contains("formulae.brew.sh") == true)
        // Ripe runs fine without the catalog.
        #expect(try check(checks, "orchard").status == .warning)
    }

    @Test func offlineWithCacheIsAWarning() async throws {
        let setup = try Setup()
        defer { setup.fixture.remove() }
        let checks = await setup.doctor(http: StaleHTTPClient(), catalog: CatalogLoader.defaultURL).run()
        #expect(try check(checks, "Homebrew data").status == .warning)
        #expect(try check(checks, "orchard").detail == "4 entries from cached copy (offline)")
        #expect(try check(checks, "orchard").status == .warning)
    }

    @Test func reportsBrokenSkipsAndInterruptedUpdates() async throws {
        let setup = try Setup()
        defer { setup.fixture.remove() }
        try Data("{ not json".utf8).write(to: setup.skips)
        try FileManager.default.createDirectory(at: setup.journal, withIntermediateDirectories: true)
        let entry = Replacer.JournalEntry(appPath: "/Applications/GrandPerspective.app", stagedPath: "/x")
        try JSONEncoder().encode(entry).write(to: setup.journal.appending(path: "A.json"))

        let checks = await setup.doctor(http: try FakeHTTPClient.fixtures(), brew: false).run()
        #expect(try check(checks, "Skips").status == .problem)
        #expect(try check(checks, "Updates").status == .warning)
        #expect(try check(checks, "Updates").detail == "1 interrupted: GrandPerspective")
        #expect(try check(checks, "Homebrew").status == .info)
        #expect(try check(checks, "orchard").detail == "turned off (RIPE_CATALOG_URL=none)")
        #expect(FileManager.default.fileExists(atPath: setup.journal.appending(path: "A.json").path), "read-only")
    }

    @Test func emptyAppFolderIsAProblem() async throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let doctor = Doctor(
            scanner: AppScanner(roots: [fixture.root]),
            context: SourceContext(http: FakeHTTPClient([]), machine: .test()),
            catalogURL: nil, tools: HandOffTools(brew: nil, mas: nil), skipsURL: fixture.root.appending(path: "s.json"),
            journalDirectory: fixture.root.appending(path: "j"), home: "/nowhere")
        #expect(doctor.apps().status == .problem)
    }
}
