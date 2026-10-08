# Why Ripe exists

Collected 2026-09-28, before the first line of code.

## MacUpdater is gone

MacUpdater (CoreCode) checked every app on a Mac for updates for about 15 years. It shut down: its database froze on 2025-12-31 and goes fully dark after 2026-12-31. People who relied on it are looking for a replacement, and nothing open source covered the same ground.

## `brew upgrade` isn't enough

A scan of a developer's Mac whose owner runs `brew update && brew upgrade` regularly:

```
Apps in /Applications:          28
  installed by Homebrew:         3
  from the Mac App Store:        3
  neither (brew can't see them): 22   (3 Sparkle, 1 Electron, 18 other)

brew outdated --cask:            0
brew outdated --cask --greedy:   3
```

What it shows:
1. Most apps are direct downloads that Homebrew doesn't know were installed.
2. Homebrew skips casks that update themselves unless you pass `--greedy`, so it reports "up to date" when it isn't.
3. An app's own updater only runs when the app is opened, so rarely opened apps (VPNs, password managers, security tools) fall furthest behind.
4. App Store apps need a separate tool (`mas`).
5. 18 of the 22 other apps declare no update feed at all, so Homebrew's cask database has to serve as a version database for every app, not only the ones it installed.

The pitch is visibility plus one command, not "apps never update without Ripe".

## Who it's for

Former MacUpdater users; developers who want one command for everything; security-minded people who want their rarely opened tools current; anyone looking after a family's or a small team's Macs. Not for people who already install every app with Homebrew and run `brew upgrade --greedy`.

## Other tools (2026-09)

Different trade-offs, all worth knowing:

- **[Latest](https://github.com/mangerlahn/Latest)**: open-source Mac app; Sparkle and App Store apps.
- **[updater](https://github.com/lu-zhengda/updater)**: Go CLI and menu bar app; Sparkle, Homebrew, App Store and GitHub.
- **[Versioneer](https://github.com/jakejarvis/versioneer)**: native app with a crowdsourced catalog.
- **[OpenUpdater](https://github.com/chenasraf/OpenUpdater)**: menu bar app.
- **[WegaMacUpdater](https://github.com/DominikSienkiewicz/WegaMacUpdater)**: SwiftUI app; Homebrew, App Store, JetBrains, GitHub Releases and Sparkle.
- Commercial: Updatest, Version Tracker, and the update checks in some cleaner apps.

What Ripe adds: a command line first; the most authoritative source per app, with `unknown` instead of guesses and `ripe why` to show the evidence; an open catalog anyone can correct by pull request (MacUpdater's database was private); and updates that are installed only when the new copy is signed by the same developer (Team ID) as the one you have.
