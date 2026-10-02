# The README demo. Re-record after a release by running the "Demo" workflow on GitHub (it records
# on a clean Mac and uploads the GIF), or locally with `make demo` (needs vhs). The demo really
# updates a staged GrandPerspective, so locally the old copy lands in your Trash.
#
# Ripe scans a staged Applications folder (scripts/demo/stage.sh), with its own cache and
# config, so nothing from the recording Mac appears in the GIF. Versions shown are whatever the
# real update sources say on the day it's recorded.

Output assets/demo.gif

Set Shell "bash"
Set FontFamily "Menlo"
Set FontSize 16
Set Width 1200
Set Height 680
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 45ms
Set WindowBar Colorful
Set BorderRadius 10

Env RIPE_APPLICATIONS_DIR "/tmp/ripe-demo/Applications"
Env RIPE_CACHE_DIR "/tmp/ripe-demo/cache"
Env XDG_CONFIG_HOME "/tmp/ripe-demo/config"
Env RIPE_STORE_COUNTRY "us"

# This checkout's build first on PATH (never an installed ripe), a prompt, and a warm cache so
# the recording shows everyday speed.
Hide
Type `export PATH="$PWD/dist:$PATH" PS1="\[\e[1;32m\]❯\[\e[0m\] "; ripe >/dev/null 2>&1; clear`
Enter
Sleep 6s
Show

Sleep 500ms
Type "ripe"
Sleep 400ms
Enter
Sleep 4s

Type "ripe why brave"
Sleep 400ms
Enter
Sleep 6s

Type "clear"
Enter
Type "ripe pick --all --dry-run"
Sleep 400ms
Enter
Sleep 6s

# A real update of a real, signed app (staged at an old version).
Type "clear"
Enter
Type "ripe pick grandperspective"
Sleep 400ms
Enter
Wait+Screen@30s /\[y\/N\]/
Sleep 1.5s
Type "y"
Sleep 300ms
Enter
Wait+Screen@90s /picked/
Sleep 5s
