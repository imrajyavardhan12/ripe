import Foundation

/// The compiled orchard catalog (`index.json`): hand-written corrections for apps Ripe can't
/// check correctly on its own. Built and validated by the orchard repository's CI.
///
/// Untrusted input. An entry can change which version Ripe compares against, never how an
/// update is verified.
public struct Catalog: Sendable, Decodable {
    /// The schema this build understands. A newer catalog is ignored rather than misread.
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let generatedAt: Date?
    private let entries: [String: CatalogEntry]

    public init(
        schemaVersion: Int = Catalog.supportedSchemaVersion, generatedAt: Date? = nil, apps: [String: CatalogEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.entries = Dictionary(apps.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, generatedAt, apps }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            generatedAt: try container.decodeIfPresent(Date.self, forKey: .generatedAt),
            apps: try container.decode([String: CatalogEntry].self, forKey: .apps)
        )
    }

    public var count: Int { entries.count }

    /// Bundle IDs are case-insensitive on macOS.
    public func entry(for bundleID: String) -> CatalogEntry? { entries[bundleID.lowercased()] }
}

public struct CatalogEntry: Sendable, Hashable, Codable {
    public var name: String
    /// Feed per CPU, keyed by ``Machine/Architecture`` raw value (`arm64`, `x86_64`).
    public var sparkleFeed: [String: URL]?
    public var homebrewCask: String?
    public var installedVersion: InstalledVersionRule?
    public var notes: String?

    public struct InstalledVersionRule: Sendable, Hashable, Codable {
        /// A path with one `*` in the file name standing for the version.
        public var glob: String
    }

    public init(
        name: String,
        sparkleFeed: [String: URL]? = nil,
        homebrewCask: String? = nil,
        installedVersion: InstalledVersionRule? = nil,
        notes: String? = nil
    ) {
        self.name = name
        self.sparkleFeed = sparkleFeed
        self.homebrewCask = homebrewCask
        self.installedVersion = installedVersion
        self.notes = notes
    }
}

/// What the catalog changed about one app, kept for `ripe why` and `--json`.
public struct CatalogApplication: Sendable, Hashable, Codable {
    public var entry: CatalogEntry
    /// Human-readable changes, like "Sparkle feed from orchard".
    public var changes: [String]
}
