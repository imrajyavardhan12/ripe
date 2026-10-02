#!/bin/sh
# Stages a fake Applications folder of well-known apps at older versions, for the README demo.
# Bundles are just Info.plists (and an App Store receipt where needed): enough for Ripe to check
# them against the real update sources. Nothing from the recording machine leaks into the demo.
#
#   scripts/demo/stage.sh <folder>
set -eu

root="${1:?usage: stage.sh <folder>}"
rm -rf "$root"
mkdir -p "$root"

# app <file name> <bundle id> <short version> [build] [sparkle feed] [sparkle public EdDSA key]
# The keys are the apps' real public keys, as shipped in every copy of them.
app() {
  bundle="$root/$1.app/Contents"
  mkdir -p "$bundle"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "<key>CFBundleIdentifier</key><string>$2</string>"
    echo "<key>CFBundleShortVersionString</key><string>$3</string>"
    if [ -n "${4:-}" ]; then echo "<key>CFBundleVersion</key><string>$4</string>"; fi
    if [ -n "${5:-}" ]; then echo "<key>SUFeedURL</key><string>$5</string>"; fi
    if [ -n "${6:-}" ]; then echo "<key>SUPublicEDKey</key><string>$6</string>"; fi
    echo '</dict></plist>'
  } > "$bundle/Info.plist"
}

# The newest version Homebrew knows, so one app shows as up to date.
latest() {
  /usr/bin/python3 -c 'import json,sys,urllib.request; print(json.load(urllib.request.urlopen("https://formulae.brew.sh/api/cask/"+sys.argv[1]+".json"))["version"].split(",")[0])' "$1"
}

app "Visual Studio Code" com.microsoft.VSCode 1.100.0
app "Firefox" org.mozilla.firefox 140.0
app "Slack" com.tinyspeck.slackmacgap 4.41.97
app "Spotify" com.spotify.client 1.2.50.335
app "1Password" com.1password.1password 8.10.60
app "OBS" com.obsproject.obs-studio 31.1.2 30000000000 https://obsproject.com/osx_update/updates_arm64_v2.xml \
  "HQ5/Ba9VHOuEWaM0jtVjZzgHKFJX9YTl+HNVpgNF0iM="
app "Brave Browser" com.brave.Browser 140.1.80.113 180.113 "" "KjcVXTGW5IOBzbzcZoZXTMf/Od/iVWUiVNhQkeL8vJ4="
app "Rectangle" com.knollsoft.Rectangle "$(latest rectangle)"
app "Amphetamine" com.if.Amphetamine 5.3.0
mkdir -p "$root/Amphetamine.app/Contents/_MASReceipt" && : > "$root/Amphetamine.app/Contents/_MASReceipt/receipt"
app "Notes Helper" dev.example.notes-helper 0.3.1

# One real, signed app at an old version, so the demo can show a genuine `ripe pick`: download,
# SHA-256, code signature and Team ID check, swap. Pinned by checksum; never the recording Mac's copy.
old_dmg="$(mktemp -d)/GrandPerspective-3_6_1.dmg"
curl -sSL -o "$old_dmg" "https://downloads.sourceforge.net/grandperspectiv/grandperspective/3.6.1/GrandPerspective-3_6_1.dmg"
echo "3a320532ae5759649f7083474d275762785c87786a478d303a704442876cd22f  $old_dmg" | shasum -a 256 -c - >/dev/null
mount="$(mktemp -d)"
hdiutil attach -nobrowse -readonly -mountpoint "$mount" "$old_dmg" -quiet
ditto "$mount/GrandPerspective.app" "$root/GrandPerspective.app"
hdiutil detach "$mount" -quiet
rm -f "$old_dmg"

echo "staged $(ls "$root" | wc -l | tr -d ' ') demo apps in $root"
