import Foundation

/// Fetches an update archive to disk.
public protocol Downloader: Sendable {
    func fetch(_ download: Download, into directory: URL) async throws -> URL
}

public struct URLSessionDownloader: Downloader {
    /// Larger than any app Ripe should install directly (Xcode-sized downloads go through the App Store).
    static let maxBytes: Int64 = 4_000_000_000
    private let session: URLSession

    public init(userAgent: String = "ripe/\(Ripe.version) (+https://github.com/imrajyavardhan12/ripe)") {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30 * 60
        configuration.httpAdditionalHeaders = ["User-Agent": userAgent]
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func fetch(_ download: Download, into directory: URL) async throws -> URL {
        // Checking an old plain-HTTP feed is tolerated; downloading code over it never is.
        guard download.url.scheme == "https" else {
            throw InstallError(.download, "refusing to download over plain HTTP: \(download.url.absoluteString)")
        }
        let temporary: URL
        let response: URLResponse
        do {
            (temporary, response) = try await session.download(from: download.url)
        } catch {
            throw InstallError(.download, "download failed: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        if let http = response as? HTTPURLResponse {
            guard (200..<300).contains(http.statusCode) else {
                throw InstallError(.download, "download failed: HTTP \(http.statusCode)")
            }
            guard http.url?.scheme == "https" else {
                throw InstallError(.download, "download was redirected to plain HTTP; refusing it")
            }
        }
        let size = (try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size <= Self.maxBytes else {
            throw InstallError(.download, "download is larger than \(Self.maxBytes / 1_000_000_000) GB; refusing it")
        }
        if let expected = download.expectedLength, expected > 0, Int64(expected) != size {
            throw InstallError(
                .download, "download is \(size) bytes but the feed says \(expected); it may be truncated")
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: Self.fileName(for: download.url, response: response))
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination
    }

    /// A safe file name: never a path, never empty. Extensions help with unpacking diagnostics only;
    /// the archive type is detected from the bytes.
    static func fileName(for url: URL, response: URLResponse?) -> String {
        let suggested = response?.suggestedFilename ?? url.lastPathComponent
        let cleaned = suggested.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "download" : cleaned
    }
}
