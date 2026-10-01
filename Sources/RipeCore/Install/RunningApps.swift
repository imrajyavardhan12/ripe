import AppKit
import Foundation

/// Quitting and relaunching the app being updated.
public protocol RunningAppControl: Sendable {
    func isRunning(_ app: InstalledApp) async -> Bool
    /// Asks politely, like choosing Quit from the menu, so the app can save work or refuse.
    /// Never force-quits. Returns whether it's gone within `timeout`.
    func quit(_ app: InstalledApp, timeout: Duration) async -> Bool
    func launch(_ url: URL) async
}

public struct WorkspaceAppControl: RunningAppControl {
    public init() {}

    public func isRunning(_ app: InstalledApp) async -> Bool {
        await MainActor.run { !Self.instances(of: app).isEmpty }
    }

    public func quit(_ app: InstalledApp, timeout: Duration) async -> Bool {
        let asked = await MainActor.run { () -> Bool in
            let instances = Self.instances(of: app)
            for instance in instances { instance.terminate() }
            return !instances.isEmpty
        }
        guard asked else { return true }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await !isRunning(app) { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await !isRunning(app)
    }

    public func launch(_ url: URL) async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// Instances of exactly this copy: another copy with the same bundle ID elsewhere is left alone.
    @MainActor private static func instances(of app: InstalledApp) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).filter {
            $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL
                == app.url.resolvingSymlinksInPath().standardizedFileURL
        }
    }
}
