import Foundation

/// An app bundle found on disk, with everything Ripe learned from reading it.
///
/// Pure data: building one never touches the network.
public struct InstalledApp: Sendable, Hashable, Codable, Identifiable {
    /// The bundle path. Unique even when the same app is installed twice.
    public var id: String { url.path }

    /// The name shown in Finder: the bundle's file name without `.app`.
    public let name: String
    public let bundleID: String
    public let url: URL
    /// From Info.plist, unless an orchard entry says where the real version lives.
    public internal(set) var version: AppVersion
    public internal(set) var signals: Signals
    /// What the orchard catalog changed about this app, if anything.
    public internal(set) var catalog: CatalogApplication?

    public init(
        name: String,
        bundleID: String,
        url: URL,
        version: AppVersion,
        signals: Signals = Signals(),
        catalog: CatalogApplication? = nil
    ) {
        self.name = name
        self.bundleID = bundleID
        self.url = url
        self.version = version
        self.signals = signals
        self.catalog = catalog
    }

    /// Clues inside the bundle about where updates come from.
    public struct Signals: Sendable, Hashable, Codable {
        /// `Contents/_MASReceipt/receipt` exists: installed from the Mac App Store.
        public var appStoreReceipt: Bool
        /// An iPhone or iPad app running on Apple silicon (`Wrapper/` layout); always from the App Store.
        public var wrappedIOSApp: Bool
        /// `SUFeedURL` from Info.plist. Many Sparkle apps set their feed in code instead, so absence proves nothing.
        public var sparkleFeedURL: URL?
        /// `SUPublicEDKey` from Info.plist: the key Sparkle updates must be signed with.
        public var sparklePublicEDKey: String?
        /// `Contents/Resources/app-update.yml` exists: an Electron app using electron-updater.
        public var electronUpdater: Bool

        public init(
            appStoreReceipt: Bool = false,
            wrappedIOSApp: Bool = false,
            sparkleFeedURL: URL? = nil,
            sparklePublicEDKey: String? = nil,
            electronUpdater: Bool = false
        ) {
            self.appStoreReceipt = appStoreReceipt
            self.wrappedIOSApp = wrappedIOSApp
            self.sparkleFeedURL = sparkleFeedURL
            self.sparklePublicEDKey = sparklePublicEDKey
            self.electronUpdater = electronUpdater
        }

        public var isFromAppStore: Bool { appStoreReceipt || wrappedIOSApp }
    }
}

/// The two version fields every bundle may declare. Either can be missing or junk.
public struct AppVersion: Sendable, Hashable, Codable {
    /// `CFBundleShortVersionString`: the version people see, like `2.7.12`.
    public let short: String?
    /// `CFBundleVersion`: the build number Sparkle compares, like `6316`.
    public let build: String?

    public init(short: String?, build: String?) {
        self.short = short?.nilIfBlank
        self.build = build?.nilIfBlank
    }

    /// What to show a person.
    public var display: String { short ?? build ?? "?" }

    public var parsedShort: Version? { short.flatMap(Version.init) }
    public var parsedBuild: Version? { build.flatMap(Version.init) }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
