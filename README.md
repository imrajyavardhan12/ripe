<p align="center"><img src="assets/logo.svg" width="112" alt="Ripe logo: a peach with an upward-arrow leaf"></p>

<h1 align="center">Ripe</h1>
<p align="center"><b>Your apps, always ripe.</b><br>One command to see every outdated app on your Mac, and update it safely, whether it came from Homebrew, the Mac App Store or a direct download.</p>

<p align="center"><img src="assets/demo.gif" alt="ripe listing outdated apps, explaining one result with ripe why, planning updates, and updating GrandPerspective with ripe pick" width="900"></p>

```sh
brew install imrajyavardhan12/tap/ripe
```

Open source, no account, no telemetry. macOS 14 or later, Apple silicon and Intel.

## Why

`brew upgrade` only knows apps that Homebrew installed, and skips self-updating ones unless you pass `--greedy`. App Store apps need a different tool. Everything else updates only when you happen to open it, which is how a rarely used VPN or password manager ends up months behind. With MacUpdater shut down, nothing open source checks all of it.

Ripe checks every app in `/Applications`, wherever it came from:

```
ripe                  # what's ripe? (apps with updates)
ripe pick <app>       # update one app
ripe pick --all       # update everything ("the harvest")
ripe why <app>        # where the version info came from, and how Ripe decided
ripe skip <app>       # skip this update (--always to ignore the app)
ripe doctor           # check Homebrew, mas, update sources and settings
ripe --json           # everything, for scripts
```

## How it knows

For each app Ripe asks the most authoritative source first:

1. **Mac App Store**, for apps installed from it.
2. **The app's own Sparkle feed**: exactly what the app's built-in updater would see, filtered the same way (stable channel, your macOS version, your CPU).
3. **Homebrew's cask database**, used as a version database for *every* app, not just ones Homebrew installed.
4. **[orchard](https://github.com/imrajyavardhan12/orchard)**, an open catalog of corrections anyone can add to by pull request: a missing update feed, the right Homebrew cask, or where an app keeps its real version.

When Ripe isn't sure, it says `unknown` and tells you why, instead of guessing. A false "update available" is worse than a missed one. `ripe why <app>` shows every source it asked and the rule that decided.

## How it updates

`ripe pick` shows the plan and asks before changing anything.

- **Homebrew apps** are updated by `brew upgrade --cask`. **App Store apps** go through the App Store (or [`mas`](https://github.com/mas-cli/mas) if you have it).
- **Everything else** is updated by Ripe only after every check passes:
  - the download matches its published SHA-256, or its Sparkle EdDSA signature checks out against the key inside **the app you already have**;
  - its code signature is valid, and its **Team ID matches your installed app's**: an update can't come from a different developer;
  - Gatekeeper accepts it, and it's newer than what you have.
- Then the app is asked to quit (never forced), the old version goes to the **Trash**, and the new one moves in. Any failure restores the old version, and an interrupted update is recovered the next time Ripe runs.
- `.pkg` installers are never run, and downloads that can't be verified are never installed. Ripe tells you where to get them instead.

Ripe needs no special macOS permissions.

## FAQ

**Is Ripe itself signed?** Not with an Apple Developer ID yet. It's installed by Homebrew, which doesn't quarantine command-line tools, so macOS doesn't block it. Every release has a SHA-256 checksum and a GitHub build attestation proving it was built from this repository by its release workflow: `gh attestation verify ripe-*.tar.gz -R imrajyavardhan12/ripe`.

**What does it send over the network?** Requests to each app's own update feed (the same request the app makes itself), bundle IDs to Apple's App Store lookup, and downloads of Homebrew's public cask database and the orchard catalog. No telemetry, no Ripe server.

**An app shows the wrong version, or no version.** Run `ripe why <app>` and [open an issue](https://github.com/imrajyavardhan12/ripe/issues/new?template=wrong-version.yml) with its output (check paths for your username before posting; newer versions shorten them to `~`). Most fixes are a small [orchard](https://github.com/imrajyavardhan12/orchard) entry anyone can contribute.

**Will it update Setapp or Apple's own apps?** No. Setapp keeps its apps updated, and Apple's built-in apps update with macOS. Apple apps sold on the App Store, like Xcode, are checked through the App Store.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/architecture.md](docs/architecture.md). Accuracy results per release are in [docs/accuracy.md](docs/accuracy.md).

## License

[MIT](LICENSE)
