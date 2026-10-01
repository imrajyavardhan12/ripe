import Foundation

/// Gets the `.app` out of a downloaded archive.
struct Unpacker: Sendable {
    enum Kind: Equatable {
        case zip, diskImage, tarball, installerPackage, unknown
    }

    var runner: any ProcessRunner

    /// Detected from the bytes, never from the file name: URLs like `…/stable` have none.
    static func kind(of file: URL) throws -> Kind {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // A UDIF disk image ends with a 512-byte trailer starting with "koly". Check it first: an
        // image's data can start with anything, including bzip2's "BZh" (GrandPerspective 3.8.1).
        let size = try handle.seekToEnd()
        if size >= 512 {
            try handle.seek(toOffset: size - 512)
            if try handle.read(upToCount: 4) == Data("koly".utf8) { return .diskImage }
        }
        try handle.seek(toOffset: 0)
        let head = try handle.read(upToCount: 8) ?? Data()
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if head.starts(with: Array("xar!".utf8)) { return .installerPackage }
        if head.starts(with: [0x1F, 0x8B]) || head.starts(with: Array("BZh".utf8))
            || head.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        {
            return .tarball
        }
        return .unknown
    }

    /// Extracts the archive inside `workspace` and returns the app whose bundle ID matches.
    func extractApp(from archive: URL, bundleID: String, workspace: URL) async throws -> URL {
        let contents = workspace.appending(path: "contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        switch try Self.kind(of: archive) {
        case .zip:
            // ditto, not unzip: it keeps the symlinks and extended attributes app bundles depend on.
            try await run("/usr/bin/ditto", ["-x", "-k", archive.path, contents.path], stage: "extract the zip")
        case .tarball:
            // bsdtar refuses absolute paths and `..` entries by default.
            try await run("/usr/bin/tar", ["-xf", archive.path, "-C", contents.path], stage: "extract the archive")
        case .diskImage:
            try await copyFromDiskImage(archive, into: contents, workspace: workspace)
        case .installerPackage:
            throw InstallError(.unpack, "the update is a .pkg installer, which runs scripts as root; Ripe won't run it")
        case .unknown:
            throw InstallError(.unpack, "the download isn't a zip, disk image or tar archive")
        }
        return try Self.findApp(bundleID: bundleID, in: contents)
    }

    private func copyFromDiskImage(_ image: URL, into contents: URL, workspace: URL) async throws {
        let mountPoint = workspace.appending(path: "mount", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        // stdin is /dev/null: an image that demands a license agreement fails instead of hanging.
        try await run(
            "/usr/bin/hdiutil",
            [
                "attach", "-nobrowse", "-readonly", "-noautoopen", "-noverify", "-mountpoint", mountPoint.path,
                image.path,
            ],
            stage: "open the disk image (it may require accepting a license; install it manually)"
        )
        var copyError: (any Error)?
        do {
            for app in try FileManager.default.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)
            where app.pathExtension == "app" {
                try await run(
                    "/usr/bin/ditto", [app.path, contents.appending(path: app.lastPathComponent).path],
                    stage: "copy from the disk image")
            }
        } catch {
            copyError = error
        }
        _ = try? await runner.run(URL(filePath: "/usr/bin/hdiutil"), ["detach", mountPoint.path, "-force"])
        if let copyError { throw copyError }
    }

    /// The app with the installed app's bundle ID, at most two folders deep, never inside another app.
    static func findApp(bundleID: String, in directory: URL, depth: Int = 0) throws -> URL {
        var matches: [URL] = []
        func search(_ folder: URL, _ depth: Int) {
            let entries =
                (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                if entry.pathExtension == "app" {
                    if BundleInfo(url: entry)?.bundleID.lowercased() == bundleID.lowercased() { matches.append(entry) }
                } else if depth < 2, (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                    (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
                {
                    search(entry, depth + 1)
                }
            }
        }
        search(directory, depth)
        guard matches.count == 1, let app = matches.first else {
            throw InstallError(
                .unpack,
                matches.isEmpty
                    ? "the download doesn't contain an app with bundle ID \(bundleID)"
                    : "the download contains \(matches.count) copies of \(bundleID); not guessing which one")
        }
        return app
    }

    private func run(_ tool: String, _ arguments: [String], stage: String) async throws {
        let result = try await runner.run(URL(filePath: tool), arguments)
        guard result.succeeded else {
            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError(.unpack, "couldn't \(stage)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }
}

/// The few Info.plist fields the installer checks on a new bundle.
struct BundleInfo: Sendable, Hashable {
    var bundleID: String
    var version: AppVersion

    init?(url: URL) {
        guard let data = try? Data(contentsOf: url.appending(path: "Contents/Info.plist")),
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = plist["CFBundleIdentifier"] as? String
        else { return nil }
        self.bundleID = bundleID
        self.version = AppVersion(
            short: plist["CFBundleShortVersionString"] as? String,
            build: plist["CFBundleVersion"] as? String
        )
    }
}
