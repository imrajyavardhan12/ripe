import Foundation
import Testing
import os

@testable import RipeCore

/// Answers each request with the next scripted response, recording what was sent.
actor ScriptedHTTPClient: HTTPClient {
    private var script: [Result<HTTPResponse, HTTPError>]
    private(set) var sent: [HTTPRequest] = []

    init(_ script: [Result<HTTPResponse, HTTPError>]) {
        self.script = script
    }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        sent.append(request)
        guard !script.isEmpty else { throw HTTPError.connection("unexpected request") }
        return try script.removeFirst().get()
    }
}

/// A clock tests can move forward.
final class TestClock: Sendable {
    private let current = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { current.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { current.withLock { $0 += seconds } }
}

struct CachingHTTPClientTests {
    let url = URL(staticString: "https://example.com/feed.xml")
    let directory = FileManager.default.temporaryDirectory.appending(path: "ripe-http-\(UUID().uuidString)")

    func ok(_ body: String, etag: String? = nil) -> Result<HTTPResponse, HTTPError> {
        var headers: [String: String] = [:]
        headers["ETag"] = etag
        return .success(HTTPResponse(url: url, status: 200, headers: headers, body: Data(body.utf8)))
    }

    var notModified: Result<HTTPResponse, HTTPError> { .success(HTTPResponse(url: url, status: 304, body: Data())) }

    func client(_ upstream: ScriptedHTTPClient, clock: TestClock, refresh: Bool = false) -> CachingHTTPClient {
        CachingHTTPClient(upstream: upstream, cache: DiskCache(directory: directory), refresh: refresh) { clock.now }
    }

    @Test func servesFreshCopyWithoutNetwork() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = ScriptedHTTPClient([ok("v1", etag: "\"a\"")])
        let clock = TestClock()
        let http = client(upstream, clock: clock)
        let request = HTTPRequest(url: url, cacheTTL: 60)

        #expect(try await http.get(request).cache == .network)
        clock.advance(30)
        let second = try await http.get(request)
        #expect(second.cache == .fresh)
        #expect(String(decoding: second.body, as: UTF8.self) == "v1")
        #expect(await upstream.sent.count == 1)
    }

    @Test func clockGoingBackwardsExpiresTheEntry() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = ScriptedHTTPClient([ok("v1", etag: "\"a\""), notModified])
        let clock = TestClock()
        let http = client(upstream, clock: clock)
        _ = try await http.get(HTTPRequest(url: url, cacheTTL: 60))
        clock.advance(-86_400)
        #expect(try await http.get(HTTPRequest(url: url, cacheTTL: 60)).cache == .revalidated)
    }

    @Test func revalidatesWithETagAfterTTL() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = ScriptedHTTPClient([ok("v1", etag: "\"a\""), notModified, ok("v2", etag: "\"b\"")])
        let clock = TestClock()
        let http = client(upstream, clock: clock)
        let request = HTTPRequest(url: url, cacheTTL: 60)

        _ = try await http.get(request)
        clock.advance(61)
        let revalidated = try await http.get(request)
        #expect(revalidated.cache == .revalidated)
        #expect(String(decoding: revalidated.body, as: UTF8.self) == "v1")
        #expect(await upstream.sent.last?.headers["If-None-Match"] == "\"a\"")

        // The 304 restarted the TTL.
        clock.advance(30)
        #expect(try await http.get(request).cache == .fresh)

        clock.advance(61)
        let changed = try await http.get(request)
        #expect(String(decoding: changed.body, as: UTF8.self) == "v2")
    }

    @Test func servesStaleCopyWhenOffline() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = ScriptedHTTPClient([ok("v1"), .failure(.offline)])
        let clock = TestClock()
        let http = client(upstream, clock: clock)
        let request = HTTPRequest(url: url, cacheTTL: 60)

        _ = try await http.get(request)
        clock.advance(3600)
        let stale = try await http.get(request)
        #expect(stale.cache == .stale)
        #expect(String(decoding: stale.body, as: UTF8.self) == "v1")
    }

    @Test func failsWhenOfflineWithNothingCached() async {
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = client(ScriptedHTTPClient([.failure(.offline)]), clock: TestClock())
        await #expect(throws: HTTPError.offline) { try await http.get(HTTPRequest(url: url, cacheTTL: 60)) }
    }

    @Test func refreshSkipsTTLButStillRevalidates() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock()
        _ = try await client(ScriptedHTTPClient([ok("v1", etag: "\"a\"")]), clock: clock)
            .get(HTTPRequest(url: url, cacheTTL: 60))

        let upstream = ScriptedHTTPClient([notModified])
        let response = try await client(upstream, clock: clock, refresh: true).get(HTTPRequest(url: url, cacheTTL: 60))
        #expect(response.cache == .revalidated)
        #expect(await upstream.sent.first?.headers["If-None-Match"] == "\"a\"")
    }

    @Test func requestsWithoutTTLBypassTheCache() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let upstream = ScriptedHTTPClient([ok("v1"), ok("v2")])
        let http = client(upstream, clock: TestClock())
        _ = try await http.get(HTTPRequest(url: url))
        let second = try await http.get(HTTPRequest(url: url))
        #expect(String(decoding: second.body, as: UTF8.self) == "v2")
    }
}
