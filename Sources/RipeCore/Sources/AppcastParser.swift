import Foundation

/// One `<item>` of a Sparkle appcast, reduced to what update checking needs.
struct AppcastItem: Sendable, Hashable {
    var title: String?
    /// `sparkle:version`: compared against `CFBundleVersion`.
    var version: String?
    /// `sparkle:shortVersionString`: what people see.
    var shortVersion: String?
    var channel: String?
    var minimumSystemVersion: String?
    var maximumSystemVersion: String?
    var hardwareRequirements: [String] = []
    var isInformational = false
    var enclosureURL: URL?
    /// `sparkle:os` on the enclosure; cross-platform feeds list Windows builds too.
    var operatingSystem: String?
    var releaseNotesURL: URL?
    var publishedAt: Date?
    /// `sparkle:edSignature` on the enclosure: Ed25519 over the archive, base64.
    var edSignature: String?
    var length: Int?
    /// `sparkle:installationType`; `package` means a `.pkg` installer.
    var installationType: String?
}

/// Parses Sparkle appcasts. Feeds are untrusted input: external entities stay unresolved and
/// nothing in a feed is ever executed or passed to a shell.
enum AppcastParser {
    struct ParseError: Error, CustomStringConvertible {
        var description: String
    }

    static func parse(_ data: Data) throws -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false  // keep `sparkle:` prefixes in element names
        parser.delegate = delegate
        guard parser.parse() else {
            throw ParseError(
                description: "malformed appcast: \(parser.parserError?.localizedDescription ?? "unknown error")")
        }
        return delegate.items
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        /// Inside `<sparkle:deltas>`: patches against one older build, never the full archive.
        private var inDeltas = false

        private let dateFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            return formatter
        }()

        func parser(
            _ parser: XMLParser,
            didStartElement element: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            text = ""
            if element == "item" {
                current = AppcastItem()
            } else if element == "sparkle:deltas" {
                inDeltas = true
            } else if element == "enclosure", current != nil, !inDeltas, attributes["sparkle:deltaFrom"] == nil,
                Self.shouldTake(attributes, over: current)
            {
                // Older feeds put versions on the enclosure instead of in elements.
                current?.enclosureURL = attributes["url"].flatMap(URL.init(string:))
                current?.operatingSystem = attributes["sparkle:os"]
                current?.edSignature = attributes["sparkle:edSignature"]?.nilIfBlank
                current?.length = attributes["length"].flatMap { Int($0) }
                if let type = attributes["sparkle:installationType"] { current?.installationType = type }
                if current?.version == nil { current?.version = attributes["sparkle:version"]?.nilIfBlank }
                if current?.shortVersion == nil {
                    current?.shortVersion = attributes["sparkle:shortVersionString"]?.nilIfBlank
                }
            } else if element == "sparkle:informationalUpdate" {
                current?.isInformational = true
            }
        }

        /// The first full archive wins, except that a macOS one replaces another platform's
        /// (cross-platform feeds list a Windows build in the same item).
        private static func shouldTake(_ attributes: [String: String], over item: AppcastItem?) -> Bool {
            guard let item, item.enclosureURL != nil else { return true }
            return !isMac(item.operatingSystem) && isMac(attributes["sparkle:os"])
        }

        private static func isMac(_ os: String?) -> Bool {
            os.map { ["macos", "osx"].contains($0.lowercased()) } ?? true
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
            text += String(decoding: cdataBlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            if element == "sparkle:deltas" { inDeltas = false }
            guard current != nil else { return }
            let value = text.nilIfBlank
            switch element {
            case "item":
                if let item = current { items.append(item) }
                current = nil
            case "title": current?.title = value
            case "sparkle:version": current?.version = value ?? current?.version
            case "sparkle:shortVersionString": current?.shortVersion = value ?? current?.shortVersion
            case "sparkle:channel": current?.channel = value
            case "sparkle:installationType": current?.installationType = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "sparkle:maximumSystemVersion": current?.maximumSystemVersion = value
            case "sparkle:hardwareRequirements":
                current?.hardwareRequirements = (value ?? "").split(separator: ",").compactMap {
                    String($0).nilIfBlank
                }
            case "sparkle:releaseNotesLink": current?.releaseNotesURL = value.flatMap(URL.init(string:))
            case "pubDate": current?.publishedAt = value.flatMap(dateFormatter.date(from:))
            default: break
            }
            text = ""
        }
    }
}
