import ArgumentParser
import Foundation
import RipeCore

/// Shell completion for app names (`ripe pick Pro<TAB>`). Runs on every TAB, so it stays local: a
/// folder scan takes milliseconds; asking which apps are ripe would need the network.
///
/// App names are untrusted: anyone who can drop a bundle in ~/Applications chooses one. The
/// argument parser hands candidates to the shell unescaped, so `escaped(_:for:)` does it here.
enum AppCompletion {
    /// Installed apps Ripe checks, by Finder name.
    static let installed = CompletionKind.custom { _, _, _ in
        escaped(installedNames(), for: CompletionShell.requesting)
    }
    /// Every app `ripe why` can explain, including the ones Ripe doesn't check (Apple, Setapp).
    static let explainable = CompletionKind.custom { _, _, _ in
        escaped(installedNames(includingSkipped: true), for: CompletionShell.requesting)
    }
    /// Apps on the skip list, by the name they were skipped under.
    static let skipped = CompletionKind.custom { _, _, _ in
        escaped(skippedNames(), for: CompletionShell.requesting)
    }

    static func installedNames(scanner: AppScanner = AppScanner(), includingSkipped: Bool = false) -> [String] {
        let result = scanner.scan()
        let skipped = includingSkipped ? result.skipped.map { $0.url.deletingPathExtension().lastPathComponent } : []
        return unique(result.apps.map(\.name) + skipped)
    }

    /// An unreadable skip list completes nothing; `ripe unskip` itself reports the error.
    static func skippedNames(store: SkipStore = SkipStore(url: SkipStore.defaultURL())) -> [String] {
        unique((try? store.load())?.apps.values.map(\.name) ?? [])
    }

    static func escaped(_ names: [String], for shell: CompletionShell?) -> [String] {
        if shell == .bash {
            // `compgen -W` expands each word, so `$(…)` in a name would run: escape it once.
            // Readline quotes the result on insertion (`complete -o filenames`): `LM\ Studio`.
            return names.map(backslashed)
        }
        if shell == .zsh {
            // `_describe` reads `name:description`; a `/` in a Finder name is a `:` on disk.
            return names.map {
                $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
            }
        }
        return names  // fish takes each line literally
    }

    /// Every ASCII character that isn't a letter or digit gets a backslash; to a shell that's
    /// the character itself.
    private static func backslashed(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isASCII, !character.isLetter, !character.isNumber { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// Two copies of an app share a name; offer it once.
    private static func unique(_ names: [String]) -> [String] {
        Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
