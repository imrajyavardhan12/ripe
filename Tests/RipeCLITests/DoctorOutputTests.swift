import Foundation
import RipeCore
import Testing

@testable import RipeCLI

struct DoctorOutputTests {
    let renderer = DoctorRenderer(terminal: Terminal(color: false))

    func machine() throws -> Machine {
        Machine(macOSVersion: try #require(Version("27.0.1")), architecture: .arm64, storeCountry: "in")
    }

    @Test func alignsChecksAndShowsHintsOnlyForNonOK() throws {
        let checks = [
            DoctorCheck("Apps", .ok, "28 in /Applications", hint: "never shown"),
            DoctorCheck("mas", .info, "not installed", hint: "`brew install mas`"),
            DoctorCheck("Homebrew data", .warning, "unreachable; using the cached copy", hint: "May be out of date."),
            DoctorCheck("Skips", .problem, "~/.config/ripe/skips.json can't be read"),
        ]
        #expect(
            renderer.render(checks, machine: try machine()) == """
                ripe \(Ripe.version) · macOS 27.0.1 · Apple silicon

                ✓ Apps           28 in /Applications
                · mas            not installed
                                 `brew install mas`
                ! Homebrew data  unreachable; using the cached copy
                                 May be out of date.
                ✗ Skips          ~/.config/ripe/skips.json can't be read

                1 problem, 1 warning.
                """)
    }

    @Test func saysSoWhenAllIsWell() throws {
        let output = renderer.render([DoctorCheck("Apps", .ok, "3 in /Applications")], machine: try machine())
        #expect(output.hasSuffix("Everything Ripe needs is in place."))
    }
}
