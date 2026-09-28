import CryptoKit
import Foundation

/// A small on-disk store: one body file plus one metadata file per key.
///
/// Every write is atomic, so a crash or a concurrent `ripe` run leaves either the old entry or
/// the new one, never a torn file. A corrupt or unreadable entry reads as a miss.
public actor DiskCache {
    public struct Metadata: Codable, Sendable, Hashable {
        public var url: URL?
        public var etag: String?
        public var lastModified: String?
        public var fetchedAt: Date
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `~/Library/Caches/ripe`, or `RIPE_CACHE_DIR` when set.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["RIPE_CACHE_DIR"], !override.isEmpty {
            return URL(filePath: override, directoryHint: .isDirectory)
        }
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches")
        return caches.appending(path: "ripe", directoryHint: .isDirectory)
    }

    /// A filesystem-safe key for any string (URLs, derived-data names).
    public static func key(for text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    public func load(_ key: String) -> (metadata: Metadata, body: Data)? {
        guard let metadataData = try? Data(contentsOf: metadataURL(key)),
            let metadata = try? JSONDecoder().decode(Metadata.self, from: metadataData),
            // Mapped, not read: a 19 MB body costs nothing until someone touches it.
            let body = try? Data(contentsOf: bodyURL(key), options: .alwaysMapped)
        else { return nil }
        return (metadata, body)
    }

    public func store(_ key: String, metadata: Metadata, body: Data) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Body first: a metadata file never points at a missing or older body.
            try body.write(to: bodyURL(key), options: .atomic)
            try JSONEncoder().encode(metadata).write(to: metadataURL(key), options: .atomic)
        } catch {
            // A cache that can't be written only costs speed; never fail a check over it.
        }
    }

    public func touch(_ key: String, fetchedAt: Date) {
        guard var entry = load(key) else { return }
        entry.metadata.fetchedAt = fetchedAt
        try? JSONEncoder().encode(entry.metadata).write(to: metadataURL(key), options: .atomic)
    }

    private func bodyURL(_ key: String) -> URL { directory.appending(path: "\(key).body") }
    private func metadataURL(_ key: String) -> URL { directory.appending(path: "\(key).json") }
}
