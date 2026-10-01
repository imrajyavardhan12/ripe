import Foundation

/// Moves things to the Trash. Behind a protocol so tests never touch the real Trash.
public protocol Trash: Sendable {
    /// Returns where the item ended up, so it can be put back.
    func trash(_ url: URL) throws -> URL
}

public struct SystemTrash: Trash {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return (resulting as URL?) ?? url
    }
}

/// Swaps an installed app for a verified new copy, as a recoverable transaction.
///
/// Only whole bundles are ever moved. macOS's App Management protection blocks writing *inside*
/// another developer's app once it has been launched, but allows renaming, trashing and moving
/// whole bundles (verified on macOS 27, see docs/architecture.md §11), so no permission is needed.
///
/// Steps, each recorded in a journal first so a crash or power loss can be undone:
/// 1. stage the new bundle next to the old one under a hidden name (same volume, so step 3 is a rename);
/// 2. move the old bundle to the Trash;
/// 3. rename the staged bundle into place. If that fails, the old bundle comes back from the Trash.
struct Replacer: Sendable {
    var trash: any Trash
    var journalDirectory: URL

    struct JournalEntry: Codable, Sendable, Hashable {
        var appPath: String
        var stagedPath: String
        var trashedPath: String?
    }

    /// - Returns: where the old version now is in the Trash.
    func replace(_ installed: URL, with newApp: URL) throws -> URL {
        let fileManager = FileManager.default
        let id = UUID().uuidString
        let staged = installed.deletingLastPathComponent()
            .appending(path: ".\(installed.deletingPathExtension().lastPathComponent).ripe-\(id).app")
        var entry = JournalEntry(appPath: installed.path, stagedPath: staged.path)
        let journal = journalDirectory.appending(path: "\(id).json")

        do {
            try fileManager.moveItem(at: newApp, to: staged)
        } catch {
            throw InstallError(
                .replace,
                "couldn't place the new version next to the old one (\(error.localizedDescription)). Nothing was changed."
            )
        }
        do {
            try write(entry, to: journal)
        } catch {
            try? fileManager.removeItem(at: staged)
            throw InstallError(
                .replace, "couldn't record the update journal (\(error.localizedDescription)). Nothing was changed.")
        }

        let trashed: URL
        do {
            trashed = try trash.trash(installed)
        } catch {
            try? fileManager.removeItem(at: staged)
            try? fileManager.removeItem(at: journal)
            throw InstallError(
                .replace,
                "couldn't move the old version to the Trash (\(error.localizedDescription)). Nothing was changed.")
        }
        entry.trashedPath = trashed.path
        try? write(entry, to: journal)

        do {
            try fileManager.moveItem(at: staged, to: installed)
        } catch {
            let restored = (try? fileManager.moveItem(at: trashed, to: installed)) != nil
            try? fileManager.removeItem(at: staged)
            if restored { try? fileManager.removeItem(at: journal) }
            throw InstallError(
                .replace,
                restored
                    ? "couldn't move the new version into place (\(error.localizedDescription)); the old version was restored."
                    : "couldn't move the new version into place, and restoring failed. The old version is in the Trash at \(trashed.path)."
            )
        }
        try? fileManager.removeItem(at: journal)
        return trashed
    }

    /// Finishes or undoes replacements interrupted by a crash. Returns what it did, for the user.
    func recoverInterrupted() -> [String] {
        let fileManager = FileManager.default
        let journals =
            (try? fileManager.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)) ?? []
        var actions: [String] = []
        for journal in journals where journal.pathExtension == "json" {
            guard let data = try? Data(contentsOf: journal),
                let entry = try? JSONDecoder().decode(JournalEntry.self, from: data)
            else {
                try? fileManager.removeItem(at: journal)
                continue
            }
            let app = URL(filePath: entry.appPath)
            let staged = URL(filePath: entry.stagedPath)
            if !fileManager.fileExists(atPath: app.path), let trashedPath = entry.trashedPath,
                fileManager.fileExists(atPath: trashedPath)
            {
                // Interrupted between trashing and renaming: put the old, known-good version back.
                if (try? fileManager.moveItem(at: URL(filePath: trashedPath), to: app)) != nil {
                    actions.append("restored \(app.lastPathComponent) from the Trash after an interrupted update")
                } else {
                    actions.append("an interrupted update left \(app.lastPathComponent) in the Trash at \(trashedPath)")
                    continue
                }
            }
            if !fileManager.fileExists(atPath: app.path), fileManager.fileExists(atPath: staged.path) {
                // Interrupted right after trashing, before the journal recorded where: the staged
                // copy already passed every check, so finish the update with it.
                if (try? fileManager.moveItem(at: staged, to: app)) != nil {
                    actions.append("finished an interrupted update of \(app.lastPathComponent)")
                }
            }
            if fileManager.fileExists(atPath: staged.path) {
                try? fileManager.removeItem(at: staged)
            }
            try? fileManager.removeItem(at: journal)
        }
        return actions
    }

    private func write(_ entry: JournalEntry, to journal: URL) throws {
        try FileManager.default.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entry).write(to: journal, options: .atomic)
    }
}
