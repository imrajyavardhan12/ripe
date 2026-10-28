## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checklist

- [ ] `make test` and `make lint` pass
- [ ] Can this make Ripe report an update that isn't real? If so, a test proves it doesn't (when unsure, Ripe says `unknown`)
- [ ] Accuracy fixes include the real-world case as a fixture or table row
- [ ] User-visible change: a line in `CHANGELOG.md` under `[Unreleased]`
- [ ] Pipeline, source or version-rule change: `docs/architecture.md` updated

## How to undo it

<!-- Usually "revert this PR". If it ships in a release, a bad tag can't be moved: the fix is a new version.
     For install-path changes, say what happens to an app that was mid-update when this lands. -->

## How it was tested

<!-- The commands you ran and their result lines. For `Sources/RipeCore/Install/`, link the Pick workflow run. -->
