# Ripe

Open-source successor to MacUpdater: one command that shows every outdated app on a Mac and updates it, whether it came from Homebrew, the Mac App Store or a direct download. Tagline: **"Your apps, always ripe."**

Read before changing the pipeline, a source, version comparison or output: @docs/architecture.md (principles, pipeline, version rules, install pipeline, decision log). Also: `docs/research.md` (why the project exists), `docs/accuracy.md` (verification log), `docs/releasing.md` (release checklist), `CONTRIBUTING.md`.

## Rules of the code

- **Never cry wolf**: when unsure the answer is `unknown`, never `outdated`. Every accuracy fix ships with a test built from the real-world case (fixture or table row).
- **Never write inside an app bundle**: App Management blocks it once an app has launched. Only move whole bundles.
- **Never test `ripe pick` on apps you rely on**: use the Pick workflow on CI, or a throwaway copy staged with `RIPE_APPLICATIONS_DIR`. Read-only commands (`ripe`, `ripe why`, `pick --dry-run`) are safe anywhere.
- Foundation + swift-argument-parser only; no new dependencies without a strong reason.
- Commit messages: one short line.

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
- **Release**: on a `vX.Y.Z` tag, following `docs/releasing.md`. Tags are signed and annotated (`git tag -m "ripe X.Y.Z" vX.Y.Z`); `CHANGELOG.md` needs a section for every tag.
- **Rulesets**: `main` takes PRs with a green `test` check, linear history, no force pushes (admins bypass); `v*` tags can't be deleted or moved, so a wrong tag means a new version.

## orchard (the catalog)

Separate repo ([imrajyavardhan12/orchard](https://github.com/imrajyavardhan12/orchard)), served at https://imrajyavardhan12.github.io/orchard/index.json. Kept curated: entries are added one at a time for a reason (`scripts/import_livecheck.py --only <cask>` for Sparkle feeds, verified with the hidden `ripe feed`). Test an entry with `RIPE_CATALOG_URL=file://…/orchard/dist/index.json ripe why <app>`.

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
