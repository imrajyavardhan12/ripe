#!/bin/sh
# Installs a ripe binary through the real Homebrew formula from a throwaway local tap, then
# runs `brew test` and `brew audit --strict`. Catches a broken formula before users do.
#
#   scripts/check-formula.sh dist/ripe [version]
#
# Leaves nothing behind: the formula is uninstalled and the tap removed, even on failure.
set -eu

binary="${1:?usage: check-formula.sh <path-to-ripe-binary> [version]}"
version="${2:-$("$binary" --version)}"
tap="ripe-check/local"
work="$(mktemp -d)"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_INSTALL_CLEANUP=1

# Refuse before touching anything: uninstalling by name could otherwise hit a real install.
if brew list --formula ripe >/dev/null 2>&1; then
  rm -rf "$work"
  echo "error: a ripe formula is already installed; uninstall it first so the check can't clobber it" >&2
  exit 1
fi

# Cleanup only undoes what this script created, in reverse order.
installed=false
tapped=false
cleanup() {
  if $installed; then brew uninstall --formula "$tap/ripe" >/dev/null 2>&1 || true; fi
  if $tapped; then brew untap "$tap" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

cp "$binary" "$work/ripe"
tar -czf "$work/ripe.tar.gz" -C "$work" ripe
sha256="$(shasum -a 256 "$work/ripe.tar.gz" | cut -d' ' -f1)"

brew tap-new --no-git "$tap" >/dev/null
tapped=true
formula="$(brew --repository)/Library/Taps/ripe-check/homebrew-local/Formula/ripe.rb"
"$(dirname "$0")/formula.sh" "$version" "$sha256" "file://$work/ripe.tar.gz" > "$formula"

installed=true
brew install --formula "$tap/ripe"
brew test "$tap/ripe"
brew audit --strict "$tap/ripe"
echo "formula OK: ripe $version installs, passes brew test and brew audit --strict"
