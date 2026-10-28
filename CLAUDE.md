# Ripe

Open-source successor to MacUpdater: one command that shows every outdated app on a Mac and updates it, whether it
came from Homebrew, the Mac App Store or a direct download. Swift CLI, shipped through a Homebrew formula.

Before changing the pipeline, a source, version comparison, install code or output, read `docs/architecture.md`
(principles, pipeline, version rules, install pipeline, decision log). Release steps: `docs/releasing.md`.
Accuracy log: `docs/accuracy.md`.

## Commands

- `make build`, `make test`, `make lint`, `make format`, `make run ARGS="…"`, `make release`
- Use `make test`, not `swift test`: with Command Line Tools only, the Swift Testing plugin path must be passed.
- Local `make release` is arm64 only (the macOS 27 toolchain has no x86_64 runtime); CI builds the universal binary.

## Verify before you say done

- Every change: `make lint && make test`. Quote the result line (`Test run with N tests … passed`).
- Never force-unwrap in tests (use `try #require`): local swift-format skips `NeverForceUnwrap` there, CI's doesn't.
- Accuracy fix: the real-world case becomes a fixture or table row, and the test fails without the fix.
- Version comparison: add the new shapes to the table and to the corpus `VersionTests` checks for antisymmetry and
  transitivity.
- On this Mac, read-only: `make run ARGS="--all"` and `make run ARGS="why <app>"`; check the verdict and evidence
  for the apps you touched.
- `ripe pick`: `--dry-run` here. A real run only on a throwaway copy staged with `RIPE_APPLICATIONS_DIR`, or the
  Pick workflow, which runs on pushes to `main` that touch `Sources/RipeCore/Install/` or `AppcastParser.swift`
  and can be started by hand. Link its run in the PR.
- Workflow edits: `actionlint .github/workflows/*.yml`.

## Rules

- **Never cry wolf**: when unsure the answer is `unknown`, never `outdated`.
- **Never write inside an app bundle**: App Management blocks it once an app has launched. Only move whole bundles.
- Foundation + swift-argument-parser only; no new dependency without a strong reason.
- No paid Apple Developer account: nothing is notarized, so don't depend on notarization or stable TCC grants.
- Commit messages: one short line. `main` has a ruleset (PRs, green `test` check, linear history; admins bypass).
  Use the bypass for docs only: `Sources/RipeCore/Install/`, `.github/workflows/`, `scripts/` and `Package.*`
  always go through a PR.
- Reviews (yours and `/code-review`) follow `REVIEW.md`.
- Releases: signed, annotated `vX.Y.Z` tags (`git tag -m "ripe X.Y.Z" vX.Y.Z`), a `CHANGELOG.md` section per tag.
  `v*` tags can't be moved or deleted, so a wrong tag means a new version.
- The Demo workflow records `assets/demo.gif`; inspect its frames for usernames or home paths before committing it.
- orchard (separate repo, served at https://imrajyavardhan12.github.io/orchard/index.json) stays curated: one entry
  at a time, for a reason. Test an entry with `RIPE_CATALOG_URL=file://…/orchard/dist/index.json ripe why <app>`.
- Fruit naming: keep new commands and docs on theme (`ripe`, `pick`, `skip`, `why`, `doctor`; orchard is the
  catalog). The logo is a peach, deliberately not an apple.
