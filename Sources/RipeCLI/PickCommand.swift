import ArgumentParser
import Foundation
import RipeCore

/// `ripe pick <app>` / `ripe pick --all`: update apps, verifying everything first.
struct PickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pick",
        abstract: "Update apps: name them, or pick every ripe one with --all.",
        discussion: """
            Homebrew and App Store apps are handed to brew and the App Store. Other apps are \
            downloaded, verified (checksum or EdDSA signature, code signature, matching Team ID, \
            Gatekeeper) and swapped in; the old version goes to the Trash. Nothing changes until \
            you confirm the plan.
            """
    )

    @Argument(help: "Apps to update, by Finder name or bundle ID.")
    var apps: [String] = []

    @Flag(help: "Update every app that has an update (the harvest).")
    var all = false

    @Flag(name: .shortAndLong, help: "Don't ask before updating.")
    var yes = false

    @Flag(help: "Show the plan and stop.")
    var dryRun = false

    @OptionGroup var options: CheckOptions

    func validate() throws {
        if apps.isEmpty && !all { throw ValidationError("Name the apps to update, or use --all.") }
        if !apps.isEmpty && all { throw ValidationError("Use either app names or --all, not both.") }
    }

    func run() async throws {
        let terminal = Terminal.current()
        let renderer = PickRenderer(terminal: terminal)
        let installer = Installer(environment: .live())
        for note in installer.recoverInterrupted() {
            print(terminal.style("Recovered: \(note)", .yellow))
        }

        // The words together too, in case they're one name with spaces (`ripe pick LM Studio`).
        let candidates = apps.map(AppQuery.init) + (apps.count > 1 ? [AppQuery(apps.joined(separator: " "))] : [])
        let named: @Sendable (InstalledApp) -> Bool = { app in candidates.contains { $0.matches(app) } }
        let report = try await options.check(including: all ? nil : named)
        let selected = try select(from: report, queries: AppQuery.resolve(apps, in: report.apps))
        var plans: [InstallPlan] = []
        var skipped: [(String, String)] = []
        for report in selected {
            switch Planner.decide(report, tools: installer.environment.tools) {
            case .plan(let plan): plans.append(plan)
            case .skip(let reason): skipped.append((report.app.name, reason))
            }
        }

        print(renderer.renderPlan(plans, skipped: skipped, tools: installer.environment.tools))
        guard !plans.isEmpty, !dryRun else { return }
        guard try confirm(plans.count) else {
            print("Nothing picked.")
            return
        }

        var results: [(InstallPlan, Result<InstallOutcome, InstallError>)] = []
        for plan in plans {
            print("\n" + renderer.renderHeader(plan))
            do {
                let outcome = try await installer.run(plan) { step in print(renderer.renderStep(step)) }
                results.append((plan, .success(outcome)))
                print(renderer.renderOutcome(outcome))
            } catch let error as InstallError {
                results.append((plan, .failure(error)))
                print(renderer.renderFailure(error))
            }
        }
        print("\n" + renderer.renderSummary(results))
        if results.contains(where: { if case .failure = $0.1 { true } else { false } }) {
            throw ExitCode.failure
        }
    }

    private func select(from report: Report, queries: [AppQuery]) throws -> [AppReport] {
        // --all respects skips: skipped apps are listed with the reason, not updated.
        if all { return report.outdated + report.skippedByUser }
        var selected: [AppReport] = []
        for query in queries {
            let matches = query.best(report.apps)
            guard !matches.isEmpty else {
                throw RipeError("No app named \"\(query.text)\" in /Applications or ~/Applications.")
            }
            selected += matches.filter { match in !selected.contains { $0.id == match.id } }
        }
        // Naming an app is an explicit request: it overrides a skip.
        return selected.map { report in
            guard case .skippedByUser(let release, _) = report.verdict else { return report }
            var report = report
            report.verdict = .outdated(release)
            return report
        }
    }

    private func confirm(_ count: Int) throws -> Bool {
        if yes { return true }
        guard isatty(STDIN_FILENO) == 1 else {
            throw RipeError("Not a terminal, so Ripe can't ask. Pass --yes to update without confirming.")
        }
        print("\nPick \(count == 1 ? "this app" : "these \(count) apps")? [y/N] ", terminator: "")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }
}

struct PickRenderer {
    var terminal: Terminal

    func renderPlan(_ plans: [InstallPlan], skipped: [(String, String)], tools: HandOffTools) -> String {
        var lines: [String] = []
        if !plans.isEmpty {
            var table = TextTable(header: ["App", "Update", "How"])
            for plan in plans {
                table.rows.append([
                    terminal.style(plan.app.name, .bold),
                    "\(plan.app.version.display) → \(terminal.style(plan.release.version, .green))",
                    how(plan.method, tools: tools),
                ])
            }
            lines.append(table.render(terminal: terminal))
        }
        for (name, reason) in skipped {
            lines.append(terminal.style("Not picking \(name): \(reason).", .dim))
        }
        if plans.isEmpty && skipped.isEmpty {
            lines.append(terminal.style("Nothing ripe. Every app with a known version is up to date.", .green))
        }
        return lines.joined(separator: "\n")
    }

    func how(_ method: InstallPlan.Method, tools: HandOffTools) -> String {
        switch method {
        case .homebrew(let token): "brew upgrade --cask \(token)"
        case .appStore(let id):
            tools.mas != nil && id != nil ? "mas upgrade" : "App Store (Ripe opens it; you click Update)"
        case .direct(let download):
            "download, verify \(download.integrity?.isEdDSA == true ? "EdDSA" : "SHA-256") + Team ID, old → Trash"
        case .manual(let reason, _): terminal.style("you: \(reason)", .yellow)
        }
    }

    func renderHeader(_ plan: InstallPlan) -> String {
        terminal.style("Picking \(plan.app.name) \(plan.app.version.display) → \(plan.release.version)", .bold)
    }

    func renderStep(_ step: String) -> String { terminal.style("  · \(step)", .dim) }

    func renderOutcome(_ outcome: InstallOutcome) -> String {
        switch outcome {
        case .updated(let version, let trashed, let relaunched):
            "  \(terminal.style("✓", .green)) updated to \(version.display)\(relaunched ? " and reopened" : ""); previous version in the Trash (\(trashed.lastPathComponent))"
        case .handedOff(let message): "  \(terminal.style("✓", .green)) \(message)"
        case .needsYou(let message): "  \(terminal.style("→", .yellow)) \(message)"
        }
    }

    func renderFailure(_ error: InstallError) -> String { "  \(terminal.style("✗", .red)) \(error.message)" }

    func renderSummary(_ results: [(InstallPlan, Result<InstallOutcome, InstallError>)]) -> String {
        var picked = 0
        var needsYou = 0
        var failed = 0
        for (_, result) in results {
            switch result {
            case .success(.needsYou): needsYou += 1
            case .success: picked += 1
            case .failure: failed += 1
            }
        }
        var parts = ["\(picked) picked"]
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if failed > 0 { parts.append(terminal.style("\(failed) failed", .red)) }
        return parts.joined(separator: " · ")
    }
}
