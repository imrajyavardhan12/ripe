# Reviewing Ripe

What a reviewer, human or `/code-review`, should look for. The principles behind it are in
`docs/architecture.md` §1.

## What failure looks like here

Ranked, highest first. Report these, with the file and line that shows the problem, not a guess from a name.

1. **Crying wolf.** Anything that can turn an unsure answer into `outdated`: a version shape the comparator
   misorders, a source match on name alone, a stale cache read as current. When unsure the answer is `unknown`.
2. **Breaking an app** (`Sources/RipeCore/Install/`). A step that changes something before every check that can
   refuse has run; writing inside a bundle instead of moving whole bundles; anything that runs a `.pkg`; a weaker
   signature, Team ID or integrity check; a downgrade; force-quitting; a path where a failed swap doesn't restore
   the old bundle.
3. **Trusting a feed.** Feed or catalog data reaching a shell, a file path or a URL without checks; plain-HTTP
   downloads; a feed or the catalog supplying the key that verifies its own download.
4. **Breaking the output contract.** A `--json` change that removes or renames a field without bumping
   `schemaVersion`; results on stderr or logs on stdout; a new exit code.
5. **Breaking a release.** `.github/workflows/release.yml` or `scripts/formula.sh` writing anything to the tap
   other than `Formula/ripe.rb` (the tap is shared); an `-rc` tag reaching the tap; a step that assumes a `v*`
   tag can be moved or deleted (the tag ruleset forbids both).

## Also check

- A bug fix comes with a test that fails without it; an accuracy fix adds the real-world case.
- A pipeline, source or version-rule change updates `docs/architecture.md` in the same PR.
- A user-visible change has a `CHANGELOG.md` line under `[Unreleased]`.
- A change that makes a line in `CLAUDE.md` or `REVIEW.md` untrue updates it.

## Keep it short

- Style is swift-format's job: no style findings. At most three nits per review.
- Skip `dist/`, `assets/`, `Package.resolved` and the fixtures under `Tests/RipeCoreTests/Fixtures/`, except to ask
  where a new fixture came from.
- Name the class of bug and every place it occurs, not one line. Don't repeat a finding already raised.
- Start the summary with the number of findings. If there's nothing to fix, say so in one line.
