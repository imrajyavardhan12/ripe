import Foundation
import RipeCore
import Testing

@testable import RipeCLI

struct ReportOutputTests {
    static let obsRelease = Release(
        version: "32.2.2", build: "31845296735", source: .sparkle, comparison: .bundleVersion,
        pageURL: URL(string: "https://obsproject.com/notes.html"), minimumSystemVersion: "13.0")
    static let braveRelease = Release(
        version: "1.96.59.0", source: .homebrewCask, comparison: .shortVersion, caskToken: "brave-browser")

    static func app(_ name: String, _ bundleID: String, _ version: String, build: String? = nil) -> InstalledApp {
        InstalledApp(
            name: name, bundleID: bundleID, url: URL(filePath: "/Applications/\(name).app"),
            version: AppVersion(short: version, build: build))
    }

    static let report = Report(
        apps: [
            AppReport(
                app: app("Brave Browser", "com.brave.Browser", "154.1.96.59"),
                verdict: .current(braveRelease),
                evidence: [
                    Evidence(
                        source: .homebrewCask, outcome: .found(braveRelease, .high, note: "cask brave-browser"),
                        decisive: true)
                ],
                explanation: "Matches the newest version on Homebrew.", managedBy: .selfUpdating),
            AppReport(
                app: app("Ghostty", "com.mitchellh.ghostty", "b40acce58"),
                verdict: .unknown(.incomparable(braveRelease)),
                evidence: [], explanation: "Can't compare.", managedBy: .none),
            AppReport(
                app: app("OBS", "com.obsproject.obs-studio", "32.2.1", build: "31000000000"),
                verdict: .outdated(obsRelease),
                evidence: [
                    Evidence(source: .sparkle, outcome: .found(obsRelease, .high, note: nil), decisive: true),
                    Evidence(source: .homebrewCask, outcome: .failed("offline"), decisive: false),
                ],
                explanation: "Sparkle has a newer version.", managedBy: .homebrew(token: "obs")),
        ],
        skipped: [SkippedBundle(url: URL(filePath: "/Applications/Safari.app"), reason: .appleSystemApp)],
        duration: .milliseconds(1250),
        generatedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )

    // MARK: JSON contract

    @Test func jsonShapeIsStable() throws {
        let json = try JSONReport(Self.report).encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "schemaVersion", "ripeVersion", "generatedAt", "durationSeconds", "summary", "apps", "skipped",
            ])
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["generatedAt"] as? String == "2026-09-21T14:13:20Z")
        #expect(object["durationSeconds"] as? Double == 1.25)
        #expect(object["summary"] as? [String: Int] == ["outdated": 1, "current": 1, "unknown": 1, "skipped": 0])
        #expect(
            object["skipped"] as? [[String: String]] == [
                ["path": "/Applications/Safari.app", "reason": "appleSystemApp"]
            ])
    }

    @Test func jsonAppGolden() throws {
        let obs = JSONReport.App(Self.report.apps[2])
        #expect(
            try JSONReport.encode(obs) == """
                {
                  "bundleId" : "com.obsproject.obs-studio",
                  "evidence" : [
                    {
                      "build" : "31845296735",
                      "confidence" : "high",
                      "decisive" : true,
                      "result" : "found",
                      "source" : "sparkle",
                      "version" : "32.2.2"
                    },
                    {
                      "decisive" : false,
                      "note" : "offline",
                      "result" : "failed",
                      "source" : "homebrew-cask"
                    }
                  ],
                  "explanation" : "Sparkle has a newer version.",
                  "installed" : {
                    "build" : "31000000000",
                    "version" : "32.2.1"
                  },
                  "latest" : {
                    "build" : "31845296735",
                    "minimumSystemVersion" : "13.0",
                    "source" : "sparkle",
                    "url" : "https://obsproject.com/notes.html",
                    "version" : "32.2.2"
                  },
                  "name" : "OBS",
                  "path" : "/Applications/OBS.app",
                  "status" : "outdated",
                  "updateWith" : {
                    "caskToken" : "obs",
                    "kind" : "homebrew"
                  }
                }
                """)
    }

    @Test func unknownCarriesAReasonCode() {
        let ghostty = JSONReport.App(Self.report.apps[1])
        #expect(ghostty.status == "unknown")
        #expect(ghostty.reason == "incomparable")
    }

    // MARK: Text

    @Test func listsOnlyOutdatedAppsWithHowToUpdate() {
        let text = ReportRenderer(terminal: Terminal(color: false)).renderOutdated(Self.report)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "App  Installed  Latest  Source   Update with")
        #expect(lines[1] == "OBS  32.2.1     32.2.2  Sparkle  brew upgrade --cask obs")
        #expect(!text.contains("Brave"))
        #expect(text.contains("1 ripe · 1 up to date · 1 unknown · 1.2s"))
    }

    @Test func skippedAppsAreCountedNotHidden() throws {
        var report = Self.report
        report.apps[2].verdict = .skippedByUser(Self.obsRelease, .version("32.2.2"))
        let text = ReportRenderer(terminal: Terminal(color: false)).renderAll(report)
        #expect(text.contains("skipped 32.2.2"))
        #expect(text.contains("0 ripe · 1 up to date · 1 unknown · 1 skipped"))
        let obs = JSONReport.App(report.apps[2])
        #expect(obs.status == "skipped" && obs.skipped == "32.2.2")
    }

    @Test func saysSoWhenNothingIsRipe() {
        var report = Self.report
        report.apps.removeLast()
        let text = ReportRenderer(terminal: Terminal(color: false)).renderOutdated(report)
        #expect(text.hasPrefix("Nothing ripe."))
    }

    @Test func whyShowsEveryConsultedSource() {
        let text = ReportRenderer(terminal: Terminal(color: false)).renderWhy(Self.report.apps[2])
        #expect(text.contains("OBS 32.2.1 (31000000000)"))
        #expect(text.contains("✓ Sparkle    32.2.2 (build 31845296735)"))
        #expect(text.contains("✗ Homebrew   offline"))
        #expect(text.contains("Homebrew (brew upgrade --cask obs)"))
        #expect(text.contains("More: https://obsproject.com/notes.html"))
    }

    @Test func findsAppsTheWayPeopleTypeThem() {
        let reports = Self.report.apps
        #expect(AppQuery("obs").best(reports).map(\.app.name) == ["OBS"])
        #expect(AppQuery("Brave").best(reports).map(\.app.name) == ["Brave Browser"])
        #expect(AppQuery("com.mitchellh.ghostty").best(reports).map(\.app.name) == ["Ghostty"])
        #expect(AppQuery("OBS.app").best(reports).map(\.app.name) == ["OBS"])
        #expect(AppQuery("zzz").best(reports).isEmpty)
    }
}
