import Foundation
import RipeCore

/// Human-readable output. Pure: takes a report, returns a string.
struct ReportRenderer {
    var terminal: Terminal

    // MARK: ripe

    func renderOutdated(_ report: Report) -> String {
        let outdated = report.outdated
        guard !outdated.isEmpty else {
            let lines = [
                terminal.style(
                    "Nothing ripe. All \(report.current.count) apps with a known version are up to date.", .green),
                footer(report),
            ]
            return lines.joined(separator: "\n")
        }
        var table = TextTable(header: ["App", "Installed", "Latest", "Source", "Update with"])
        for item in outdated {
            guard case .outdated(let release) = item.verdict else { continue }
            let (installed, latest) = versions(item.app.version, release)
            table.rows.append([
                terminal.style(item.app.name, .bold), installed, terminal.style(latest, .green),
                release.source.displayName, terminal.style(updateWith(item, release), .dim),
            ])
        }
        return table.render(terminal: terminal) + "\n\n" + footer(report)
    }

    // MARK: ripe --all

    func renderAll(_ report: Report) -> String {
        var table = TextTable(header: ["App", "Installed", "Latest", "Status", "Source"])
        for item in report.apps {
            let release = item.verdict.release
            let (installed, latest) = release.map { versions(item.app.version, $0) } ?? (item.app.version.display, "—")
            table.rows.append([
                item.app.name, installed, latest, status(item.verdict), release?.source.displayName ?? "—",
            ])
        }
        return table.render(terminal: terminal) + "\n\n" + footer(report, hintAll: false)
    }

    // MARK: ripe why

    func renderWhy(_ item: AppReport) -> String {
        let app = item.app
        let build = app.version.build.map { $0 == app.version.short ? "" : " (\($0))" } ?? ""
        var lines = [
            "\(terminal.style(app.name, .bold)) \(app.version.display)\(build)  \(terminal.style(app.url.path, .dim))",
            "\(app.bundleID)",
            "",
            "\(status(item.verdict)): \(item.explanation)",
            "Updates through: \(updateChannel(item))",
            "",
            terminal.style("Sources, most authoritative first:", .bold),
        ]
        if let catalog = app.catalog {
            lines.append("  \(terminal.style("◆", .yellow)) orchard    \(catalog.changes.joined(separator: "; "))")
        }
        if item.evidence.isEmpty {
            lines.append("  none apply. Ripe can't check this app yet; an orchard catalog entry would fix that.")
        }
        for evidence in item.evidence {
            let name = evidence.source.displayName.padding(toLength: 10, withPad: " ", startingAt: 0)
            switch evidence.outcome {
            case .found(let release, let confidence, let note):
                let build = release.build.map { " (build \($0))" } ?? ""
                let marker = evidence.decisive ? terminal.style("✓", .green) : terminal.style("·", .dim)
                let details = [note, "\(confidence) confidence", evidence.decisive ? "decided" : "not needed"]
                    .compactMap { $0 }.joined(separator: " · ")
                lines.append("  \(marker) \(name) \(release.version)\(build)  \(terminal.style(details, .dim))")
            case .failed(let message):
                lines.append("  \(terminal.style("✗", .red)) \(name) \(message)")
            case .notApplicable:
                continue
            }
        }
        if let notes = app.catalog?.entry.notes {
            lines += ["", "Note: \(notes)"]
        }
        if let url = item.verdict.release?.pageURL {
            lines += ["", "More: \(url.absoluteString)"]
        }
        return lines.joined(separator: "\n")
    }

    func renderSkipped(_ skipped: SkippedBundle) -> String {
        let name = skipped.url.deletingPathExtension().lastPathComponent
        let reason =
            switch skipped.reason {
            case .appleSystemApp: "it's part of macOS and updates with the system (Software Update)."
            case .safariWebApp: "it's a Safari web app; it always runs the live website."
            case .setapp: "it's managed by Setapp, which keeps it updated."
            case .installer: "it looks like an installer or uninstaller, not the app itself."
            case .missingBundleID: "its Info.plist has no bundle identifier."
            case .missingVersion: "its Info.plist declares no version."
            case .unreadableInfoPlist: "its Info.plist couldn't be read."
            }
        return "\(terminal.style(name, .bold)) isn't checked: \(reason)\n\(terminal.style(skipped.url.path, .dim))"
    }

    // MARK: Pieces

    private func footer(_ report: Report, hintAll: Bool = true) -> String {
        let seconds = Double(report.duration.components.seconds) + Double(report.duration.components.attoseconds) / 1e18
        var parts = ["\(report.outdated.count) ripe", "\(report.current.count) up to date"]
        if !report.unknown.isEmpty { parts.append("\(report.unknown.count) unknown") }
        parts.append(String(format: "%.1fs", seconds))
        var lines = [terminal.style(parts.joined(separator: " · "), .dim)]
        var hints = ["`ripe why <app>` explains any result"]
        if hintAll { hints.append("`ripe --all` lists every app") }
        lines.append(terminal.style(hints.joined(separator: "; ") + ".", .dim))
        return lines.joined(separator: "\n")
    }

    /// Shows build numbers only when the visible versions are equal but builds differ.
    private func versions(_ installed: AppVersion, _ release: Release) -> (String, String) {
        let installedText = installed.display
        guard installedText == release.version, let build = release.build, let installedBuild = installed.build,
            build != installedBuild
        else { return (installedText, release.version) }
        return ("\(installedText) (\(installedBuild))", "\(release.version) (\(build))")
    }

    private func status(_ verdict: Verdict) -> String {
        switch verdict {
        case .outdated: terminal.style("ripe", .yellow)
        case .current: terminal.style("up to date", .green)
        case .unknown(let reason): terminal.style(Self.describe(reason), .dim)
        }
    }

    static func describe(_ reason: UnknownReason) -> String {
        switch reason {
        case .noSource: "unknown: no update source"
        case .sourcesFailed: "unknown: source failed"
        case .incomparable: "unknown: versions not comparable"
        case .lowConfidence: "unknown: possible update, weak match"
        case .requiresNewerMacOS(let release): "needs macOS \(release.minimumSystemVersion ?? "newer")"
        }
    }

    private func updateWith(_ item: AppReport, _ release: Release) -> String {
        switch item.managedBy {
        case .appStore: "App Store"
        case .homebrew(let token): "brew upgrade --cask \(token)"
        case .selfUpdating: "the app's updater"
        case .none: release.pageURL?.host().map { "download from \($0)" } ?? "the vendor's website"
        }
    }

    private func updateChannel(_ item: AppReport) -> String {
        switch item.managedBy {
        case .appStore: "the Mac App Store"
        case .homebrew(let token): "Homebrew (brew upgrade --cask \(token))"
        case .selfUpdating: "its own built-in updater (runs when the app is open)"
        case .none: "manual download"
        }
    }
}
