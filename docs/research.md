# Research and rationale

Collected 2026-09-28 while choosing the project.

## Why this project

MacUpdater (CoreCode, https://www.corecode.io/macupdater/) shut down. Its database froze on 2025-12-31 and goes fully dark after 2026-12-31. It sold for ~15 years, so demand is proven, and its users are actively looking for a replacement (TidBITS covered the shutdown in September 2026).

## Evidence: `brew upgrade` isn't enough

Scan of the maintainer's own Mac (a developer who runs `brew update && brew upgrade`):

```
Total apps in /Applications:   28
  Managed by Homebrew cask:     3
  From Mac App Store:           3
  Neither (brew can't see):    22   (Sparkle 3, Electron 1, other 18)

brew outdated --cask:           0
brew outdated --cask --greedy:  3
```

Takeaways:
1. Most apps are direct downloads that brew doesn't know about.
2. brew skips `auto_updates` casks unless you pass `--greedy`, so it reports "up to date" when it isn't.
3. An app's own updater only runs when the app is opened; rarely-opened security tools (KeePassXC, Cryptomator, BlockBlock, Mullvad VPN) go stale.
4. App Store apps need a separate tool (`mas`).
5. 18 of 22 non-brew apps had no detectable feed (custom updaters), so the Homebrew cask API must be used as a version database for all apps.

Target users: former MacUpdater users, developers who want one command for everything, security-minded users, people managing family or small-team Macs. Not for: people who install every app via brew with `--greedy`.

The pitch is visibility plus one command, not "apps never update without Ripe".

## Competitors (as of 2026-09)

None dominant, most are small or alpha:
- **Latest** (https://github.com/mangerlahn/Latest): open source, Sparkle + App Store only; found 12 of 86 updates in one comparison.
- **updater** (https://github.com/lu-zhengda/updater): Go CLI + menu bar, Sparkle/brew/MAS/GitHub, ~14 stars.
- **Versioneer** (https://github.com/jakejarvis/versioneer): native app, early alpha, crowdsourced catalog idea.
- **OpenUpdater** (https://github.com/chenasraf/OpenUpdater): menu bar app.
- **Floodtide**: new updater, launched 2026-09.
- **WegaMacUpdater** (https://github.com/DominikSienkiewicz/WegaMacUpdater): Swift 6 + SwiftUI app; brew casks, MAS, JetBrains, GitHub Releases, Sparkle. Closest to Ripe's source list, but GUI-only.
- **AppFresh** (https://github.com/AppFresh/AppFresh): discovery + update tracking for non-App-Store apps, ~2 stars.
- Paid: Mole app (includes updates), App Cleaner & Uninstaller, Updatest, Version Tracker.
- Pearcleaner has basic update checks, but development stopped at the end of 2025.

## General lesson from the research

In 2026, every paid-Mac-app category has 5 to 10 AI-built open-source clones, mostly under 200 stars. The idea alone doesn't win: a sharp angle, polish, trust (signing, verification), sustained maintenance and a good launch do. Ripe's angles: open PR-driven catalog, wraps brew + mas, Team ID verification before install, CLI-first.

## Ideas considered and rejected

- Open-source Hazel: organize (3.1k stars, Python CLI) already covers CLI-first; a native GUI needs signing.
- Dropover clone: crowded (OpenYoink, Droppy, Shelf...), needs Accessibility permission.
- Shell undo for AI agents: crowded, and agents now ship built-in checkpoints (Claude Code `/rewind`).
- launchd TUI, "why is my Mac slow" CLI, browser-history search, Mac-setup-as-code: crowded or low ceiling.
