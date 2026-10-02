import Foundation
import Testing

@testable import RipeCore

struct SkipListTests {
    static let raycast = InstalledApp.test("Raycast.app", bundleID: "com.raycast.macos", version: "1.104.24")

    func release(_ version: String) -> Release {
        Release(version: version, source: .homebrewCask, comparison: .shortVersion)
    }

    @Test func skippedVersionHidesItAndOlderButNeverNewer() {
        var skips = SkipList()
        skips.skip(Self.raycast, version: "2.6.0.0")
        #expect(skips.rule(for: Self.raycast, release: release("2.6.0.0")) == .version("2.6.0.0"))
        #expect(
            skips.rule(for: Self.raycast, release: release("2.6")) == .version("2.6.0.0"),
            "same version, other spelling")
        #expect(skips.rule(for: Self.raycast, release: release("2.5.9")) == .version("2.6.0.0"), "lagging catalog")
        #expect(skips.rule(for: Self.raycast, release: release("2.6.1")) == nil, "a newer fix must show up again")
    }

    @Test func alwaysHidesEverythingUntilUnskipped() {
        var skips = SkipList()
        skips.skipAlways(Self.raycast)
        #expect(skips.rule(for: Self.raycast, release: release("99.0")) == .always)
        let removed = skips.unskip(bundleID: "COM.RAYCAST.MACOS")
        #expect(removed, "bundle IDs are case-insensitive")
        #expect(skips.rule(for: Self.raycast, release: release("99.0")) == nil)
        let removedAgain = skips.unskip(bundleID: "com.raycast.macos")
        #expect(!removedAgain)
    }

    @Test func otherAppsAreUnaffected() {
        var skips = SkipList()
        skips.skipAlways(Self.raycast)
        let other = InstalledApp.test("OBS.app", bundleID: "com.obsproject.obs-studio", version: "1")
        #expect(skips.rule(for: other, release: release("2")) == nil)
    }

    @Test func onlyUpdatesCanBeSkipped() {
        var skips = SkipList()
        skips.skipAlways(Self.raycast)
        let update = AppReport(
            app: Self.raycast, verdict: .outdated(release("2.6")), evidence: [], explanation: "x", managedBy: .none)
        let current = AppReport(
            app: Self.raycast, verdict: .current(release("1.104.24")), evidence: [], explanation: "x", managedBy: .none)
        #expect(Ripe.applySkips(skips, to: update).verdict == .skippedByUser(release("2.6"), .always))
        #expect(Ripe.applySkips(skips, to: current).verdict == current.verdict)
    }

    // MARK: Storage

    @Test func roundTripsAndMissingFileIsEmpty() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let store = SkipStore(url: sandbox.url("config/ripe/skips.json"))
        #expect(try store.load().isEmpty)

        var skips = SkipList()
        skips.skip(Self.raycast, version: "2.6.0.0")
        try store.save(skips)
        #expect(try store.load() == skips)
    }

    @Test func neverOverwritesAFileItCantRead() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = sandbox.url("skips.json")
        try Data("{ hand-edited, broken".utf8).write(to: url)
        #expect(throws: SkipStoreError.self) { try SkipStore(url: url).load() }

        try Data(#"{"schemaVersion": 2, "apps": {}}"#.utf8).write(to: url)
        #expect(throws: SkipStoreError.self) { try SkipStore(url: url).load() }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("schemaVersion\": 2"))
    }

    @Test func followsXDGConfigHome() {
        #expect(SkipStore.defaultURL(environment: ["XDG_CONFIG_HOME": "/tmp/cfg"]).path == "/tmp/cfg/ripe/skips.json")
        #expect(SkipStore.defaultURL(environment: [:]).path.hasSuffix("/.config/ripe/skips.json"))
    }

    @Test func plannerExplainsSkips() {
        let report = AppReport(
            app: Self.raycast, verdict: .skippedByUser(release("2.6"), .version("2.6")), evidence: [], explanation: "",
            managedBy: .none)
        guard case .skip(let reason) = Planner.decide(report, tools: HandOffTools(brew: nil, mas: nil)) else {
            Issue.record("a skipped update is never picked by --all")
            return
        }
        #expect(reason.contains("ripe unskip Raycast"))
    }
}
