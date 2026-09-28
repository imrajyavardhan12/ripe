/// Left-aligned columns separated by two spaces. Cells may contain ANSI styling;
/// widths are measured on the visible text.
struct TextTable {
    var header: [String]
    var rows: [[String]] = []

    func render(terminal: Terminal) -> String {
        let all = [header] + rows
        let columns = all.map(\.count).max() ?? 0
        let widths = (0..<columns).map { column in
            all.map { $0.indices.contains(column) ? Self.visibleWidth($0[column]) : 0 }.max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                let isLast = index == cells.count - 1
                return isLast ? cell : cell + String(repeating: " ", count: widths[index] - Self.visibleWidth(cell))
            }
            .joined(separator: "  ")
        }
        let styledHeader = header.map { terminal.style($0, .bold) }
        return ([line(styledHeader)] + rows.map(line)).joined(separator: "\n")
    }

    /// Character count ignoring ANSI escape sequences.
    static func visibleWidth(_ text: String) -> Int {
        var width = 0
        var inEscape = false
        for character in text {
            if inEscape {
                if character == "m" { inEscape = false }
            } else if character == "\u{1B}" {
                inEscape = true
            } else {
                width += 1
            }
        }
        return width
    }
}
