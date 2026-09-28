import Foundation

/// Mac App Store apps, via Apple's public lookup API.
///
/// Exclusive for the apps it covers: an App Store app can only be updated through the store,
/// so the resolver ignores every other source for it.
public struct AppStoreSource: UpdateSource {
    public let id = SourceID.appStore

    static let endpoint = URL(staticString: "https://itunes.apple.com/lookup")
    /// The lookup API takes a comma-separated list; batching keeps well clear of its rate limit.
    static let batchSize = 50

    public init() {}

    public func applies(to app: InstalledApp) -> Bool { app.signals.isFromAppStore }

    public func check(_ apps: [InstalledApp], context: SourceContext) async -> [InstalledApp.ID: SourceOutcome] {
        let eligible = apps.filter(applies(to:))
        let bundleIDs = Array(Set(eligible.map(\.bundleID))).sorted()
        let batches = stride(from: 0, to: bundleIDs.count, by: Self.batchSize).map {
            Array(bundleIDs[$0..<min($0 + Self.batchSize, bundleIDs.count)])
        }

        var listings: [String: Result<Listing, HTTPError>] = [:]
        await withTaskGroup(of: [String: Result<Listing, HTTPError>].self) { group in
            for batch in batches {
                group.addTask { await Self.lookup(batch, context: context) }
            }
            for await result in group {
                listings.merge(result) { first, _ in first }
            }
        }

        let country = context.machine.storeCountry.uppercased()
        var outcomes: [InstalledApp.ID: SourceOutcome] = [:]
        for app in eligible {
            switch listings[app.bundleID] {
            case .success(let listing)?:
                outcomes[app.id] = listing.outcome
            case .failure(let error)?:
                outcomes[app.id] = .failed("App Store lookup failed: \(error)")
            case nil:
                outcomes[app.id] = .failed("not listed in the \(country) App Store (removed, or a different region)")
            }
        }
        return outcomes
    }

    /// One request for a batch. Bundle IDs missing from the response simply don't appear.
    static func lookup(_ bundleIDs: [String], context: SourceContext) async -> [String: Result<Listing, HTTPError>] {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleIDs.joined(separator: ",")),
            URLQueryItem(name: "country", value: context.machine.storeCountry),
        ]
        guard let url = components?.url else { return [:] }
        do {
            let response = try await context.http.get(HTTPRequest(url: url, cacheTTL: 3600))
            context.log.debug("App Store: \(bundleIDs.count) apps, \(response.cache.rawValue)")
            return try parse(response.body).mapValues { .success($0) }
        } catch let error as HTTPError {
            return Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, .failure(error)) })
        } catch {
            let failure = HTTPError.connection("unreadable App Store response")
            return Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, .failure(failure)) })
        }
    }

    struct Listing: Sendable, Hashable {
        var release: Release
        /// `mac-software`, or `software` for iPhone/iPad and universal-purchase apps.
        var kind: String?

        var outcome: SourceOutcome {
            // For iPhone-family records the version may track the iOS build rather than the Mac one.
            let isMac = kind == "mac-software"
            return .found(release, isMac ? .high : .medium, note: isMac ? nil : "store record is for iPhone/iPad")
        }
    }

    static func parse(_ data: Data) throws -> [String: Listing] {
        struct Response: Decodable {
            var results: [Item]
        }
        struct Item: Decodable {
            var bundleId: String?
            var version: String?
            var kind: String?
            var trackViewUrl: URL?
            var minimumOsVersion: String?
            var currentVersionReleaseDate: Date?
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var listings: [String: Listing] = [:]
        for item in try decoder.decode(Response.self, from: data).results {
            guard let bundleID = item.bundleId, let version = item.version?.nilIfBlank else { continue }
            let release = Release(
                version: version,
                source: .appStore,
                comparison: .shortVersion,
                pageURL: item.trackViewUrl,
                // For iPhone-family records this is an iOS version, meaningless on a Mac.
                minimumSystemVersion: item.kind == "mac-software" ? item.minimumOsVersion : nil,
                publishedAt: item.currentVersionReleaseDate
            )
            listings[bundleID] = Listing(release: release, kind: item.kind)
        }
        return listings
    }
}
