import Foundation

/// Why an install stopped. Every message is written for the person at the terminal and says
/// what state their app is in, because "did it break my app?" is the first question.
public struct InstallError: Error, Sendable, Hashable, CustomStringConvertible {
    public enum Stage: String, Sendable, Hashable {
        case plan, download, integrity, unpack, verify, quit, replace, handOff
    }

    public var stage: Stage
    public var message: String

    public init(_ stage: Stage, _ message: String) {
        self.stage = stage
        self.message = message
    }

    public var description: String { message }
}
