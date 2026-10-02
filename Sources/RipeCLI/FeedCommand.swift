import ArgumentParser
import Foundation
import RipeCore

/// `ripe feed <url>…`: the release Ripe would take from each Sparkle feed on this Mac. Hidden:
/// a tool for orchard's importer and contributors, not part of the everyday interface.
struct FeedCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "feed",
        abstract: "Show the release Ripe would take from Sparkle feeds on this Mac (one JSON line each).",
        shouldDisplay: false
    )

    @Argument(help: "Sparkle appcast URLs.")
    var urls: [String]

    @OptionGroup var options: CheckOptions

    struct Line: Encodable {
        var url: String
        var version: String?
        var build: String?
        var minimumSystemVersion: String?
        var error: String?
    }

    func run() async throws {
        var feeds: [URL] = []
        for text in urls {
            guard let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw ValidationError("Not a feed URL: \(text)")
            }
            feeds.append(url)
        }
        // Not `options.environment()`: that also reads the skips file, which feeds don't need.
        let context = Ripe.Environment.live(refresh: options.refresh, log: options.verbose ? .standardError : .silent)
            .context
        let outcomes = await Ripe.checkFeeds(feeds, context: context)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (text, feed) in zip(urls, feeds) {
            var line = Line(url: text)
            switch outcomes[feed] ?? .failed("not checked") {
            case .found(let release, _, _):
                line.version = release.version
                line.build = release.build
                line.minimumSystemVersion = release.minimumSystemVersion
            case .failed(let message):
                line.error = message
            case .notApplicable:
                line.error = "not applicable"
            }
            print(String(decoding: try encoder.encode(line), as: UTF8.self))
        }
    }
}
