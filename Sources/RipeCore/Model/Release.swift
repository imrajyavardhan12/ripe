import Foundation

/// Where version information came from. Declaration order is authority order: when two
/// sources disagree, the earlier one wins.
public enum SourceID: String, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case appStore = "app-store"
    case sparkle
    case homebrewCask = "homebrew-cask"

    public var displayName: String {
        switch self {
        case .appStore: "App Store"
        case .sparkle: "Sparkle"
        case .homebrewCask: "Homebrew"
        }
    }

    private var rank: Int {
        switch self {
        case .appStore: 0
        case .sparkle: 1
        case .homebrewCask: 2
        }
    }

    public static func < (lhs: SourceID, rhs: SourceID) -> Bool { lhs.rank < rhs.rank }
}

/// How sure a source is that its answer is about *this* app.
public enum Confidence: Int, Sendable, Hashable, Codable, Comparable, CustomStringConvertible {
    /// A weak clue. Never enough to report an update.
    case low
    /// A name match without contradicting evidence.
    case medium
    /// The app's own feed, its App Store record, or a matching bundle ID.
    case high

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        }
    }
}

/// The newest version one source knows about.
public struct Release: Sendable, Hashable, Codable {
    /// Which installed field this release is compared against.
    public enum Comparison: String, Sendable, Hashable, Codable {
        /// `build` against `CFBundleVersion`, falling back to `version` against the short version.
        /// Sparkle's own rule.
        case bundleVersion
        /// `version` against `CFBundleShortVersionString` only.
        case shortVersion
    }

    /// The version people see, like `32.2.2`.
    public var version: String
    /// A build number, when the source has one.
    public var build: String?
    public var source: SourceID
    public var comparison: Comparison
    /// Store page, release notes or homepage.
    public var pageURL: URL?
    public var minimumSystemVersion: String?
    public var publishedAt: Date?
    /// The Homebrew cask this came from, when `source` is `.homebrewCask`.
    public var caskToken: String?
    /// Where to get it and how to prove the bytes are genuine. `nil` when the source has no download.
    public var download: Download?
    /// The App Store `trackId`, when `source` is `.appStore`.
    public var appStoreID: Int?

    public init(
        version: String,
        build: String? = nil,
        source: SourceID,
        comparison: Comparison,
        pageURL: URL? = nil,
        minimumSystemVersion: String? = nil,
        publishedAt: Date? = nil,
        caskToken: String? = nil,
        download: Download? = nil,
        appStoreID: Int? = nil
    ) {
        self.version = version
        self.build = build
        self.source = source
        self.comparison = comparison
        self.pageURL = pageURL
        self.minimumSystemVersion = minimumSystemVersion
        self.publishedAt = publishedAt
        self.caskToken = caskToken
        self.download = download
        self.appStoreID = appStoreID
    }
}

/// A downloadable update and the evidence that its bytes are genuine.
public struct Download: Sendable, Hashable, Codable {
    public enum Integrity: Sendable, Hashable, Codable {
        /// Published by Homebrew for the cask.
        case sha256(String)
        /// Sparkle's Ed25519 signature over the archive, checked against the installed app's
        /// own `SUPublicEDKey`, so neither a feed nor the catalog can supply the key.
        case edDSA(signature: String)
    }

    public var url: URL
    /// `nil` means the bytes can't be verified, so Ripe won't install them itself.
    public var integrity: Integrity?
    public var expectedLength: Int?
    /// A `.pkg` installer runs scripts as root: never installed directly by Ripe.
    public var isInstallerPackage: Bool

    public init(url: URL, integrity: Integrity?, expectedLength: Int? = nil, isInstallerPackage: Bool = false) {
        self.url = url
        self.integrity = integrity
        self.expectedLength = expectedLength
        self.isInstallerPackage = isInstallerPackage
    }
}

/// What one source said about one app.
public enum SourceOutcome: Sendable, Hashable {
    case found(Release, Confidence, note: String?)
    /// The source has nothing to do with this app.
    case notApplicable
    /// The source applies but couldn't answer: offline, not listed, no usable version.
    case failed(String)
}
