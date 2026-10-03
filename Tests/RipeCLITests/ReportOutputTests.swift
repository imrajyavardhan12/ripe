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

    static let brew = HandOffTools(brew: URL(filePath: "/opt/homebrew/bin/brew"), mas: nil)

    @Test func listsOnlyOutdatedAppsWithHowToUpdate() {
        let text = ReportRenderer(terminal: Terminal(color: false), tools: Self.brew).renderOutdated(Self.report)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "App  Installed  Latest  Source   Update with")
        #expect(lines[1] == "OBS  32.2.1     32.2.2  Sparkle  brew upgrade --cask obs")
        #expect(!text.contains("Brave"))
        #expect(text.contains("1 ripe · 1 up to date · 1 unknown · 1.2s"))
    }

    /// "Update with" is what `ripe pick` would do (the maintainer's Mac, 2026-10-03: the list said
    /// "the app's updater" for LM Studio while pick planned a verified download).
    @Test func updateWithMatchesThePickPlan() throws {
        let download = Download(
            url: try #require(URL(string: "https://installers.lmstudio.ai/LM-Studio.dmg")),
            integrity: .sha256(String(repeating: "a", count: 64)))
        let verified = Release(
            version: "0.4.25", source: .homebrewCask, comparison: .shortVersion,
            pageURL: URL(string: "https://lmstudio.ai/"), download: download)
        let pkg = Release(
            version: "2026.5", source: .homebrewCask, comparison: .shortVersion,
            pageURL: URL(string: "https://mullvad.net/"),
            download: Download(url: download.url, integrity: download.integrity, isInstallerPackage: true))
        func column(_ release: Release, _ managedBy: ManagedBy, tools: HandOffTools = Self.brew) -> String {
            let item = AppReport(
                app: Self.app("Tool", "dev.example.tool", "1.0"), verdict: .outdated(release), evidence: [],
                explanation: "", managedBy: managedBy)
            let report = Report(apps: [item], skipped: [], duration: .zero, generatedAt: Date())
            let text = ReportRenderer(terminal: Terminal(color: false), tools: tools).renderOutdated(report)
            return text.split(separator: "\n")[1].split(separator: "  ").last.map(String.init) ?? ""
        }
        #expect(column(verified, .selfUpdating) == "ripe pick, or the app")
        #expect(column(verified, .none) == "ripe pick")
        #expect(column(pkg, .none) == "download from mullvad.net")
        #expect(
            column(Release(version: "2", source: .sparkle, comparison: .bundleVersion), .selfUpdating)
                == "the app's updater")
        #expect(column(verified, .homebrew(token: "lm-studio")) == "brew upgrade --cask lm-studio")
        // Without brew on PATH, pick can't hand off to it, and the list says so.
        #expect(
            column(verified, .homebrew(token: "lm-studio"), tools: HandOffTools(brew: nil, mas: nil))
                == "download from lmstudio.ai")
    }

    @Test func whySaysWhatPickWouldDo() {
        let obs = ReportRenderer(terminal: Terminal(color: false), tools: Self.brew).renderWhy(Self.report.apps[2])
        #expect(obs.contains("With ripe pick: brew upgrade --cask obs"))
        let current = ReportRenderer(terminal: Terminal(color: false), tools: Self.brew).renderWhy(Self.report.apps[0])
        #expect(!current.contains("With ripe pick"), "nothing to pick when it's up to date")
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

    @Test func pathsUnderHomeAreShortened() {
        let home = "/Users/someone"
        #expect(
            ReportRenderer.displayPath(URL(filePath: "/Users/someone/Applications/X.app"), home: home)
                == "~/Applications/X.app")
        #expect(ReportRenderer.displayPath(URL(filePath: "/Applications/X.app"), home: home) == "/Applications/X.app")
        #expect(
            ReportRenderer.displayPath(URL(filePath: "/Users/someoneelse/X.app"), home: home)
                == "/Users/someoneelse/X.app")
    }

    @Test func findsAppsTheWayPeopleTypeThem() {
        let reports = Self.report.apps
        #expect(AppQuery("obs").best(reports).map(\.app.name) == ["OBS"])
        #expect(AppQuery("Brave").best(reports).map(\.app.name) == ["Brave Browser"])
        #expect(AppQuery("com.mitchellh.ghostty").best(reports).map(\.app.name) == ["Ghostty"])
        #expect(AppQuery("OBS.app").best(reports).map(\.app.name) == ["OBS"])
        #expect(AppQuery("zzz").best(reports).isEmpty)
    }

    @Test func namesWithSpacesNeedNoQuotes() throws {
        // The maintainer typed `ripe why LM Studio` and got "Unexpected argument 'Studio'" (0.3.0).
        #expect(try WhyCommand.parse(["Brave", "Browser"]).app == "Brave Browser")
        #expect(try WhyCommand.parse(["Brave Browser", "--json"]).app == "Brave Browser")
        #expect(try SkipCommand.parse(["Brave", "Browser", "--always"]).app == "Brave Browser")
        #expect(try SkipCommand.parse(["--list"]).app == nil)
        #expect(try UnskipCommand.parse(["Brave", "Browser"]).app == "Brave Browser")
    }

    @Test func pickTellsOneSpacedNameFromSeveralApps() {
        let reports = Self.report.apps
        func names(_ words: [String]) -> [[String]] {
            AppQuery.resolve(words, in: reports).map { $0.best(reports).map(\.app.name) }
        }
        // "Browser" alone names nothing, so the words are one name.
        #expect(names(["Brave", "Browser"]) == [["Brave Browser"]])
        // Each word names an app: two apps, as before.
        #expect(names(["OBS", "Ghostty"]) == [["OBS"], ["Ghostty"]])
        // Nothing matches either way: kept separate, so the error names the word that failed.
        #expect(names(["zzz", "yyy"]) == [[], []])
    }
}
