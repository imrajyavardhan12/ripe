<p align="center"><img src="assets/logo.svg" width="128" alt="Ripe logo: a peach with an upward-arrow leaf"></p>

<h1 align="center">Ripe</h1>
<p align="center"><b>Your apps, always ripe.</b><br>One command to see every outdated app on your Mac, whether it came from Homebrew, the Mac App Store or a direct download.</p>

---

> **Status: v0.1 in development.** Update checks work (App Store, Sparkle, Homebrew catalog); installing updates comes in v0.2. Follow the repo to catch the first release.

## Why

`brew upgrade` only knows about apps installed through Homebrew, and skips self-updating ones unless you pass `--greedy`. App Store apps need `mas`. Everything else updates only when you happen to open it. On a typical developer Mac, that leaves most apps unchecked.

Ripe checks them all in one place:

```
ripe              # what's ripe? (apps with updates)
ripe pick <app>   # update one app            (v0.2)
ripe pick --all   # harvest everything        (v0.2)
ripe why <app>    # where the version info came from and how the app updates
```

## Principles

- **No false alarms.** If Ripe isn't sure, it says so instead of guessing.
- **Nothing breaks.** Updates are verified (checksum or EdDSA signature, code signature, matching Team ID) and the old version goes to the Trash.
- **Private.** No telemetry, no account, no server.
- **Wraps your tools.** Homebrew and App Store apps are updated through `brew` and `mas`.

The catalog of app update sources, **orchard**, is open and maintained by pull request.

## Install

Coming with v0.1:

```sh
brew install imrajyavardhan12/tap/ripe
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/architecture.md](docs/architecture.md).

## License

[MIT](LICENSE)
