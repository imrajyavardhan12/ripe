import Foundation

/// One line of `ripe doctor`.
public struct DoctorCheck: Sendable, Hashable {
    public enum Status: Sendable, Hashable, Comparable {
        /// Context, not a problem (an optional tool that isn't installed).
        case info
        case ok
        /// Ripe works, but less well (offline, using cached data).
        case warning
        /// Something stops Ripe from working properly.
        case problem
    }

    public var name: String
    public var status: Status
    public var detail: String
    /// What to do about it, when there's something to do.
    public var hint: String?

    public init(_ name: String, _ status: Status, _ detail: String, hint: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.hint = hint
    }
}

/// Checks what Ripe depends on: app folders, Homebrew and mas, the three online sources, the
/// skips file and interrupted updates. Read-only: it reports an interrupted update but leaves
/// recovering it to the next `ripe pick`.
public struct Doctor: Sendable {
    public var scanner: AppScanner
    public var context: SourceContext
    public var catalogURL: URL?
    public var tools: HandOffTools
    public var skipsURL: URL
    public var journalDirectory: URL
    public var home: String

    public init(
        scanner: AppScanner, context: SourceContext, catalogURL: URL?, tools: HandOffTools, skipsURL: URL,
        journalDirectory: URL, home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) {
        self.scanner = scanner
        self.context = context
        self.catalogURL = catalogURL
        self.tools = tools
        self.skipsURL = skipsURL
        self.journalDirectory = journalDirectory
        self.home = home
    }

    /// Revalidates every cached source (`refresh`), so the answers reflect the network now.
    public static func live(environment: [String: String] = ProcessInfo.processInfo.environment) -> Doctor {
        let ripe = Ripe.Environment.live(refresh: true, environment: environment)
        return Doctor(
            scanner: ripe.scanner, context: ripe.context, catalogURL: ripe.catalogURL, tools: .find(),
            skipsURL: SkipStore.defaultURL(environment: environment),
            journalDirectory: Installer.Environment.defaultJournalDirectory
        )
    }

    public func run() async -> [DoctorCheck] {
        async let casks = homebrewData()
        async let store = appStore()
        async let catalog = orchard()
        var checks = [apps(), homebrew(), mas()]
        checks += await [casks, store, catalog]
        checks += [skips(), interruptedUpdates()]
        return checks
    }

    // MARK: Local

    func apps() -> DoctorCheck {
        let result = scanner.scan()
        let folders = scanner.roots.map(display).joined(separator: ", ")
        let unreadable = scanner.roots.filter { !FileManager.default.isReadableFile(atPath: $0.path) }
        if result.apps.isEmpty {
            return DoctorCheck(
                "Apps", .problem, "none found in \(folders)",
                hint: unreadable.isEmpty
                    ? "Is RIPE_APPLICATIONS_DIR pointing somewhere unexpected?"
                    : "Can't read \(unreadable.map(display).joined(separator: ", ")).")
        }
        let skipped = result.skipped.isEmpty ? "" : " (skipped: \(Self.describe(result.skipped)))"
        return DoctorCheck("Apps", .ok, "\(result.apps.count) in \(folders)\(skipped)")
    }

    /// "2 Apple apps, 1 web app": what discovery left out, by reason.
    static func describe(_ skipped: [SkippedBundle]) -> String {
        let counts = Dictionary(grouping: skipped, by: \.reason).mapValues(\.count)
        let order: [(SkipReason, String)] = [
            (.appleSystemApp, "Apple app"), (.setapp, "Setapp app"), (.safariWebApp, "web app"),
            (.installer, "installer"), (.missingBundleID, "without a bundle ID"),
            (.missingVersion, "without a version"), (.unreadableInfoPlist, "unreadable"),
        ]
        return order.compactMap { reason, noun in
            guard let count = counts[reason] else { return nil }
            let plural = noun.hasPrefix("with") || noun == "unreadable" || count == 1 ? noun : noun + "s"
            return "\(count) \(plural)"
        }.joined(separator: ", ")
    }

    func homebrew() -> DoctorCheck {
        guard let brew = tools.brew else {
            return DoctorCheck(
                "Homebrew", .info, "not installed",
                hint: "Ripe still checks every app; Homebrew-installed apps need brew to be updated.")
        }
        let casks = context.machine.homebrewCasks.count
        return DoctorCheck("Homebrew", .ok, "\(display(brew)), \(casks) cask\(casks == 1 ? "" : "s") installed")
    }

    func mas() -> DoctorCheck {
        guard let mas = tools.mas else {
            return DoctorCheck(
                "mas", .info, "not installed: App Store updates open the App Store for you to click Update",
                hint: "`brew install mas` lets `ripe pick` update App Store apps itself.")
        }
        return DoctorCheck("mas", .ok, display(mas))
    }

    func skips() -> DoctorCheck {
        guard FileManager.default.fileExists(atPath: skipsURL.path) else {
            return DoctorCheck("Skips", .ok, "none")
        }
        do {
            let list = try SkipStore(url: skipsURL).load()
            let count = list.apps.count
            return DoctorCheck("Skips", .ok, "\(count) app\(count == 1 ? "" : "s") in \(display(skipsURL))")
        } catch {
            return DoctorCheck(
                "Skips", .problem, "\(display(skipsURL)) can't be read: \(error)",
                hint: "Fix the file, or delete it to clear every skip.")
        }
    }

    func interruptedUpdates() -> DoctorCheck {
        let files =
            (try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil))
            ?? []
        let apps = files.filter { $0.pathExtension == "json" }.map { file -> String in
            guard let data = try? Data(contentsOf: file),
                let entry = try? JSONDecoder().decode(Replacer.JournalEntry.self, from: data)
            else { return file.lastPathComponent }
            return URL(filePath: entry.appPath).deletingPathExtension().lastPathComponent
        }
        guard !apps.isEmpty else { return DoctorCheck("Updates", .ok, "no interrupted updates") }
        return DoctorCheck(
            "Updates", .warning, "\(apps.count) interrupted: \(apps.sorted().joined(separator: ", "))",
            hint: "The next `ripe pick` finishes each one or puts the old version back.")
    }

    // MARK: Network

    func homebrewData() async -> DoctorCheck {
        // Same request as the cask source, so this revalidates the cache Ripe actually uses.
        let request = HTTPRequest(url: HomebrewCaskSource.endpoint, maxBytes: 60_000_000, cacheTTL: 6 * 3600)
        return await reach("Homebrew data", request) { _ in "formulae.brew.sh reachable" }
    }

    func appStore() async -> DoctorCheck {
        var components = URLComponents(url: AppStoreSource.endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "bundleId", value: "com.apple.dt.Xcode"),
            URLQueryItem(name: "country", value: context.machine.storeCountry),
        ]
        guard let url = components?.url else { return DoctorCheck("App Store", .problem, "bad lookup URL") }
        return await reach("App Store", HTTPRequest(url: url, cacheTTL: 3600)) { _ in
            "lookup reachable (store region: \(context.machine.storeCountry.uppercased()))"
        }
    }

    func orchard() async -> DoctorCheck {
        guard let url = catalogURL else {
            return DoctorCheck("orchard", .info, "turned off (RIPE_CATALOG_URL=none)")
        }
        let loader = CatalogLoader(url: url, refresh: true)
        let data: Data
        let origin: String
        if url.isFileURL {
            guard let local = try? Data(contentsOf: url) else {
                return DoctorCheck("orchard", .problem, "can't read \(display(url))", hint: "Check RIPE_CATALOG_URL.")
            }
            (data, origin) = (local, "local file \(display(url))")
        } else {
            do {
                let response = try await context.http.get(
                    HTTPRequest(url: url, maxBytes: 5_000_000, cacheTTL: 6 * 3600, timeout: 3))
                (data, origin) = (response.body, response.cache == .stale ? "cached copy (offline)" : url.host() ?? "")
            } catch {
                return DoctorCheck(
                    "orchard", .warning, "unreachable: \(error)",
                    hint: "Ripe works without the catalog; a few apps may show as unknown.")
            }
        }
        guard let catalog = loader.decode(data, log: context.log) else {
            return DoctorCheck(
                "orchard", .warning, "catalog from \(origin) is unreadable or too new for this Ripe",
                hint: "Update Ripe (`brew upgrade ripe`).")
        }
        return DoctorCheck(
            "orchard", origin.hasPrefix("cached") ? .warning : .ok, "\(catalog.count) entries from \(origin)")
    }

    private func reach(
        _ name: String, _ request: HTTPRequest, describe: (HTTPResponse) -> String
    ) async -> DoctorCheck {
        do {
            let response = try await context.http.get(request)
            if response.cache == .stale {
                return DoctorCheck(
                    name, .warning, "unreachable; using the cached copy",
                    hint: "Results may be out of date until the network is back.")
            }
            return DoctorCheck(name, .ok, describe(response))
        } catch {
            return DoctorCheck(
                name, .problem, "unreachable: \(error)",
                hint: "Check the connection, VPN or firewall for \(request.url.host() ?? "it").")
        }
    }

    private func display(_ url: URL) -> String {
        let path = url.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
