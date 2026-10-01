import ArgumentParser
import Foundation
import RipeCore

public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ripe",
        abstract: "Your apps, always ripe. See every outdated app on your Mac, wherever it came from.",
        version: Ripe.version,
        subcommands: [ListCommand.self, PickCommand.self, WhyCommand.self],
        defaultSubcommand: ListCommand.self
    )

    public init() {}
}

/// Flags every checking command shares.
struct CheckOptions: ParsableArguments {
    @Flag(help: "Ignore cached results and ask every source again.")
    var refresh = false

    @Flag(help: "Print debug details (sources, cache hits, timings) to stderr.")
    var verbose = false

    func environment() -> Ripe.Environment {
        .live(refresh: refresh, log: verbose ? .standardError : .silent)
    }

    /// Runs a check with a one-line progress note on stderr when it's a terminal.
    func check(including filter: (@Sendable (InstalledApp) -> Bool)? = nil) async -> Report {
        let showProgress = isatty(STDERR_FILENO) == 1 && !verbose
        if showProgress { FileHandle.standardError.write(Data("Checking your apps…".utf8)) }
        let report = await Ripe.check(environment(), including: filter)
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        return report
    }
}

/// `ripe` with no arguments: what's ripe?
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List apps with available updates."
    )

    @Flag(name: .shortAndLong, help: "Show every app, not only those with updates.")
    var all = false

    @Flag(help: "Print the full report as JSON (always includes every app).")
    var json = false

    @OptionGroup var options: CheckOptions

    func run() async throws {
        let report = await options.check()
        if json {
            print(try JSONReport(report).encoded())
        } else {
            let renderer = ReportRenderer(terminal: .current())
            print(all ? renderer.renderAll(report) : renderer.renderOutdated(report))
        }
    }
}

/// `ripe why <app>`: every source consulted and the rule that decided.
struct WhyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why",
        abstract: "Explain where an app's version information came from and how it updates."
    )

    @Argument(help: "App name as shown in Finder (case-insensitive), or its bundle ID.")
    var app: String

    @Flag(help: "Print the explanation as JSON.")
    var json = false

    @OptionGroup var options: CheckOptions

    func run() async throws {
        let query = app
        let report = await options.check { AppQuery(query).matches($0) }
        let matches = AppQuery(query).best(report.apps)

        guard !matches.isEmpty else {
            if let skipped = report.skipped.first(where: {
                AppQuery(query).matches(name: $0.url.deletingPathExtension().lastPathComponent)
            }) {
                print(ReportRenderer(terminal: .current()).renderSkipped(skipped))
                return
            }
            throw RipeError("No app named \"\(query)\" in /Applications or ~/Applications.")
        }
        if json {
            let apps = matches.map(JSONReport.App.init)
            print(try JSONReport.encode(apps.count == 1 ? AnyEncodable(apps[0]) : AnyEncodable(apps)))
        } else {
            let renderer = ReportRenderer(terminal: .current())
            print(matches.map(renderer.renderWhy).joined(separator: "\n\n"))
        }
    }
}

struct RipeError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Finds apps by what a person would type: the Finder name, a bundle ID, or a unique prefix.
struct AppQuery: Sendable {
    let text: String
    init(_ text: String) { self.text = text.lowercased().replacingOccurrences(of: ".app", with: "") }

    func matches(_ app: InstalledApp) -> Bool {
        matches(name: app.name) || app.bundleID.lowercased() == text
    }

    func matches(name: String) -> Bool {
        name.lowercased().hasPrefix(text)
    }

    /// Exact name or bundle ID matches win over prefix matches.
    func best(_ reports: [AppReport]) -> [AppReport] {
        let exact = reports.filter { $0.app.name.lowercased() == text || $0.app.bundleID.lowercased() == text }
        return exact.isEmpty ? reports.filter { matches($0.app) } : exact
    }
}
