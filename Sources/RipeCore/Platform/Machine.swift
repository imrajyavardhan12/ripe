import Foundation

/// Facts about this Mac that change which update applies. Injected, so tests can pretend to be
/// an Intel Mac on Sonoma.
public struct Machine: Sendable, Hashable {
    public enum Architecture: String, Sendable, Hashable, Codable {
        case arm64
        case intel = "x86_64"
    }

    public var macOSVersion: Version
    public var architecture: Architecture
    /// Two-letter App Store storefront used for lookups, lowercased.
    public var storeCountry: String
    /// Tokens of casks installed by Homebrew (folder names in the Caskroom).
    public var homebrewCasks: Set<String>
    /// Installed casks from third-party taps, which the public cask API doesn't list.
    public var tapCasks: [TapCask]

    public init(
        macOSVersion: Version, architecture: Architecture, storeCountry: String, homebrewCasks: Set<String> = [],
        tapCasks: [TapCask] = []
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.storeCountry = storeCountry
        self.homebrewCasks = homebrewCasks
        self.tapCasks = tapCasks
    }

    /// Homebrew's name for this macOS release, used as a key in cask `variations`.
    public var macOSCodename: String? {
        switch macOSVersion.release.first {
        case 27: "golden_gate"
        case 26: "tahoe"
        case 15: "sequoia"
        case 14: "sonoma"
        case 13: "ventura"
        case 12: "monterey"
        case 11: "big_sur"
        default: nil
        }
    }

    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Machine {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return Machine(
            macOSVersion: Version(release: [os.majorVersion, os.minorVersion, os.patchVersion]),
            architecture: hardwareArchitecture(),
            storeCountry: storeCountry(environment: environment),
            homebrewCasks: installedCasks(environment: environment),
            tapCasks: TapCaskReader.installed(prefixes: homebrewPrefixes(environment: environment))
        )
    }

    /// The CPU, not the process: a universal binary runs natively, but an x86_64 build under
    /// Rosetta would otherwise pick Intel downloads on an Apple silicon Mac.
    static func hardwareArchitecture() -> Architecture {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let found = sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0
        return found && value == 1 ? .arm64 : .intel
    }

    /// The App Store region follows the Apple ID, which apps can't read; the Mac's region is
    /// right for almost everyone. `RIPE_STORE_COUNTRY` overrides it.
    static func storeCountry(environment: [String: String]) -> String {
        if let override = environment["RIPE_STORE_COUNTRY"], override.count == 2 {
            return override.lowercased()
        }
        return Locale.current.region?.identifier.lowercased() ?? "us"
    }

    static func homebrewPrefixes(environment: [String: String]) -> [String] {
        [environment["HOMEBREW_PREFIX"], "/opt/homebrew", "/usr/local"].compactMap { $0 }
    }

    static func installedCasks(environment: [String: String]) -> Set<String> {
        var tokens = Set<String>()
        for prefix in Set(homebrewPrefixes(environment: environment)) {
            let caskroom = URL(filePath: prefix).appending(path: "Caskroom")
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: caskroom.path)) ?? []
            tokens.formUnion(entries.filter { !$0.hasPrefix(".") })
        }
        return tokens
    }
}
