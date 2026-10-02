import Foundation

/// A cask Homebrew installed from a third-party tap (`brew install nikitabobko/tap/aerospace`).
/// The public cask API only covers `homebrew/cask`, so these are read from the local tap: the
/// answer is what `brew upgrade` would install as of the last `brew update`.
public struct TapCask: Sendable, Hashable {
    public var token: String
    /// `nikitabobko/tap`
    public var tap: String
    /// The tap's current `version` for the cask, as `short` or `short,build`.
    public var version: String
    /// App bundles the cask installed, by file name (`AeroSpace.app`).
    public var appNames: [String]

    public init(token: String, tap: String, version: String, appNames: [String]) {
        self.token = token
        self.tap = tap
        self.version = version
        self.appNames = appNames
    }
}

enum TapCaskReader {
    /// Reads each cask's install receipt, then its tap's cask file. Only files under
    /// `<prefix>/Library/Taps/` are read, and nothing in them is ever run.
    static func installed(prefixes: [String]) -> [TapCask] {
        var casks: [TapCask] = []
        for prefix in Set(prefixes) {
            let caskroom = URL(filePath: prefix).appending(path: "Caskroom")
            let taps = URL(filePath: prefix).appending(path: "Library/Taps").standardizedFileURL.path + "/"
            let tokens = (try? FileManager.default.contentsOfDirectory(atPath: caskroom.path)) ?? []
            for token in tokens where !token.hasPrefix(".") {
                let receipt = caskroom.appending(path: "\(token)/.metadata/INSTALL_RECEIPT.json")
                guard let data = try? Data(contentsOf: receipt),
                    let cask = read(token: token, receipt: data, tapsRoot: taps)
                else { continue }
                casks.append(cask)
            }
        }
        return casks.sorted { $0.token < $1.token }
    }

    struct Receipt: Decodable {
        struct Source: Decodable {
            var tap: String?
            var path: String?
        }
        var source: Source?
        var uninstallArtifacts: [[String: AnyArtifact]]?

        enum CodingKeys: String, CodingKey {
            case source
            case uninstallArtifacts = "uninstall_artifacts"
        }
    }

    /// An artifact's arguments: strings (paths) mixed with option dictionaries (`target:`).
    struct AnyArtifact: Decodable {
        var strings: [String]
        init(from decoder: any Decoder) throws {
            var container = try decoder.unkeyedContainer()
            var strings: [String] = []
            while !container.isAtEnd {
                if let value = try? container.decode(String.self) {
                    strings.append(value)
                } else {
                    _ = try? container.decode(Skip.self)
                }
            }
            self.strings = strings
        }
        private struct Skip: Decodable {}
    }

    static func read(token: String, receipt data: Data, tapsRoot: String) -> TapCask? {
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
            let tap = receipt.source?.tap, tap != "homebrew/cask", tap != "homebrew/core",
            let path = receipt.source?.path,
            URL(filePath: path).standardizedFileURL.path.hasPrefix(tapsRoot),
            let source = try? String(contentsOfFile: path, encoding: .utf8),
            let version = literalVersion(in: source)
        else { return nil }
        let apps = (receipt.uninstallArtifacts ?? []).flatMap { $0["app"]?.strings.prefix(1) ?? [] }
            .map { URL(filePath: $0).lastPathComponent }
        guard !apps.isEmpty else { return nil }
        return TapCask(token: token, tap: tap, version: version, appNames: apps)
    }

    /// The cask's `version "…"`, only when there is exactly one and it's a plain literal. A
    /// computed, per-CPU or `:latest` version would need Ruby to evaluate, so it's left out.
    static func literalVersion(in source: String) -> String? {
        let lines = source.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let versions = lines.filter { $0.hasPrefix("version ") || $0.hasPrefix("version\t") }
        guard versions.count == 1 else { return nil }
        let value = versions[0].dropFirst("version".count).trimmingCharacters(in: .whitespaces)
        guard let quote = value.first, quote == "\"" || quote == "'",
            let end = value.dropFirst().firstIndex(of: quote)
        else { return nil }
        let literal = String(value[value.index(after: value.startIndex)..<end])
        let rest = value[value.index(after: end)...].trimmingCharacters(in: .whitespaces)
        guard !literal.isEmpty, !literal.contains("#{"), rest.isEmpty || rest.hasPrefix("#") else { return nil }
        return literal
    }
}
