import Foundation

public struct HTTPRequest: Sendable, Hashable {
    public var url: URL
    public var headers: [String: String]
    /// Larger responses fail with ``HTTPError/tooLarge(limit:)`` instead of eating memory.
    public var maxBytes: Int
    /// How long a cached copy is served without asking the server. `nil` means never cache.
    public var cacheTTL: TimeInterval?
    /// Plain HTTP is refused unless the caller opts in (checking, never downloading, from old Sparkle feeds).
    public var allowInsecure: Bool

    public init(
        url: URL,
        headers: [String: String] = [:],
        maxBytes: Int = 5_000_000,
        cacheTTL: TimeInterval? = nil,
        allowInsecure: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.maxBytes = maxBytes
        self.cacheTTL = cacheTTL
        self.allowInsecure = allowInsecure
    }
}

public struct HTTPResponse: Sendable {
    public enum CacheStatus: String, Sendable {
        /// Fetched from the server just now.
        case network
        /// Served from disk without contacting the server (within its TTL).
        case fresh
        /// The server confirmed the cached copy is current (304).
        case revalidated
        /// The server couldn't be reached, so an expired copy was served.
        case stale
    }

    public var url: URL
    public var status: Int
    /// Header names are lowercased.
    public var headers: [String: String]
    public var body: Data
    public var cache: CacheStatus

    public init(url: URL, status: Int, headers: [String: String] = [:], body: Data, cache: CacheStatus = .network) {
        self.url = url
        self.status = status
        self.headers = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
        self.cache = cache
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public enum HTTPError: Error, Sendable, Hashable, CustomStringConvertible {
    case insecureURL(URL)
    case status(Int)
    case tooLarge(limit: Int)
    case timedOut
    case offline
    case connection(String)
    case cancelled

    public var description: String {
        switch self {
        case .insecureURL(let url): "refused plain-HTTP URL \(url.absoluteString)"
        case .status(let code): "HTTP \(code)"
        case .tooLarge(let limit): "response larger than \(limit / 1_000_000) MB"
        case .timedOut: "timed out"
        case .offline: "no internet connection"
        case .connection(let message): message
        case .cancelled: "cancelled"
        }
    }

    /// Worth one quick retry: a dropped connection or an overloaded server.
    var isTransient: Bool {
        switch self {
        case .connection: true
        case .status(let code): [502, 503, 504].contains(code)
        default: false
        }
    }
}

/// GET-only HTTP, which is all a read-only checker needs. Implementations throw ``HTTPError``.
///
/// Returns 2xx responses and 304 (for conditional requests); anything else throws.
public protocol HTTPClient: Sendable {
    func get(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String = "ripe/\(Ripe.version) (+https://github.com/imrajyavardhan12/ripe)") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 30
        configuration.urlCache = nil  // CachingHTTPClient owns caching
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        self.userAgent = userAgent
    }

    public func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard Self.isAllowed(request.url, insecure: request.allowInsecure) else {
            throw HTTPError.insecureURL(request.url)
        }
        var urlRequest = URLRequest(url: request.url)
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            return try await perform(urlRequest, request)
        } catch let error as HTTPError where error.isTransient {
            try? await Task.sleep(for: .milliseconds(Int.random(in: 200...600)))
            return try await perform(urlRequest, request)
        }
    }

    private func perform(_ urlRequest: URLRequest, _ request: HTTPRequest) async throws -> HTTPResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError {
            throw HTTPError(error)
        } catch is CancellationError {
            throw HTTPError.cancelled
        } catch {
            throw HTTPError.connection(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.connection("not an HTTP response")
        }
        // A redirect must not downgrade HTTPS to HTTP.
        if let finalURL = http.url, !Self.isAllowed(finalURL, insecure: request.allowInsecure) {
            throw HTTPError.insecureURL(finalURL)
        }
        guard (200..<300).contains(http.statusCode) || http.statusCode == 304 else {
            throw HTTPError.status(http.statusCode)
        }
        guard data.count <= request.maxBytes else {
            throw HTTPError.tooLarge(limit: request.maxBytes)
        }
        var headers: [String: String] = [:]
        for case (let name as String, let value as String) in http.allHeaderFields {
            headers[name] = value
        }
        return HTTPResponse(url: http.url ?? request.url, status: http.statusCode, headers: headers, body: data)
    }

    private static func isAllowed(_ url: URL, insecure: Bool) -> Bool {
        url.scheme == "https" || (insecure && url.scheme == "http")
    }
}

extension HTTPError {
    init(_ error: URLError) {
        switch error.code {
        case .timedOut: self = .timedOut
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: self = .offline
        case .cancelled: self = .cancelled
        case .appTransportSecurityRequiresSecureConnection: self = .insecureURL(error.failingURL ?? URL(filePath: "/"))
        default: self = .connection(error.localizedDescription)
        }
    }
}
