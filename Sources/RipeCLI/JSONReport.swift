import Foundation
import RipeCore

/// The `--json` contract. Deliberately separate from RipeCore's model so internal refactors
/// can't break scripts. Additive changes keep `schemaVersion`; anything else bumps it.
/// Golden tests in RipeCLITests pin the shape.
struct JSONReport: Encodable {
    static let schemaVersion = 1

    var schemaVersion = Self.schemaVersion
    var ripeVersion = Ripe.version
    var generatedAt: Date
    var durationSeconds: Double
    var summary: Summary
    var apps: [App]
    var skipped: [Skipped]

    struct Summary: Encodable {
        var outdated: Int
        var current: Int
        var unknown: Int
    }

    struct App: Encodable {
        var name: String
        var bundleId: String
        var path: String
        var installed: Installed
        /// `outdated`, `current` or `unknown`.
        var status: String
        /// Why the status is `unknown`: `no-source`, `sources-failed`, `incomparable`,
        /// `low-confidence` or `requires-newer-macos`.
        var reason: String?
        var latest: Latest?
        var updateWith: UpdateWith
        var explanation: String
        var evidence: [EvidenceItem]
    }

    struct Installed: Encodable {
        var version: String?
        var build: String?
    }

    struct Latest: Encodable {
        var version: String
        var build: String?
        var source: String
        var url: URL?
        var minimumSystemVersion: String?
        var publishedAt: Date?
    }

    struct UpdateWith: Encodable {
        /// `app-store`, `homebrew`, `self-updating` or `manual`.
        var kind: String
        var caskToken: String?
    }

    struct EvidenceItem: Encodable {
        var source: String
        /// `found` or `failed`.
        var result: String
        var version: String?
        var build: String?
        var confidence: String?
        var note: String?
        var decisive: Bool
    }

    struct Skipped: Encodable {
        var path: String
        var reason: String
    }
}

extension JSONReport {
    init(_ report: Report) {
        generatedAt = report.generatedAt
        durationSeconds =
            Double(report.duration.components.seconds) + Double(report.duration.components.attoseconds) / 1e18
        summary = Summary(outdated: report.outdated.count, current: report.current.count, unknown: report.unknown.count)
        apps = report.apps.map(App.init)
        skipped = report.skipped.map { Skipped(path: $0.url.path, reason: $0.reason.rawValue) }
    }

    func encoded() throws -> String { try Self.encode(self) }

    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

extension JSONReport.App {
    init(_ report: AppReport) {
        let app = report.app
        name = app.name
        bundleId = app.bundleID
        path = app.url.path
        installed = JSONReport.Installed(version: app.version.short, build: app.version.build)
        switch report.verdict {
        case .outdated: status = "outdated"
        case .current: status = "current"
        case .unknown(let why):
            status = "unknown"
            reason =
                switch why {
                case .noSource: "no-source"
                case .sourcesFailed: "sources-failed"
                case .incomparable: "incomparable"
                case .lowConfidence: "low-confidence"
                case .requiresNewerMacOS: "requires-newer-macos"
                }
        }
        latest = report.verdict.release.map {
            JSONReport.Latest(
                version: $0.version, build: $0.build, source: $0.source.rawValue, url: $0.pageURL,
                minimumSystemVersion: $0.minimumSystemVersion, publishedAt: $0.publishedAt)
        }
        updateWith =
            switch report.managedBy {
            case .appStore: JSONReport.UpdateWith(kind: "app-store")
            case .homebrew(let token): JSONReport.UpdateWith(kind: "homebrew", caskToken: token)
            case .selfUpdating: JSONReport.UpdateWith(kind: "self-updating")
            case .none: JSONReport.UpdateWith(kind: "manual")
            }
        explanation = report.explanation
        evidence = report.evidence.map { item in
            switch item.outcome {
            case .found(let release, let confidence, let note):
                JSONReport.EvidenceItem(
                    source: item.source.rawValue, result: "found", version: release.version, build: release.build,
                    confidence: confidence.description, note: note, decisive: item.decisive)
            case .failed(let message):
                JSONReport.EvidenceItem(source: item.source.rawValue, result: "failed", note: message, decisive: false)
            case .notApplicable:
                JSONReport.EvidenceItem(source: item.source.rawValue, result: "not-applicable", decisive: false)
            }
        }
    }
}

/// Lets `ripe why --json` print one object for one match and an array for several.
struct AnyEncodable: Encodable {
    private let encodeValue: (any Encoder) throws -> Void
    init(_ value: some Encodable) { encodeValue = value.encode(to:) }
    func encode(to encoder: any Encoder) throws { try encodeValue(encoder) }
}
