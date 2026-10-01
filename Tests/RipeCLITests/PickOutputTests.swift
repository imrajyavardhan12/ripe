import Foundation
import RipeCore
import Testing

@testable import RipeCLI

struct PickOutputTests {
    static func plan(_ name: String, _ method: InstallPlan.Method) -> InstallPlan {
        let app = InstalledApp(
            name: name, bundleID: "dev.example.\(name.lowercased())", url: URL(filePath: "/Applications/\(name).app"),
            version: AppVersion(short: "1.0", build: nil))
        let release = Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion)
        return InstallPlan(
            report: AppReport(app: app, verdict: .outdated(release), evidence: [], explanation: "", managedBy: .none),
            release: release, method: method)
    }

    let renderer = PickRenderer(terminal: Terminal(color: false))
    let noTools = HandOffTools(brew: nil, mas: nil)

    @Test func planSaysExactlyHowEachAppWillBeUpdated() {
        let download = Download(url: URL(filePath: "/x"), integrity: .edDSA(signature: "s"))
        let text = renderer.renderPlan(
            [
                Self.plan("Brave", .direct(download)),
                Self.plan("Raycast", .homebrew(token: "raycast")),
                Self.plan("Dropover", .appStore(id: 1)),
                Self.plan("Mullvad", .manual(reason: "the update is a .pkg installer", url: nil)),
            ],
            skipped: [("Ghostty", "Ripe isn't sure it's outdated")],
            tools: noTools)
        #expect(text.contains("Brave     1.0 → 2.0  download, verify EdDSA + Team ID, old → Trash"))
        #expect(text.contains("brew upgrade --cask raycast"))
        #expect(text.contains("App Store (Ripe opens it; you click Update)"))
        #expect(text.contains("you: the update is a .pkg installer"))
        #expect(text.contains("Not picking Ghostty: Ripe isn't sure it's outdated."))
    }

    @Test func summaryCountsEachKindOfResult() {
        let plan = Self.plan("A", .homebrew(token: "a"))
        let summary = renderer.renderSummary([
            (plan, .success(.handedOff("ok"))),
            (
                plan,
                .success(
                    .updated(
                        to: AppVersion(short: "2", build: nil), previousVersionAt: URL(filePath: "/t"),
                        relaunched: false))
            ),
            (plan, .success(.needsYou("click"))),
            (plan, .failure(InstallError(.verify, "nope"))),
        ])
        #expect(summary == "2 picked · 1 needs you · 1 failed")
    }
}
