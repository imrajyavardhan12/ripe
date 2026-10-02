# Changelog

All notable changes to Ripe. The release workflow publishes each version's section as its release notes and refuses to release a version without one.

## [Unreleased]

- orchard fallback feeds: the catalog can now give Sparkle feeds to apps that set theirs in code (first entries: Ghostty and KeepingYouAwake), each verified against Homebrew's version first. Used only when the app declares no feed and its name matches, and an update is reported only when the build number and the visible version agree.
- Commit-hash versions that start with digits (Ghostty tip `0081d4530`) are recognized as not comparable instead of being read as a number, and versions like `3.10.8 :0294d207:` ignore the hash.

- `ripe why` shows paths under your home folder as `~/…`, so pasting it into a bug report doesn't reveal your username.
- `RIPE_APPLICATIONS_DIR` (colon-separated) points Ripe at other folders instead of `/Applications` and `~/Applications`, for testing and demos.
- README demo, recorded reproducibly by the Demo workflow on a clean Mac (VHS): a staged folder of well-known apps and a real, verified update.

## [0.3.0] - 2026-10-02

- `ripe skip <app>` skips the update on offer; the app shows up again when a newer version ships, so a later fix is never hidden. `--always` ignores the app until `ripe unskip <app>`; `ripe skip --list` shows what's skipped. Skips live in `~/.config/ripe/skips.json` (respects `XDG_CONFIG_HOME`). `ripe pick --all` respects skips; naming an app (`ripe pick Raycast`) overrides them. Skipped apps stay visible in `--all`, `why`, the summary line and `--json` (`status: "skipped"`).

## [0.2.0] - 2026-10-02

First release: see what's outdated, and update it safely.

- `ripe` lists apps with updates: App Store apps, Sparkle apps and anything in Homebrew's cask database, whether or not Homebrew installed it.
- `ripe --all` shows every app with its status; `ripe why <app>` shows every source consulted and the rule that decided.
- `--json` output with a versioned schema (`schemaVersion: 1`).
- Never guesses: weak matches, unreadable versions (git hashes) and different numbering schemes are reported as `unknown` with the reason, not as updates.
- Understands Sparkle channels, per-CPU and minimum-macOS rules, Homebrew per-OS variations, and Chromium-style version prefixes.
- orchard catalog support: community entries add missing Sparkle feeds, pin Homebrew casks and read the real version of apps that update in place. `RIPE_CATALOG_URL` tests a local catalog.
- Fast and offline-friendly: about 1 s cold and 0.2 s warm for 30 apps; cached answers are used when the network is down.
- `ripe pick <app>…` and `ripe pick --all` update apps. Homebrew apps go through `brew upgrade --cask`, App Store apps through `mas` or the App Store. Other apps are downloaded and installed only after every check passes: SHA-256 or Sparkle EdDSA signature, strict code signature, the **same Team ID as the installed app**, Gatekeeper, no downgrade. The app is quit politely and reopened, the old version goes to the Trash, and an interrupted update is recovered on the next run. `.pkg` installers are never run. Shows the plan and asks first; `--dry-run` and `--yes` for scripts.
- Needs no special macOS permission: Ripe only moves whole app bundles, which App Management allows.
