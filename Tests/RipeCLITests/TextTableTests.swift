import Testing

@testable import RipeCLI

struct TextTableTests {
    @Test func alignsColumnsWithoutTrailingSpaces() {
        var table = TextTable(header: ["App", "Version"])
        table.rows = [["OBS", "32.2.2"], ["Visual Studio Code", "1.139.1"]]
        #expect(
            table.render(terminal: Terminal(color: false)) == """
                App                 Version
                OBS                 32.2.2
                Visual Studio Code  1.139.1
                """)
    }

    @Test func measuresStyledCellsByVisibleText() {
        let terminal = Terminal(color: true)
        var table = TextTable(header: ["A", "B"])
        table.rows = [[terminal.style("xx", .green), "y"]]
        let lines = table.render(terminal: terminal).split(separator: "\n")
        #expect(TextTable.visibleWidth(String(lines[0])) == TextTable.visibleWidth(String(lines[1])))
    }

    @Test func noEscapesWithoutColor() {
        #expect(Terminal(color: false).style("x", .bold) == "x")
    }
}
