import Foundation

/// Debug logging for `--verbose`. Always stderr, so stdout stays clean for results and JSON.
public struct Logger: Sendable {
    private let sink: (@Sendable (String) -> Void)?

    public init(sink: (@Sendable (String) -> Void)?) {
        self.sink = sink
    }

    public static let silent = Logger(sink: nil)

    public static let standardError = Logger { message in
        FileHandle.standardError.write(Data("ripe: \(message)\n".utf8))
    }

    public var isEnabled: Bool { sink != nil }

    public func debug(_ message: @autoclosure () -> String) {
        sink?(message())
    }
}

extension URL {
    /// A URL from a literal that is known to be valid. Traps on a typo, which tests catch.
    init(staticString literal: StaticString) {
        guard let url = URL(string: "\(literal)") else { preconditionFailure("Invalid URL literal: \(literal)") }
        self = url
    }
}
