import Foundation
import Testing

@testable import RipeCore

struct ResolverTests {
    let resolver = Resolver(machine: .test(macOS: "15.6", homebrewCasks: ["obs"]))

    static let obs = InstalledApp.test(
        "OBS.app", bundleID: "com.obsproject.obs-studio", version: "32.2.2", build: "31845296735",
        signals: .init(sparkleFeedURL: URL(staticString: "https://obsproject.com/appcast.xml")))

    func sparkle(_ version: String, build: String) -> SourceOutcome {
        .found(Release(version: version, build: build, source: .sparkle, comparison: .bundleVersion), .high, note: nil)
    }

    func cask(_ version: String, _ confidence: Confidence = .high, token: String = "obs") -> SourceOutcome {
        .found(
            Release(version: version, source: .homebrewCask, comparison: .shortVersion, caskToken: token), confidence,
            note: nil)
    }

    @Test func authoritativeSourceWinsOverCatalog() {
        // The cask database claims a newer version; the app's own feed says it's current.
        let report = resolver.resolve(
            Self.obs, outcomes: [.sparkle: sparkle("32.2.2", build: "31845296735"), .homebrewCask: cask("33.0")])
        #expect(
            report.verdict
                == .current(
                    Release(version: "32.2.2", build: "31845296735", source: .sparkle, comparison: .bundleVersion)))
        #expect(report.evidence.map(\.source) == [.sparkle, .homebrewCask])
        #expect(report.evidence.map(\.decisive) == [true, false])
    }

    @Test func fallsBackWhenTheAuthoritativeSourceFails() {
        let report = resolver.resolve(Self.obs, outcomes: [.sparkle: .failed("feed 404"), .homebrewCask: cask("33.0")])
        guard case .outdated(let release) = report.verdict else {
            Issue.record("expected outdated, got \(report.verdict)")
            return
        }
        #expect(release.source == .homebrewCask)
        #expect(report.explanation.contains("Sparkle failed"))
    }

    @Test func appStoreIsExclusive() {
        let app = InstalledApp.test(
            "Dropover.app", bundleID: "me.damir.dropover-mac", version: "5.3.0", signals: .init(appStoreReceipt: true))
        let store = SourceOutcome.found(
            Release(version: "5.3.0", source: .appStore, comparison: .shortVersion), .high, note: nil)
        let report = resolver.resolve(app, outcomes: [.appStore: store, .homebrewCask: cask("9.0", token: "dropover")])
        guard case .current = report.verdict else {
            Issue.record("the cask must not override the store")
            return
        }
        #expect(report.evidence.map(\.source) == [.appStore])
        #expect(report.managedBy == .appStore)
    }

    @Test func weakMatchNeverClaimsAnUpdate() {
        let app = InstalledApp.test("Tool.app", bundleID: "dev.example.tool", version: "1.0")
        let report = resolver.resolve(app, outcomes: [.homebrewCask: cask("2.0", .low, token: "tool")])
        #expect(
            report.verdict
                == .unknown(
                    .lowConfidence(
                        Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion, caskToken: "tool"))))
    }

    @Test func updateNeedingNewerMacOSIsNotReported() {
        let app = InstalledApp.test("Tool.app", bundleID: "dev.example.tool", version: "1.0")
        let release = Release(
            version: "2.0", source: .sparkle, comparison: .bundleVersion, minimumSystemVersion: "26.0")
        let report = resolver.resolve(app, outcomes: [.sparkle: .found(release, .high, note: nil)])
        #expect(report.verdict == .unknown(.requiresNewerMacOS(release)))
    }

    @Test func installedNewerThanSourceIsCurrent() {
        let app = InstalledApp.test("Tool.app", bundleID: "dev.example.tool", version: "2.1-beta")
        guard case .current = resolver.resolve(app, outcomes: [.homebrewCask: cask("2.0")]).verdict else {
            Issue.record("a beta ahead of the catalog is not outdated")
            return
        }
    }

    @Test func incomparableVersionsAreUnknown() {
        let ghostty = InstalledApp.test("Ghostty.app", bundleID: "com.mitchellh.ghostty", version: "b40acce58")
        guard case .unknown(.incomparable) = resolver.resolve(ghostty, outcomes: [.homebrewCask: cask("1.3.1")]).verdict
        else {
            Issue.record("a git hash can't be compared")
            return
        }
    }

    @Test func noSourceAndFailedSourcesAreDistinguished() {
        let app = InstalledApp.test("Tool.app", bundleID: "dev.example.tool", version: "1.0")
        #expect(resolver.resolve(app, outcomes: [.homebrewCask: .notApplicable]).verdict == .unknown(.noSource))
        #expect(
            resolver.resolve(app, outcomes: [.homebrewCask: .failed("offline")]).verdict == .unknown(.sourcesFailed))
    }

    @Test func managedByHomebrewOnlyWhenInstalledByIt() {
        let installed = resolver.resolve(Self.obs, outcomes: [.homebrewCask: cask("32.2.2")])
        #expect(installed.managedBy == .homebrew(token: "obs"))
        let other = resolver.resolve(Self.obs, outcomes: [.homebrewCask: cask("32.2.2", token: "obs@beta")])
        #expect(other.managedBy == .selfUpdating)
    }
}
