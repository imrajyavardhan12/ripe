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
| Cask API: 7,766 casks, **19 MB** (2 MB gzip on the wire, 0.4 s), 0.5 s to parse, `ETag`, `max-age=600` | Must cache with conditional GET and keep a compact derived index. Never parse 19 MB on a warm run. |
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
- **`Verdict`**: `.outdated(Release)`, `.current`, `.unknown(Reason)`, `.skippedByUser(Release, SkipRule)`. Skips (`SkipList`, `~/.config/ripe/skips.json`) are applied after resolution, so the resolver stays a pure function of the evidence. A version skip hides that release and anything not newer, never a newer one: a skip must not hide a later fix.
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
| 3 | **Electron feed** (planned) | `app-update.yml` present | GitHub provider or generic `latest-mac.yml`. |
| 4 | **GitHub Releases** (planned) | orchard maps the app to a repo | Skip drafts and pre-releases. |
| 5 | **Homebrew cask DB** | Match found (see below) | A version *database* for every app, not only brew-installed ones. Lowest authority because matching is heuristic. |

orchard entries are not a rank; they **enrich apps after discovery and before any source runs**, so sources stay catalog-unaware (`Catalog/`). Schema v1 has four directives (`fallbackSparkleFeed` was added later; older clients ignore it):

| Directive | Effect | First real use |
|---|---|---|
| `sparkleFeed` (per CPU) | Sets the app's Sparkle feed, overriding Info.plist (fixes dead feeds). Sparkle then answers authoritatively. | Brave sets its feed in code; with it, Brave is compared by build number (196.59 = 196.59) instead of by scheme alignment. |
| `homebrewCask` | Pins the cask; beats every matching heuristic. | Ambiguous channels, same-name apps. |
| `fallbackSparkleFeed` (per CPU) | Like `sparkleFeed`, but only when the app declares no feed **and** its Finder name equals the entry's name; compared with `crossChecked` (below) at medium confidence. Written by orchard's importer, one named cask at a time, from Homebrew casks whose livecheck reads a Sparkle feed, each verified with `ripe feed` against the cask version. | KeepingYouAwake moved from the cask fallback to its own feed (2026-10-02). |
| `installedVersion.glob` | Reads the real version from file names (lists one folder, never opens files) and uses it when it's newer than the bundle's (old downloads linger next to a freshly installed bundle); marks the app self-updating. | Obsidian runs `obsidian-1.13.4.asar` while its bundle says 1.12.4. |

The compiled catalog (`index.json`, built and validated by the orchard repo's CI, served by GitHub Pages) is fetched with a 3 s timeout and a 6 h TTL, falls back to the cached copy, and remembers an unavailable catalog for an hour so it never slows a run. A catalog with a newer `schemaVersion` is ignored, not misread. `RIPE_CATALOG_URL` points at a local build (`file://…`) so contributors can test an entry with `ripe why` before opening a PR; `none` disables it. The catalog is untrusted: the client re-checks the path rules for version globs, and nothing in it can weaken install verification (§11). orchard is the correction layer that turns `ripe why` bug reports into fixes for everyone.

**Third-party taps**: the public API only lists `homebrew/cask`. For a cask Homebrew installed from another tap, its install receipt (`Caskroom/<token>/.metadata/INSTALL_RECEIPT.json`) names the tap file and the app it installed; Ripe reads that file's single literal `version` (no Ruby is evaluated; computed, per-CPU and `:latest` versions are left out) and answers with high confidence for that exact app, even offline. It's what `brew upgrade` would install as of the last `brew update`, so a stale tap can only miss an update. Only files under `<prefix>/Library/Taps/` are read. First real use: AeroSpace (`nikitabobko/tap`).

**Cask matching**, the heuristic the whole product leans on:
1. Build a compact index once per cask ETag: app filename → casks, bundle ID → casks. Bundle IDs come from `uninstall[].quit`, `uninstall[].signal`, and zap paths shaped like `~/Library/Preferences/<id>.plist` or `.../Caches/<id>`.
2. Bundle ID match = strong. Filename match with no conflicting bundle ID = medium. Filename match whose cask names a *different* bundle ID = rejected.
3. Several candidates: a cask Homebrew installed (matching by name or bundle ID) wins outright; otherwise a channel cask (`@nightly`, `@beta`) is dropped whenever a stable cask matches with medium confidence or better (Freelens: only `freelens@nightly` listed the bundle ID, which used to make the nightly win). Then a cask that matches both name and bundle ID beats one that matches the bundle ID alone (`chatgpt` vs `codex-app`, which both quit `com.openai.codex`); then the brew-installed token; then the token without `@` (stable channel). Still tied with different tokens → low confidence.
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
- **Cross-checked** (`Release.Comparison.crossChecked`) for feeds nobody has checked against the real app (orchard fallback feeds): both fields are compared, each with the scheme guard, and an answer exists only when they agree. A visible version that's present but unreadable means `unknown`, not "use the build". Measured reason: Ghostty tip (`0081d4530`, build 18035) against the stable feed (build 15212) would otherwise read as current by build alone.
- **Words and revisions**: a tag Ripe doesn't know (`-latest`, `.CE`) is not a pre-release marker, so equal numbers with and without it are incomparable rather than older; known markers (`beta`, `rc`, `nightly`…) still rank. A numeric `-N(.N)` after a version of three or more parts is a packaging revision and is dropped (`154.0.8037.57-1.1`); dates keep their dashes.
- **Catalog more precise than the app** (cask and App Store comparisons only; Sparkle feeds speak the app's own numbering): equal cask build part and `CFBundleVersion` → same release (WeChat `4.1.15 (270102)` vs `4.1.15.22,270102`); a `CFBundleVersion` that carries the full version is compared instead (Opera `136.0` / `136.0.6008.80`); otherwise an extra trailing part of 100 or more is a build number the app doesn't show → incomparable (CapCut `9.5.0` vs `9.5.0.4590`), while a small one is an ordinary release (`1.2` vs `1.2.1`). Placeholder versions (`0.0.0`, `0.0.1`) compare to nothing.
- **Commit hashes** are not versions, even when they start with digits: 7 to 40 hex characters with a letter and no separators parse as nothing (`0081d4530` used to read as 81 plus a tag). Colon-wrapped hashes after a version (`3.10.8 :0294d207:`, Vienna) are dropped like parenthesized notes.

## 8. Platform: network, cache, concurrency

- **HTTPClient** protocol over `URLSession`: 10 s request timeout, HTTPS required (plain-HTTP Sparkle feeds allowed for *checking* but flagged; never for downloading), response size cap (25 MB for the cask DB, 5 MB otherwise), one retry with jitter on transient errors, `User-Agent: ripe/<version> (+https://github.com/imrajyavardhan12/ripe)`.
- **CachingHTTPClient** decorator: on-disk cache in `~/Library/Caches/ripe/` (override `RIPE_CACHE_DIR`). Stores body, `ETag`, `Last-Modified`, fetch time. Per-request TTL: feeds 30 min, App Store 1 h, cask DB 6 h (a stale catalog can only cause a missed update, never a false one, and the file changes every few minutes, so a short TTL would re-download 19 MB constantly). After the TTL, conditional GET; `--refresh` skips the TTL but still revalidates. Server `max-age` is ignored (iTunes sends 24 h, too stale for update checks). If the network fails, the expired copy is served and marked stale, so `ripe` works offline.
- **Derived index cache**: the parsed cask index is written next to the raw body, keyed by ETag. Warm runs load the small index only.
- **Concurrency**: Swift 6 strict concurrency. Sources are `Sendable` structs; the cache is an actor. Per-host concurrency limit (6) so Ripe is a polite client. Sparkle feeds are fetched at most 16 at a time (each is on a different host, so the per-host limit doesn't bound them). Overall run deadline (30 s, matching URLSession's per-download limit, so a first run on a slow link can still fetch the 2 MB cask data): when it fires, in-flight requests are cancelled, and every app a *late* source covers (per `applies(to:)`) gets a timeout failure instead of silently reading as "not applicable". Sources that answered in time are untouched.
- **Host** value: macOS version and codename, CPU arch, App Store country (`Locale.current.region`), paths. Injected, so tests can pretend to be an Intel Mac on Sonoma.
- **ProcessRunner** (v0.2+) for `brew`, `mas`, `hdiutil`, `ditto`: argument arrays only, never a shell string.

## 9. Output contract

- **Default (TTY)**: table of outdated apps (name, installed → latest, source, how to update: what `ripe pick` would do, from the same `Planner`, so the list and the plan never disagree), then a one-line summary: `3 ripe · 41 current · 6 unknown (ripe why <app>)`. Color only on a TTY; respects `NO_COLOR`.
- **`--all`**: every app with its verdict.
- **`--json`**: stable, documented schema with `"schemaVersion": 1`. Additive changes keep the version (new fields, new `status` values such as `skipped`, so consumers must tolerate unknown statuses); breaking changes bump it. Covered by golden tests.
- **stdout carries results only**; logs, progress and warnings go to stderr. `--verbose` for debug logs.
- **Exit codes**: `0` success (regardless of how many updates), `1` runtime failure, `64` usage error (ArgumentParser default). A future `--check` may return `10` when updates exist, for scripts.

## 10. Errors and partial failure

A run succeeds when discovery succeeds. Everything after that degrades per app: a dead feed, a DNS failure or a malformed appcast becomes an `unknown` with a reason, plus a single stderr line summarizing failed sources. Errors are typed per layer (`DiscoveryError`, `SourceError`, `HTTPError`) and carry a user-facing message; raw `NSError` text never reaches the terminal unwrapped.

**`ripe doctor`** (`Doctor/`) checks the same dependencies a run has, in one read-only pass: app folders, `brew` and `mas`, the three online sources (revalidated through the normal cache, so "offline, using cache" is told apart from "unreachable"), the skips file and leftover journal entries. Problems (Ripe can't work properly) exit 1; warnings (works, degraded) and info (optional tool missing) don't.

## 11. Security and privacy

**Read path (v0.1):**
- Feeds are untrusted input. `XMLParser` with external entities off, size caps, no code execution, nothing from a feed is ever passed to a shell.
- No telemetry. The only data leaving the Mac is what each app already sends (its feed request) plus bundle IDs to Apple's lookup API and one download of the public cask DB.

**Write path (`ripe pick`, `Install/`):**

Planning is separate from doing (`Planner`, pure): every selected app gets a method before anything runs, the plan is shown, and nothing changes until the person confirms (`--yes` for scripts; non-interactive runs without it are refused). Methods, in order of preference (principle 6):

| Method | When | What runs |
|---|---|---|
| Homebrew | `managedBy == .homebrew` | `brew upgrade --cask --greedy <token>` (greedy: a named auto-updating cask is otherwise skipped) |
| App Store | App Store app | `mas upgrade <id>` if `mas` exists, else opens the store page for the person to click Update |
| Direct | a download **with** integrity data: cask SHA-256, or Sparkle EdDSA plus the installed app's `SUPublicEDKey` | the pipeline below |
| Direct (Homebrew's copy) | the deciding source has no verifiable download, but a high-confidence cask match offers **the same version** with a SHA-256 (Maccy's feed is unsigned; its cask isn't) | the pipeline below, with the cask's download |
| Manual | anything else (`.pkg`, `no_check` casks, no download, no key) | nothing; tells the person why and where to get it |

Direct installs: every check that can refuse comes before every step that can change anything, so a refusal always means "nothing was changed".
1. The installed app must be signed by an identified developer (Team ID, not ad-hoc): it's the anchor for trust.
2. Download over HTTPS only (plain-HTTP feeds may be *checked*, never downloaded from; HTTPS→HTTP redirects refused), 4 GB cap, declared length enforced.
3. Integrity: SHA-256 (streamed) or Ed25519 via CryptoKit against the **installed** app's key, so neither a feed nor the catalog can supply the key.
4. Unpack by content sniffing, not file name: the UDIF `koly` trailer first (a DMG can start with `BZh`, found on GrandPerspective 3.8.1), then zip (`ditto`, which preserves bundle symlinks), tar (`bsdtar`, refuses `..`), xar → refused (`.pkg` runs root scripts). Exactly one app with the installed bundle ID, or refuse.
5. Verify the new bundle: newer than installed (no downgrades); `SecStaticCodeCheckValidity` strict, all architectures, nested code; **Team ID equals the installed app's**, no override flag; if Gatekeeper accepts the installed app it must accept the new one; native architecture unless the installed version wasn't native either.
6. Quit politely (`NSRunningApplication.terminate`, 20 s), never force. An app that won't quit (unsaved work) stops the install.
7. Replace as a journaled transaction (`Replacer`): stage the new bundle as a hidden sibling (same volume, so the final step is a rename), journal, move the old bundle to the Trash, journal, rename into place; on failure the old bundle comes back from the Trash. `recoverInterrupted()` runs before every `pick`: it restores the old version, finishes with the already-verified staged copy, or removes leftovers, depending on where the crash happened.
8. Relaunch if it was running; report the version now on disk.

**App Management TCC, measured on macOS 27 (2026-10-01)** with a notarized third-party app, from a terminal *without* the App Management permission:

| Operation | Before the app's first launch | After it |
|---|---|---|
| Write inside the bundle / edit Info.plist | allowed | **blocked** (error 513) |
| Rename, trash, or move the whole bundle; move a new bundle in | allowed | allowed |

So Ripe never needs the permission, under one rule: **only ever move whole bundles; never write inside one.** Homebrew documents the same behavior. End-to-end check on a real Mac: GrandPerspective 3.6.1 (running) → 3.8.1 via `ripe pick`: SHA-256, DMG, Team ID `3Z75QZGN66`, Gatekeeper, quit, swap, relaunch; nothing left behind.

**Supply chain for Ripe itself:** no notarization is possible, so releases carry SHA-256 checksums and GitHub build-provenance attestations (`actions/attest-build-provenance`); users can verify with `gh attestation verify`. Dependencies: ArgumentParser only, pinned by `Package.resolved`.

## 12. Testing strategy

| Layer | What | How |
|---|---|---|
| Versions | parse and compare | Table-driven cases from real apps (every row in §2) + property tests. The largest suite in the repo. |
| Parsers | appcast, cask index, iTunes JSON | Real responses captured into `Tests/**/Fixtures/`, trimmed. Every bug report with a weird feed adds a fixture. |
| Discovery | bundle inspection | Build throwaway `.app` directories in a temp dir (Info.plist + receipts). No binary fixtures. |
| Pipeline | resolver end to end | Fake `HTTPClient` serving fixtures + fake `Host`. Asserts verdicts and evidence. |
| CLI | table and JSON output | Expected output inline in the tests; a test pins the JSON shape (schema v1). |
| Accuracy | false positives on real apps | The **Accuracy** workflow (`scripts/accuracy/`): installs the latest version of 80 popular casks (weekly) or 120 more (monthly) on clean macOS 26, macOS 15 and Intel runners, runs `ripe --all`, and fails on any update Ripe reports for an app that was just installed. Stale installs and feeds ahead of Homebrew are reported separately. The false-positive count is the headline metric; notable runs go in `docs/accuracy.md`. |
| Install | `ripe pick` end to end | The **Pick** workflow (`scripts/pick-e2e.sh`): stages old, genuinely signed releases (pinned by SHA-256) and updates them on clean Macs, covering Homebrew SHA-256 + DMG and zip, Sparkle EdDSA + DMG, and Homebrew's copy for an unsigned feed; checks version, strict signature, unchanged Team ID, old copy in the Trash, no leftovers, plus a refusal that must change nothing. Runs on install-code changes and weekly. |

## 13. Performance budget

| Step | Budget (200 apps) | How |
|---|---|---|
| Discovery | < 100 ms | Plain plist reads, no code-signature checks on the read path (measured: 27 ms for 27 apps) |
| Cask index, warm | < 150 ms | Derived compact index, no 19 MB parse |
| Network, warm | ~0 | TTL cache |
| Network, cold | < 4 s | Parallel sources, batched App Store, per-host limit 6 |
| Total warm / cold | < 1 s / < 5 s | `ripe --verbose` prints timings; each accuracy run reports its total (1.3–3.7 s for 80–120 freshly installed apps on CI runners) |

## 14. Release engineering

- **CI** (GitHub Actions, macOS runner): `swift format lint --strict`, `swift build`, `swift test`, universal release build, formula check. Weekly: the Accuracy and Pick workflows (real apps, real APIs); monthly: the extended accuracy list.
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
    Catalog/        Catalog, CatalogLoader, CatalogEnricher (orchard)
    Install/        Planner, Installer, Downloader, Integrity, Unpacker, CodeSignature, Replacer, RunningApps
    Platform/       HTTPClient, CachingHTTPClient, DiskCache, Machine, TapCasks, ProcessRunner, Logger
    Doctor/         Doctor (`ripe doctor`'s checks)
    Ripe.swift      public façade: Ripe.check(options) async -> Report
  RipeCLI/          RootCommand (list, why), PickCommand, SkipCommand, DoctorCommand, FeedCommand (hidden), renderers, JSONReport, Terminal
  ripe/             main.swift
Tests/
  RipeCoreTests/    (+ Fixtures/)
  RipeCLITests/
docs/               architecture.md, research.md (why Ripe exists), accuracy.md (verification log), releasing.md
scripts/            accuracy/ (popular-app accuracy run), pick-e2e.sh, formula and release helpers, demo/
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
| 10 | MIT license | Same as `mas` and Latest; lowest friction for contributors. | — |
| 11 | Seeded catalog feeds are fallbacks, never overrides | A feed taken from Homebrew's livecheck hasn't been checked against the app's bundle; replacing the app's own feed or trusting its build numbers outright could cry wolf. Fallback + name match + cross-check keeps the gain (authoritative feeds for apps that set theirs in code) without that risk. Released clients ignore the new key. | An entry is verified against a real bundle (then it can become `sparkleFeed`). |
| 12 | orchard stays curated: entries are added one by one for a reason, never in bulk | A 571-entry seed from Homebrew livecheck changed no verdict on the maintainer's Mac, couldn't show its benefit elsewhere (many entries are no-ops for apps that declare their own feed), and would turn a reviewed catalog into a generated dump. Coverage grows from `ripe why` reports. | Data shows many users hitting `unknown` for apps a seed would fix. |

## 17. Open risks

- **App Management TCC**: resolved by measurement (§11). Whole-bundle moves need no permission; a future change that writes inside a bundle would break on every launched app, so tests and review must keep that rule.
- **In-place updaters**: some apps update their code without touching Info.plist (Obsidian's bundle says 1.12.4 while it runs 1.13.4). Mitigation: orchard `installedVersion` rules, one per app; no generic detection.
- **Scheme mismatches** (Brave-style) are the main false-positive and false-negative source. Mitigation: alignment heuristic, `unknown` fallback, orchard mappings, fixture per reported case.
- **Upstream drift**: cask JSON and iTunes API are unversioned. Mitigation: tolerant decoding (only the fields we need, all optional), and the weekly accuracy runs, which exercise the real APIs on clean Macs.
- **Rate limits**: iTunes lookup is rate-limited. Mitigation: batching, 1 h cache.
- **Intel support**: toolchains built for macOS 27+ (Swift 6.4 Command Line Tools) ship no x86_64 runtime libraries, so universal binaries are built only in CI on an older runner image. When GitHub's runners move to Xcode 27, pin an older Xcode or drop Intel; decide based on how many users are still on Intel Macs.
- **Swift Testing with Command Line Tools only**: the default `swiftbuild` build system doesn't reliably find the Testing macro plugin; `make test` passes `-plugin-path` explicitly.
- **Coverage ceiling**: apps with no feed and no cask stay `unknown`. Mitigation: orchard, plus showing the count openly so users can contribute.
