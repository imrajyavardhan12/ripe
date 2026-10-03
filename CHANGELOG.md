# Changelog

All notable changes to Ripe. The release workflow publishes each version's section as its release notes and refuses to release a version without one.

## [Unreleased]

- App names with spaces no longer need quotes: `ripe why LM Studio`, `ripe skip Brave Browser`. `ripe pick LM Studio` treats the words as one name when they only match together; `ripe pick Raycast Postman` still updates two apps.

- `ripe pick` downloads the full update for Sparkle apps that also publish delta patches (Rectangle and many others), instead of a patch it can't install; in cross-platform feeds it takes the macOS archive. Found by the new end-to-end pick workflow, which updates real apps on clean Macs.
- `ripe pick` uses Homebrew's verified download when an app's own feed offers the same version without a signature (Maccy), instead of asking you to update by hand. The new copy still has to pass the SHA-256, signature, Team ID and Gatekeeper checks.

- Apps installed from third-party Homebrew taps (like `nikitabobko/tap/aerospace`) are checked against the tap's cask, read locally from your Homebrew installation; they used to show as unknown.

- `ripe doctor` checks what Ripe depends on: app folders, Homebrew and mas, the Homebrew, App Store and orchard sources (live, or offline from cache), the skips file and interrupted updates. Exits 1 when something is broken; its output is the first thing to paste into a bug report.

- orchard fallback feeds: the catalog can now give Sparkle feeds to apps that set theirs in code (first entries: Ghostty and KeepingYouAwake), each verified against Homebrew's version first. Used only when the app declares no feed and its name matches, and an update is reported only when the build number and the visible version agree.
- Eight more false updates fixed, all found by the accuracy workflow's extended list (120 more apps): words that aren't pre-release markers (`2026.9.181013-latest`, `8.0.47.CE`) no longer make a version look older; packaging revisions (`154.0.8037.57-1.1`) are ignored; an app whose build number is the full version (Opera) or matches Homebrew's build (WeChat) is compared by it; a build number only Homebrew shows (CapCut `9.5.0` vs `9.5.0.4590`) and placeholder versions (`0.0.1`) are reported as unknown; and a `@nightly` or `@beta` cask no longer outranks the stable cask for the same app (Freelens).
- Versions with a commit hash after a dash (GitHub Desktop's `3.6.6-8b85519e`) no longer read as a newer version. Found by the new accuracy workflow, which installs 80 popular apps on a clean Mac every week and fails on any false update.
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
