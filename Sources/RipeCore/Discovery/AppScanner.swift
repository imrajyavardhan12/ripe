import Foundation

public struct DiscoveryResult: Sendable, Hashable {
    public var apps: [InstalledApp]
    public var skipped: [SkippedBundle]
}

/// Finds app bundles in the usual install locations.
///
/// Sequential on purpose: reading 200 Info.plists takes a few milliseconds, well under the
/// discovery budget, so concurrency would add complexity without a measurable gain.
public struct AppScanner: Sendable {
    public var roots: [URL]
    /// `1` finds `/Applications/X.app`; `2` also finds `/Applications/Utilities/X.app` and vendor folders.
    public var maxDepth: Int

    public init(roots: [URL] = AppScanner.defaultRoots, maxDepth: Int = 2) {
        self.roots = roots
        self.maxDepth = maxDepth
    }

    public static var defaultRoots: [URL] { defaultRoots() }

    /// `/Applications` and `~/Applications`, or the folders in `RIPE_APPLICATIONS_DIR`
    /// (colon-separated), which replace them entirely: for demos and testing against a staged folder.
    public static func defaultRoots(environment: [String: String] = ProcessInfo.processInfo.environment) -> [URL] {
        if let override = environment["RIPE_APPLICATIONS_DIR"], !override.isEmpty {
            return override.split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        }
        return [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(
                path: "Applications", directoryHint: .isDirectory),
        ]
    }

    public func scan() -> DiscoveryResult {
        var result = DiscoveryResult(apps: [], skipped: [])
        var seen = Set<String>()
        for bundle in roots.flatMap({ bundles(in: $0, depth: 1) }) {
            // The same bundle can be reachable twice through a symlinked folder.
            guard seen.insert(bundle.resolvingSymlinksInPath().path).inserted else { continue }
            switch BundleInspector.inspect(bundle) {
            case .app(let app): result.apps.append(app)
            case .skipped(let reason): result.skipped.append(SkippedBundle(url: bundle, reason: reason))
            }
        }
        result.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    private func bundles(in directory: URL, depth: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                // Not `.skipsHiddenFiles`: it also drops bundles with the Finder "hidden" flag, which
                // macOS sets on the /Applications/Safari.app symlink. Only dotfiles are skipped.
                options: [.skipsPackageDescendants]
            )
        else { return [] }

        var found: [URL] = []
        for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
            if entry.pathExtension == "app" {
                found.append(entry)
            } else if depth < maxDepth, (try? entry.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
                found += bundles(in: entry, depth: depth + 1)
            }
        }
        return found
    }
}
