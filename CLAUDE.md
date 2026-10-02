# Ripe

Open-source successor to MacUpdater: one command that shows every outdated app on a Mac and updates them, whether they came from Homebrew, the Mac App Store, or a direct download.

Tagline: **"Your apps, always ripe."**

Background research, competitors and the evidence behind this project: @docs/research.md

Architecture, principles, pipeline, version rules and decision log (read before changing the pipeline, a source, version comparison or output): @docs/architecture.md

## Status

v0.1 feature-complete, not yet released: App Store, Sparkle and Homebrew cask sources, resolver with evidence, disk cache with offline fallback, `ripe`, `ripe --all`, `ripe why <app>`, `--json` (schema v1). Verified against the maintainer's Mac in `docs/accuracy.md` (keep that log updated per release).

orchard catalog v1 done: client support in `Sources/RipeCore/Catalog/`, catalog repo at `~/Developer/orchard` (github.com/imrajyavardhan12/orchard, public; served at https://imrajyavardhan12.github.io/orchard/index.json, redeployed on every push to main or by hand via workflow_dispatch). Test local entries with `RIPE_CATALOG_URL=file://…/orchard/dist/index.json`.

Release tooling done: `scripts/formula.sh` (verified with `brew test` and `brew audit --strict` from a throwaway local tap), release workflow updates the existing public tap `imrajyavardhan12/homebrew-tap` (shared with `margin`; don't touch `margin.rb`). Process in `docs/releasing.md`; `CHANGELOG.md` must have a section for every tag.

`ripe pick` done (`Sources/RipeCore/Install/`, design and the measured App Management rule in docs/architecture.md §11): hand-off to brew/mas, direct installs only after integrity + strict signature + matching Team ID + Gatekeeper, journaled whole-bundle swap. **Never write inside an app bundle** (blocked by App Management once an app has launched); only move whole bundles. Verified end to end on a throwaway app; never test `pick` on the maintainer's real apps without asking.

**Released:** v0.2.0 (2026-10-02, first public release) and v0.3.0 (2026-10-02, `ripe skip`/`unskip`). Install: `brew install imrajyavardhan12/tap/ripe`. The maintainer uses the Homebrew install, not `make install`. Release pipeline is hardened (pinned macos-26 + Xcode 26.6, actions pinned by SHA with Dependabot, formula checked before publishing, tap install verified on a clean machine after); `main` carries the next `-dev` version.

Priorities (the maintainer delegated prioritization, 2026-10-02): launch kit in progress. README rewritten for launch, demo GIF done (`make demo`, VHS against a staged `/tmp/ripe-demo`, never the maintainer's real apps; inspect frames for leaks before committing). Launch drafts written (a private Claude Doc; posting is the maintainer's call). Catalog coverage done: orchard `scripts/import_livecheck.py` seeds `fallback_sparkle_feed` entries from Homebrew livecheck (571 on 2026-10-02, each verified with the hidden `ripe feed`); they take effect from the next release. Next: `ripe doctor`, Electron and GitHub sources. Next: `ripe skip`, `ripe doctor`, Electron and GitHub sources (v0.3).

## Working in this repo

- `make build`, `make test`, `make lint`, `make format`, `make release`, `make run ARGS="..."`.
- Always use `make test`, not bare `swift test`: with Command Line Tools only, the Swift Testing macro plugin must be passed explicitly.
- `make lint` must pass (CI runs `swift format lint --strict`).
- Local `make release` builds arm64 only; the macOS 27 toolchain has no x86_64 runtime libs. CI builds the universal binary.
- Every accuracy fix needs a test with a real-world case (fixture or table row). When unsure, the answer is `unknown`, never `outdated`.

## Name and metaphor

Fruit theme throughout. Keep new commands and docs consistent with it.

```
ripe              # list apps with updates ("what's ripe?")
ripe pick <app>   # update one app
ripe pick --all   # update everything ("harvest")
ripe skip <app>   # ignore an app or a specific version
ripe why <app>    # show where version info came from and how the app updates
```

- **orchard**: the community app catalog, a separate repo (see Catalog).
- Logo: `assets/logo.svg`, a peach with a leaf-shaped upward arrow. Deliberately not an apple (avoid resembling Apple's trademark).

## Hard constraint: no paid Apple Developer account

The maintainer has no $99/yr account, so nothing can be notarized.
- Ship as a **CLI via a Homebrew formula** (own tap first: `brew install imrajyavardhan12/tap/ripe`). Formula binaries aren't quarantined, so Gatekeeper never blocks them.
- Don't depend on anything that needs notarization or stable TCC grants for v0.x.
- A menu bar GUI is a v1.0+ extra. If built unsigned, sign with a consistent self-signed cert so TCC grants survive updates.
- Buying the account later is on the table if the project gets traction; signing is a trust differentiator in this crowded space.

## Tech stack (decided)

- **Swift 6** (toolchain 6.4 installed), Swift Package Manager. Core logic in `RipeCore` (reusable by a future SwiftUI menu bar app), commands and rendering in `RipeCLI`, and a thin `ripe` executable.
- `swift-argument-parser` for the CLI. Otherwise Foundation only (`URLSession`, `XMLParser`, `PropertyListDecoder`); keep dependencies minimal.
- `async/await` + task groups: checking ~200 apps should take a few seconds.
- Security framework (`SecStaticCode`) for code-signature / Team ID checks.
- Swift Testing for tests. GitHub Actions on macOS runners; universal binary (arm64 + x86_64).
- Minimum macOS 14. Precedent for this distribution model: `mas` (Swift CLI shipped as a Homebrew formula).

## Update sources

Detect per app, in roughly this order:
1. **Mac App Store**: `Contents/_MASReceipt` exists → iTunes lookup API by bundle ID.
2. **Sparkle**: `SUFeedURL` in `Info.plist` → parse the appcast.
3. **Electron**: `Contents/Resources/app-update.yml` → its provider (GitHub / generic `latest-mac.yml`).
4. **Homebrew cask API** (`formulae.brew.sh/api/cask.json`): use it as a **version database for every app, not only brew-installed ones**. Match by app bundle name / bundle ID. This covers most apps with custom updaters (Brave, Mullvad, OBS...).
5. **GitHub Releases**: for apps the catalog maps to a repo.
6. **orchard overrides**: hand-written entries for odd apps.

Also call `brew outdated --cask --greedy` and `mas outdated` when available. Ripe **wraps** brew and mas rather than competing with them.

## Catalog (orchard)

Separate GitHub repo, one small YAML file per app, added by PR and validated by CI. CI compiles everything into one JSON index served free via GitHub Pages or jsDelivr. The client caches it locally with ETag. No server, no cost. The open catalog is the answer to MacUpdater's moat (its private database).

## Trust and safety (core selling point)

- Before installing, verify the downloaded app's code signature and that its **Team ID matches the installed app's**. Refuse on mismatch.
- Move the old version to the Trash, never delete it: every update is reversible.
- Prefer delegating to the app's native path (`brew upgrade`, App Store, the app's own updater) when that applies.
- Open risk to test early: since macOS 13, replacing another app's bundle needs the "App Management" TCC permission for the terminal. Prototype this before building `ripe pick`.

## Roadmap

1. **v0.1**: `ripe` lists outdated apps (App Store + Sparkle + Homebrew cask API). Read-only.
2. **v0.2**: `ripe pick` with signature/Team ID verification; orchard catalog v1.
3. **v0.3**: `skip` (shipped 2026-10-02). Electron + GitHub sources move to v0.4.

`why` and `--json` moved into v0.1: they fall out of the evidence model and are how false positives get debugged and reported.
4. **v1.0**: optional menu bar app.

Launch timing matters: MacUpdater's database goes fully dark after **2026-12-31**, and people are looking for a replacement now.

## Launch checklist (later)

README with a GIF in the first screen, one-line install, Show HN + r/macapps + X on the same day.
