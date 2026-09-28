import Foundation

public enum Verdict: Sendable, Hashable {
    case outdated(Release)
    case current(Release)
    case unknown(UnknownReason)

    public var release: Release? {
        switch self {
        case .outdated(let release), .current(let release): release
        case .unknown(let reason): reason.release
        }
    }
}

public enum UnknownReason: Sendable, Hashable {
    /// No source applies. These apps are the orchard catalog's backlog.
    case noSource
    /// Every applicable source failed (offline, not listed, unversioned).
    case sourcesFailed
    /// The versions can't be ordered: a git hash, unrelated tags, or different numbering schemes.
    case incomparable(Release)
    /// Looks outdated, but the match between app and source is too weak to claim it.
    case lowConfidence(Release)
    /// A newer version exists but needs a newer macOS than this Mac runs.
    case requiresNewerMacOS(Release)

    public var release: Release? {
        switch self {
        case .noSource, .sourcesFailed: nil
        case .incomparable(let release), .lowConfidence(let release), .requiresNewerMacOS(let release): release
        }
    }
}

/// Who should perform an update, which `ripe pick` will respect.
public enum ManagedBy: Sendable, Hashable {
    case appStore
    case homebrew(token: String)
    /// Sparkle or Electron: the app updates itself when opened.
    case selfUpdating
    case none
}

/// One line of the audit trail behind a verdict.
public struct Evidence: Sendable, Hashable {
    public var source: SourceID
    public var outcome: SourceOutcome
    /// This source's answer decided the verdict.
    public var decisive: Bool

    public init(source: SourceID, outcome: SourceOutcome, decisive: Bool) {
        self.source = source
        self.outcome = outcome
        self.decisive = decisive
    }
}

public struct AppReport: Sendable, Hashable, Identifiable {
    public var app: InstalledApp
    public var verdict: Verdict
    /// Every applicable source, most authoritative first.
    public var evidence: [Evidence]
    /// The rule that produced the verdict, in words.
    public var explanation: String
    public var managedBy: ManagedBy

    public var id: String { app.id }

    public init(app: InstalledApp, verdict: Verdict, evidence: [Evidence], explanation: String, managedBy: ManagedBy) {
        self.app = app
        self.verdict = verdict
        self.evidence = evidence
        self.explanation = explanation
        self.managedBy = managedBy
    }
}

public struct Report: Sendable {
    public var apps: [AppReport]
    public var skipped: [SkippedBundle]
    public var duration: Duration
    public var generatedAt: Date

    public init(apps: [AppReport], skipped: [SkippedBundle], duration: Duration, generatedAt: Date) {
        self.apps = apps
        self.skipped = skipped
        self.duration = duration
        self.generatedAt = generatedAt
    }

    public var outdated: [AppReport] { apps.filter { if case .outdated = $0.verdict { true } else { false } } }
    public var current: [AppReport] { apps.filter { if case .current = $0.verdict { true } else { false } } }
    public var unknown: [AppReport] { apps.filter { if case .unknown = $0.verdict { true } else { false } } }
}
