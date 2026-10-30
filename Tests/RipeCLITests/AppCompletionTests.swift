import ArgumentParser
import Foundation
import RipeCore
import Testing

@testable import RipeCLI

struct AppCompletionTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "ripe-completion-\(UUID().uuidString)")

    func app(_ relativePath: String, id: String) throws {
        let contents = root.appending(path: relativePath).appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleShortVersionString": "1.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }

    @Test func offersEachInstalledAppOnceInFinderOrder() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try app("Zed.app", id: "dev.zed.Zed")
        try app("Proton Pass.app", id: "me.proton.pass")
        try app("Folio.app", id: "test.folio")
        try app("Copies/Folio.app", id: "test.folio.copy")

        let names = AppCompletion.installedNames(scanner: AppScanner(roots: [root]))
        #expect(names == ["Folio", "Proton Pass", "Zed"])
    }

    @Test func whyAlsoOffersAppsRipeDoesNotCheck() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try app("Zed.app", id: "dev.zed.Zed")
        try app("Safari.app", id: "com.apple.Safari")
        let scanner = AppScanner(roots: [root])

        #expect(AppCompletion.installedNames(scanner: scanner) == ["Zed"])
        #expect(AppCompletion.installedNames(scanner: scanner, includingSkipped: true) == ["Safari", "Zed"])
    }

    /// App names are chosen by whoever made the bundle. Bash's `compgen -W` expands each candidate,
    /// so a name like this ran `touch` on TAB before escaping.
    @Test(arguments: [
        ("Zed", #"Zed"#, "Zed"),
        ("LM Studio", #"LM\ Studio"#, #"LM Studio"#),
        ("Ev$(touch MARK)", #"Ev\$\(touch\ MARK\)"#, "Ev$(touch MARK)"),
        ("Baldur's Gate 3", #"Baldur\'s\ Gate\ 3"#, "Baldur's Gate 3"),
        ("AC:DC", #"AC\:DC"#, #"AC\:DC"#),
        (#"Back\slash"#, #"Back\\slash"#, #"Back\\slash"#),
        ("Café", #"Café"#, "Café"),
    ])
    func escapesNamesForEachShell(name: String, bash: String, zsh: String) {
        #expect(AppCompletion.escaped([name], for: .bash) == [bash])
        #expect(AppCompletion.escaped([name], for: .zsh) == [zsh])
        #expect(AppCompletion.escaped([name], for: .fish) == [name])
    }

    @Test func offersSkippedApps() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try app("Raycast.app", id: "com.raycast.macos")
        let app = try #require(AppScanner(roots: [root]).scan().apps.first)
        let store = SkipStore(url: root.appending(path: "skips.json"))
        var list = SkipList()
        list.skipAlways(app)
        try store.save(list)

        #expect(AppCompletion.skippedNames(store: store) == ["Raycast"])
    }

    @Test func unreadableSkipListCompletesNothing() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "skips.json")
        try Data("not json".utf8).write(to: url)

        #expect(AppCompletion.skippedNames(store: SkipStore(url: url)).isEmpty)
    }
}
