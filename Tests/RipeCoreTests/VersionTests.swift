import Foundation
import Testing

@testable import RipeCore

struct VersionTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let installed: String
        let latest: String
        let expected: VersionOrder?
        var testDescription: String { "\(installed) vs \(latest)" }
    }

    @Test(arguments: [
        // Plain numeric
        Case(installed: "1.2.3", latest: "1.2.4", expected: .older),
        Case(installed: "1.10", latest: "1.9", expected: .newer),
        Case(installed: "1.2", latest: "1.2.0", expected: .same),
        Case(installed: "1.2.0.0", latest: "1.2", expected: .same),
        Case(installed: "2.7.12", latest: "2.7.12", expected: .same),
        Case(installed: "32.2.2", latest: "33.0.0", expected: .older),
        Case(installed: "2026.3", latest: "2026.5", expected: .older),  // Mullvad VPN
        Case(installed: "2026.01.39", latest: "2026.1.39", expected: .same),  // leading zeros
        // Large build numbers (OBS `sparkle:version`)
        Case(installed: "31845296735", latest: "36194435514", expected: .older),
        // Pre-releases sort before their release
        Case(installed: "1.0b3", latest: "1.0", expected: .older),
        Case(installed: "1.0", latest: "1.0rc1", expected: .newer),
        Case(installed: "1.0a1", latest: "1.0b1", expected: .older),
        Case(installed: "1.0b2", latest: "1.0b10", expected: .older),
        Case(installed: "1.0beta", latest: "1.0b", expected: .same),
        Case(installed: "1.0b", latest: "1.0b2", expected: .older),
        Case(installed: "0.21.3-Beta", latest: "0.21.3", expected: .older),  // AeroSpace
        Case(installed: "0.21.3-Beta", latest: "0.21.4-Beta", expected: .older),
        Case(installed: "1.0-rc.1", latest: "1.0-beta.9", expected: .newer),
        Case(installed: "1.0-dev", latest: "1.0-alpha", expected: .older),
        // Noise that must not affect order
        Case(installed: "v1.2.3", latest: "1.2.3", expected: .same),
        Case(installed: "0.4.24+1", latest: "0.4.24", expected: .same),  // LM Studio build metadata
        Case(installed: "5.0 (1234)", latest: "5.0", expected: .same),
        Case(installed: "2.0 build 5", latest: "2.0.5", expected: .same),
        Case(installed: "1.0 final", latest: "1.0", expected: .same),
        Case(installed: "1.0", latest: "1.0.1", expected: .older),
        // Visible versions with a build or hash attached, as Sparkle feeds publish them (2026-10-02)
        Case(installed: "1.166.0 (87901)", latest: "1.167.0 (88045)", expected: .older),  // Arc
        Case(installed: "3.29.2", latest: "3.29.2(400)", expected: .same),  // Airy
        Case(installed: "5.34", latest: "5.34(14042)", expected: .same),  // Folx
        Case(installed: "3.10.8", latest: "3.10.8 :0294d207:", expected: .same),  // Vienna
        Case(installed: "9.0.1", latest: "9.0.1 (build 6491)", expected: .same),  // Tunnelblick
        // Commit hash after a dash (GitHub Desktop cask, accuracy run 2026-10-02)
        Case(installed: "3.6.6", latest: "3.6.6-8b85519e", expected: .same),
        Case(installed: "3.6.5", latest: "3.6.6-8b85519e", expected: .older),
        Case(installed: "3.6.6-13b57bd2", latest: "3.6.6-8b85519e", expected: .same),
        Case(installed: "0.21.3-Beta", latest: "0.21.3-beta2", expected: .older),  // tags still count
        // Unknown tags can't be ordered against each other
        Case(installed: "1.0-foo", latest: "1.0-bar", expected: nil),
        Case(installed: "1.0-foo", latest: "1.0-foo", expected: .same),
        Case(installed: "1.0-foo", latest: "1.0", expected: .older),
        // A number against a tag at the same position
        Case(installed: "1.0b2", latest: "1.0b-rc", expected: nil),
    ])
    func order(_ c: Case) throws {
        let installed = try #require(Version(c.installed))
        let latest = try #require(Version(c.latest))
        #expect(installed.order(comparedTo: latest) == c.expected)
    }

    @Test(arguments: [
        "", "   ", "latest", "b40acce58", "0081d4530", "1a2b3c4", "deadbeefcafe", "beta", "v", "abc1.2",
        "99999999999999999999",
    ])
    func unparseable(_ raw: String) {
        #expect(Version(raw) == nil)
    }

    @Test func keepsRawString() throws {
        #expect(try #require(Version(" v1.2-Beta ")).raw == " v1.2-Beta ")
        #expect(try #require(Version("1.2-beta")).isPrerelease)
        #expect(try #require(Version("1.2")).isPrerelease == false)
    }

    @Test func codableRoundTrip() throws {
        let version = try #require(Version("1.0b3"))
        let data = try JSONEncoder().encode(version)
        #expect(String(decoding: data, as: UTF8.self) == "\"1.0b3\"")
        let decoded = try JSONDecoder().decode(Version.self, from: data)
        #expect(decoded.order(comparedTo: version) == .same)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Version.self, from: Data("\"latest\"".utf8)) }
    }

    // MARK: - Ordering laws, checked over every pair and triple of a realistic corpus

    static let corpus = [
        "0.9", "1", "1.0", "1.0.0", "1.0a1", "1.0a2", "1.0b1", "1.0b10", "1.0rc1", "1.0.1", "1.0-dev",
        "1.1", "1.10", "1.2-beta.3", "2.0 build 5", "2.0.5", "10.0", "154.1.96.59", "1.96.59.0",
        "2026.5", "31845296735", "0.21.3-Beta", "1.0-foo", "1.0-bar",
    ].compactMap(Version.init)

    @Test func antisymmetric() {
        for a in Self.corpus {
            #expect(a.order(comparedTo: a) == .same, "\(a) vs itself")
            for b in Self.corpus {
                let forward = a.order(comparedTo: b)
                let backward = b.order(comparedTo: a)
                switch forward {
                case .older: #expect(backward == .newer, "\(a) vs \(b)")
                case .newer: #expect(backward == .older, "\(a) vs \(b)")
                case .same: #expect(backward == .same, "\(a) vs \(b)")
                case nil: #expect(backward == nil, "\(a) vs \(b)")
                }
            }
        }
    }

    @Test func transitive() {
        for a in Self.corpus {
            for b in Self.corpus where a.order(comparedTo: b) == .older {
                for c in Self.corpus where b.order(comparedTo: c) == .older {
                    #expect(a.order(comparedTo: c) == .older, "\(a) < \(b) < \(c)")
                }
            }
        }
    }
}
