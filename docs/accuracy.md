# Accuracy log

Ripe's headline metric is its false-positive rate: how often it claims an update that isn't real. Each release gets a verification run on real Macs, recorded here. When a verdict is wrong, the fix lands with a test (fixture or table row), and the row below links to it.

## 2026-10-02 · Accuracy workflow, clean macOS 26 runner · 0.4.0-dev

First automated run: the 80 most-installed app casks, freshly installed, then `ripe --all`. A fresh install must read as current, so any update Ripe reports is either a false positive or the app's own feed running ahead of Homebrew.

80 installed, 80 found, 2.0 s. 77 current, 1 unknown (WezTerm: bundle says 0.1.0, Homebrew uses date versions, so not comparable), 2 reported updates:

- **GitHub Desktop: false positive, fixed.** Cask version `3.6.6-8b85519e` read as 3.6.6.8, so the installed 3.6.6 looked outdated. A commit hash after a dash is now build metadata (`VersionTests`, GitHub Desktop rows).
- **QLMarkdown: real.** Its own Sparkle feed offers 1.5.7 (build 59) while the cask still says 1.5.6.

Earlier attempts the same day taught the harness two lessons: Homebrew dropped `--no-quarantine` (nothing installed, yet the run "passed": it now fails below 40 installs), and runner images carry stale cask data (36 apps installed old versions, which Ripe correctly reported as outdated: 36 of 36 caught, recall evidence; the run now refreshes Homebrew first and reports stale installs separately).

## 2026-10-02 (evening) · maintainer's Mac · 0.4.0-dev with the seeded orchard catalog

27 apps, local catalog with 571 seeded fallback feeds. 12 ripe, 9 up to date, 6 unknown, identical to the same build without the seeded entries. Two apps got a seeded feed: **KeepingYouAwake** is now decided by its own Sparkle feed (build 1060800 = 1060800, still current); **Ghostty** (tip build, version `0081d4530`) stays unknown, now because its version is a commit hash. The importer's bundle IDs matched all 4 of this Mac's apps that it covers. No false positives. (The bulk set was withdrawn the same day to keep orchard curated; only the Ghostty and KeepingYouAwake entries were kept.)

## 2026-10-02 (later) · maintainer's Mac · pre-release v0.3.0

12 ripe, 9 up to date, 7 unknown: the same set as the v0.2.0 run, minus Helium (updated with `ripe pick`). No new false positives. `ripe skip` / `unskip` exercised against real apps (Raycast version skip, Postman `--always`) with an isolated config folder.

## 2026-10-02 · maintainer's Mac (macOS 27.0, Apple silicon) · pre-release v0.2.0

28 apps, live orchard catalog. 13 ripe, 8 up to date, 7 unknown. Verdicts match the 2026-09-28 run below, plus newer upstream releases since then (Brave 1.96.60, Helium 0.18.2.1, Mullvad Browser 15.0.24, Postman 12.30.5, Raycast 2.6.0.0, WhatsApp 26.38.74).

- **Brave** is now decided by Sparkle through the orchard feed (build comparison), no longer by the Homebrew fallback.
- **Obsidian** reports its real running version (1.13.4) through orchard; 1.13.7 is a real update.
- **First real update by the maintainer:** `ripe pick Helium` 0.18.1.1 → 0.18.2.1 (Homebrew cask download, SHA-256, strict signature, matching Team ID, swap, old version in the Trash). Ripe then reported it up to date.
- Earlier the same week: GrandPerspective 3.6.1 → 3.8.1 end to end on a throwaway install, app running during the update (quit and relaunched).

No false positives found.

## 2026-09-28 · maintainer's Mac (macOS 27.0, Apple silicon) · v0.1.0-dev

28 apps checked in 1.2 s cold, 0.19 s warm. 12 ripe, 9 up to date, 7 unknown.

| App | Installed | Ripe says | Source | Verified | Notes |
|---|---|---|---|---|---|
| Dropover | 5.3.0 | ripe → 5.3.1 | App Store | ✅ real | |
| WhatsApp | 26.36.74 | ripe → 26.37.76 | App Store | ✅ real | iPhone-family store record, medium confidence |
| Mullvad VPN | 2026.3 | ripe → 2026.5 | Homebrew (`.pkg` cask, matched by bundle ID) | ✅ real | |
| Raycast | 1.104.24 | ripe → 2.5.3.0 | Homebrew | ✅ agrees with `brew outdated --greedy` | |
| Cryptomator, LuLu, Mullvad Browser, LM Studio, Postman, Proton Pass, ChatGPT | | ripe | Homebrew | plausible, not individually confirmed | ChatGPT needed the name tie-break (`chatgpt` vs `codex-app`) |
| **Obsidian** | 1.12.4 (bundle) | ripe → 1.13.7 | Homebrew | ⚠️ right verdict, wrong reason → ✅ fixed | Updates in place; the bundle keeps the installer version. It really runs 1.13.4 (`obsidian-1.13.4.asar`), so 1.13.7 is a real update. Fixed by orchard `md.obsidian.yml` (`installed_version`). |
| OBS | 32.2.2 | up to date | Sparkle | ✅ | Found a bug: stable items labeled `stable` were skipped. Fixed, `SparkleSourceTests.picksNewestStableItemForThisMac` |
| Brave Browser | 154.1.96.59 | up to date | Homebrew 1.96.59.0 → Sparkle via orchard | ✅ | Was scheme alignment; orchard `com.brave.Browser.yml` adds Brave's real feed, so it's now compared by build (196.59) |
| Flux, Helium, KeePassXC, KeepingYouAwake, Stats, Xcode, Zed | | up to date | various | ✅ | |
| Ghostty | b40acce58 | unknown (not comparable) | | ✅ correct | Tip build with a git-hash version |
| Codenotch | 1.4.0 | unknown (source failed) | Sparkle feed 404 | ✅ correct | |
| AeroSpace | 0.21.3-Beta | unknown (no source) | | gap | Installed from a third-party tap; the core cask API doesn't have it. Reading installed taps is a candidate for v0.2. |
| Folio ×2, Proompt, Claude Code URL Handler | | unknown (no source) | | gap | Personal or niche apps |

Also observed: `brew outdated --cask --greedy` lists `llama-app` as outdated, but `/Applications/Llama.app` no longer exists (deleted by hand). Ripe checks what's on disk, so it doesn't report phantom apps.

**Result: 12 reported updates. 5 confirmed real, 7 plausible but not individually confirmed, 0 known false positives** once the orchard catalog is applied. (The Obsidian verdict was right but compared the wrong version; now it's right for the right reason.)
