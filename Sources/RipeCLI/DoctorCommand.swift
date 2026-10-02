import ArgumentParser
import Foundation
import RipeCore

/// `ripe doctor`: checks everything Ripe depends on. The first thing to paste into a bug report.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check what Ripe depends on: app folders, Homebrew, mas, update sources and settings.",
        discussion: "Exits with status 1 when something stops Ripe from working properly."
    )

    func run() async throws {
        let terminal = Terminal.current()
        let showProgress = isatty(STDERR_FILENO) == 1
        if showProgress { FileHandle.standardError.write(Data("Checking…".utf8)) }
        let checks = await Doctor.live().run()
        if showProgress { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }

        print(DoctorRenderer(terminal: terminal).render(checks, machine: Machine.current()))
        if checks.contains(where: { $0.status == .problem }) {
            throw ExitCode.failure
        }
    }
}

struct DoctorRenderer {
    var terminal: Terminal

    func render(_ checks: [DoctorCheck], machine: Machine) -> String {
        let os = machine.macOSVersion.description
        let cpu = machine.architecture == .arm64 ? "Apple silicon" : "Intel"
        var lines = ["ripe \(Ripe.version) · macOS \(os) · \(cpu)", ""]
        let width = checks.map(\.name.count).max() ?? 0
        for check in checks {
            let name = check.name.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("\(symbol(check.status)) \(name)  \(check.detail)")
            if let hint = check.hint, check.status != .ok {
                lines.append("  \(String(repeating: " ", count: width))  \(terminal.style(hint, .dim))")
            }
        }
        let problems = checks.filter { $0.status == .problem }.count
        let warnings = checks.filter { $0.status == .warning }.count
        lines.append("")
        lines.append(
            problems + warnings == 0
                ? "Everything Ripe needs is in place."
                : [
                    problems > 0 ? "\(problems) problem\(problems == 1 ? "" : "s")" : nil,
                    warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil,
                ]
                .compactMap { $0 }.joined(separator: ", ") + ".")
        return lines.joined(separator: "\n")
    }

    private func symbol(_ status: DoctorCheck.Status) -> String {
        switch status {
        case .ok: terminal.style("✓", .green)
        case .info: terminal.style("·", .dim)
        case .warning: terminal.style("!", .yellow)
        case .problem: terminal.style("✗", .red)
        }
    }
}
