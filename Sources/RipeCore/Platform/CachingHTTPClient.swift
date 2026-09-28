import Foundation

/// Adds a disk cache in front of another client.
///
/// Within a request's TTL the cached copy is served with no network at all. After it, the
/// request goes out as a conditional GET (`If-None-Match` / `If-Modified-Since`), so an
/// unchanged 19 MB cask database costs one small 304. If the server can't be reached, the
/// expired copy is served and marked `.stale`: an offline `ripe` still answers.
public struct CachingHTTPClient: HTTPClient {
    private let upstream: any HTTPClient
    private let cache: DiskCache
    /// Ignore TTLs and revalidate everything (`--refresh`).
    private let refresh: Bool
    private let now: @Sendable () -> Date

    public init(
        upstream: any HTTPClient,
        cache: DiskCache,
        refresh: Bool = false,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.upstream = upstream
        self.cache = cache
        self.refresh = refresh
        self.now = now
    }

    public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let ttl = request.cacheTTL else { return try await upstream.get(request) }
        let key = DiskCache.key(for: request.url.absoluteString)
        let cached = await cache.load(key)

        if let cached, !refresh, now().timeIntervalSince(cached.metadata.fetchedAt) < ttl {
            return response(from: cached, for: request, status: .fresh)
        }

        var conditional = request
        if let metadata = cached?.metadata {
            if let etag = metadata.etag { conditional.headers["If-None-Match"] = etag }
            if let lastModified = metadata.lastModified { conditional.headers["If-Modified-Since"] = lastModified }
        }

        let fetched: HTTPResponse
        do {
            fetched = try await upstream.get(conditional)
        } catch let error as HTTPError where error != .cancelled {
            if let cached { return response(from: cached, for: request, status: .stale) }
            throw error
        }

        if fetched.status == 304 {
            guard let cached else { throw HTTPError.status(304) }
            await cache.touch(key, fetchedAt: now())
            return response(from: cached, for: request, status: .revalidated)
        }
        let metadata = DiskCache.Metadata(
            url: request.url,
            etag: fetched.header("ETag"),
            lastModified: fetched.header("Last-Modified"),
            fetchedAt: now()
        )
        await cache.store(key, metadata: metadata, body: fetched.body)
        return fetched
    }

    private func response(
        from cached: (metadata: DiskCache.Metadata, body: Data),
        for request: HTTPRequest,
        status: HTTPResponse.CacheStatus
    ) -> HTTPResponse {
        var headers: [String: String] = [:]
        headers["etag"] = cached.metadata.etag
        headers["last-modified"] = cached.metadata.lastModified
        return HTTPResponse(url: request.url, status: 200, headers: headers, body: cached.body, cache: status)
    }
}
