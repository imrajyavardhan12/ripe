# Releasing

## One-time setup

1. Create a fine-grained personal access token: **Settings → Developer settings → Fine-grained tokens**, repository access **only `imrajyavardhan12/homebrew-tap`**, permission **Contents: Read and write**. Give it an expiry and a calendar reminder.
2. Save it as a secret in this repository: `gh secret set HOMEBREW_TAP_TOKEN -R imrajyavardhan12/ripe` (paste when prompted).

Without the secret, releases still publish; only the tap update is skipped.

## Each release

1. Run an accuracy check on at least one real Mac and add it to `docs/accuracy.md`. Any new false positive blocks the release until fixed (with a test) or explained.
2. In `CHANGELOG.md`, rename `## [Unreleased]` to `## [X.Y.Z] - YYYY-MM-DD` and start a new empty `## [Unreleased]`.
3. Commit, then tag and push:

   ```sh
   git tag vX.Y.Z && git push origin vX.Y.Z
   ```

4. The `Release` workflow tests, builds the universal binary, attests it, publishes the GitHub release with the changelog section as notes, and commits `Formula/ripe.rb` to the tap.
5. Check it: `brew update && brew install imrajyavardhan12/tap/ripe && ripe --version`.
6. Bump `Ripe.version` in `Sources/RipeCore/Ripe.swift` to the next `-dev` version, so builds from `main` never claim to be older than the release.

Tags with a suffix (`v0.2.0-rc.1`) are published as pre-releases and don't touch the tap.

## Testing a formula change locally

```sh
make release && scripts/check-formula.sh dist/ripe
```

It installs the binary through the real formula from a throwaway local tap, runs `brew test` and `brew audit --strict`, and cleans up. It refuses to run if `ripe` is already installed through Homebrew, so it can never touch a real install (`brew uninstall ripe` first, reinstall after). CI runs it on every push; the release runs it before publishing anything.

## Build machine and actions

- CI and releases run on `macos-26` with **Xcode 26.6 selected explicitly**. Toolchains built for macOS 27+ ship no x86_64 runtime, so moving to a newer Xcode can silently drop the Intel slice; the release refuses to publish without both slices. Bump the image or Xcode on purpose, in its own PR.
- Every action is pinned to a full commit SHA, with the version in a comment. Dependabot opens weekly PRs to bump them; review the release notes before merging.
- After a release updates the tap, a separate job installs `ripe` from the tap on a clean machine and runs `brew test`. If that fails, the release is broken for users: fix forward with a patch release.
