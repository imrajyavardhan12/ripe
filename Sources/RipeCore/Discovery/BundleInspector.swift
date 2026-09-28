import Foundation

/// Why a bundle was left out of the report. Kept so `ripe why` can answer "why isn't X listed?".
public enum SkipReason: String, Sendable, Hashable, Codable {
    /// `com.apple.*` without an App Store receipt: updated by macOS itself.
    case appleSystemApp
    /// A Safari "Add to Dock" web app.
    case safariWebApp
    /// Lives in `/Applications/Setapp`, which Setapp keeps updated.
    case setapp
    /// A vendor installer or uninstaller, not the app itself.
    case installer
    case missingBundleID
    case missingVersion
    case unreadableInfoPlist
}

public struct SkippedBundle: Sendable, Hashable, Codable {
    public let url: URL
    public let reason: SkipReason

    public init(url: URL, reason: SkipReason) {
        self.url = url
        self.reason = reason
    }
}

/// Reads one `.app` bundle into an ``InstalledApp``. Never throws: a bad bundle is a skip, not a failure.
enum BundleInspector {
    enum Inspection: Sendable, Hashable {
        case app(InstalledApp)
        case skipped(SkipReason)
    }

    static func inspect(_ url: URL) -> Inspection {
        let fileManager = FileManager.default
        let name = url.deletingPathExtension().lastPathComponent

        if url.deletingLastPathComponent().lastPathComponent == "Setapp" {
            return .skipped(.setapp)
        }
        if name.hasSuffix(" Installer") || name.hasSuffix(" Uninstaller") {
            return .skipped(.installer)
        }

        // iPhone/iPad apps on Apple silicon keep a plain iOS bundle inside `Wrapper/`.
        let wrapper = url.appending(path: "Wrapper", directoryHint: .isDirectory)
        let wrappedBundle = (try? fileManager.contentsOfDirectory(at: wrapper, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "app" }
        let infoPlistURL =
            wrappedBundle?.appending(path: "Info.plist")
            ?? url.appending(path: "Contents/Info.plist")

        guard let data = try? Data(contentsOf: infoPlistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return .skipped(.unreadableInfoPlist)
        }

        guard let bundleID = (plist["CFBundleIdentifier"] as? String)?.nilIfBlank else {
            return .skipped(.missingBundleID)
        }
        if bundleID.hasPrefix("com.apple.Safari.WebApp.") {
            return .skipped(.safariWebApp)
        }

        let version = AppVersion(
            short: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String
        )
        guard version.short != nil || version.build != nil else {
            return .skipped(.missingVersion)
        }

        let contents = url.appending(path: "Contents", directoryHint: .isDirectory)
        let appStoreReceipt = fileManager.fileExists(atPath: contents.appending(path: "_MASReceipt/receipt").path)
        // Apple's own apps update with macOS, except the ones sold on the App Store (Xcode, Pages, Logic...).
        if bundleID.hasPrefix("com.apple."), !appStoreReceipt {
            return .skipped(.appleSystemApp)
        }
        let signals = InstalledApp.Signals(
            appStoreReceipt: appStoreReceipt,
            wrappedIOSApp: wrappedBundle != nil,
            sparkleFeedURL: (plist["SUFeedURL"] as? String)?.nilIfBlank.flatMap(URL.init(string:)),
            sparklePublicEDKey: (plist["SUPublicEDKey"] as? String)?.nilIfBlank,
            electronUpdater: fileManager.fileExists(atPath: contents.appending(path: "Resources/app-update.yml").path)
        )
        return .app(InstalledApp(name: name, bundleID: bundleID, url: url, version: version, signals: signals))
    }
}
