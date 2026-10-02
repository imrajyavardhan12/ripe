import Foundation

/// Why an available update isn't being offered: the person chose to skip it.
public enum SkipRule: Sendable, Hashable, Codable {
    /// Ignore the app until `ripe unskip`.
    case always
    /// Ignore this version (and anything not newer); a newer release shows up again.
    case version(String)
}

/// Updates the person chose to skip, stored as JSON in `~/.config/ripe/skips.json` so it's
/// readable, hand-editable and fits in dotfiles.
public struct SkipList: Sendable, Hashable, Codable {
    public struct Entry: Sendable, Hashable, Codable {
        public var name: String
        public var always: Bool
        public var versions: [String]
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion = SkipList.currentSchemaVersion
    /// Keyed by lowercased bundle ID: bundle IDs are case-insensitive on macOS.
    public private(set) var apps: [String: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { apps.isEmpty }

    public func entry(for bundleID: String) -> Entry? { apps[bundleID.lowercased()] }

    /// The rule that hides `release` for this app, if any.
    ///
    /// A skipped version hides that release and anything not newer than it (a lagging catalog
    /// can briefly offer an older one), but never a newer release: skipping must not hide a
    /// later fix.
    public func rule(for app: InstalledApp, release: Release) -> SkipRule? {
        guard let entry = entry(for: app.bundleID) else { return nil }
        if entry.always { return .always }
        let offered = Version(release.version)
        for skipped in entry.versions {
            if skipped == release.version { return .version(skipped) }
            if let offered, let skippedVersion = Version(skipped),
                offered.order(comparedTo: skippedVersion).map({ $0 != .newer }) == true
            {
                return .version(skipped)
            }
        }
        return nil
    }

    public mutating func skip(_ app: InstalledApp, version: String) {
        var entry = entry(for: app.bundleID) ?? Entry(name: app.name, always: false, versions: [])
        if !entry.versions.contains(version) { entry.versions.append(version) }
        apps[app.bundleID.lowercased()] = entry
    }

    public mutating func skipAlways(_ app: InstalledApp) {
        var entry = entry(for: app.bundleID) ?? Entry(name: app.name, always: true, versions: [])
        entry.always = true
        apps[app.bundleID.lowercased()] = entry
    }

    /// Removes every skip for the app. Returns whether there was one.
    @discardableResult
    public mutating func unskip(bundleID: String) -> Bool {
        apps.removeValue(forKey: bundleID.lowercased()) != nil
    }
}

/// Reads and writes the skip list.
public struct SkipStore: Sendable {
    public var url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `$XDG_CONFIG_HOME/ripe/skips.json`, else `~/.config/ripe/skips.json`.
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let base =
            environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config", directoryHint: .isDirectory)
        return base.appending(path: "ripe/skips.json")
    }

    /// A missing file is an empty list. A file Ripe can't read is an error, never silently
    /// replaced: it may hold choices the person made by hand.
    public func load() throws -> SkipList {
        guard FileManager.default.fileExists(atPath: url.path) else { return SkipList() }
        do {
            let list = try JSONDecoder().decode(SkipList.self, from: Data(contentsOf: url))
            guard list.schemaVersion <= SkipList.currentSchemaVersion else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return list
        } catch {
            throw SkipStoreError(url: url, underlying: error.localizedDescription)
        }
    }

    public func save(_ list: SkipList) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: url, options: .atomic)
    }
}

public struct SkipStoreError: Error, Sendable, CustomStringConvertible {
    public var url: URL
    public var underlying: String

    public var description: String {
        "can't read \(url.path) (\(underlying)). Fix or delete it; Ripe won't overwrite choices it can't read."
    }
}
