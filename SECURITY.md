# Security policy

Ripe checks for and (from v0.2) installs software, so security reports get priority.

## Reporting

Please report vulnerabilities privately through GitHub: **Security → Report a vulnerability** on this repository. Don't open a public issue. You'll get an acknowledgement within 72 hours.

Especially in scope:
- Any way to make Ripe install an app not signed by the same Team ID as the installed one.
- Bypassing signature, checksum or EdDSA verification.
- Feed or catalog content that leads to code execution, path traversal or file overwrite.
- Leaking data beyond what's described in `docs/architecture.md` §11.

## Verifying a Ripe release

Ripe isn't notarized (see the README). Every release archive has a SHA-256 checksum and a GitHub build-provenance attestation:

```sh
gh attestation verify ripe-<version>-universal-macos.tar.gz -R imrajyavardhan12/ripe
```
