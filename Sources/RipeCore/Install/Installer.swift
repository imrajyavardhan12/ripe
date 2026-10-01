import Foundation

public enum InstallOutcome: Sendable, Hashable {
    /// Replaced by Ripe. The previous version is in the Trash.
    case updated(to: AppVersion, previousVersionAt: URL, relaunched: Bool)
    /// Brew or mas did the update.
    case handedOff(String)
    /// A person has to finish it (App Store button, manual download).
    case needsYou(String)
}

/// Runs install plans. Every step that could hurt an app comes after every check that could
/// refuse it, so a refusal always means "nothing was changed".
public struct Installer: Sendable {
    public struct Environment: Sendable {
        public var downloader: any Downloader
        public var runner: any ProcessRunner
        public var signatures: any CodeSignatureChecking
        public var apps: any RunningAppControl
        public var trash: any Trash
        public var tools: HandOffTools
        public var machine: Machine
        /// Scratch space for downloads, emptied after each install.
        public var workDirectory: URL
        public var journalDirectory: URL

        public init(
            downloader: any Downloader, runner: any ProcessRunner, signatures: any CodeSignatureChecking,
            apps: any RunningAppControl, trash: any Trash, tools: HandOffTools, machine: Machine,
            workDirectory: URL, journalDirectory: URL
        ) {
            self.downloader = downloader
            self.runner = runner
            self.signatures = signatures
            self.apps = apps
            self.trash = trash
            self.tools = tools
            self.machine = machine
            self.workDirectory = workDirectory
            self.journalDirectory = journalDirectory
        }

        public static func live(machine: Machine = .current()) -> Environment {
            let runner = LiveProcessRunner()
            let cache = DiskCache.defaultDirectory()
            let support =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
            return Environment(
                downloader: URLSessionDownloader(), runner: runner,
                signatures: LiveCodeSignatureChecker(runner: runner), apps: WorkspaceAppControl(),
                trash: SystemTrash(), tools: .find(), machine: machine,
                workDirectory: cache.appending(path: "downloads", directoryHint: .isDirectory),
                journalDirectory: support.appending(path: "ripe/journal", directoryHint: .isDirectory)
            )
        }
    }

    public var environment: Environment

    public init(environment: Environment) {
        self.environment = environment
    }

    var replacer: Replacer { Replacer(trash: environment.trash, journalDirectory: environment.journalDirectory) }

    /// Undo or finish updates a crash interrupted. Run before any new install.
    public func recoverInterrupted() -> [String] { replacer.recoverInterrupted() }

    public func run(_ plan: InstallPlan, progress: @Sendable (String) -> Void = { _ in }) async throws -> InstallOutcome
    {
        switch plan.method {
        case .homebrew(let token):
            return try await handOffToHomebrew(plan, token: token, progress: progress)
        case .appStore(let id):
            return try await handOffToAppStore(id: id, progress: progress)
        case .direct(let download):
            return try await install(plan, download: download, progress: progress)
        case .manual(let reason, let url):
            return .needsYou(
                [reason, url.map { "get it from \($0.absoluteString)" }].compactMap { $0 }.joined(separator: "; "))
        }
    }

    // MARK: Hand-offs

    private func handOffToHomebrew(_ plan: InstallPlan, token: String, progress: (String) -> Void) async throws
        -> InstallOutcome
    {
        guard let brew = environment.tools.brew else {
            throw InstallError(.handOff, "`brew` isn't available")
        }
        // --greedy: an explicitly named auto-updating cask is still skipped without it.
        progress("brew upgrade --cask --greedy \(token)")
        let result = try await environment.runner.run(
            brew, ["upgrade", "--cask", "--greedy", token], interactive: true)
        guard result.succeeded else {
            throw InstallError(.handOff, "`brew upgrade --cask \(token)` failed (exit \(result.status))")
        }
        let now = BundleInfo(url: plan.app.url)?.version.display ?? "the latest version"
        return .handedOff("Homebrew updated it to \(now)")
    }

    private func handOffToAppStore(id: Int?, progress: (String) -> Void) async throws -> InstallOutcome {
        if let mas = environment.tools.mas, let id {
            progress("mas upgrade \(id)")
            let result = try await environment.runner.run(mas, ["upgrade", String(id)], interactive: true)
            guard result.succeeded else {
                throw InstallError(.handOff, "`mas upgrade \(id)` failed (exit \(result.status))")
            }
            return .handedOff("updated through the App Store (mas)")
        }
        let page = id.map { "macappstore://apps.apple.com/app/id\($0)" } ?? "macappstore://showUpdatesPage"
        _ = try? await environment.runner.run(URL(filePath: "/usr/bin/open"), [page])
        return .needsYou("opened the App Store; click Update there (or `brew install mas` to let Ripe do it)")
    }

    // MARK: Direct install

    private func install(_ plan: InstallPlan, download: Download, progress: (String) -> Void) async throws
        -> InstallOutcome
    {
        let app = plan.app
        let unchanged = "Nothing was changed."

        // Who made the installed app is the anchor for everything else.
        let installedIdentity: SigningIdentity
        do {
            installedIdentity = try environment.signatures.identity(of: app.url)
        } catch {
            throw InstallError(.verify, "couldn't read who signed the installed app. \(unchanged)")
        }
        guard let teamID = installedIdentity.teamID, !installedIdentity.isAdHoc else {
            throw InstallError(
                .verify,
                "the installed app isn't signed by an identified developer, so Ripe can't confirm an update comes from the same one. \(unchanged)"
            )
        }

        let workspace = environment.workDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: workspace) }

        progress("downloading \(download.url.host() ?? download.url.absoluteString)")
        let archive = try await environment.downloader.fetch(download, into: workspace)

        guard let integrity = download.integrity else {
            throw InstallError(.integrity, "no checksum or signature to verify the download. \(unchanged)")
        }
        progress(integrity.isEdDSA ? "verifying EdDSA signature" : "verifying SHA-256")
        try Integrity.verify(archive, against: integrity, publicKey: app.signals.sparklePublicEDKey)

        progress("unpacking")
        let newApp = try await Unpacker(runner: environment.runner)
            .extractApp(from: archive, bundleID: app.bundleID, workspace: workspace)

        guard let newInfo = BundleInfo(url: newApp) else {
            throw InstallError(.verify, "the downloaded app has no readable Info.plist. \(unchanged)")
        }
        let comparison = VersionMatcher.compare(
            app.version,
            with: Release(
                version: newInfo.version.short ?? newInfo.version.display, build: newInfo.version.build,
                source: plan.release.source, comparison: plan.release.comparison))
        guard comparison.order == .older else {
            throw InstallError(
                .verify,
                "the download is \(newInfo.version.display), which isn't newer than the installed \(app.version.display). \(unchanged)"
            )
        }

        progress("checking code signature and Team ID")
        let newIdentity = try environment.signatures.validatedIdentity(of: newApp)
        guard newIdentity.teamID == teamID, !newIdentity.isAdHoc else {
            throw InstallError(
                .verify,
                "Team ID mismatch: the installed app is signed by \(teamID), the download by \(newIdentity.teamID ?? "nobody"). Not installing. \(unchanged)"
            )
        }
        if await environment.signatures.passesGatekeeper(app.url),
            await !environment.signatures.passesGatekeeper(newApp)
        {
            throw InstallError(
                .verify,
                "Gatekeeper accepts the installed app but rejects the download (not notarized or revoked). \(unchanged)"
            )
        }
        guard Self.runs(newApp, on: environment.machine.architecture, replacing: app.url) else {
            throw InstallError(
                .verify,
                "the download doesn't run natively on this Mac's processor, but the installed version does. \(unchanged)"
            )
        }

        let wasRunning = await environment.apps.isRunning(app)
        if wasRunning {
            progress("quitting \(app.name)")
            guard await environment.apps.quit(app, timeout: .seconds(20)) else {
                throw InstallError(
                    .quit, "\(app.name) didn't quit (it may have unsaved work). Quit it and try again. \(unchanged)")
            }
        }

        progress("replacing (old version → Trash)")
        let trashed = try replacer.replace(app.url, with: newApp)

        let installed = BundleInfo(url: app.url)?.version ?? newInfo.version
        if wasRunning { await environment.apps.launch(app.url) }
        return .updated(to: installed, previousVersionAt: trashed, relaunched: wasRunning)
    }

    /// The update must run natively, unless the installed version didn't either (an Intel-only
    /// app on Apple silicon may stay Intel-only, but a native app must never become emulated).
    static func runs(_ bundle: URL, on architecture: Machine.Architecture, replacing installed: URL) -> Bool {
        func architectures(_ url: URL) -> [Int]? { Bundle(url: url)?.executableArchitectures?.map(\.intValue) }
        // No executable info (rare, script-based apps): let the signature checks speak for it.
        guard let new = architectures(bundle), !new.isEmpty else { return true }
        let native = architecture == .arm64 ? NSBundleExecutableArchitectureARM64 : NSBundleExecutableArchitectureX86_64
        if new.contains(native) { return true }
        let installedIsNative = architectures(installed)?.contains(native) ?? true
        return !installedIsNative && new.contains(NSBundleExecutableArchitectureX86_64)
    }
}

extension Download.Integrity {
    public var isEdDSA: Bool { if case .edDSA = self { true } else { false } }
}
