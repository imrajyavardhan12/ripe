import Foundation

/// Everything a source may use to reach the outside world.
public struct SourceContext: Sendable {
    public var http: any HTTPClient
    public var machine: Machine
    /// For derived data worth keeping between runs, like the compact cask index.
    public var cache: DiskCache?
    public var log: Logger

    public init(http: any HTTPClient, machine: Machine, cache: DiskCache? = nil, log: Logger = .silent) {
        self.http = http
        self.machine = machine
        self.cache = cache
        self.log = log
    }
}

/// A place that knows the newest version of some apps.
///
/// A source receives every app and answers for the ones it applies to, so it can batch the
/// way its API prefers. It never throws: problems become `.failed` outcomes, so one broken
/// feed never fails a run. Apps missing from the result are treated as `.notApplicable`.
public protocol UpdateSource: Sendable {
    var id: SourceID { get }
    /// Cheap and offline: whether this source could say anything about the app.
    func applies(to app: InstalledApp) -> Bool
    func check(_ apps: [InstalledApp], context: SourceContext) async -> [InstalledApp.ID: SourceOutcome]
}
