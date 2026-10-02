#!/bin/bash
# Accuracy run: install the latest version of popular apps into a throwaway folder, run Ripe on
# that folder, and grade the result. A freshly installed latest version must never be reported
# as outdated, so every such report is a false positive or Homebrew lagging an upstream feed.
#
#   scripts/accuracy/run.sh <ripe binary> <work dir> [cask list, default casks.txt]
#
# CI only (the Accuracy workflow): it installs casks, which changes the machine's Homebrew state.
# Never run it on a Mac someone uses.
set -euo pipefail

ripe=$1
work=$2
here=$(cd "$(dirname "$0")" && pwd)
list=${3:-$here/casks.txt}
expected=$(grep -cv '^#' "$list")
apps="$work/Applications"
mkdir -p "$apps"
: > "$work/installed.tsv"   # token, app name, cask version

# Runner images carry weeks-old cask data: refresh it once, or brew installs stale versions that
# Ripe (correctly) reports as outdated.
brew update --quiet
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1

grep -v '^#' "$list" | while read -r token; do
    [ -n "$token" ] || continue
    before=$(ls "$apps")
    if ! brew install --cask --appdir="$apps" "$token" < /dev/null > "$work/install-$token.log" 2>&1; then
        echo "::warning::$token failed to install (see install-$token.log)"
        continue
    fi
    app=$(comm -13 <(echo "$before") <(ls "$apps") | grep '\.app$' | head -1 || true)
    version=$(brew info --cask --json=v2 "$token" < /dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["casks"][0]["version"])')
    printf '%s\t%s\t%s\n' "$token" "${app%.app}" "$version" >> "$work/installed.tsv"
    echo "installed $token ${app:-?} $version"
done

RIPE_APPLICATIONS_DIR="$apps" "$ripe" --all --json > "$work/report.json"
python3 "$here/evaluate.py" "$work/installed.tsv" "$work/report.json" "$expected"
