# Ripe

Open-source successor to MacUpdater: one command that shows every outdated app on a Mac and updates it, whether it came from Homebrew, the Mac App Store or a direct download. Tagline: **"Your apps, always ripe."**

Read before changing the pipeline, a source, version comparison or output: @docs/architecture.md (principles, pipeline, version rules, install pipeline, decision log). Also: `docs/research.md` (why the project exists), `docs/accuracy.md` (verification log, one entry per release), `docs/releasing.md` (release checklist).

## State

- Latest release **v0.4.0** (2026-10-07); `main` carries `0.5.0-dev`. Install: `brew install imrajyavardhan12/tap/ripe` (the maintainer uses this, not `make install`).
- Launch planned for 2026-10-13/14 (Show HN, r/macapps, r/commandline). Drafts live in a private doc; posting is the maintainer's call.
- Next: the open Dependabot PR (checkout 5→7, attest-build-provenance 3→4: test with an `-rc` tag first, which skips the tap); `managedBy` is decided by cask token alone, so a second, non-Homebrew copy of a Homebrew app reads as Homebrew-managed; then Electron and GitHub Releases sources, driven by `ripe why` reports.

## Working agreement

- The maintainer delegated prioritization: decide, build, verify on real data, report at milestones.
- Ask first for: secrets and tokens, accounts, spending, anything posted publicly, and anything touching the maintainer's installed apps. **Never run `ripe pick` on the maintainer's apps**; use CI (Pick workflow) or a throwaway copy.
- Commit messages: one short line.

## Rules of the code

- **Never cry wolf**: when unsure the answer is `unknown`, never `outdated`. Every accuracy fix ships with a test built from the real-world case (fixture or table row).
- **Never write inside an app bundle**: App Management blocks it once an app has launched. Only move whole bundles.
- Foundation + swift-argument-parser only; no new dependencies without a strong reason.

## Commands and gotchas

- `make build`, `make test`, `make lint`, `make format`, `make release`, `make run ARGS="…"`.
- Use `make test`, not `swift test`: with Command Line Tools only, the Swift Testing plugin path has to be passed.
- `make lint` must pass. The local 6.4 toolchain's swift-format skips `NeverForceUnwrap` in Swift Testing files but CI's doesn't: never force-unwrap in tests (`try #require`).
- Local `make release` is arm64 only (the macOS 27 toolchain has no x86_64 runtime); CI builds the universal binary.

## CI workflows

- **CI**: lint, tests, universal build, formula check, on every push.
- **Accuracy**: installs 80 popular casks (weekly) or 120 more (monthly) on macOS 26, macOS 15 and Intel runners; fails on any false positive. Record notable runs in `docs/accuracy.md`.
- **Pick**: updates real old apps end to end on clean runners; weekly and on install-code changes.
- **Demo**: records `assets/demo.gif` on a clean Mac (run it at the release tag). Inspect frames for usernames or home paths before committing.
- **Release**: on a `vX.Y.Z` tag. Tags are signed and annotated: `git tag -m "ripe X.Y.Z" vX.Y.Z`.

## Release facts

- The tap `imrajyavardhan12/homebrew-tap` is shared with the maintainer's `margin` project: never touch `Formula/margin.rb`.
- `HOMEBREW_TAP_TOKEN` (fine-grained, tap only) expires **2027-09-20** (calendar reminder). GitHub's token page may say "Never used" because the tap is updated with `git push`.
- `CHANGELOG.md` needs a section for every tag; the release refuses to publish without one.

## orchard (the catalog)

Separate repo at `~/Developer/orchard` (public), served at https://imrajyavardhan12.github.io/orchard/index.json. Kept curated: entries are added one at a time for a reason (`scripts/import_livecheck.py --only <cask>` for Sparkle feeds, verified with the hidden `ripe feed`). Test an entry with `RIPE_CATALOG_URL=file://…/orchard/dist/index.json ripe why <app>`.

## Constraint: no paid Apple Developer account

Nothing can be notarized, so Ripe ships as a CLI through a Homebrew formula (formula binaries aren't quarantined). Don't depend on notarization or stable TCC grants. A menu bar app is a v1.0+ extra; if built unsigned, sign it with a consistent self-signed certificate so TCC grants survive updates.

## Name and metaphor

Fruit theme; keep new commands and docs consistent with it. orchard is the catalog. The logo (`assets/logo.svg`) is a peach with a leaf-shaped arrow, deliberately not an apple.

```
ripe              # what's ripe? (apps with updates)
ripe pick <app>   # update one; --all is the harvest
ripe skip <app>   # skip a version, or --always
ripe why <app>    # the evidence behind a verdict
ripe doctor       # check brew, mas, sources, skips and interrupted updates
```
