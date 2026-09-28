# Accuracy log

Ripe's headline metric is its false-positive rate: how often it claims an update that isn't real. Each release gets a verification run on real Macs, recorded here. When a verdict is wrong, the fix lands with a test (fixture or table row), and the row below links to it.

## 2026-09-28 · maintainer's Mac (macOS 27.0, Apple silicon) · v0.1.0-dev

28 apps checked in 1.2 s cold, 0.19 s warm. 12 ripe, 9 up to date, 7 unknown.

| App | Installed | Ripe says | Source | Verified | Notes |
|---|---|---|---|---|---|
| Dropover | 5.3.0 | ripe → 5.3.1 | App Store | ✅ real | |
| WhatsApp | 26.36.74 | ripe → 26.37.76 | App Store | ✅ real | iPhone-family store record, medium confidence |
| Mullvad VPN | 2026.3 | ripe → 2026.5 | Homebrew (`.pkg` cask, matched by bundle ID) | ✅ real | |
| Raycast | 1.104.24 | ripe → 2.5.3.0 | Homebrew | ✅ agrees with `brew outdated --greedy` | |
| Cryptomator, LuLu, Mullvad Browser, LM Studio, Postman, Proton Pass, ChatGPT | | ripe | Homebrew | plausible, not individually confirmed | ChatGPT needed the name tie-break (`chatgpt` vs `codex-app`) |
| **Obsidian** | 1.12.4 | ripe → 1.13.7 | Homebrew | ❌ **likely false positive** | Updates in place; Info.plist keeps the installer version. Needs an orchard entry. |
| OBS | 32.2.2 | up to date | Sparkle | ✅ | Found a bug: stable items labeled `stable` were skipped. Fixed, `SparkleSourceTests.picksNewestStableItemForThisMac` |
| Brave Browser | 154.1.96.59 | up to date | Homebrew 1.96.59.0 | ✅ | Scheme alignment (`VersionMatcherTests.alignsChromiumPrefixedVersions`) |
| Flux, Helium, KeePassXC, KeepingYouAwake, Stats, Xcode, Zed | | up to date | various | ✅ | |
| Ghostty | b40acce58 | unknown (not comparable) | | ✅ correct | Tip build with a git-hash version |
| Codenotch | 1.4.0 | unknown (source failed) | Sparkle feed 404 | ✅ correct | |
| AeroSpace | 0.21.3-Beta | unknown (no source) | | gap | Installed from a third-party tap; the core cask API doesn't have it. Reading installed taps is a candidate for v0.2. |
| Folio ×2, Proompt, Claude Code URL Handler | | unknown (no source) | | gap | Personal or niche apps |

Also observed: `brew outdated --cask --greedy` lists `llama-app` as outdated, but `/Applications/Llama.app` no longer exists (deleted by hand). Ripe checks what's on disk, so it doesn't report phantom apps.

**Result: 1 likely false positive in 12 reported updates.**
