import Foundation

/// Homebrew's cask database, used as a version lookup for every app, whether or not Homebrew
/// installed it.
///
/// The lowest-authority source, because matching an app to a cask is a heuristic. It still
/// covers most apps with custom updaters that no feed can see (browsers, VPNs, Electron apps).
public struct HomebrewCaskSource: UpdateSource {
    public let id = SourceID.homebrewCask

    static let endpoint = URL(staticString: "https://formulae.brew.sh/api/cask.json")
    /// Bump the suffix whenever `CaskIndex.build` changes what it extracts, so stale compact
    /// indexes from older Ripe versions are rebuilt instead of reused.
    static let derivedIndexKey = "cask-index-v1"

    public init() {}

    public func applies(to app: InstalledApp) -> Bool { !app.signals.isFromAppStore }

    public func check(_ apps: [InstalledApp], context: SourceContext) async -> [InstalledApp.ID: SourceOutcome] {
        let eligible = apps.filter(applies(to:))
        guard !eligible.isEmpty else { return [:] }

        let index: CaskIndex
        do {
            index = try await Self.loadIndex(context: context)
        } catch {
            let outcome = SourceOutcome.failed("Homebrew cask database unavailable: \(error)")
            return Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, outcome) })
        }

        var outcomes: [InstalledApp.ID: SourceOutcome] = [:]
        for app in eligible {
            if let outcome = Self.outcome(for: app, in: index, machine: context.machine) {
                outcomes[app.id] = outcome
            }
        }
        return outcomes
    }

    // MARK: Matching

    struct Match: Hashable {
        var cask: CaskIndex.Cask
        var confidence: Confidence
        var reason: String
        /// The cask installs a file with this app's name. Breaks ties between casks that quit
        /// the same bundle ID (OpenAI's `chatgpt` and `codex-app` both quit `com.openai.codex`).
        var nameMatch = false

        var strength: Int { confidence.rawValue * 2 + (nameMatch ? 1 : 0) }
    }

    /// `nil` when no cask mentions the app.
    static func outcome(for app: InstalledApp, in index: CaskIndex, machine: Machine) -> SourceOutcome? {
        guard let match = match(app, in: index, installedTokens: machine.homebrewCasks) else { return nil }
        let cask = match.cask
        guard cask.isVersioned else {
            return .failed("cask \(cask.token) doesn't track versions (version: latest)")
        }
        // `29.2,42065` is `short,build`; only the short part is comparable to the app's version.
        let parts = cask.version(on: machine).split(separator: ",", maxSplits: 1).map(String.init)
        let release = Release(
            version: parts[0],
            build: parts.count > 1 ? parts[1] : nil,
            source: .homebrewCask,
            comparison: .shortVersion,
            pageURL: cask.homepage,
            caskToken: cask.token
        )
        return .found(release, match.confidence, note: "cask \(cask.token), \(match.reason)")
    }

    static func match(_ app: InstalledApp, in index: CaskIndex, installedTokens: Set<String>) -> Match? {
        if let token = app.catalog?.entry.homebrewCask {
            // A human-verified mapping beats every heuristic; a pin to a missing cask matches nothing.
            return index.cask(token: token).map { Match(cask: $0, confidence: .high, reason: "pinned by orchard") }
        }
        let fileName = app.url.lastPathComponent
        let bundleID = app.bundleID.lowercased()

        let matches = index.candidates(appName: fileName, bundleID: app.bundleID).compactMap { cask -> Match? in
            let nameMatch = cask.appNames.contains { $0.caseInsensitiveCompare(fileName) == .orderedSame }
            let quitMatch = cask.quitIDs.contains { $0.lowercased() == bundleID }
            let zapMatch = cask.zapIDs.contains { $0.lowercased() == bundleID }
            // Same file name, but the cask quits a different app: two unrelated apps share a name.
            if nameMatch, !quitMatch, !zapMatch, !cask.quitIDs.isEmpty { return nil }
            if quitMatch && nameMatch {
                return Match(cask: cask, confidence: .high, reason: "name and bundle ID match", nameMatch: true)
            }
            if quitMatch { return Match(cask: cask, confidence: .high, reason: "bundle ID matches") }
            if nameMatch && zapMatch {
                return Match(cask: cask, confidence: .high, reason: "name and bundle ID match", nameMatch: true)
            }
            if nameMatch { return Match(cask: cask, confidence: .medium, reason: "app name matches", nameMatch: true) }
            return Match(cask: cask, confidence: .low, reason: "bundle ID appears in the cask's cleanup paths")
        }
        guard let best = matches.map(\.strength).max() else { return nil }
        let top = matches.filter { $0.strength == best }
        if top.count == 1 { return top[0] }

        // Several casks install the same app (stable, @beta, @nightly). The one Homebrew
        // installed wins; otherwise the stable channel.
        if let installed = top.first(where: { installedTokens.contains($0.cask.token) }) {
            return installed
        }
        let stable = top.filter { !$0.cask.token.contains("@") }
        if stable.count == 1 { return stable[0] }
        let tokens = top.map(\.cask.token).sorted()
        guard var first = (stable.isEmpty ? top : stable).min(by: { $0.cask.token < $1.cask.token }) else { return nil }
        first.confidence = .low
        first.reason = "ambiguous between \(tokens.joined(separator: ", "))"
        return first
    }

    // MARK: Index

    static func loadIndex(context: SourceContext) async throws -> CaskIndex {
        // Staleness only risks a missed update, never a false one, so a long TTL is safe.
        let request = HTTPRequest(url: endpoint, maxBytes: 60_000_000, cacheTTL: 6 * 3600)
        let response = try await context.http.get(request)
        let validator = response.header("ETag") ?? response.header("Last-Modified")
        let key = DiskCache.key(for: derivedIndexKey)

        if let validator, let cache = context.cache, let derived = await cache.load(key),
            derived.metadata.etag == validator,
            let index = try? JSONDecoder().decode(CaskIndex.self, from: derived.body)
        {
            context.log.debug("Homebrew: compact index (\(index.casks.count) casks), \(response.cache.rawValue)")
            return index
        }

        let started = ContinuousClock.now
        let index = try CaskIndex.build(fromAPI: response.body)
        context.log.debug(
            "Homebrew: parsed \(response.body.count / 1_000_000) MB into \(index.casks.count) casks in \(ContinuousClock.now - started)"
        )
        if let validator, let cache = context.cache, let encoded = try? JSONEncoder().encode(index) {
            let metadata = DiskCache.Metadata(url: endpoint, etag: validator, fetchedAt: Date())
            await cache.store(key, metadata: metadata, body: encoded)
        }
        return index
    }
}
