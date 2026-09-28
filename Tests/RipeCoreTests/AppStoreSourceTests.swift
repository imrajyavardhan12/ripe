import Foundation
import Testing

@testable import RipeCore

struct AppStoreSourceTests {
    static let dropover = InstalledApp.test(
        "Dropover.app", bundleID: "me.damir.dropover-mac", version: "5.3.0",
        signals: .init(appStoreReceipt: true))
    static let whatsapp = InstalledApp.test(
        "WhatsApp.app", bundleID: "net.whatsapp.WhatsApp", version: "26.36.74",
        signals: .init(appStoreReceipt: true))
    static let delisted = InstalledApp.test(
        "Gone.app", bundleID: "com.example.gone", version: "1.0", signals: .init(appStoreReceipt: true))
    static let direct = InstalledApp.test("OBS.app", bundleID: "com.obsproject.obs-studio", version: "32.2.2")

    @Test func parsesLookupResults() throws {
        let listings = try AppStoreSource.parse(Fixture.data("itunes-lookup.json"))
        let dropover = try #require(listings["me.damir.dropover-mac"])
        #expect(dropover.release.version == "5.3.1")
        #expect(dropover.release.minimumSystemVersion == "13.0")
        #expect(dropover.release.pageURL != nil)
        #expect(dropover.kind == "mac-software")

        // iPhone-family record: its minimum OS is an iOS version, so it's dropped.
        let whatsapp = try #require(listings["net.whatsapp.WhatsApp"])
        #expect(whatsapp.release.minimumSystemVersion == nil)
    }

    @Test func batchesAndReportsEveryStoreApp() async throws {
        let http = try FakeHTTPClient.fixtures()
        let context = SourceContext(http: http, machine: .test(country: "in"))
        let apps = [Self.dropover, Self.whatsapp, Self.delisted, Self.direct]
        let outcomes = await AppStoreSource().check(apps, context: context)

        #expect(outcomes[Self.direct.id] == nil, "not an App Store app")
        guard case .found(_, let confidence, _)? = outcomes[Self.dropover.id],
            case .found(_, let iosConfidence, let note)? = outcomes[Self.whatsapp.id],
            case .failed(let message)? = outcomes[Self.delisted.id]
        else {
            Issue.record("unexpected outcomes \(outcomes)")
            return
        }
        #expect(confidence == .high)
        #expect(iosConfidence == .medium && note != nil)
        #expect(message.contains("IN App Store"))

        let requests = await http.requests.all
        #expect(requests.count == 1, "one batched request")
        let query = try #require(requests.first?.url.query())
        #expect(query.contains("country=in"))
        #expect(query.contains("com.example.gone,me.damir.dropover-mac,net.whatsapp.WhatsApp"))
    }

    @Test func networkFailureIsPerApp() async {
        let context = SourceContext(http: FakeHTTPClient([("https://itunes", .fail(.offline))]), machine: .test())
        let outcomes = await AppStoreSource().check([Self.dropover], context: context)
        guard case .failed(let message)? = outcomes[Self.dropover.id] else {
            Issue.record("expected failure")
            return
        }
        #expect(message.contains("no internet connection"))
    }
}
