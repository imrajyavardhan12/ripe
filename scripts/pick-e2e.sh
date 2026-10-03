#!/bin/bash
# End-to-end test of `ripe pick` with real apps: stages old, genuinely signed releases, updates
# them, and checks the result the way a person would care about. Covers every direct-install
# path: Homebrew SHA-256 + DMG (GrandPerspective), Homebrew SHA-256 + zip (AltTab), Sparkle EdDSA
# + DMG (Rectangle), and Homebrew's verified copy when the app's feed has no signature (Maccy).
# Also checks a refusal: an installed copy without a Team ID must be left exactly as it was.
#
#   scripts/pick-e2e.sh <ripe binary> <work dir>
#
# CI only (the Pick workflow): old versions go to this machine's Trash. Never on a Mac someone uses.
set -euo pipefail

ripe=$1
work=$2
apps="$work/Applications"
refuse="$work/Refuse"
rm -rf "$work"
mkdir -p "$apps" "$refuse" "$work/dl"
export RIPE_CACHE_DIR="$work/cache" XDG_CONFIG_HOME="$work/config"

fail() { echo "::error::$*"; exit 1; }

# fetch <url> <sha256> <file>: old releases from the vendors' own pages, pinned by checksum.
fetch() {
    curl -fsSL -o "$work/dl/$3" "$1"
    echo "$2  $work/dl/$3" | shasum -a 256 -c - > /dev/null || fail "checksum mismatch for $3"
}
from_dmg() {
    local mount
    mount=$(mktemp -d)
    hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$work/dl/$1" -quiet
    ditto "$mount/$2" "$apps/$2"
    hdiutil detach "$mount" -quiet
}

fetch https://downloads.sourceforge.net/grandperspectiv/grandperspective/3.6.1/GrandPerspective-3_6_1.dmg \
    3a320532ae5759649f7083474d275762785c87786a478d303a704442876cd22f GrandPerspective-3_6_1.dmg
fetch https://github.com/rxhanson/Rectangle/releases/download/v0.90/Rectangle0.90.dmg \
    482e3bf43c6d164a27bd6a98481e3b6f83236fb5529d6a0d4c771f4e160dc6de Rectangle0.90.dmg
fetch https://github.com/lwouis/alt-tab-macos/releases/download/v11.5.0/AltTab-11.5.0.zip \
    e85da60eb7e57714cee6357ba2e51bcde9393a4d64d3f6b507e71e6579ea7366 AltTab-11.5.0.zip
fetch https://github.com/p0deje/Maccy/releases/download/2.6.1/Maccy.app.zip \
    84b95baf1961bdf30045188c855237f90c1426ac8f123b4ae8f74191f9f38682 Maccy-2.6.1.zip
from_dmg GrandPerspective-3_6_1.dmg GrandPerspective.app
from_dmg Rectangle0.90.dmg Rectangle.app
ditto -xk "$work/dl/AltTab-11.5.0.zip" "$apps"
ditto -xk "$work/dl/Maccy-2.6.1.zip" "$apps"

version() { plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist"; }
team() { codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'; }

# --- Refusal: an ad-hoc signed copy has no Team ID to match, so nothing may change. ---
ditto "$apps/GrandPerspective.app" "$refuse/GrandPerspective.app"
codesign --force --deep --sign - "$refuse/GrandPerspective.app" 2> /dev/null
before=$(find "$refuse" -type f -exec shasum {} + | sort | shasum)
trash_before=$(ls -A ~/.Trash 2> /dev/null | wc -l)
if RIPE_APPLICATIONS_DIR="$refuse" "$ripe" pick --yes GrandPerspective > "$work/refuse.log" 2>&1; then
    cat "$work/refuse.log"
    fail "pick updated an app with no Team ID"
fi
grep -q "identified developer" "$work/refuse.log" || { cat "$work/refuse.log"; fail "refusal didn't say why"; }
[ "$(find "$refuse" -type f -exec shasum {} + | sort | shasum)" = "$before" ] || fail "refused pick changed files"
[ "$(ls -A ~/.Trash 2> /dev/null | wc -l)" -eq "$trash_before" ] || fail "refused pick touched the Trash"
echo "✓ refused the ad-hoc copy and changed nothing"

# --- Updates ---
export RIPE_APPLICATIONS_DIR="$apps"
"$ripe" --all --json > "$work/before.json"
# Per-app facts in files: macOS ships bash 3.2, which has no associative arrays.
state="$work/state"
mkdir -p "$state"
for app in "$apps"/*.app; do
    name=$(basename "$app" .app)
    version "$app" > "$state/$name.old"
    team "$app" > "$state/$name.team"
    python3 -c '
import json, sys
for a in json.load(open(sys.argv[1]))["apps"]:
    if a["name"] == sys.argv[2] and a["status"] == "outdated":
        print(a["latest"]["version"])' "$work/before.json" "$name" > "$state/$name.expected"
    [ -s "$state/$name.expected" ] || fail "$name isn't reported as outdated before the update"
done

"$ripe" pick --all --yes 2>&1 | tee "$work/pick.log"

for app in "$apps"/*.app; do
    name=$(basename "$app" .app)
    now=$(version "$app")
    expected=$(cat "$state/$name.expected")
    [ "$now" = "$expected" ] || fail "$name is $now, expected $expected"
    codesign --verify --strict --deep "$app" 2> /dev/null || fail "$name doesn't pass a strict signature check"
    [ "$(team "$app")" = "$(cat "$state/$name.team")" ] || fail "$name changed Team ID"
    ls ~/.Trash | grep -q "^$name" || fail "the old $name isn't in the Trash"
    echo "✓ $name $(cat "$state/$name.old") → $now, Team ID $(cat "$state/$name.team"), old copy in the Trash"
done
[ "$(ls -d "$apps"/*.app | wc -l)" -eq 4 ] || fail "expected 4 apps after the update"

leftovers=$(ls -A "$apps" | grep -v '\.app$' || true)
[ -z "$leftovers" ] || fail "left behind in Applications: $leftovers"
hidden=$(ls -A "$apps" | grep '^\.' || true)
[ -z "$hidden" ] || fail "staging leftovers: $hidden"
journal="$HOME/Library/Application Support/ripe/journal"
[ -z "$(ls -A "$journal" 2> /dev/null)" ] || fail "update journal not cleaned up"

"$ripe" --all --json > "$work/after.json"
python3 - "$work/after.json" << 'EOF'
import json, sys
apps = json.load(open(sys.argv[1]))["apps"]
stale = [a["name"] for a in apps if a["status"] != "current"]
if stale:
    sys.exit(f"::error::not current after the update: {', '.join(stale)}")
print(f"✓ all {len(apps)} apps report as current")
EOF
