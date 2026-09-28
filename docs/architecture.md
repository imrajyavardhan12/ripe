# Architecture

How Ripe is built and why. Read this before changing the pipeline, a source, the version comparator, or the output contract. Decisions that change this document should update it in the same PR.

## 1. Principles

Ranked. When two conflict, the higher one wins.

1. **Never cry wolf.** A false "update available" costs more trust than a missed one. When Ripe is unsure it says `unknown` and explains why; it never guesses `outdated`.
2. **Never break an app.** Every change is verified first, reversible (old version goes to the Trash), and delegated to the app's native updater when one applies.
3. **Explain every verdict.** Each result carries the evidence behind it (sources consulted, versions seen, rule applied). `ripe why` prints it; bug reports paste it.
4. **Fast.** 200 apps: under 1 s warm, under 5 s cold.
5. **Private.** No telemetry, no account, no Ripe server. Network calls go only to the update sources themselves.
6. **Wrap, don't replace.** brew, mas and each app's own updater stay in charge of what they own.

## 2. Ground truth that shaped the design

Measured on 2026-09-28 against the maintainer's Mac and live APIs. These are the failure modes the design exists to handle.

| Observation | Consequence |
|---|---|
| OBS's appcast lists a **beta** (`sparkle:channel` = beta) as its first item | Naive "take the first item" reports a false update. Filter channels; default channel only. |
| Brave: installed `CFBundleShortVersionString` = `154.1.96.59`, cask version = `1.96.59.0` | Installed and catalog versions use **different schemes**. Plain comparison says "installed is newer" forever. Needs scheme alignment or `unknown`. |
| Ghostty tip: short version = `b40acce58` (a git hash) | Some versions are not comparable at all. Must produce `unknown`, not a crash or a guess. |
| AeroSpace `0.21.3-Beta`, LM Studio `0.4.24+1`, KeePassXC empty `CFBundleVersion` | Pre-release tags, build metadata and missing fields are normal input. |
| Brave, Ghostty, ChatGPT have `SUPublicEDKey` but **no** `SUFeedURL` in Info.plist (feed set in code) | Sparkle detection by Info.plist misses many Sparkle apps. The cask database is the fallback. |
| Cask API: 7,766 casks, **19 MB**, 3.4 s cold, `ETag`, `max-age=600` | Must cache with conditional GET and keep a compact derived index. Never parse 19 MB on a warm run. |
| 2,147 casks have `version: latest`; 810 use `short,build` (`29.2,42065`) | Unversioned casks can't answer. Comma versions must be split before comparing. |
| 1,448 casks have per-OS/arch `variations` (e.g. VS Code `arm64_big_sur` pins 1.106.3) | The newest version depends on the host's macOS and CPU. Resolve the variation for this Mac. |
| 137 app filenames map to several casks (`1Password.app` → stable/beta/nightly; `Thorium.app` → two unrelated apps) | Filename match alone is ambiguous. Prefer the stable channel; confirm with bundle ID. |
| 663 casks install a `.pkg` (no `app` artifact), e.g. Mullvad VPN | Match these by bundle ID taken from `uninstall.quit` or zap paths. |
| iTunes lookup accepts comma-separated bundle IDs; WhatsApp returns `kind: software` (iOS-family) | Batch App Store lookups. Treat non-`mac-software` results with lower confidence. |
| `~/Applications` holds Safari web apps (`com.apple.Safari.WebApp.*`) and duplicates (`Folio.app` twice) | Discovery must filter web apps, Apple system apps and installers, and handle duplicate bundle IDs. |

## 3. System overview

```
                 ┌────────────────────────── RipeCore ───────────────────────────┐
                 │                                                                │
 /Applications ─▶│  Discovery ──▶ [InstalledApp] ──┬─▶ AppStoreSource  ─┐         │
 ~/Applications  │  (BundleInspector)              ├─▶ SparkleSource   ─┤         │
                 │                                 ├─▶ HomebrewCask... ─┼─▶ Resolver ──▶ Report
                 │                                 └─▶ (later sources) ─┘   (policy,  │  (verdicts
                 │                                        │                 compare)  │   + evidence)
                 │            Platform ports: HTTPClient · Cache · ProcessRunner · Host │
                 └──────────────────────────────────────────────────────────────────────┘
                                                                                   │
                 RipeCLI:  commands (ArgumentParser) ─▶ renderers (table · json) ◀──┘
```

One run is a pure-ish pipeline: **discover → query sources in parallel → resolve per app → render**. Everything that touches the outside world (network, disk cache, subprocesses, OS facts) sits behind a small protocol so the whole pipeline runs in tests against fixtures.

## 4. Modules

| Target | Kind | Depends on | Owns |
|---|---|---|---|
| `RipeCore` | library | Foundation, Security | Domain model, discovery, sources, resolver, platform ports and their live implementations. The public API a future menu bar app will call. |
| `RipeCLI` | library | RipeCore, ArgumentParser | Commands, flags, table and JSON rendering, terminal detection. |
| `ripe` | executable | RipeCLI | `main` only. |
| `RipeCoreTests`, `RipeCLITests` | tests | Swift Testing | Unit, fixture and golden tests. |

Dependency rule: arrows point one way (`ripe → RipeCLI → RipeCore`). RipeCore never imports ArgumentParser or prints. Inside RipeCore, `Model/` depends on nothing; `Sources/` and `Discovery/` depend on `Model/` and `Platform/` protocols, never on each other.

Why not more modules now: every module boundary in Swift costs `public` boilerplate. Split `Sources/` into its own target when a second consumer (the GUI) or compile times justify it.

## 5. Domain model (`RipeCore/Model`)

- **`InstalledApp`**: `id` (bundle ID + path), `name`, `bundleID`, `url`, `version: AppVersion` (short + build), and `signals`: App Store receipt, Sparkle feed URL, Sparkle EdDSA key present, Electron update config, wrapped iOS app. Pure value, `Sendable`, `Codable`.
- **`Version`**: parsed, comparable version. See §7.
- **`Release`**: a candidate newest version from one source: `version`, optional `build`, `source`, download URL, release-notes URL, `minimumSystemVersion`, publish date.
- **`SourceOutcome`**: per app per source: `.found(Release, Confidence)`, `.notApplicable`, `.failed(SourceError)`.
- **`Verdict`**: `.outdated(Release)`, `.current`, `.unknown(Reason)`, `.ignored(Reason)`.
- **`Evidence`**: ordered list of what each source said and which rule produced the verdict. Built from day one; `ripe why` and `--json` are just views of it.
- **`AppReport`** = `InstalledApp` + `Verdict` + `Evidence` + `managedBy` (`.homebrew(token)`, `.appStore(id)`, `.selfUpdating`, `.none`).
- **`Report`**: all `AppReport`s + run metadata (duration, sources that failed, cache state).

## 6. Pipeline

### 6.1 Discovery

- Scan `/Applications` (depth 2, to catch `Utilities/` and vendor folders like `Adobe X/`) and `~/Applications` (depth 2). Never descend into a `.app`. Skip only dotfiles, not Finder-hidden entries: macOS flags the `/Applications/Safari.app` symlink as hidden.
- Read `Contents/Info.plist` with `PropertyListSerialization` (handles binary plists). Unreadable bundle → skipped with a logged reason, never a crash.
- Skip: `com.apple.*` apps without an App Store receipt (OS updates own them; Xcode, Pages and Logic have receipts and are kept), Safari web apps (`com.apple.Safari.WebApp.*`), `Setapp/` (Setapp owns them), bundles without a bundle ID or version.
- Detect signals by file presence: `Contents/_MASReceipt/receipt`, `Wrapper/` + `iTunesMetadata.plist` (iOS app on Apple silicon), `SUFeedURL`, `SUPublicEDKey`, `Contents/Resources/app-update.yml`.
- Duplicate bundle IDs: report each path; resolve once per bundle ID + version.
- Sequential: 27 real bundles take 27 ms end to end including process start, so concurrency would add complexity for no measurable gain. Revisit only if a profile says so.

### 6.2 Sources

```swift
public protocol UpdateSource: Sendable {
    var id: SourceID { get }
    func applies(to app: InstalledApp) -> Bool   // cheap, offline
    func check(_ apps: [InstalledApp], context: SourceContext) async -> [InstalledApp.ID: SourceOutcome]
}
```

A source receives **all** apps and decides which it can answer. This lets each source batch in the way its API wants (App Store: 50 bundle IDs per request; cask DB: one index load; Sparkle: one request per feed, in parallel). The resolver runs all sources concurrently in a task group. A source never throws: its failures become `.failed` outcomes, so one broken feed never fails the run.

Authority, highest first:

| Rank | Source | Applies when | Notes |
|---|---|---|---|
| 1 | **App Store** | App Store receipt or wrapped iOS app | Exclusive: an App Store app only updates through the store, so other sources are ignored for it. Batch lookup, `country` = the Mac's region. `kind != mac-software` → lower confidence. |
| 2 | **Sparkle appcast** | `SUFeedURL` present | Exactly what the app's own updater would see. Stable channel only: items with no channel or a channel named `stable`, `release`, `default`, `production` or `public` (OBS labels its stable items explicitly; an earlier version that accepted only unlabeled items picked a three-year-old release). Any other channel is opt-in inside the app; drop items whose `minimumSystemVersion` or `hardwareRequirements` this Mac fails; ignore `informationalUpdate`. Compare `sparkle:version` against `CFBundleVersion` (Sparkle's own rule), falling back to `shortVersionString`. |
| 3 | **Electron feed** (v0.3) | `app-update.yml` present | GitHub provider or generic `latest-mac.yml`. |
| 4 | **GitHub Releases** (v0.3) | orchard maps the app to a repo | Skip drafts and pre-releases. |
| 5 | **Homebrew cask DB** | Match found (see below) | A version *database* for every app, not only brew-installed ones. Lowest authority because matching is heuristic. |

orchard entries are not a rank; they **enrich apps after discovery and before any source runs**, so sources stay catalog-unaware (`Catalog/`). Schema v1 has three directives:

| Directive | Effect | First real use |
|---|---|---|
| `sparkleFeed` (per CPU) | Sets the app's Sparkle feed, overriding Info.plist (fixes dead feeds). Sparkle then answers authoritatively. | Brave sets its feed in code; with it, Brave is compared by build number (196.59 = 196.59) instead of by scheme alignment. |
| `homebrewCask` | Pins the cask; beats every matching heuristic. | Ambiguous channels, same-name apps. |
| `installedVersion.glob` | Reads the real version from file names (lists one folder, never opens files); marks the app self-updating. | Obsidian runs `obsidian-1.13.4.asar` while its bundle says 1.12.4. |

The compiled catalog (`index.json`, built and validated by the orchard repo's CI, served by GitHub Pages) is fetched with a 3 s timeout and a 6 h TTL, falls back to the cached copy, and remembers an unavailable catalog for an hour so it never slows a run. A catalog with a newer `schemaVersion` is ignored, not misread. `RIPE_CATALOG_URL` points at a local build (`file://…`) so contributors can test an entry with `ripe why` before opening a PR; `none` disables it. The catalog is untrusted: the client re-checks the path rules for version globs, and nothing in it can weaken install verification (§11). orchard is the correction layer that turns `ripe why` bug reports into fixes for everyone.

**Cask matching**, the heuristic the whole product leans on:
1. Build a compact index once per cask ETag: app filename → casks, bundle ID → casks. Bundle IDs come from `uninstall[].quit`, `uninstall[].signal`, and zap paths shaped like `~/Library/Preferences/<id>.plist` or `.../Caches/<id>`.
2. Bundle ID match = strong. Filename match with no conflicting bundle ID = medium. Filename match whose cask names a *different* bundle ID = rejected.
3. Several candidates: a cask that matches both name and bundle ID beats one that matches the bundle ID alone (`chatgpt` vs `codex-app`, which both quit `com.openai.codex`); then the brew-installed token; then the token without `@` (stable channel). Still tied with different tokens → low confidence.
4. Resolve `variations` for this host (`arm64_<codename>` on Apple silicon, `<codename>` on Intel, else base). Skip `version: latest` and disabled casks.
5. Split `short,build` versions: compare the short part to `CFBundleShortVersionString`, the build part to `CFBundleVersion` only when the short parts are equal.

### 6.3 Resolution

For each app, take the outcomes in authority order:

1. First `.found` from the highest-ranked applicable source decides. A lower-ranked source can never override a higher one (a stale cask never contradicts the app's own appcast).
2. If the top source `.failed`, fall back to the next, and record the downgrade in evidence.
3. Compare (§7). `newer` → `.outdated`; `same` or installed-is-newer (beta users, lagging catalogs) → `.current`; `incomparable` → `.unknown`.
4. `.outdated` requires confidence ≥ medium. A weak match that looks outdated is reported as `.unknown("possible update 2.1 → 2.3, low-confidence match")`, never as `.outdated`.
5. No applicable source → `.unknown("no update source")`. These are orchard's backlog.

`managedBy` is set independently: Caskroom directory present → `.homebrew(token)`; App Store receipt → `.appStore`; Sparkle/Electron → `.selfUpdating`. `ripe pick` uses it to delegate.

## 7. Versions (the hardest part)

Most bugs in update checkers are version bugs, so this gets its own module, an exhaustive table-driven test suite, and property tests (antisymmetry, transitivity).

- **Parse** into components: numeric runs, string runs, separators. Keep a pre-release marker (`a`, `alpha`, `b`, `beta`, `rc`, `pre`, `dev`, `-Beta`) and drop build metadata after `+`. Strip a leading `v`.
- **Compare** Sparkle-style (`SUStandardVersionComparator` semantics): numbers numerically, `1.2 == 1.2.0`, pre-release < release (`1.0b3 < 1.0`), `rc > beta > alpha`.
- **Incomparable** when either side has no numeric component (`b40acce58`), or when the schemes clearly differ.
- **Scheme alignment** for Brave-style mismatches: if the candidate's components appear as a contiguous suffix of the installed version (`1.96.59` inside `154.1.96.59`), compare on that alignment. Otherwise, if the leading components differ by an order of magnitude, mark incomparable rather than claim installed-is-newer. orchard can pin a per-app mapping when heuristics fail.
- **Two fields**: `CFBundleShortVersionString` is what humans see; `CFBundleVersion` is what Sparkle compares. Each source declares which one it speaks.

## 8. Platform: network, cache, concurrency

- **HTTPClient** protocol over `URLSession`: 10 s request timeout, HTTPS required (plain-HTTP Sparkle feeds allowed for *checking* but flagged; never for downloading in v0.2), response size cap (25 MB for the cask DB, 5 MB otherwise), one retry with jitter on transient errors, `User-Agent: ripe/<version> (+https://github.com/imrajyavardhan12/ripe)`.
- **CachingHTTPClient** decorator: on-disk cache in `~/Library/Caches/ripe/` (override `RIPE_CACHE_DIR`). Stores body, `ETag`, `Last-Modified`, fetch time. Per-request TTL: feeds 30 min, App Store 1 h, cask DB 6 h (a stale catalog can only cause a missed update, never a false one, and the file changes every few minutes, so a short TTL would re-download 19 MB constantly). After the TTL, conditional GET; `--refresh` skips the TTL but still revalidates. Server `max-age` is ignored (iTunes sends 24 h, too stale for update checks). If the network fails, the expired copy is served and marked stale, so `ripe` works offline.
- **Derived index cache**: the parsed cask index is written next to the raw body, keyed by ETag. Warm runs load the small index only.
- **Concurrency**: Swift 6 strict concurrency. Sources are `Sendable` structs; the cache is an actor. Per-host concurrency limit (6) so Ripe is a polite client. Overall run deadline (15 s): when it fires, in-flight requests are cancelled, and every app a *late* source covers (per `applies(to:)`) gets a timeout failure instead of silently reading as "not applicable". Sources that answered in time are untouched.
- **Host** value: macOS version and codename, CPU arch, App Store country (`Locale.current.region`), paths. Injected, so tests can pretend to be an Intel Mac on Sonoma.
- **ProcessRunner** (v0.2+) for `brew`, `mas`, `hdiutil`, `ditto`: argument arrays only, never a shell string.

## 9. Output contract

- **Default (TTY)**: table of outdated apps (name, installed → latest, source, how to update), then a one-line summary: `3 ripe · 41 current · 6 unknown (ripe why <app>)`. Color only on a TTY; respects `NO_COLOR`.
- **`--all`**: every app with its verdict.
- **`--json`**: stable, documented schema with `"schemaVersion": 1`. Additive changes keep the version; breaking changes bump it. Covered by golden tests.
- **stdout carries results only**; logs, progress and warnings go to stderr. `--verbose` for debug logs.
- **Exit codes**: `0` success (regardless of how many updates), `1` runtime failure, `64` usage error (ArgumentParser default). A future `--check` may return `10` when updates exist, for scripts.

## 10. Errors and partial failure

A run succeeds when discovery succeeds. Everything after that degrades per app: a dead feed, a DNS failure or a malformed appcast becomes an `unknown` with a reason, plus a single stderr line summarizing failed sources. Errors are typed per layer (`DiscoveryError`, `SourceError`, `HTTPError`) and carry a user-facing message; raw `NSError` text never reaches the terminal unwrapped.

## 11. Security and privacy

**Read path (v0.1):**
- Feeds are untrusted input. `XMLParser` with external entities off, size caps, no code execution, nothing from a feed is ever passed to a shell.
- No telemetry. The only data leaving the Mac is what each app already sends (its feed request) plus bundle IDs to Apple's lookup API and one download of the public cask DB.

**Write path (v0.2), designed now so v0.1 doesn't paint us into a corner:**
- Files downloaded by a CLI through `URLSession` are **not quarantined**, so Gatekeeper never checks them. Ripe bypasses Gatekeeper by construction and therefore owes the user its own verification, all of which must pass:
  1. Integrity: cask `sha256`, or Sparkle `sparkle:edSignature` verified against the installed app's `SUPublicEDKey` (Ed25519 via CryptoKit). Same bar as Sparkle itself.
  2. Code signature valid (`SecStaticCodeCheckValidity`, strict) and **Team ID equals the installed app's**. Refuse on mismatch; no override flag in v0.2.
  3. Gatekeeper assessment of the new bundle (`SecAssessment`), so an un-notarized update of a notarized app is refused.
- Install is a transaction: quit the app politely, move old bundle to the Trash, move new bundle in, relaunch if it was running. Any failure rolls back.
- Delegation first: brew-managed → `brew upgrade --cask <token>`; App Store → `mas` or open the store page; Ripe installs directly only when it can do all three checks.
- App Management TCC (macOS 13+) may block replacing bundles from the terminal. `ripe doctor` will detect it and explain the one-time grant. Prototype before building `pick`.

**Supply chain for Ripe itself:** no notarization is possible, so releases carry SHA-256 checksums and GitHub build-provenance attestations (`actions/attest-build-provenance`); users can verify with `gh attestation verify`. Dependencies: ArgumentParser only, pinned by `Package.resolved`.

## 12. Testing strategy

| Layer | What | How |
|---|---|---|
| Versions | parse and compare | Table-driven cases from real apps (every row in §2) + property tests. The largest suite in the repo. |
| Parsers | appcast, cask index, iTunes JSON | Real responses captured into `Tests/**/Fixtures/`, trimmed. Every bug report with a weird feed adds a fixture. |
| Discovery | bundle inspection | Build throwaway `.app` directories in a temp dir (Info.plist + receipts). No binary fixtures. |
| Pipeline | resolver end to end | Fake `HTTPClient` serving fixtures + fake `Host`. Asserts verdicts and evidence. |
| CLI | table and JSON output | Golden files; JSON schema snapshot. |
| Live contract | real APIs still look like fixtures | `.tags(.live)`, run only when `RIPE_LIVE_TESTS=1`; nightly CI job. Catches upstream format drift before users do. |
| Accuracy | precision / recall on real Macs | `scripts/accuracy.sh` compares Ripe's output against `brew outdated --greedy` and manual spot checks. The false-positive rate is the headline metric; track it per release. |

## 13. Performance budget

| Step | Budget (200 apps) | How |
|---|---|---|
| Discovery | < 100 ms | Plain plist reads, no code-signature checks on the read path (measured: 27 ms for 27 apps) |
| Cask index, warm | < 150 ms | Derived compact index, no 19 MB parse |
| Network, warm | ~0 | TTL cache |
| Network, cold | < 4 s | Parallel sources, batched App Store, per-host limit 6 |
| Total warm / cold | < 1 s / < 5 s | Measured in CI on every PR via `ripe --json --verbose` timing lines |

## 14. Release engineering

- **CI** (GitHub Actions, macOS runner): `swift format lint --strict`, `swift build`, `swift test`, universal release build. Nightly: live contract tests.
- **Release** on tag `vX.Y.Z`: universal binary (`--arch arm64 --arch x86_64`), stripped, `tar.gz` + SHA-256, provenance attestation, GitHub Release with notes from `CHANGELOG.md`, then bump the formula in the `homebrew-tap` repo.
- SemVer. Pre-1.0: minor = features, patch = fixes. The JSON schema has its own version (§9).

## 15. Repository layout

```
Package.swift
Sources/
  RipeCore/
    Model/          InstalledApp, AppVersion, Version, Release, Verdict, Evidence, Report
    Discovery/      AppScanner, BundleInspector
    Sources/        UpdateSource, AppStoreSource, SparkleSource (+AppcastParser), HomebrewCaskSource (+CaskIndex)
    Resolution/     Resolver, ResolutionPolicy
    Platform/       HTTPClient, CachingHTTPClient, DiskCache, Host, ProcessRunner, Logger
    Ripe.swift      public façade: Ripe.check(options) async -> Report
  RipeCLI/          RootCommand, ListCommand, WhyCommand, renderers, Terminal
  ripe/             main.swift
Tests/
  RipeCoreTests/    (+ Fixtures/)
  RipeCLITests/     (+ Golden/)
docs/               architecture.md, research.md
scripts/            accuracy.sh, release helpers
.github/            workflows/, ISSUE_TEMPLATE/
```

## 16. Decision log

| # | Decision | Why | Revisit when |
|---|---|---|---|
| 1 | Swift, SPM, macOS 14+ | Native APIs (plist, Security, CryptoKit) with no bindings; same language as the future GUI; `mas` precedent. | Never for core. |
| 2 | Three targets, not more | Enforces CLI/core split without `public` boilerplate everywhere. | GUI starts, or builds get slow. |
| 3 | Foundation + ArgumentParser only | Small attack surface and fast builds for a tool that installs software. | A dependency saves > 1 week and is well maintained. |
| 4 | Client reads orchard as compiled JSON, never YAML | No YAML parser in the client; CI validates YAML once. | — |
| 5 | Cask DB is the lowest-authority source | Matching is heuristic; authoritative feeds must win. | Never. |
| 6 | `unknown` over guessing | Principle 1. | Never. |
| 7 | `--json` and `why` ship in v0.1 (moved up from v0.3) | Cheap given the evidence model, and they are how we debug false positives and how users report them. | — |
| 8 | Cache in `~/Library/Caches/ripe`, config in `~/.config/ripe` | Mac convention for caches; dotfile-friendly config for developers. | — |
| 9 | No telemetry, ever | Principle 5; trust is the product. | Never. |
| 10 | MIT license | Same as `mas` and Latest; lowest friction for contributors. | Before the first public release, if the maintainer prefers Apache-2.0. |

## 17. Open risks

- **App Management TCC** may make direct installs awkward from a terminal. Mitigation: delegation first, `ripe doctor`, clear guidance.
- **In-place updaters**: some apps update their code without touching Info.plist (Obsidian's bundle says 1.12.4 while it runs 1.13.4). Mitigation: orchard `installedVersion` rules, one per app; no generic detection.
- **Scheme mismatches** (Brave-style) are the main false-positive and false-negative source. Mitigation: alignment heuristic, `unknown` fallback, orchard mappings, fixture per reported case.
- **Upstream drift**: cask JSON and iTunes API are unversioned. Mitigation: tolerant decoding (only the fields we need, all optional), nightly live contract tests.
- **Rate limits**: iTunes lookup is rate-limited. Mitigation: batching, 1 h cache.
- **Intel support**: toolchains built for macOS 27+ (Swift 6.4 Command Line Tools) ship no x86_64 runtime libraries, so universal binaries are built only in CI on an older runner image. When GitHub's runners move to Xcode 27, pin an older Xcode or drop Intel; decide based on how many users are still on Intel Macs.
- **Swift Testing with Command Line Tools only**: the default `swiftbuild` build system doesn't reliably find the Testing macro plugin; `make test` passes `-plugin-path` explicitly.
- **Coverage ceiling**: apps with no feed and no cask stay `unknown`. Mitigation: orchard, plus showing the count openly so users can contribute.
