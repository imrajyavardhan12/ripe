import ArgumentParser
import RipeCore

public struct RootCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "ripe",
        abstract: "Your apps, always ripe. See every outdated app on your Mac, wherever it came from.",
        version: Ripe.version,
        subcommands: [ListCommand.self],
        defaultSubcommand: ListCommand.self
    )

    public init() {}
}

/// `ripe` with no arguments: what's ripe?
///
/// Until update sources land this lists what discovery found and each app's update channel.
struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List apps with available updates."
    )

    func run() async throws {
        let terminal = Terminal.current()
        let result = AppScanner().scan()
        print(DiscoveryRenderer(terminal: terminal).render(result))
    }
}

struct DiscoveryRenderer {
    var terminal: Terminal

    func render(_ result: DiscoveryResult) -> String {
        var table = TextTable(header: ["App", "Version", "Channel"])
        for app in result.apps {
            table.rows.append([app.name, app.version.display, terminal.style(channel(of: app), .dim)])
        }
        let summary = "\(result.apps.count) apps · \(result.skipped.count) skipped (system, web apps, installers)"
        return table.render(terminal: terminal) + "\n\n" + terminal.style(summary, .dim)
    }

    func channel(of app: InstalledApp) -> String {
        let signals = app.signals
        if signals.isFromAppStore { return "App Store" }
        if signals.sparkleFeedURL != nil { return "Sparkle feed" }
        if signals.electronUpdater { return "Electron updater" }
        if signals.sparklePublicEDKey != nil { return "Sparkle (feed set in code)" }
        return "—"
    }
}
