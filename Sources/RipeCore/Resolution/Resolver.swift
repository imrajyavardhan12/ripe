import Foundation

/// Turns what every source said into one verdict per app, following the authority rules in
/// docs/architecture.md §6.3.
struct Resolver: Sendable {
    var machine: Machine

    func resolve(_ app: InstalledApp, outcomes: [SourceID: SourceOutcome]) -> AppReport {
        // An App Store app only updates through the store, so nothing else gets a say.
        let considered = outcomes.filter { !app.signals.isFromAppStore || $0.key == .appStore }
        let applicable = considered.filter { $0.value != .notApplicable }.sorted { $0.key < $1.key }

        var evidence = applicable.map { Evidence(source: $0.key, outcome: $0.value, decisive: false) }
        let managedBy = managedBy(app, outcomes: outcomes)

        // The most authoritative source that answered decides. A lower source never overrides it.
        guard let index = evidence.firstIndex(where: { if case .found = $0.outcome { true } else { false } }),
            case .found(let release, let confidence, _) = evidence[index].outcome
        else {
            let verdict: Verdict = evidence.isEmpty ? .unknown(.noSource) : .unknown(.sourcesFailed)
            let explanation =
                evidence.isEmpty
                ? "No update source knows this app."
                : "Every source that applies failed to answer."
            return AppReport(
                app: app, verdict: verdict, evidence: evidence, explanation: explanation, managedBy: managedBy)
        }
        evidence[index].decisive = true

        let skippedFailures = evidence[..<index].map(\.source.displayName)
        let fallbackNote = skippedFailures.isEmpty ? "" : " (\(skippedFailures.joined(separator: ", ")) failed)"
        let source = release.source.displayName
        let comparison = VersionMatcher.compare(app.version, with: release)

        let verdict: Verdict
        let explanation: String
        switch comparison.order {
        case .older?:
            if let minimum = release.minimumSystemVersion.flatMap(Version.init),
                machine.macOSVersion.order(comparedTo: minimum) == .older
            {
                verdict = .unknown(.requiresNewerMacOS(release))
                explanation = "\(source) has \(release.version), but it needs macOS \(minimum.raw) or later."
            } else if confidence < .medium {
                verdict = .unknown(.lowConfidence(release))
                explanation =
                    "\(source) suggests \(release.version) is available, but the match is too weak to be sure (\(comparison.basis))."
            } else {
                verdict = .outdated(release)
                explanation = "\(source) has a newer version\(fallbackNote): \(comparison.basis)."
            }
        case .same?:
            verdict = .current(release)
            explanation = "Matches the newest version on \(source)\(fallbackNote): \(comparison.basis)."
        case .newer?:
            verdict = .current(release)
            explanation =
                "Installed version is newer than \(source)'s\(fallbackNote), likely a beta or a lagging catalog: \(comparison.basis)."
        case nil:
            verdict = .unknown(.incomparable(release))
            explanation = "Can't compare with \(source): \(comparison.basis)."
        }
        return AppReport(app: app, verdict: verdict, evidence: evidence, explanation: explanation, managedBy: managedBy)
    }

    private func managedBy(_ app: InstalledApp, outcomes: [SourceID: SourceOutcome]) -> ManagedBy {
        if app.signals.isFromAppStore { return .appStore }
        if case .found(let release, _, _)? = outcomes[.homebrewCask], let token = release.caskToken,
            machine.homebrewCasks.contains(token)
        {
            return .homebrew(token: token)
        }
        if app.signals.sparkleFeedURL != nil || app.signals.sparklePublicEDKey != nil || app.signals.electronUpdater {
            return .selfUpdating
        }
        return .none
    }
}
