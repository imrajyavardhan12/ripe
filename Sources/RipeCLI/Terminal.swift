import Foundation

/// What the output stream supports. Resolved once per run and passed down, so renderers stay pure.
public struct Terminal: Sendable {
    public var color: Bool
    public var width: Int?

    public init(color: Bool, width: Int? = nil) {
        self.color = color
        self.width = width
    }

    /// Color only on an interactive terminal, and never when `NO_COLOR` is set (https://no-color.org).
    public static func current(environment: [String: String] = ProcessInfo.processInfo.environment) -> Terminal {
        let isTTY = isatty(STDOUT_FILENO) == 1
        let noColor = environment["NO_COLOR"].map { !$0.isEmpty } ?? false
        var size = winsize()
        let width = isTTY && ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : nil
        return Terminal(color: isTTY && !noColor && environment["TERM"] != "dumb", width: width)
    }

    public enum Style: String, Sendable {
        case bold = "1"
        case dim = "2"
        case green = "32"
        case yellow = "33"
        case red = "31"
    }

    public func style(_ text: String, _ style: Style) -> String {
        color ? "\u{1B}[\(style.rawValue)m\(text)\u{1B}[0m" : text
    }
}
