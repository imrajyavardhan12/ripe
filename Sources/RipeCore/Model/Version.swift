import Foundation

/// A parsed app version.
///
/// Comparison follows Sparkle's conventions, so Ripe agrees with what an app's own
/// updater would decide: numbers compare numerically, missing trailing components
/// count as zero (`1.2` equals `1.2.0`), and a pre-release sorts before its release
/// (`1.0b3` is older than `1.0`).
///
/// `Version` is deliberately not `Comparable`. Some pairs can't be ordered (two
/// unrelated pre-release tags, for example), and forcing an answer is how update
/// checkers report false updates. Use ``order(comparedTo:)`` and handle `nil`.
public struct Version: Sendable, Hashable, CustomStringConvertible {
    /// The string exactly as the app or source wrote it.
    public let raw: String
    /// Leading numeric components: `[1, 96, 59]` for `1.96.59-beta2`.
    let release: [Int]
    /// Everything after the first pre-release tag: `[.tag(.beta), .number(2)]`.
    let prerelease: [Token]

    enum Token: Hashable, Sendable {
        case number(Int)
        case tag(Tag)
    }

    enum Tag: Hashable, Sendable {
        case dev, alpha, beta, preview, rc
        case other(String)

        /// Known tags order dev < alpha < beta < preview < rc. Unknown tags have no rank.
        var rank: Int? {
            switch self {
            case .dev: 0
            case .alpha: 1
            case .beta: 2
            case .preview: 3
            case .rc: 4
            case .other: nil
            }
        }

        init(_ word: String) {
            switch word {
            case "dev", "d", "nightly", "snapshot", "canary": self = .dev
            case "alpha", "a": self = .alpha
            case "beta", "b": self = .beta
            case "pre", "preview": self = .preview
            case "rc": self = .rc
            default: self = .other(word)
            }
        }
    }

    /// Words that carry no ordering meaning and are dropped: `2.0 build 5` reads as `2.0.5`.
    private static let noiseWords: Set<String> = ["build", "release", "final", "stable", "version", "ver"]

    /// Parses `raw`, returning `nil` when it has no leading number (`b40acce58`, `latest`, `""`),
    /// since nothing can be concluded from such a version.
    public init?(_ raw: String) {
        self.raw = raw
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Build metadata (`0.4.24+1`), parenthesized notes (`5.0 (1234)`) and colon-wrapped
        // commit hashes (Vienna's `3.10.8 :0294d207:`) don't affect order.
        if let cut = text.firstIndex(where: { $0 == "+" || $0 == "(" }) {
            text = String(text[..<cut])
        }
        if let hash = text.range(of: " :") {
            text = String(text[..<hash.lowerBound])
        }
        // A commit hash isn't a version, even one that starts with digits (Ghostty tip `0081d4530`
        // would otherwise read as 81 plus a tag, and `1a2b3c4` as a 1.x release).
        if (7...40).contains(text.count), text.allSatisfy(\.isHexDigit), text.contains(where: \.isLetter) {
            return nil
        }
        if text.first == "v", text.dropFirst().first?.isASCIINumber == true {
            text.removeFirst()
        }

        var release: [Int] = []
        var prerelease: [Token] = []
        for word in Self.words(in: text) where !Self.noiseWords.contains(word) {
            if let number = Int(word) {
                if prerelease.isEmpty { release.append(number) } else { prerelease.append(.number(number)) }
            } else if word.first?.isASCIINumber == true {
                return nil  // numeric run too large for Int
            } else if release.isEmpty {
                return nil  // leading letters: a hash or a codename
            } else {
                prerelease.append(.tag(Tag(word)))
            }
        }
        guard !release.isEmpty else { return nil }
        self.release = release
        self.prerelease = prerelease
    }

    /// Builds a version from already-parsed parts (OS versions, scheme alignment).
    init(release: [Int], prerelease: [Token] = [], raw: String? = nil) {
        precondition(!release.isEmpty, "A version needs at least one numeric component")
        self.release = release
        self.prerelease = prerelease
        self.raw = raw ?? release.map(String.init).joined(separator: ".")
    }

    /// Splits into runs of digits and runs of letters; anything else is a separator.
    private static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var currentIsNumber = false
        for character in text {
            let isNumber = character.isASCIINumber
            let isLetter = character.isLetter
            if !isNumber && !isLetter {
                if !current.isEmpty { words.append(current) }
                current = ""
                continue
            }
            if !current.isEmpty && isNumber != currentIsNumber {
                words.append(current)
                current = ""
            }
            current.append(character)
            currentIsNumber = isNumber
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    public var description: String { raw }

    public var isPrerelease: Bool { !prerelease.isEmpty }

    /// How `self` relates to `other`, or `nil` when the two can't be ordered.
    ///
    /// `installed.order(comparedTo: latest) == .older` means an update is available.
    public func order(comparedTo other: Version) -> VersionOrder? {
        let length = max(release.count, other.release.count)
        for index in 0..<length {
            let mine = index < release.count ? release[index] : 0
            let theirs = index < other.release.count ? other.release[index] : 0
            if mine != theirs { return mine < theirs ? .older : .newer }
        }
        return Self.orderPrerelease(prerelease, other.prerelease)
    }

    private static func orderPrerelease(_ lhs: [Token], _ rhs: [Token]) -> VersionOrder? {
        switch (lhs.isEmpty, rhs.isEmpty) {
        case (true, true): return .same
        case (true, false): return .newer  // 1.0 is newer than 1.0b3
        case (false, true): return .older
        case (false, false): break
        }
        for index in 0..<max(lhs.count, rhs.count) {
            let mine = index < lhs.count ? lhs[index] : nil
            let theirs = index < rhs.count ? rhs[index] : nil
            switch (mine, theirs) {
            case (.number(let a)?, .number(let b)?):
                if a != b { return a < b ? .older : .newer }
            case (.number(let a)?, nil):
                if a != 0 { return .newer }  // 1.0b2 is newer than 1.0b
            case (nil, .number(let b)?):
                if b != 0 { return .older }
            case (.tag(let a)?, .tag(let b)?):
                if a == b { continue }
                guard let rankA = a.rank, let rankB = b.rank else { return nil }
                return rankA < rankB ? .older : .newer
            default:
                return nil  // a number against a tag, or a trailing tag: no safe answer
            }
        }
        return .same
    }
}

public enum VersionOrder: String, Sendable, Codable {
    case older, same, newer
}

extension Version: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let version = Version(raw) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unparseable version \"\(raw)\"")
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension Character {
    fileprivate var isASCIINumber: Bool { isASCII && isNumber }
}
