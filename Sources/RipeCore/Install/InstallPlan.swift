import Foundation

/// How one app will be updated. Decided before anything runs, so `ripe pick` can show the
/// whole plan and ask first.
public struct InstallPlan: Sendable, Hashable {
    public enum Method: Sendable, Hashable {
        /// Homebrew installed it, so Homebrew updates it.
        case homebrew(token: String)
        /// App Store apps only update through the store.
        case appStore(id: Int?)
        /// Ripe downloads, verifies and replaces the bundle itself.
        case direct(Download)
        /// No safe automatic path; tell the person where to get it.
        case manual(reason: String, url: URL?)
    }

    public var report: AppReport
    public var release: Release
    public var method: Method

    public var app: InstalledApp { report.app }

    public init(report: AppReport, release: Release, method: Method) {
        self.report = report
        self.release = release
        self.method = method
    }
}

/// Command-line tools Ripe can hand off to, found once per run.
public struct HandOffTools: Sendable, Hashable {
    public var brew: URL?
    public var mas: URL?

    public init(brew: URL?, mas: URL?) {
        self.brew = brew
        self.mas = mas
    }

    public static func find() -> HandOffTools {
        HandOffTools(brew: ExecutableLocator.find("brew"), mas: ExecutableLocator.find("mas"))
    }
}

public enum Planner {
    public enum Decision: Sendable, Hashable {
        case plan(InstallPlan)
        /// Not pickable, and why (up to date, or the verdict is unknown).
        case skip(String)
    }

    /// Delegation first (principle 6); direct install only when the download can be verified.
    public static func decide(_ report: AppReport, tools: HandOffTools) -> Decision {
        guard case .outdated(let release) = report.verdict else {
            switch report.verdict {
            case .current: return .skip("already up to date")
            case .unknown: return .skip("Ripe isn't sure it's outdated (`ripe why \(report.app.name)`)")
            case .skippedByUser(let release, .always):
                return .skip("you skipped it (\(release.version) available; `ripe unskip \(report.app.name)`)")
            case .skippedByUser(let release, .version):
                return .skip("you skipped \(release.version) (`ripe unskip \(report.app.name)`)")
            case .outdated: return .skip("")  // unreachable
            }
        }
        let fallbackURL = release.pageURL ?? release.download?.url

        let method: InstallPlan.Method
        switch report.managedBy {
        case .appStore:
            method = .appStore(id: release.appStoreID)
        case .homebrew(let token) where tools.brew != nil:
            method = .homebrew(token: token)
        case .homebrew:
            method = .manual(reason: "Homebrew manages this app but `brew` isn't on PATH", url: fallbackURL)
        case .selfUpdating, .none:
            method = directOrManual(report, release, fallbackURL)
        }
        return .plan(InstallPlan(report: report, release: release, method: method))
    }

    private static func directOrManual(_ report: AppReport, _ release: Release, _ fallbackURL: URL?)
        -> InstallPlan.Method
    {
        guard let download = release.download else {
            return .manual(reason: "\(release.source.displayName) doesn't offer a download", url: fallbackURL)
        }
        if download.isInstallerPackage {
            return .manual(reason: "the update is a .pkg installer, which Ripe never runs", url: fallbackURL)
        }
        switch download.integrity {
        case nil:
            return .manual(reason: "there's no checksum or signature to verify the download", url: fallbackURL)
        case .edDSA? where report.app.signals.sparklePublicEDKey == nil:
            return .manual(reason: "the app has no Sparkle signing key to verify the download", url: fallbackURL)
        default:
            return .direct(download)
        }
    }
}
