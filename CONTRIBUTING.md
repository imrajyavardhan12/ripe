# Contributing

Thanks for helping keep Macs ripe. Read [`docs/architecture.md`](docs/architecture.md) first; it explains the pipeline and the principles that settle most design questions.

## Setup

Requirements: macOS 14+, Swift 6 toolchain (Xcode 16+ or the Command Line Tools).

```sh
make build     # debug build
make test      # all tests (works with Command Line Tools only)
make lint      # swift-format, same check as CI
make format    # fix formatting in place
make run ARGS="--help"
```

## Ground rules

- **No false updates.** If a change can make Ripe report an update that isn't real, it needs a test proving it doesn't. When in doubt, return `unknown`.
- **Every accuracy fix comes with a fixture.** Capture the real feed, plist or API response in `Tests/**/Fixtures/`, trimmed to what matters.
- **No new dependencies** without discussing it in an issue first.
- **No network in unit tests.** Use the fake HTTP client. Live tests are tagged and only run with `RIPE_LIVE_TESTS=1`.
- Keep commits small, with a short one-line message.

## Wrong version for an app?

Open a "Wrong version or missed update" issue and paste `ripe why <app> --json`. Most fixes end up as an orchard catalog entry rather than a code change.
