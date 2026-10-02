import Foundation
import Testing

@testable import RipeCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"),
            "missing fixture \(name)")
        return try Data(contentsOf: url)
    }
}

extension Machine {
    static func test(
        macOS: String = "27.0",
        architecture: Architecture = .arm64,
        country: String = "in",
        homebrewCasks: Set<String> = [],
        tapCasks: [TapCask] = []
    ) -> Machine {
        guard let version = Version(macOS) else { preconditionFailure("bad test macOS version \(macOS)") }
        return Machine(
            macOSVersion: version,
            architecture: architecture,
            storeCountry: country,
            homebrewCasks: homebrewCasks,
            tapCasks: tapCasks
        )
    }
}

extension InstalledApp {
    /// An in-memory app; no bundle on disk.
    static func test(
        _ fileName: String,
        bundleID: String,
        version: String?,
        build: String? = nil,
        signals: Signals = Signals()
    ) -> InstalledApp {
        InstalledApp(
            name: URL(filePath: fileName).deletingPathExtension().lastPathComponent,
            bundleID: bundleID,
            url: URL(filePath: "/Applications/\(fileName)"),
            version: AppVersion(short: version, build: build),
            signals: signals
        )
    }
}

/// Serves canned responses by URL prefix and records every request.
struct FakeHTTPClient: HTTPClient {
    enum Route: Sendable {
        case ok(Data, headers: [String: String] = [:])
        case fail(HTTPError)
    }

    var routes: [(prefix: String, route: Route)]
    let requests = RequestLog()

    init(_ routes: [(prefix: String, route: Route)]) {
        self.routes = routes
    }

    func get(_ request: HTTPRequest) async throws -> HTTPResponse {
        await requests.append(request)
        guard let route = routes.first(where: { request.url.absoluteString.hasPrefix($0.prefix) })?.route else {
            throw HTTPError.status(404)
        }
        switch route {
        case .ok(let body, let headers):
            return HTTPResponse(url: request.url, status: 200, headers: headers, body: body)
        case .fail(let error):
            throw error
        }
    }
}

actor RequestLog {
    private(set) var all: [HTTPRequest] = []
    func append(_ request: HTTPRequest) { all.append(request) }
}

/// The three public APIs Ripe talks to, answered from fixtures.
extension FakeHTTPClient {
    static func fixtures() throws -> FakeHTTPClient {
        FakeHTTPClient([
            ("https://itunes.apple.com/lookup", .ok(try Fixture.data("itunes-lookup.json"))),
            ("https://obsproject.com/", .ok(try Fixture.data("obs-appcast.xml"))),
            ("https://justgetflux.com/", .ok(try Fixture.data("flux-appcast.xml"))),
            (
                "https://formulae.brew.sh/api/cask.json",
                .ok(try Fixture.data("cask-sample.json"), headers: ["ETag": "\"v1\""])
            ),
        ])
    }
}
