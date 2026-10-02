import ArgumentParser
import Foundation
import RipeCore

/// `ripe skip <app>`: stop offering the current update. `--always`: ignore the app.
struct SkipCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skip",
        abstract: "Skip an app's current update, or ignore the app with --always.",
        discussion: """
            Without --always only the version on offer now is skipped; the app shows up again \
            when a newer one ships, so a later fix is never hidden. Skips live in \
            ~/.config/ripe/skips.json. `ripe pick <app>` still updates a skipped app when you name it.
            """
    )

    @Argument(help: "App to skip, by Finder name or bundle ID.")
    var app: String?

    @Flag(help: "Ignore the app until `ripe unskip`, whatever version ships.")
    var always = false

    @Flag(help: "Show what's skipped.")
    var list = false

    @OptionGroup var options: CheckOptions

    func validate() throws {
        if list && app != nil { throw ValidationError("Use either an app name or --list.") }
        if !list && app == nil { throw ValidationError("Name the app to skip, or use --list.") }
    }

    func run() async throws {
        let store = SkipStore(url: SkipStore.defaultURL())
        var skips = try loadSkips(store)
        let terminal = Terminal.current()

        if list {
            print(SkipRenderer(terminal: terminal).renderList(skips))
            return
        }
        guard let name = app else { return }
        let query = AppQuery(name)
        let report = try await options.check { query.matches($0) }
        let matches = query.best(report.apps)
        guard let target = matches.first, matches.count == 1 else {
            throw RipeError(
                matches.isEmpty
                    ? "No app named \"\(name)\" in /Applications or ~/Applications."
                    : "\"\(name)\" matches \(matches.map(\.app.name).joined(separator: ", ")); use the full name or bundle ID."
            )
        }

        if always {
            skips.skipAlways(target.app)
            try store.save(skips)
            print("Skipping \(target.app.name) from now on. `ripe unskip \(target.app.name)` to see its updates again.")
            return
        }
        guard let release = target.verdict.release, Self.hasUpdate(target.verdict) else {
            throw RipeError(
                "\(target.app.name) has no update to skip right now. Use --always to ignore it permanently.")
        }
        skips.skip(target.app, version: release.version)
        try store.save(skips)
        print("Skipping \(target.app.name) \(release.version). It shows up again when a newer version ships.")
    }

    static func hasUpdate(_ verdict: Verdict) -> Bool {
        switch verdict {
        case .outdated, .skippedByUser: true
        case .current, .unknown: false
        }
    }
}

/// `ripe unskip <app>`: offer the app's updates again.
struct UnskipCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unskip",
        abstract: "Offer an app's updates again."
    )

    @Argument(help: "App to unskip, by name as shown in `ripe skip --list`, or its bundle ID.")
    var app: String

    func run() throws {
        let store = SkipStore(url: SkipStore.defaultURL())
        var skips = try loadSkips(store)
        let query = AppQuery(app)
        // Works from the skip list alone, so an uninstalled app can still be unskipped.
        let matches = skips.apps.filter { id, entry in query.matches(name: entry.name) || id == query.text }
        guard let (bundleID, entry) = matches.first, matches.count == 1 else {
            throw RipeError(
                matches.isEmpty
                    ? "\"\(app)\" isn't skipped. `ripe skip --list` shows what is."
                    : "\"\(app)\" matches several skipped apps; use the bundle ID.")
        }
        skips.unskip(bundleID: bundleID)
        try store.save(skips)
        print("\(entry.name)'s updates will be offered again.")
    }
}

private func loadSkips(_ store: SkipStore) throws -> SkipList {
    do {
        return try store.load()
    } catch {
        throw RipeError("\(error)")
    }
}

struct SkipRenderer {
    var terminal: Terminal

    func renderList(_ skips: SkipList) -> String {
        guard !skips.isEmpty else { return "Nothing skipped." }
        var table = TextTable(header: ["App", "Skipped", "Bundle ID"])
        for (bundleID, entry) in skips.apps.sorted(by: {
            $0.value.name.localizedStandardCompare($1.value.name) == .orderedAscending
        }) {
            let what = entry.always ? "always" : entry.versions.joined(separator: ", ")
            table.rows.append([entry.name, what, terminal.style(bundleID, .dim)])
        }
        return table.render(terminal: terminal)
    }
}
