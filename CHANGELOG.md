# Changelog

All notable changes to Ripe. The release workflow publishes each version's section as its release notes and refuses to release a version without one.

## [Unreleased]

First release: read-only update checks.

- `ripe` lists apps with updates: App Store apps, Sparkle apps and anything in Homebrew's cask database, whether or not Homebrew installed it.
- `ripe --all` shows every app with its status; `ripe why <app>` shows every source consulted and the rule that decided.
- `--json` output with a versioned schema (`schemaVersion: 1`).
- Never guesses: weak matches, unreadable versions (git hashes) and different numbering schemes are reported as `unknown` with the reason, not as updates.
- Understands Sparkle channels, per-CPU and minimum-macOS rules, Homebrew per-OS variations, and Chromium-style version prefixes.
- orchard catalog support: community entries add missing Sparkle feeds, pin Homebrew casks and read the real version of apps that update in place. `RIPE_CATALOG_URL` tests a local catalog.
- Fast and offline-friendly: about 1 s cold and 0.2 s warm for 30 apps; cached answers are used when the network is down.
