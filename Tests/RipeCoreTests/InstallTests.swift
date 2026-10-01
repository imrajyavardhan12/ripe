import CryptoKit
import Foundation
import Testing

@testable import RipeCore

struct IntegrityTests {
    @Test func sha256MatchAndMismatch() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = sandbox.url("archive.zip")
        try Data("hello".utf8).write(to: file)
        let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        try Integrity.verify(file, against: .sha256(digest.uppercased()), publicKey: nil)
        #expect(throws: InstallError.self) {
            try Integrity.verify(file, against: .sha256(String(repeating: "0", count: 64)), publicKey: nil)
        }
    }

    @Test func edDSAUsesTheInstalledAppsKey() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let file = sandbox.url("archive.zip")
        let data = Data("the real archive".utf8)
        try data.write(to: file)
        let (publicKey, signature) = try TestKeys.sign(data)

        try Integrity.verify(file, against: .edDSA(signature: signature), publicKey: publicKey)

        // Tampered bytes, a different key, and a missing key all refuse.
        try Data("tampered archive".utf8).write(to: file)
        #expect(throws: InstallError.self) {
            try Integrity.verify(file, against: .edDSA(signature: signature), publicKey: publicKey)
        }
        try data.write(to: file)
        let (otherKey, _) = try TestKeys.sign(data)
        #expect(throws: InstallError.self) {
            try Integrity.verify(file, against: .edDSA(signature: signature), publicKey: otherKey)
        }
        #expect(throws: InstallError.self) {
            try Integrity.verify(file, against: .edDSA(signature: signature), publicKey: nil)
        }
        #expect(throws: InstallError.self) {
            try Integrity.verify(file, against: .edDSA(signature: "%%%"), publicKey: publicKey)
        }
    }
}

struct UnpackerTests {
    @Test func detectsArchivesByContent() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let app = try sandbox.app("src/Tool.app", version: "2.0")
        // No extension, like real download URLs (`…/stable`).
        #expect(try Unpacker.kind(of: try await sandbox.zip(app, to: "stable")) == .zip)
        #expect(try Unpacker.kind(of: try await sandbox.diskImage(app, to: "tool.dmg")) == .diskImage)

        let pkg = sandbox.url("x.pkg")
        try Data("xar!rest".utf8).write(to: pkg)
        #expect(try Unpacker.kind(of: pkg) == .installerPackage)

        let junk = sandbox.url("junk")
        try Data("<html>nope</html>".utf8).write(to: junk)
        #expect(try Unpacker.kind(of: junk) == .unknown)
    }

    /// GrandPerspective 3.8.1's DMG starts with bzip2 bytes; it was once mistaken for a tarball.
    @Test func diskImageTrailerWinsOverCompressedHead() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var bytes = Data("BZh91AY&SY".utf8) + Data(count: 2000)
        var trailer = Data("koly".utf8)
        trailer.append(Data(count: 508))
        bytes.append(trailer)
        let file = sandbox.url("image")
        try bytes.write(to: file)
        #expect(try Unpacker.kind(of: file) == .diskImage)
    }

    @Test(arguments: ["zip", "dmg", "tgz"])
    func extractsTheMatchingApp(format: String) async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let app = try sandbox.app("src/Tool.app", version: "2.0")
        try sandbox.app("src/Uninstall Tool.app", bundleID: "dev.example.uninstaller", version: "1.0")
        let archive: URL
        switch format {
        case "zip": archive = try await sandbox.zip(app, to: "tool.zip")
        case "dmg": archive = try await sandbox.diskImage(sandbox.url("src"), to: "tool.dmg")
        default:
            archive = sandbox.url("tool.tar.gz")
            _ = try await LiveProcessRunner().run(
                URL(filePath: "/usr/bin/tar"), ["-czf", archive.path, "-C", sandbox.url("src").path, "Tool.app"])
        }
        let extracted = try await Unpacker(runner: LiveProcessRunner())
            .extractApp(from: archive, bundleID: "dev.example.tool", workspace: sandbox.url("work-\(format)"))
        #expect(BundleInfo(url: extracted)?.version.short == "2.0")
        #expect(extracted.lastPathComponent == "Tool.app")
    }

    @Test func refusesPackagesAndMissingOrDuplicateApps() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let pkg = sandbox.url("update")
        try Data("xar!".utf8).write(to: pkg)
        await #expect(throws: InstallError.self) {
            try await Unpacker(runner: LiveProcessRunner()).extractApp(
                from: pkg, bundleID: "x.y", workspace: sandbox.url("w1"))
        }
        try sandbox.app("two/A.app", version: "1")
        try sandbox.app("two/B.app", version: "1")
        #expect(throws: InstallError.self) {
            try Unpacker.findApp(bundleID: "dev.example.tool", in: sandbox.url("two"))
        }
        #expect(throws: InstallError.self) { try Unpacker.findApp(bundleID: "other.app", in: sandbox.url("two")) }
    }
}

struct ReplacerTests {
    @Test func swapsBundlesAndKeepsTheOldOneInTheTrash() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let installed = try sandbox.app("Applications/Tool.app", version: "1.0")
        let new = try sandbox.app("work/Tool.app", version: "2.0")
        let replacer = Replacer(
            trash: FolderTrash(folder: sandbox.url("Trash")), journalDirectory: sandbox.url("journal"))

        let trashed = try replacer.replace(installed, with: new)

        #expect(BundleInfo(url: installed)?.version.short == "2.0")
        #expect(BundleInfo(url: trashed)?.version.short == "1.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.url("Applications").path) == ["Tool.app"])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: sandbox.url("journal").path)) ?? [] == [])
    }

    @Test func failedTrashChangesNothing() throws {
        struct BrokenTrash: Trash {
            func trash(_ url: URL) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
        }
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let installed = try sandbox.app("Applications/Tool.app", version: "1.0")
        let new = try sandbox.app("work/Tool.app", version: "2.0")
        let replacer = Replacer(trash: BrokenTrash(), journalDirectory: sandbox.url("journal"))

        #expect(throws: InstallError.self) { try replacer.replace(installed, with: new) }
        #expect(BundleInfo(url: installed)?.version.short == "1.0")
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.url("Applications").path) == ["Tool.app"])
    }

    @Test func reportsWhereTheOldVersionIsWhenRestoreFails() throws {
        /// Trashes, then occupies the path so neither the new version nor the restore can move in.
        struct SquattingTrash: Trash {
            var folder: URL
            func trash(_ url: URL) throws -> URL {
                let moved = try FolderTrash(folder: folder).trash(url)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try Data().write(to: url.appending(path: "squatter"))
                return moved
            }
        }
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let installed = try sandbox.app("Applications/Tool.app", version: "1.0")
        let new = try sandbox.app("work/Tool.app", version: "2.0")
        let replacer = Replacer(
            trash: SquattingTrash(folder: sandbox.url("Trash")), journalDirectory: sandbox.url("journal"))

        let error = try #require(throws: InstallError.self) { try replacer.replace(installed, with: new) }
        #expect(error.message.contains("old version is in the Trash"))
        // The journal stays, so the next run can still recover.
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.url("journal").path).count == 1)
    }

    @Test func recoversEveryInterruptedState() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let journal = sandbox.url("journal")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
        func record(_ entry: Replacer.JournalEntry) throws {
            try JSONEncoder().encode(entry).write(to: journal.appending(path: "\(UUID().uuidString).json"))
        }

        // A: crashed after trashing, before the rename: the old version comes back.
        let trashedA = try sandbox.app("Trash/A.app", bundleID: "dev.a", version: "1.0")
        let stagedA = try sandbox.app("Applications/.A.ripe-1.app", bundleID: "dev.a", version: "2.0")
        try record(
            .init(appPath: sandbox.url("Applications/A.app").path, stagedPath: stagedA.path, trashedPath: trashedA.path)
        )
        // B: crashed after trashing, before the journal recorded where: the verified new copy finishes it.
        let stagedB = try sandbox.app("Applications/.B.ripe-2.app", bundleID: "dev.b", version: "2.0")
        try record(.init(appPath: sandbox.url("Applications/B.app").path, stagedPath: stagedB.path, trashedPath: nil))
        // C: crashed after staging only: the app is intact, the staged copy goes.
        try sandbox.app("Applications/C.app", bundleID: "dev.c", version: "1.0")
        let stagedC = try sandbox.app("Applications/.C.ripe-3.app", bundleID: "dev.c", version: "2.0")
        try record(.init(appPath: sandbox.url("Applications/C.app").path, stagedPath: stagedC.path, trashedPath: nil))
        // D: garbage.
        try Data("not json".utf8).write(to: journal.appending(path: "bad.json"))

        let actions = Replacer(trash: FolderTrash(folder: sandbox.url("Trash")), journalDirectory: journal)
            .recoverInterrupted()

        #expect(BundleInfo(url: sandbox.url("Applications/A.app"))?.version.short == "1.0")
        #expect(BundleInfo(url: sandbox.url("Applications/B.app"))?.version.short == "2.0")
        #expect(BundleInfo(url: sandbox.url("Applications/C.app"))?.version.short == "1.0")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: sandbox.url("Applications").path).sorted() == [
                "A.app", "B.app", "C.app",
            ])
        #expect(try FileManager.default.contentsOfDirectory(atPath: journal.path).isEmpty)
        #expect(actions.count == 2)
    }
}

struct PlannerTests {
    static let tools = HandOffTools(brew: URL(filePath: "/opt/homebrew/bin/brew"), mas: nil)

    func report(
        _ release: Release, managedBy: ManagedBy = .selfUpdating, edKey: String? = nil, verdict: Verdict? = nil
    ) -> AppReport {
        let app = InstalledApp.test(
            "Tool.app", bundleID: "dev.example.tool", version: "1.0", signals: .init(sparklePublicEDKey: edKey))
        return AppReport(
            app: app, verdict: verdict ?? .outdated(release), evidence: [], explanation: "", managedBy: managedBy)
    }

    func method(_ report: AppReport, tools: HandOffTools = PlannerTests.tools) -> InstallPlan.Method? {
        if case .plan(let plan) = Planner.decide(report, tools: tools) { return plan.method }
        return nil
    }

    let download = Download(
        url: URL(staticString: "https://example.com/tool.zip"), integrity: .sha256(String(repeating: "a", count: 64)))

    @Test func delegatesToHomebrewAndTheAppStore() {
        let release = Release(
            version: "2.0", source: .homebrewCask, comparison: .shortVersion, download: download, appStoreID: 42)
        #expect(method(report(release, managedBy: .homebrew(token: "tool"))) == .homebrew(token: "tool"))
        #expect(method(report(release, managedBy: .appStore)) == .appStore(id: 42))
        guard
            case .manual? = method(
                report(release, managedBy: .homebrew(token: "tool")), tools: HandOffTools(brew: nil, mas: nil))
        else {
            Issue.record("no brew means a manual step")
            return
        }
    }

    @Test func installsDirectlyOnlyWhenTheDownloadCanBeVerified() {
        let verified = Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion, download: download)
        #expect(method(report(verified)) == .direct(download))

        var unverified = download
        unverified.integrity = nil
        var package = download
        package.isInstallerPackage = true
        let signed = Download(url: download.url, integrity: .edDSA(signature: "sig"))
        for (release, why) in [
            (Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion), "no download"),
            (
                Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion, download: unverified),
                "no checksum"
            ),
            (Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion, download: package), "pkg"),
            (
                Release(version: "2.0", source: .sparkle, comparison: .bundleVersion, download: signed),
                "EdDSA without app key"
            ),
        ] {
            guard case .manual? = method(report(release)) else {
                Issue.record("\(why) must not install directly")
                continue
            }
        }
        let withKey = Release(version: "2.0", source: .sparkle, comparison: .bundleVersion, download: signed)
        #expect(method(report(withKey, edKey: "key")) == .direct(signed))
    }

    @Test func skipsAnythingNotOutdated() {
        let release = Release(version: "2.0", source: .homebrewCask, comparison: .shortVersion, download: download)
        #expect(
            Planner.decide(report(release, verdict: .current(release)), tools: Self.tools)
                == .skip("already up to date"))
        guard
            case .skip = Planner.decide(report(release, verdict: .unknown(.lowConfidence(release))), tools: Self.tools)
        else {
            Issue.record("unknown verdicts are never picked")
            return
        }
    }
}

/// The whole direct-install path with real archives and real file moves, fake signatures and apps.
struct InstallerTests {
    struct Setup {
        let sandbox: Sandbox
        let installed: InstalledApp
        let plan: InstallPlan

        init(newVersion: String = "2.0") async throws {
            sandbox = try Sandbox()
            let installedURL = try sandbox.app("Applications/Tool.app", version: "1.0")
            installed = InstalledApp(
                name: "Tool", bundleID: "dev.example.tool", url: installedURL,
                version: AppVersion(short: "1.0", build: nil))
            let new = try sandbox.app("release/Tool.app", version: newVersion)
            let archive = try await sandbox.zip(new, to: "tool.zip")
            let download = Download(
                url: URL(staticString: "https://example.com/tool.zip"),
                integrity: .sha256(try Integrity.sha256(of: archive)))
            let release = Release(
                version: newVersion, source: .homebrewCask, comparison: .shortVersion, download: download)
            plan = InstallPlan(
                report: AppReport(
                    app: installed, verdict: .outdated(release), evidence: [], explanation: "", managedBy: .none),
                release: release, method: .direct(download))
            archiveURL = archive
        }

        let archiveURL: URL

        func installer(
            installedTeam: String? = "TEAM123", downloadTeam: String? = "TEAM123", apps: FakeApps = FakeApps(),
            downloadPassesGatekeeper: Bool = true
        ) -> Installer {
            Installer(
                environment: .init(
                    downloader: FakeDownloader(archive: archiveURL), runner: LiveProcessRunner(),
                    signatures: FakeSignatures(
                        installed: SigningIdentity(teamID: installedTeam, isAdHoc: installedTeam == nil),
                        download: SigningIdentity(teamID: downloadTeam, isAdHoc: downloadTeam == nil),
                        downloadPassesGatekeeper: downloadPassesGatekeeper),
                    apps: apps, trash: FolderTrash(folder: sandbox.url("Trash")),
                    tools: HandOffTools(brew: nil, mas: nil),
                    machine: .test(), workDirectory: sandbox.url("work"), journalDirectory: sandbox.url("journal")))
        }

        var installedVersion: String? { BundleInfo(url: installed.url)?.version.short }
    }

    @Test func updatesQuitsAndRelaunches() async throws {
        let setup = try await Setup()
        defer { setup.sandbox.remove() }
        let apps = FakeApps(running: true)
        let outcome = try await setup.installer(apps: apps).run(setup.plan)

        guard case .updated(let version, let trashed, let relaunched) = outcome else {
            Issue.record("expected an update, got \(outcome)")
            return
        }
        #expect(version.short == "2.0" && relaunched)
        #expect(setup.installedVersion == "2.0")
        #expect(BundleInfo(url: trashed)?.version.short == "1.0")
        #expect(await apps.launched == [setup.installed.url])
        #expect((try? FileManager.default.contentsOfDirectory(atPath: setup.sandbox.url("work").path)) ?? [] == [])
    }

    /// Each refusal must leave the installed app exactly as it was.
    @Test(arguments: ["team mismatch", "ad-hoc installed", "gatekeeper", "not newer", "won't quit"])
    func refusesWithoutChangingAnything(_ scenario: String) async throws {
        let setup = try await Setup(newVersion: scenario == "not newer" ? "1.0" : "2.0")
        defer { setup.sandbox.remove() }
        let installer: Installer
        switch scenario {
        case "team mismatch": installer = setup.installer(downloadTeam: "EVIL999")
        case "ad-hoc installed": installer = setup.installer(installedTeam: nil)
        case "gatekeeper": installer = setup.installer(downloadPassesGatekeeper: false)
        case "won't quit": installer = setup.installer(apps: FakeApps(running: true, refusesToQuit: true))
        default: installer = setup.installer()
        }
        let error = try await #require(throws: InstallError.self) { try await installer.run(setup.plan) }
        #expect(error.message.contains("Nothing was changed"))
        #expect(setup.installedVersion == "1.0")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: setup.sandbox.url("Trash").path)) ?? [] == [])
    }

    @Test func refusesATamperedDownload() async throws {
        let setup = try await Setup()
        defer { setup.sandbox.remove() }
        var plan = setup.plan
        let tampered = Download(
            url: URL(staticString: "https://example.com/tool.zip"),
            integrity: .sha256(String(repeating: "0", count: 64)))
        plan.method = .direct(tampered)
        await #expect(throws: InstallError.self) { try await setup.installer().run(plan) }
        #expect(setup.installedVersion == "1.0")
    }

    @Test func handsOffToHomebrewWithGreedy() async throws {
        let setup = try await Setup()
        defer { setup.sandbox.remove() }
        let runner = RecordingRunner()
        var environment = setup.installer().environment
        environment.runner = runner
        environment.tools = HandOffTools(brew: URL(filePath: "/opt/homebrew/bin/brew"), mas: nil)
        var plan = setup.plan
        plan.method = .homebrew(token: "tool")

        guard case .handedOff = try await Installer(environment: environment).run(plan) else {
            Issue.record("expected a hand-off")
            return
        }
        #expect(await runner.commands == [["brew", "upgrade", "--cask", "--greedy", "tool"]])

        let failing = RecordingRunner(status: 1)
        environment.runner = failing
        await #expect(throws: InstallError.self) { try await Installer(environment: environment).run(plan) }
    }

    @Test func appStoreWithoutMasOpensTheStore() async throws {
        let setup = try await Setup()
        defer { setup.sandbox.remove() }
        let runner = RecordingRunner()
        var environment = setup.installer().environment
        environment.runner = runner
        var plan = setup.plan
        plan.method = .appStore(id: 1_355_679_052)

        guard case .needsYou = try await Installer(environment: environment).run(plan) else {
            Issue.record("the person has to click Update")
            return
        }
        #expect(await runner.commands == [["open", "macappstore://apps.apple.com/app/id1355679052"]])
    }

    @Test func nativeArchitectureRule() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        // Bundles without an executable can't be judged; signature checks decide.
        let bundle = try sandbox.app("A.app", version: "1")
        #expect(Installer.runs(bundle, on: .arm64, replacing: bundle))
    }
}

/// The real Security framework against bundles we can make in a test: unsigned and ad-hoc.
struct LiveCodeSignatureTests {
    @Test func unsignedBundlesFailValidation() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let bundle = try sandbox.app("Unsigned.app", version: "1.0")
        #expect(throws: InstallError.self) { try LiveCodeSignatureChecker().validatedIdentity(of: bundle) }
    }

    @Test func adHocSignaturesHaveNoTeam() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let bundle = try sandbox.app("AdHoc.app", version: "1.0")
        let executable = bundle.appending(path: "Contents/MacOS/AdHoc")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: executable)
        let signed = try await LiveProcessRunner().run(
            URL(filePath: "/usr/bin/codesign"), ["--force", "--sign", "-", bundle.path])
        try #require(signed.succeeded, "codesign failed: \(signed.errorOutput)")

        let identity = try LiveCodeSignatureChecker().validatedIdentity(of: bundle)
        #expect(identity.teamID == nil)
        #expect(identity.isAdHoc)
    }

    @Test func appleAppsValidate() throws {
        let calculator = URL(filePath: "/System/Applications/Calculator.app")
        try #require(FileManager.default.fileExists(atPath: calculator.path))
        let identity = try LiveCodeSignatureChecker().validatedIdentity(of: calculator)
        #expect(!identity.isAdHoc)
    }
}
