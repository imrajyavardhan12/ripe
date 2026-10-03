import Foundation

/// Applies catalog entries to discovered apps before any source runs, so sources stay
/// catalog-unaware: a feed from orchard looks to `SparkleSource` like one from Info.plist.
struct CatalogEnricher: Sendable {
    var catalog: Catalog
    var machine: Machine
    var home: URL = FileManager.default.homeDirectoryForCurrentUser

    func apply(to app: InstalledApp) -> InstalledApp {
        guard let entry = catalog.entry(for: app.bundleID) else { return app }
        var app = app
        var changes: [String] = []
        var feedKind: CatalogApplication.FeedKind?

        let arch = machine.architecture.rawValue
        if let feed = entry.sparkleFeed?[arch] {
            // orchard is the correction layer, so it may replace a dead feed from Info.plist.
            app.signals.sparkleFeedURL = feed
            feedKind = .correction
            changes.append("Sparkle feed \(feed.absoluteString)")
        } else if let feed = entry.fallbackSparkleFeed?[arch], app.signals.sparkleFeedURL == nil,
            app.name.caseInsensitiveCompare(entry.name) == .orderedSame
        {
            // Never replaces the app's own feed: that is exactly what its updater reads. The
            // bundle ID behind a seeded entry is inferred from Homebrew's data, so the Finder name
            // must match too: a wrong guess then attaches to nothing rather than to another app.
            app.signals.sparkleFeedURL = feed
            feedKind = .fallback
            changes.append(
                "Sparkle feed \(feed.absoluteString) (from Homebrew's livecheck, used because the app declares none)")
        }
        if let token = entry.homebrewCask {
            changes.append("Homebrew cask pinned to \(token)")
        }
        if let rule = entry.installedVersion {
            if let found = InstalledVersionLocator.locate(glob: rule.glob, home: home) {
                // The app runs the newer of its bundle and its downloaded copies: after a fresh
                // install (or `ripe pick`), old downloads linger next to a newer bundle.
                if let bundle = app.version.parsedShort, bundle.order(comparedTo: found.version) == .newer {
                    changes.append(
                        "\(found.path) holds \(found.version.raw), but the bundle's \(bundle.raw) is newer; using the bundle"
                    )
                } else {
                    app.version = AppVersion(short: found.version.raw, build: nil)
                    changes.append("installed version \(found.version.raw) read from \(found.path)")
                }
            } else {
                changes.append("no files match \(rule.glob); using the bundle's version")
            }
        }
        app.catalog = CatalogApplication(entry: entry, changes: changes, sparkleFeed: feedKind)
        return app
    }
}

/// Finds an app's real version from file names, for apps that update in place
/// (`~/Library/Application Support/obsidian/obsidian-1.13.4.asar`). Lists one folder; never
/// opens a file.
enum InstalledVersionLocator {
    /// The only places a catalog may point at. The orchard CI enforces the same rule; this is
    /// the client's own check, because the catalog is untrusted.
    static let allowedRoots = ["~/Library/", "/Library/", "/Applications/"]

    static func locate(glob: String, home: URL) -> (version: Version, path: String)? {
        guard allowedRoots.contains(where: glob.hasPrefix), !glob.split(separator: "/").contains("..") else {
            return nil
        }
        let expanded = glob.hasPrefix("~/") ? home.path + glob.dropFirst(1) : glob
        let directory = URL(filePath: expanded).deletingLastPathComponent()
        let pattern = URL(filePath: expanded).lastPathComponent
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let (prefix, suffix) = (String(parts[0]), String(parts[1]))

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var best: (version: Version, path: String)?
        for name in names
        where name.hasPrefix(prefix) && name.hasSuffix(suffix) && name.count > prefix.count + suffix.count {
            let middle = String(name.dropFirst(prefix.count).dropLast(suffix.count))
            guard let version = Version(middle) else { continue }
            if let current = best, version.order(comparedTo: current.version) != .newer { continue }
            best = (version, glob.replacingOccurrences(of: "*", with: middle))
        }
        return best
    }
}
