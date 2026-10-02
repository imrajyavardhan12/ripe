import Foundation
import Testing

@testable import RipeCore

struct TapCaskTests {
    @Test(
        arguments: [
            ("  version '0.21.3-Beta'", "0.21.3-Beta"),  // AeroSpace, nikitabobko/tap (2026-10-02)
            (#"  version "29.2,42065""#, "29.2,42065"),
            (#"  version "1.4.0" # pinned"#, "1.4.0"),
            ("  version :latest", nil),
            (##"  version "#{MAJOR}.1""##, nil),
            (#"  version "1.0" if Hardware::CPU.arm?"#, nil),
        ] as [(String, String?)])
    func literalVersions(_ line: String, _ expected: String?) {
        #expect(TapCaskReader.literalVersion(in: "cask \"x\" do\n\(line)\nend\n") == expected)
    }

    @Test func perCPUVersionsAreLeftOut() {
        let source = """
            cask "x" do
              on_arm do
                version "2.0"
              end
              on_intel do
                version "1.9"
              end
            end
            """
        #expect(TapCaskReader.literalVersion(in: source) == nil)
    }

    /// A trimmed copy of AeroSpace's real receipt, pointed at a temporary tap.
    func receipt(tap: String, path: String) -> Data {
        Data(
            """
            {"source": {"tap": "\(tap)", "version": "0.21.3-Beta", "path": "\(path)"},
             "uninstall_artifacts": [
               {"app": ["AeroSpace-v0.21.3-Beta/AeroSpace.app"]},
               {"binary": ["AeroSpace-v0.21.3-Beta/bin/aerospace", {"target": "/opt/homebrew/bin/aerospace"}]}
             ]}
            """.utf8)
    }

    @Test func readsTheTapFileTheReceiptPointsAt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "taps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let casks = root.appending(path: "Library/Taps/nikitabobko/homebrew-tap/Casks")
        try FileManager.default.createDirectory(at: casks, withIntermediateDirectories: true)
        let file = casks.appending(path: "aerospace.rb")
        try Data("cask \"aerospace\" do\n  version '0.22.0'\nend\n".utf8).write(to: file)
        let taps = root.appending(path: "Library/Taps").path + "/"

        let cask = TapCaskReader.read(
            token: "aerospace", receipt: receipt(tap: "nikitabobko/tap", path: file.path), tapsRoot: taps)
        #expect(
            cask == TapCask(token: "aerospace", tap: "nikitabobko/tap", version: "0.22.0", appNames: ["AeroSpace.app"]))

        // Core casks come from the API; a receipt pointing outside the taps folder is never read.
        #expect(
            TapCaskReader.read(token: "x", receipt: receipt(tap: "homebrew/cask", path: file.path), tapsRoot: taps)
                == nil)
        let outside = root.appending(path: "elsewhere.rb")
        try Data("cask \"x\" do\n  version '9.9'\nend\n".utf8).write(to: outside)
        #expect(TapCaskReader.read(token: "x", receipt: receipt(tap: "a/b", path: outside.path), tapsRoot: taps) == nil)
        let sneaky = taps + "../../elsewhere.rb"
        #expect(TapCaskReader.read(token: "x", receipt: receipt(tap: "a/b", path: sneaky), tapsRoot: taps) == nil)
    }

    @Test func tapCaskDecidesForTheAppItInstalled() throws {
        let aerospace = TapCask(
            token: "aerospace", tap: "nikitabobko/tap", version: "0.22.0", appNames: ["AeroSpace.app"])
        let machine = Machine.test(homebrewCasks: ["aerospace"], tapCasks: [aerospace])
        let app = InstalledApp.test("AeroSpace.app", bundleID: "bobko.aerospace", version: "0.21.3-Beta")
        let index = try CaskIndex.build(fromAPI: try Fixture.data("cask-sample.json"))

        let outcome = try #require(HomebrewCaskSource.outcome(for: app, in: index, machine: machine))
        guard case .found(let release, .high, let note) = outcome else {
            Issue.record("expected a high-confidence release, got \(outcome)")
            return
        }
        #expect(release.version == "0.22.0")
        #expect(note?.contains("nikitabobko/tap/aerospace") == true)

        let report = Resolver(machine: machine).resolve(app, outcomes: [.homebrewCask: outcome])
        #expect(report.managedBy == .homebrew(token: "aerospace"), "ripe pick hands it to brew upgrade")
        #expect(report.verdict.release?.version == "0.22.0")
    }

    @Test func answersOfflineToo() async throws {
        let aerospace = TapCask(
            token: "aerospace", tap: "nikitabobko/tap", version: "0.21.3-Beta", appNames: ["AeroSpace.app"])
        let context = SourceContext(
            http: FakeHTTPClient([]), machine: .test(homebrewCasks: ["aerospace"], tapCasks: [aerospace]))
        let app = InstalledApp.test("AeroSpace.app", bundleID: "bobko.aerospace", version: "0.21.3-Beta")
        let outcomes = await HomebrewCaskSource().check([app], context: context)
        guard case .found(let release, _, _)? = outcomes[app.id] else {
            Issue.record("expected the tap to answer, got \(String(describing: outcomes[app.id]))")
            return
        }
        #expect(release.version == "0.21.3-Beta")
    }
}
