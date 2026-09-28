import Foundation
import Testing

@testable import RipeCore

/// Builds throwaway `.app` directories so discovery runs against a real file system.
struct AppFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ripe-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func app(
        _ relativePath: String,
        info: [String: Any],
        appStoreReceipt: Bool = false,
        electron: Bool = false
    ) throws -> URL {
        let bundle = root.appending(path: relativePath)
        let contents = bundle.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))
        if appStoreReceipt { try touch(contents.appending(path: "_MASReceipt/receipt")) }
        if electron { try touch(contents.appending(path: "Resources/app-update.yml")) }
        return bundle
    }

    func wrappedIOSApp(_ relativePath: String, info: [String: Any]) throws {
        let inner = root.appending(path: relativePath).appending(path: "Wrapper/Inner.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: inner.appending(path: "Info.plist"))
    }

    func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
    }
}

struct AppScannerTests {
    @Test func readsVersionsAndSignals() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app(
            "OBS.app",
            info: [
                "CFBundleIdentifier": "com.obsproject.obs-studio",
                "CFBundleShortVersionString": "32.2.2",
                "CFBundleVersion": "31845296735",
                "SUFeedURL": "https://obsproject.com/osx_update/updates_arm64_v2.xml",
                "SUPublicEDKey": "abc=",
            ])
        try fixture.app(
            "Dropover.app",
            info: ["CFBundleIdentifier": "me.damir.dropover-mac", "CFBundleShortVersionString": "5.3.0"],
            appStoreReceipt: true)
        try fixture.app(
            "LM Studio.app",
            info: ["CFBundleIdentifier": "ai.elementlabs.lmstudio", "CFBundleShortVersionString": "0.4.24+1"],
            electron: true)
        try fixture.wrappedIOSApp(
            "WhatsApp.app",
            info: ["CFBundleIdentifier": "net.whatsapp.WhatsApp", "CFBundleShortVersionString": "26.36"])

        let apps = AppScanner(roots: [fixture.root]).scan().apps
        #expect(apps.map(\.name) == ["Dropover", "LM Studio", "OBS", "WhatsApp"])

        let obs = try #require(apps.first { $0.name == "OBS" })
        #expect(obs.version == AppVersion(short: "32.2.2", build: "31845296735"))
        #expect(obs.signals.sparkleFeedURL?.host() == "obsproject.com")
        #expect(obs.signals.sparklePublicEDKey == "abc=")
        #expect(obs.signals.isFromAppStore == false)

        #expect(apps.first { $0.name == "Dropover" }?.signals.appStoreReceipt == true)
        #expect(apps.first { $0.name == "LM Studio" }?.signals.electronUpdater == true)
        #expect(apps.first { $0.name == "WhatsApp" }?.signals.wrappedIOSApp == true)
    }

    @Test func skipsWhatItCannotOrShouldNotUpdate() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app(
            "Safari.app", info: ["CFBundleIdentifier": "com.apple.Safari", "CFBundleShortVersionString": "27.0"])
        try fixture.app(
            "Notion.app",
            info: ["CFBundleIdentifier": "com.apple.Safari.WebApp.48755C8A", "CFBundleShortVersionString": "1.0"])
        try fixture.app("Setapp/CleanShot X.app", info: ["CFBundleIdentifier": "x", "CFBundleShortVersionString": "4"])
        try fixture.app(
            "BlockBlock Installer.app",
            info: [
                "CFBundleIdentifier": "com.objective-see.blockblock.installer", "CFBundleShortVersionString": "2.4.4",
            ])
        try fixture.app("NoID.app", info: ["CFBundleShortVersionString": "1.0"])
        try fixture.app("NoVersion.app", info: ["CFBundleIdentifier": "dev.example.noversion", "CFBundleVersion": " "])
        try fixture.touch(fixture.root.appending(path: "Broken.app/Contents/Info.plist"))

        let result = AppScanner(roots: [fixture.root]).scan()
        #expect(result.apps.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: result.skipped.map { ($0.url.lastPathComponent, $0.reason) })
        #expect(
            reasons == [
                "Safari.app": .appleSystemApp,
                "Notion.app": .safariWebApp,
                "CleanShot X.app": .setapp,
                "BlockBlock Installer.app": .installer,
                "NoID.app": .missingBundleID,
                "NoVersion.app": .missingVersion,
                "Broken.app": .unreadableInfoPlist,
            ])
    }

    @Test func keepsAppleAppsSoldOnTheAppStore() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app(
            "Xcode.app", info: ["CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": "27.0"],
            appStoreReceipt: true)
        let app = try #require(AppScanner(roots: [fixture.root]).scan().apps.first)
        #expect(app.name == "Xcode" && app.signals.isFromAppStore)
    }

    @Test func buildNumberAloneIsEnough() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        try fixture.app("Handler.app", info: ["CFBundleIdentifier": "dev.example.handler", "CFBundleVersion": "1.0"])
        let app = try #require(AppScanner(roots: [fixture.root]).scan().apps.first)
        #expect(app.version.display == "1.0")
    }

    @Test func respectsDepthAndNeverEntersBundles() throws {
        let fixture = try AppFixture()
        defer { fixture.remove() }
        let info = { (id: String) in ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1"] }
        try fixture.app("Top.app", info: info("dev.example.top"))
        try fixture.app("Utilities/Nested.app", info: info("dev.example.nested"))
        try fixture.app("Vendor/Suite/TooDeep.app", info: info("dev.example.deep"))
        try fixture.app("Top.app/Contents/Helpers/Helper.app", info: info("dev.example.helper"))

        let names = AppScanner(roots: [fixture.root]).scan().apps.map(\.name)
        #expect(names == ["Nested", "Top"])
    }

    @Test func missingRootIsNotAnError() {
        let result = AppScanner(roots: [URL(filePath: "/nonexistent-\(UUID().uuidString)")]).scan()
        #expect(result.apps.isEmpty && result.skipped.isEmpty)
    }
}
