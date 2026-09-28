import Foundation

/// Fetches the orchard catalog. Ripe works without it, so every failure means "no catalog",
/// never a failed run.
struct CatalogLoader: Sendable {
    static let defaultURL = URL(staticString: "https://imrajyavardhan12.github.io/orchard/index.json")
    static let unavailableKey = "catalog-unavailable-v1"

    var url: URL
    var refresh: Bool
    var now: @Sendable () -> Date = Date.init

    func load(context: SourceContext) async -> Catalog? {
        let data: Data
        if url.isFileURL {
            // Contributors test entries locally: RIPE_CATALOG_URL=file://…/dist/index.json
            guard let local = try? Data(contentsOf: url) else {
                context.log.debug("orchard: can't read \(url.path)")
                return nil
            }
            data = local
        } else {
            let missKey = DiskCache.key(for: "\(Self.unavailableKey) \(url.absoluteString)")
            // Remember a failure for an hour so an unreachable catalog doesn't slow every run.
            if !refresh, let miss = await context.cache?.load(missKey),
                now().timeIntervalSince(miss.metadata.fetchedAt) < 3600
            {
                context.log.debug("orchard: skipped, unavailable at \(miss.metadata.fetchedAt)")
                return nil
            }
            do {
                let request = HTTPRequest(url: url, maxBytes: 5_000_000, cacheTTL: 6 * 3600, timeout: 3)
                let response = try await context.http.get(request)
                context.log.debug("orchard: \(response.cache.rawValue)")
                data = response.body
            } catch {
                context.log.debug("orchard: unavailable (\(error)); continuing without it")
                let metadata = DiskCache.Metadata(url: url, fetchedAt: now())
                await context.cache?.store(missKey, metadata: metadata, body: Data())
                return nil
            }
        }
        return decode(data, log: context.log)
    }

    func decode(_ data: Data, log: Logger) -> Catalog? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let catalog = try? decoder.decode(Catalog.self, from: data) else {
            log.debug("orchard: catalog is malformed; ignoring it")
            return nil
        }
        guard catalog.schemaVersion <= Catalog.supportedSchemaVersion else {
            log.debug("orchard: catalog schema \(catalog.schemaVersion) is newer than this Ripe supports; update Ripe")
            return nil
        }
        log.debug("orchard: \(catalog.count) entries")
        return catalog
    }
}
