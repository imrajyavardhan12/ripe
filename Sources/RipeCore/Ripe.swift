import Foundation

/// Entry point for anything that embeds Ripe: the CLI today, a menu bar app later.
public enum Ripe {
    /// Replaced by the release workflow from the git tag.
    public static let version = "0.5.0-dev"

    /// Everything a check depends on. `live` for real use; tests assemble their own.
    public struct Environment: Sendable {
        public var scanner: AppScanner
        public var sources: [any UpdateSource]
        public var context: SourceContext
        /// The orchard catalog (`https://` or `file://`); `nil` runs without it.
        public var catalogURL: URL?
        /// Updates the person chose to skip.
        public var skips: SkipList
        public var refresh: Bool
        /// Sources still running after this are cut off; the report ships without them.
        public var deadline: Duration

        public init(
            scanner: AppScanner,
            sources: [any UpdateSource],
            context: SourceContext,
            catalogURL: URL? = nil,
            skips: SkipList = SkipList(),
            refresh: Bool = false,
            // Matches URLSession's per-download limit: the first run fetches ~2 MB (gzip) of cask
            // data, which needs ~16 s at 1 Mbps. Warm runs finish in well under a second.
            deadline: Duration = .seconds(30)
        ) {
            self.scanner = scanner
            self.sources = sources
            self.context = context
            self.catalogURL = catalogURL
            self.skips = skips
            self.refresh = refresh
            self.deadline = deadline
        }

        public static func live(
            refresh: Bool = false,
            log: Logger = .silent,
            skips: SkipList = SkipList(),
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Environment {
            let cache = DiskCache(directory: DiskCache.defaultDirectory(environment: environment))
            let http = CachingHTTPClient(upstream: URLSessionHTTPClient(), cache: cache, refresh: refresh)
            return Environment(
                scanner: AppScanner(),
                sources: [AppStoreSource(), SparkleSource(), HomebrewCaskSource()],
                context: SourceContext(http: http, machine: .current(environment: environment), cache: cache, log: log),
                catalogURL: catalogURL(environment: environment),
                skips: skips,
                refresh: refresh
            )
        }

        /// `RIPE_CATALOG_URL` points at another catalog (a local build while writing an entry);
        /// `none` turns the catalog off.
        static func catalogURL(environment: [String: String]) -> URL? {
            guard let override = environment["RIPE_CATALOG_URL"], !override.isEmpty else {
                return CatalogLoader.defaultURL
            }
            return override == "none" ? nil : URL(string: override)
        }
    }

    /// Discovers apps, applies the orchard catalog, asks every source in parallel and resolves
    /// one verdict per app.
    ///
    /// `including` narrows the check to some apps (`ripe why`); skipped bundles are always reported.
    public static func check(
        _ environment: Environment,
        including filter: (@Sendable (InstalledApp) -> Bool)? = nil
    ) async -> Report {
        let started = ContinuousClock.now
        let discovery = environment.scanner.scan()
        var apps = filter.map { discovery.apps.filter($0) } ?? discovery.apps
        let log = environment.context.log
        log.debug(
            "found \(discovery.apps.count) apps, skipped \(discovery.skipped.count) in \(ContinuousClock.now - started)"
        )

        if let url = environment.catalogURL,
            let catalog = await CatalogLoader(url: url, refresh: environment.refresh).load(context: environment.context)
        {
            let enricher = CatalogEnricher(catalog: catalog, machine: environment.context.machine)
            apps = apps.map(enricher.apply(to:))
        }

        let outcomes = await querySources(apps, environment: environment)
        let resolver = Resolver(machine: environment.context.machine)
        let reports = apps.map { app in
            let perSource = outcomes.mapValues { $0[app.id] ?? .notApplicable }
            return applySkips(environment.skips, to: resolver.resolve(app, outcomes: perSource))
        }
        let duration = ContinuousClock.now - started
        log.debug("checked in \(duration)")
        return Report(apps: reports, skipped: discovery.skipped, duration: duration, generatedAt: Date())
    }

    /// The release Ripe would take from each Sparkle feed on this Mac, without any installed app.
    /// For orchard tooling: an importer checks candidate feeds with exactly the client's rules.
    public static func checkFeeds(_ feeds: [URL], context: SourceContext) async -> [URL: SourceOutcome] {
        await withTaskGroup(of: (URL, SourceOutcome).self) { group in
            var outcomes: [URL: SourceOutcome] = [:]
            var inFlight = 0
            for feed in Set(feeds) {
                if inFlight == SparkleSource.maxConcurrentFeeds, let (url, outcome) = await group.next() {
                    outcomes[url] = outcome
                    inFlight -= 1
                }
                group.addTask { (feed, await SparkleSource.check(feed: feed, context: context)) }
                inFlight += 1
            }
            for await (url, outcome) in group {
                outcomes[url] = outcome
            }
            return outcomes
        }
    }

    /// Only an update can be skipped; current and unknown verdicts are left as they are.
    static func applySkips(_ skips: SkipList, to report: AppReport) -> AppReport {
        guard case .outdated(let release) = report.verdict, let rule = skips.rule(for: report.app, release: release)
        else {
            return report
        }
        var report = report
        report.verdict = .skippedByUser(release, rule)
        report.explanation += " Skipped by you (`ripe unskip \(report.app.name)` to see it again)."
        return report
    }

    private static func querySources(
        _ apps: [InstalledApp],
        environment: Environment
    ) async -> [SourceID: [InstalledApp.ID: SourceOutcome]] {
        let context = environment.context
        let deadline = environment.deadline
        return await withTaskGroup(of: (SourceID, [InstalledApp.ID: SourceOutcome])?.self) { group in
            for source in environment.sources {
                group.addTask {
                    let started = ContinuousClock.now
                    let outcomes = await source.check(apps, context: context)
                    context.log.debug(
                        "\(source.id.displayName): \(outcomes.count) answers in \(ContinuousClock.now - started)")
                    return (source.id, outcomes)
                }
            }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil  // the deadline marker
            }

            var results: [SourceID: [InstalledApp.ID: SourceOutcome]] = [:]
            var deadlineHit = false
            var onTime = Set<SourceID>()
            for await result in group {
                guard let (id, outcomes) = result else {
                    // The timer also ends (cancelled) after every source answered; only a timer
                    // that fires first counts as the deadline.
                    if results.count < environment.sources.count {
                        deadlineHit = true
                        group.cancelAll()  // in-flight requests fail fast
                    }
                    continue
                }
                results[id] = outcomes
                if !deadlineHit { onTime.insert(id) }
                if results.count == environment.sources.count {
                    group.cancelAll()  // stops the timer
                }
            }
            guard deadlineHit else { return results }

            // Cut off: any covered app a late source didn't answer for timed out, rather than
            // silently reading as "not applicable".
            for source in environment.sources where !onTime.contains(source.id) {
                var outcomes = results[source.id] ?? [:]
                let missing = apps.filter { source.applies(to: $0) && outcomes[$0.id] == nil }
                if !missing.isEmpty { context.log.debug("\(source.id.displayName): cut off by the deadline") }
                for app in missing {
                    outcomes[app.id] = .failed("no answer within \(deadline)")
                }
                results[source.id] = outcomes
            }
            return results
        }
    }
}
