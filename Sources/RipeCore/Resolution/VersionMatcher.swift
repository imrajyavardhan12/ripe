/// Compares an installed app's version fields against a release, choosing the right fields and
/// refusing to compare versions that use different numbering schemes.
enum VersionMatcher {
    struct Result: Sendable, Hashable {
        /// Installed relative to the release; `nil` when they can't be ordered.
        var order: VersionOrder?
        /// How the comparison was made, in words, for `ripe why`.
        var basis: String
    }

    static func compare(_ installed: AppVersion, with release: Release) -> Result {
        // Sparkle's rule: the feed's build number against CFBundleVersion.
        if release.comparison == .bundleVersion,
            let installedBuild = installed.parsedBuild,
            let releaseBuild = release.build.flatMap(Version.init)
        {
            return Result(
                order: installedBuild.order(comparedTo: releaseBuild),
                basis: "build \(installedBuild.raw) vs \(releaseBuild.raw)"
            )
        }

        // Some bundles only fill in CFBundleVersion; use it only when the short version is absent.
        // An unreadable short version (a git hash) must not quietly become a build-number comparison.
        let installedVersion = installed.short == nil ? installed.parsedBuild : installed.parsedShort
        guard let installedVersion else {
            return Result(order: nil, basis: "installed version \"\(installed.display)\" isn't a comparable version")
        }
        guard let releaseVersion = Version(release.version) else {
            return Result(order: nil, basis: "latest version \"\(release.version)\" isn't a comparable version")
        }
        return compareAcrossSchemes(installedVersion, releaseVersion)
    }

    /// Plain comparison, unless the leading numbers are so far apart that the two sides clearly
    /// count differently. Brave reports `154.1.96.59` (Chromium major first) while Homebrew
    /// says `1.96.59.0`; a plain comparison would call Brave up to date forever.
    static func compareAcrossSchemes(_ installed: Version, _ latest: Version) -> Result {
        let basis = "version \(installed.raw) vs \(latest.raw)"
        let a = installed.release
        let b = latest.release
        guard a[0] != b[0], differByOrderOfMagnitude(a[0], b[0]) else {
            return Result(order: installed.order(comparedTo: latest), basis: basis)
        }
        // Try dropping leading components from the installed version until it lines up with
        // the release's first number.
        for start in 1..<a.count where a[start] == b[0] {
            let aligned = Version(release: Array(a[start...]), prerelease: installed.prerelease)
            return Result(
                order: aligned.order(comparedTo: latest),
                basis:
                    "\(basis), aligned as \(aligned.raw) (installed version has a \(a[0...start - 1].map(String.init).joined(separator: ".")) prefix)"
            )
        }
        return Result(order: nil, basis: "\(basis): numbering schemes differ")
    }

    private static func differByOrderOfMagnitude(_ x: Int, _ y: Int) -> Bool {
        let small = max(min(x, y), 1)
        return max(x, y) >= small * 10
    }
}
