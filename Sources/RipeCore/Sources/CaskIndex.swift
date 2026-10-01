import Foundation

/// The parts of Homebrew's cask database that matching needs, indexed for lookup.
///
/// Built once from the 19 MB `cask.json` and cached on disk next to it (keyed by the
/// download's ETag), so warm runs decode a few hundred KB instead of the whole database.
struct CaskIndex: Sendable, Codable {
    struct Cask: Sendable, Codable, Hashable {
        var token: String
        /// File names the cask installs, after any rename: `Thorium Browser.app`.
        var appNames: [String]
        /// Bundle IDs from `uninstall: quit/signal`: Homebrew quits exactly this app before upgrading.
        var quitIDs: [String]
        /// Bundle IDs inferred from `zap` paths like `~/Library/Preferences/<id>.plist`. Weaker:
        /// zap stanzas also list helpers and related apps.
        var zapIDs: [String]
        var version: String
        var url: URL?
        /// Hex SHA-256 of the download, or `nil` for `no_check` casks (which can't be installed safely).
        var sha256: String?
        /// Overrides for other OS/CPU combinations, keyed like `arm64_big_sur` or `big_sur`.
        var variations: [String: Variation]
        var homepage: URL?
        var autoUpdates: Bool
        /// The cask runs a `.pkg` installer: never installed directly, only through Homebrew.
        var installsPackage: Bool

        struct Variation: Sendable, Codable, Hashable {
            var version: String?
            var url: URL?
            var sha256: String?
        }

        /// What Homebrew would install on this Mac.
        struct Resolved: Sendable, Hashable {
            var version: String
            var url: URL?
            var sha256: String?
        }

        /// `version: latest` casks always download whatever is current and can't be compared.
        var isVersioned: Bool { version != "latest" }

        func resolved(on machine: Machine) -> Resolved {
            let base = Resolved(version: version, url: url, sha256: sha256)
            guard let codename = machine.macOSCodename else { return base }
            let key = machine.architecture == .arm64 ? "arm64_\(codename)" : codename
            guard let variation = variations[key] else { return base }
            // A variation that changes the URL without a checksum must not inherit the base checksum.
            let sha256 = variation.url == nil ? (variation.sha256 ?? base.sha256) : variation.sha256
            return Resolved(version: variation.version ?? version, url: variation.url ?? url, sha256: sha256)
        }

        func version(on machine: Machine) -> String { resolved(on: machine).version }
    }

    let casks: [Cask]
    private let byAppName: [String: [Int]]
    private let byBundleID: [String: [Int]]
    private let byToken: [String: Int]

    init(casks: [Cask]) {
        self.casks = casks
        var byAppName: [String: [Int]] = [:]
        var byBundleID: [String: [Int]] = [:]
        byToken = Dictionary(casks.enumerated().map { ($1.token, $0) }, uniquingKeysWith: { first, _ in first })
        for (index, cask) in casks.enumerated() {
            for name in Set(cask.appNames.map { $0.lowercased() }) { byAppName[name, default: []].append(index) }
            for id in Set((cask.quitIDs + cask.zapIDs).map { $0.lowercased() }) {
                byBundleID[id, default: []].append(index)
            }
        }
        self.byAppName = byAppName
        self.byBundleID = byBundleID
    }

    enum CodingKeys: CodingKey { case casks }

    init(from decoder: any Decoder) throws {
        self.init(casks: try decoder.container(keyedBy: CodingKeys.self).decode([Cask].self, forKey: .casks))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(casks, forKey: .casks)
    }

    func cask(token: String) -> Cask? { byToken[token].map { casks[$0] } }

    /// Casks that mention this app by installed file name or bundle ID.
    func candidates(appName: String, bundleID: String) -> [Cask] {
        let indices = (byAppName[appName.lowercased()] ?? []) + (byBundleID[bundleID.lowercased()] ?? [])
        var seen = Set<Int>()
        return indices.filter { seen.insert($0).inserted }.map { casks[$0] }
    }
}

// MARK: - Building from the Homebrew API

extension CaskIndex {
    struct FormatError: Error, CustomStringConvertible {
        var description: String
    }

    /// Parses `https://formulae.brew.sh/api/cask.json`. Tolerant by design: the API is
    /// unversioned, so every field is optional and a cask we can't read is skipped, not fatal.
    static func build(fromAPI data: Data) throws -> CaskIndex {
        guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw FormatError(description: "cask database is not a JSON array")
        }
        return CaskIndex(casks: entries.compactMap(cask(from:)))
    }

    private static func cask(from entry: [String: Any]) -> Cask? {
        guard let token = entry["token"] as? String, let version = entry["version"] as? String else { return nil }
        if entry["disabled"] as? Bool == true { return nil }

        var appNames: [String] = []
        var quitIDs: [String] = []
        var zapIDs: [String] = []
        var installsPackage = false
        for artifact in entry["artifacts"] as? [[String: Any]] ?? [] {
            if artifact["pkg"] != nil { installsPackage = true }
            if let app = artifact["app"] as? [Any] {
                appNames.append(contentsOf: installedAppNames(app, target: artifact["target"] as? String))
            }
            for stanza in artifact["uninstall"] as? [[String: Any]] ?? [] {
                quitIDs += strings(stanza["quit"]) + strings(stanza["signal"]).filter(looksLikeBundleID)
            }
            for stanza in artifact["zap"] as? [[String: Any]] ?? [] {
                zapIDs += strings(stanza["trash"]).compactMap(bundleID(fromZapPath:))
            }
        }

        var variations: [String: Cask.Variation] = [:]
        for (key, value) in entry["variations"] as? [String: Any] ?? [:] {
            guard let value = value as? [String: Any] else { continue }
            let variation = Cask.Variation(
                version: value["version"] as? String,
                url: (value["url"] as? String).flatMap(URL.init(string:)),
                sha256: checksum(value["sha256"])
            )
            if variation.version != nil || variation.url != nil { variations[key] = variation }
        }

        return Cask(
            token: token,
            appNames: appNames,
            quitIDs: quitIDs.filter(looksLikeBundleID),
            zapIDs: Array(Set(zapIDs)).sorted(),
            version: version,
            url: (entry["url"] as? String).flatMap(URL.init(string:)),
            sha256: checksum(entry["sha256"]),
            variations: variations,
            homepage: (entry["homepage"] as? String).flatMap(URL.init(string:)),
            autoUpdates: entry["auto_updates"] as? Bool ?? false,
            installsPackage: installsPackage
        )
    }

    /// A 64-character hex SHA-256, or `nil` for `no_check` and anything malformed.
    private static func checksum(_ value: Any?) -> String? {
        guard let text = (value as? String)?.lowercased(), text.count == 64,
            text.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return text
    }

    /// `app` stanzas look like `["Brave Browser.app"]` or `["Thorium.app", {"target": "Thorium Browser.app"}]`,
    /// and the artifact may carry the full install path as `target`. The installed name wins.
    private static func installedAppNames(_ stanza: [Any], target: String?) -> [String] {
        if let target, target.hasSuffix(".app") {
            return [URL(filePath: target).lastPathComponent]
        }
        let renamed = stanza.compactMap { ($0 as? [String: Any])?["target"] as? String }.first
        if let renamed { return [URL(filePath: renamed).lastPathComponent] }
        return stanza.compactMap { $0 as? String }.map { URL(filePath: $0).lastPathComponent }
    }

    /// Values in cask JSON are a string, a list, or nested lists.
    private static func strings(_ value: Any?) -> [String] {
        switch value {
        case let string as String: [string]
        case let list as [Any]: list.flatMap { strings($0) }
        default: []
        }
    }

    /// Folders under `~/Library` whose entries are named after the owning app's bundle ID.
    private static let bundleIDFolders = [
        "Library/Preferences/", "Library/Caches/", "Library/HTTPStorages/", "Library/Saved Application State/",
        "Library/Containers/", "Library/WebKit/", "Library/Cookies/",
    ]

    static func bundleID(fromZapPath path: String) -> String? {
        guard !path.contains("*"),
            let folder = bundleIDFolders.first(where: { path.contains($0) }),
            let range = path.range(of: folder)
        else { return nil }
        var name = String(path[range.upperBound...])
        guard !name.contains("/") else { return nil }
        for suffix in [".plist", ".savedState", ".binarycookies"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return looksLikeBundleID(name) ? name : nil
    }

    /// Reverse-DNS shape: at least two dot-separated parts of letters, digits and hyphens.
    static func looksLikeBundleID(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2
            && parts.allSatisfy { part in
                !part.isEmpty
                    && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            }
    }
}
