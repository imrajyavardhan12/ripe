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
make release && tar -czf /tmp/ripe.tar.gz -C dist ripe
brew tap-new --no-git ripe-test/local
scripts/formula.sh 0.0.0-test "$(shasum -a 256 /tmp/ripe.tar.gz | cut -d' ' -f1)" file:///tmp/ripe.tar.gz \
  > "$(brew --repository)/Library/Taps/ripe-test/homebrew-local/Formula/ripe.rb"
HOMEBREW_NO_INSTALL_FROM_API=1 brew install ripe-test/local/ripe
brew test ripe-test/local/ripe && brew audit --strict ripe-test/local/ripe
brew uninstall ripe-test/local/ripe && brew untap ripe-test/local
```
