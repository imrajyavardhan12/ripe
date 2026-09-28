import Testing

@testable import RipeCore

struct VersionMatcherTests {
    func release(_ version: String, build: String? = nil, comparison: Release.Comparison = .shortVersion) -> Release {
        Release(version: version, build: build, source: .homebrewCask, comparison: comparison)
    }

    func order(_ short: String?, build: String? = nil, vs release: Release) -> VersionOrder? {
        VersionMatcher.compare(AppVersion(short: short, build: build), with: release).order
    }

    @Test func sparkleComparesBuildNumbers() {
        let latest = release("32.2.2", build: "31845296735", comparison: .bundleVersion)
        #expect(order("32.2.2", build: "31845296735", vs: latest) == .same)
        #expect(order("32.2.1", build: "31000000000", vs: latest) == .older)
        // Build wins even when the visible versions look equal.
        #expect(order("32.2.2", build: "31000000000", vs: latest) == .older)
    }

    @Test func sparkleFallsBackToShortVersionWithoutBuilds() {
        #expect(order("42.1", vs: release("42.2", build: "42.2", comparison: .bundleVersion)) == .older)
        #expect(order("2.7.12", build: nil, vs: release("2.7.12", comparison: .bundleVersion)) == .same)
    }

    @Test func caskBuildPartIsDisplayOnly() {
        // `6.0,9001`: the build part may be a download ID, never compared.
        #expect(order("6.0", build: "1", vs: release("6.0", build: "9001")) == .same)
    }

    @Test func usesBuildWhenShortVersionIsMissing() {
        #expect(order(nil, build: "1.0", vs: release("1.1")) == .older)
    }

    // MARK: Numbering schemes

    @Test func alignsChromiumPrefixedVersions() {
        // Brave: installed 154.1.96.59 (Chromium 154 + Brave 1.96.59), Homebrew says 1.96.59.0.
        #expect(order("154.1.96.59", vs: release("1.96.59.0")) == .same)
        #expect(order("154.1.96.59", vs: release("1.97.10.0")) == .older)
        #expect(order("155.1.97.10", vs: release("1.96.59.0")) == .newer)
    }

    @Test func refusesToCompareDifferentSchemes() {
        // No alignment possible and the leading numbers are an order of magnitude apart.
        #expect(order("154.2.0", vs: release("3.1.0")) == nil)
        #expect(order("2.0", vs: release("2026.5")) == nil)
        #expect(order("1.0", vs: release("10.0")) == nil)
    }

    @Test func ordinaryMajorUpgradesStillCompare() {
        #expect(order("1.104.24", vs: release("2.5.3.0")) == .older)
        #expect(order("9.9", vs: release("10.0")) == .older)
        #expect(order("0.9", vs: release("1.0")) == .older)
    }

    @Test func unparseableVersionsAreIncomparable() {
        let ghostty = VersionMatcher.compare(AppVersion(short: "b40acce58", build: "17955"), with: release("1.3.1"))
        #expect(ghostty.order == nil)
        #expect(ghostty.basis.contains("b40acce58"))
        #expect(order("1.0", vs: release("latest")) == nil)
    }
}
