import Foundation

/// Apps that declare a Sparkle feed (`SUFeedURL`) in Info.plist.
///
/// Authoritative: the feed is exactly what the app's own updater reads, and items are filtered
/// the way Sparkle filters them, so Ripe reports what the app would offer on this Mac.
public struct SparkleSource: UpdateSource {
    public let id = SourceID.sparkle
    static let maxConcurrentFeeds = 16

    public init() {}

    /// App Store apps can carry leftover Sparkle keys; the store owns their updates.
    public func applies(to app: InstalledApp) -> Bool {
        app.signals.sparkleFeedURL != nil && !app.signals.isFromAppStore
    }

    public func check(_ apps: [InstalledApp], context: SourceContext) async -> [InstalledApp.ID: SourceOutcome] {
        let eligible = apps.filter(applies(to:))
        return await withTaskGroup(of: (InstalledApp.ID, SourceOutcome).self) { group in
            var outcomes: [InstalledApp.ID: SourceOutcome] = [:]
            var inFlight = 0
            for app in eligible {
                guard let feed = app.signals.sparkleFeedURL else { continue }
                // Every feed is on a different host, so URLSession's per-host limit doesn't bound this.
                if inFlight == Self.maxConcurrentFeeds, let (id, outcome) = await group.next() {
                    outcomes[id] = outcome
                    inFlight -= 1
                }
                let catalogFeed = app.catalog?.sparkleFeed
                group.addTask { (app.id, await Self.check(feed: feed, catalogFeed: catalogFeed, context: context)) }
                inFlight += 1
            }
            for await (id, outcome) in group {
                outcomes[id] = outcome
            }
            return outcomes
        }
    }

    static func check(
        feed: URL, catalogFeed: CatalogApplication.FeedKind? = nil, context: SourceContext
    ) async -> SourceOutcome {
        let items: [AppcastItem]
        do {
            let request = HTTPRequest(url: feed, cacheTTL: 30 * 60, allowInsecure: true)
            let response = try await context.http.get(request)
            context.log.debug("Sparkle: \(feed.host() ?? feed.absoluteString) \(response.cache.rawValue)")
            items = try AppcastParser.parse(response.body)
        } catch {
            return .failed("feed \(feed.host() ?? feed.absoluteString): \(error)")
        }
        guard let item = newestEligible(items, on: context.machine) else {
            return .failed("feed lists no release for this Mac (\(items.count) items checked)")
        }
        guard let version = item.shortVersion ?? item.version else {
            return .failed("newest feed item has no version")
        }
        let download = item.enclosureURL.map { url in
            Download(
                url: url,
                integrity: item.edSignature.map { Download.Integrity.edDSA(signature: $0) },
                expectedLength: item.length,
                isInstallerPackage: item.installationType == "package" || url.pathExtension.lowercased() == "pkg"
            )
        }
        let release = Release(
            version: version,
            build: item.version,
            source: .sparkle,
            comparison: catalogFeed == .fallback ? .crossChecked : .bundleVersion,
            pageURL: item.releaseNotesURL,
            minimumSystemVersion: item.minimumSystemVersion,
            publishedAt: item.publishedAt,
            download: download
        )
        let origin: String? =
            switch catalogFeed {
            case .correction: "feed from orchard"
            case .fallback: "feed from orchard, seeded from Homebrew's livecheck"
            case nil: nil
            }
        let notes = [origin, feed.scheme == "http" ? "feed is plain HTTP" : nil].compactMap { $0 }
        // A seeded feed was matched to the app through Homebrew's data, not declared by the app.
        let confidence: Confidence = catalogFeed == .fallback ? .medium : .high
        return .found(release, confidence, note: notes.isEmpty ? nil : notes.joined(separator: ", "))
    }

    /// Channel names that mean "the normal release". Sparkle offers items without a channel to
    /// everyone; some feeds (OBS) label their stable items explicitly. Any other channel (beta,
    /// nightly, or a name we don't know) is opt-in inside the app, so it's never offered here.
    static let stableChannels: Set<String> = ["stable", "release", "default", "production", "public"]

    /// The newest item Sparkle itself would offer: stable channel only, runnable on this Mac's
    /// macOS version and CPU, and not a notice-only informational update.
    static func newestEligible(_ items: [AppcastItem], on machine: Machine) -> AppcastItem? {
        let eligible = items.filter { item in
            if let channel = item.channel, !stableChannels.contains(channel.lowercased()) { return false }
            guard !item.isInformational else { return false }
            guard item.version != nil || item.shortVersion != nil else { return false }
            if let os = item.operatingSystem, !["macos", "osx"].contains(os.lowercased()) { return false }
            if let minimum = item.minimumSystemVersion.flatMap(Version.init),
                machine.macOSVersion.order(comparedTo: minimum) == .older
            {
                return false
            }
            if let maximum = item.maximumSystemVersion.flatMap(Version.init),
                machine.macOSVersion.order(comparedTo: maximum) == .newer
            {
                return false
            }
            if !item.hardwareRequirements.isEmpty, !item.hardwareRequirements.contains(machine.architecture.rawValue) {
                return false
            }
            return true
        }
        // Feeds aren't reliably sorted, so compare rather than trusting the first item.
        return eligible.reduce(nil) { best, item in
            guard let best else { return item }
            return Self.order(item, comparedTo: best) == .newer ? item : best
        }
    }

    private static func order(_ lhs: AppcastItem, comparedTo rhs: AppcastItem) -> VersionOrder? {
        if let a = lhs.version.flatMap(Version.init), let b = rhs.version.flatMap(Version.init) {
            return a.order(comparedTo: b)
        }
        if let a = lhs.shortVersion.flatMap(Version.init), let b = rhs.shortVersion.flatMap(Version.init) {
            return a.order(comparedTo: b)
        }
        return nil
    }
}
