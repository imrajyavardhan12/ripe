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
        if release.comparison == .crossChecked {
            return crossCheck(installed, with: release)
        }
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
        if release.comparison == .shortVersion,
            let refined = refine(installed, installedVersion, against: release, releaseVersion)
        {
            return refined
        }
        return compareAcrossSchemes(installedVersion, releaseVersion)
    }

    /// Cases where a catalog's version and the app's visible version don't line up one to one,
    /// each seen on real apps. `nil` falls through to the plain comparison.
    static func refine(
        _ installed: AppVersion, _ version: Version, against release: Release, _ latest: Version
    ) -> Result? {
        let basis = "version \(version.raw) vs \(latest.raw)"
        let mine = version.release
        let theirs = latest.release
        // npm's and Xcode's defaults, left unchanged by apps that never set a version (Hermes says
        // 0.0.1 whatever it runs). Nothing can be concluded from them.
        if version.prerelease.isEmpty, [[0, 0, 0], [0, 0, 1]].contains(padded(mine, to: 3)), mine.count <= 3,
            version.order(comparedTo: latest) != .same
        {
            return Result(order: nil, basis: "\(basis): \(version.raw) looks like a placeholder the app never set")
        }
        let isPrefix = theirs.count > mine.count && Array(theirs.prefix(mine.count)) == mine
        // WeChat 4.1.15 (270102) against `4.1.15.22,270102`: the same build is the same release.
        if isPrefix || theirs == mine, let build = installed.build, let releaseBuild = release.build,
            build == releaseBuild
        {
            return Result(order: .same, basis: "\(basis), same build \(build)")
        }
        guard isPrefix, latest.prerelease.isEmpty else { return nil }
        // Opera shows 136.0 but its CFBundleVersion is the full 136.0.6008.80.
        if let build = installed.parsedBuild, build.release.count >= theirs.count, build.release.starts(with: mine) {
            return compareAcrossSchemes(build, latest, field: "build")
        }
        // CapCut shows 9.5.0 while Homebrew says 9.5.0.4590: the extra part is a build number the
        // app doesn't expose, so whether this copy is that build can't be known. A small extra
        // part (1.2 against 1.2.1) is an ordinary release and compares normally.
        if theirs[mine.count] >= 100 {
            return Result(
                order: nil,
                basis: "\(basis): \(latest.raw) adds a build number (\(theirs[mine.count])) that the app doesn't show")
        }
        return nil
    }

    private static func padded(_ parts: [Int], to count: Int) -> [Int] {
        parts + Array(repeating: 0, count: max(0, count - parts.count))
    }

    /// Both fields, each guarded against scheme mismatches; an answer only when they agree. A feed
    /// whose build numbers count differently from the app's (`1.2.3` against `456`) would
    /// otherwise turn into a confident false update.
    static func crossCheck(_ installed: AppVersion, with release: Release) -> Result {
        // A visible version that's there but unreadable (Ghostty tip builds show a git hash) means
        // a channel this feed may not describe; the build number alone isn't enough then.
        if installed.short != nil, installed.parsedShort == nil {
            return Result(order: nil, basis: "installed version \"\(installed.display)\" isn't a comparable version")
        }
        guard Version(release.version) != nil else {
            return Result(order: nil, basis: "latest version \"\(release.version)\" isn't a comparable version")
        }
        let byBuild = installed.parsedBuild.flatMap { build in
            release.build.flatMap(Version.init).map { compareAcrossSchemes(build, $0, field: "build") }
        }
        let byVersion = installed.parsedShort.flatMap { short in
            Version(release.version).map { compareAcrossSchemes(short, $0) }
        }
        switch (byBuild, byVersion) {
        case (let build?, let version?):
            // One side can't be ordered at all: its own reason says why.
            if version.order == nil { return version }
            if build.order == nil { return build }
            guard build.order == version.order else {
                return Result(
                    order: nil,
                    basis: "\(build.basis) and \(version.basis) disagree, so the feed may number builds differently"
                )
            }
            return Result(order: build.order, basis: "\(build.basis), \(version.basis)")
        case (let only?, nil), (nil, let only?):
            return only
        case (nil, nil):
            return Result(order: nil, basis: "installed version \"\(installed.display)\" isn't a comparable version")
        }
    }

    /// Plain comparison, unless the leading numbers are so far apart that the two sides clearly
    /// count differently. Brave reports `154.1.96.59` (Chromium major first) while Homebrew
    /// says `1.96.59.0`; a plain comparison would call Brave up to date forever.
    static func compareAcrossSchemes(_ installed: Version, _ latest: Version, field: String = "version") -> Result {
        let basis = "\(field) \(installed.raw) vs \(latest.raw)"
        let a = installed.release
        let b = latest.release
        guard a[0] != b[0], differByOrderOfMagnitude(a[0], b[0]) else {
            let order = installed.order(comparedTo: latest)
            // Same numbers, but a label (`-latest`, `.CE`) or unrelated pre-release tags differ.
            return Result(
                order: order, basis: order == nil ? "\(basis): the labels after the numbers can't be ordered" : basis)
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
