import CryptoKit
import Foundation
import Testing

@testable import RipeCore

/// A temp folder with helpers for building bundles and archives the way real downloads look.
struct Sandbox {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "ripe-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func url(_ path: String) -> URL { root.appending(path: path) }

    @discardableResult
    func app(_ path: String, bundleID: String = "dev.example.tool", version: String, build: String? = nil) throws -> URL
    {
        let bundle = url(path)
        try FileManager.default.createDirectory(
            at: bundle.appending(path: "Contents"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version]
        info["CFBundleVersion"] = build
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundle.appending(path: "Contents/Info.plist"))
        return bundle
    }

    /// `ditto -c -k --keepParent`, the way most Mac apps ship as zips.
    func zip(_ bundle: URL, to name: String) async throws -> URL {
        let archive = url(name)
        let result = try await LiveProcessRunner()
            .run(URL(filePath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", bundle.path, archive.path])
        try #require(result.succeeded, "ditto failed: \(result.errorOutput)")
        return archive
    }

    func diskImage(_ bundle: URL, to name: String) async throws -> URL {
        let archive = url(name)
        let result = try await LiveProcessRunner().run(
            URL(filePath: "/usr/bin/hdiutil"),
            ["create", "-quiet", "-srcfolder", bundle.path, "-format", "UDZO", "-volname", "Test", archive.path])
        try #require(result.succeeded, "hdiutil failed: \(result.errorOutput)")
        return archive
    }
}

/// Serves a prepared archive as if it had been downloaded.
struct FakeDownloader: Downloader {
    var archive: URL

    func fetch(_ download: Download, into directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: archive.lastPathComponent)
        try FileManager.default.copyItem(at: archive, to: destination)
        return destination
    }
}

/// Signing identities by bundle path, so tests can stage mismatches without real certificates.
struct FakeSignatures: CodeSignatureChecking {
    var installed: SigningIdentity
    var download: SigningIdentity
    var installedPassesGatekeeper = true
    var downloadPassesGatekeeper = true

    func identity(of bundle: URL) throws -> SigningIdentity { installed }
    func validatedIdentity(of bundle: URL) throws -> SigningIdentity { download }
    func passesGatekeeper(_ bundle: URL) async -> Bool {
        bundle.path.contains("/Applications/") ? installedPassesGatekeeper : downloadPassesGatekeeper
    }
}

actor FakeApps: RunningAppControl {
    var running: Bool
    var refusesToQuit: Bool
    private(set) var launched: [URL] = []

    init(running: Bool = false, refusesToQuit: Bool = false) {
        self.running = running
        self.refusesToQuit = refusesToQuit
    }

    func isRunning(_ app: InstalledApp) async -> Bool { running }
    func quit(_ app: InstalledApp, timeout: Duration) async -> Bool {
        if !refusesToQuit { running = false }
        return !running
    }
    func launch(_ url: URL) async { launched.append(url) }
}

/// A Trash that's just a folder, so tests never touch the real one.
struct FolderTrash: Trash {
    var folder: URL

    func trash(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "\(UUID().uuidString)-\(url.lastPathComponent)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// Records commands instead of running them (brew, mas, open); delegates file tools to the real runner.
actor RecordingRunner: ProcessRunner {
    private(set) var commands: [[String]] = []
    var status: Int32 = 0

    init(status: Int32 = 0) { self.status = status }

    func run(_ executable: URL, _ arguments: [String], interactive: Bool) async throws -> ProcessResult {
        let tool = executable.lastPathComponent
        if ["ditto", "tar", "hdiutil"].contains(tool) {
            return try await LiveProcessRunner().run(executable, arguments, interactive: interactive)
        }
        commands.append([tool] + arguments)
        return ProcessResult(status: status, output: "", errorOutput: "")
    }
}

enum TestKeys {
    /// A Sparkle-style Ed25519 key pair and a signature over `data`, all base64 like in a feed.
    static func sign(_ data: Data) throws -> (publicKey: String, signature: String) {
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: data)
        return (key.publicKey.rawRepresentation.base64EncodedString(), signature.base64EncodedString())
    }
}
