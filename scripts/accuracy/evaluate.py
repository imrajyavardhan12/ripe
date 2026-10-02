"""Grades an accuracy run: Ripe's report on freshly installed casks.

    python3 scripts/accuracy/evaluate.py installed.tsv report.json

Every app was just installed at the cask's current version, so:
- outdated, decided by the Homebrew cask itself, to the version just installed: impossible unless
  Ripe misread a version. A false positive; the run fails.
- outdated to a *different* cask version: Homebrew moved on during the run, or the machine
  installed from stale cask data. A harness problem, reported separately; too many fail the run.
- outdated, decided by a higher source (Sparkle, App Store): either a false positive or the app's
  own feed is ahead of Homebrew. Listed for review with both versions; doesn't fail the run.
- current: right. unknown: a coverage gap, counted by reason.

Writes a Markdown summary to $GITHUB_STEP_SUMMARY when set, and to stdout.
"""

from __future__ import annotations

import collections
import json
import os
import sys

MIN_INSTALLED = 40  # of the 80 in casks.txt


def same_version(latest: str | None, cask_version: str) -> bool:
    """`1.2.0` vs cask `1.2,345`: the cask's first part, ignoring trailing zeros."""

    def norm(value: str) -> list[str]:
        parts = value.split(",")[0].strip().split(".")
        while len(parts) > 1 and parts[-1] == "0":
            parts.pop()
        return parts

    return latest is not None and norm(latest) == norm(cask_version)


def main(installed_path: str, report_path: str) -> int:
    installed, elsewhere = {}, []
    with open(installed_path, encoding="utf-8") as handle:
        for line in handle:
            token, app, version = line.rstrip("\n").split("\t")
            if app:
                installed[app.lower()] = (token, version)
            else:
                elsewhere.append(token)  # already on the machine, so nothing landed in the test folder
    report = json.load(open(report_path, encoding="utf-8"))

    false_positives, review, stale, unknown, current = [], [], [], collections.Counter(), 0
    matched = 0
    for app in report["apps"]:
        cask = installed.get(app["name"].lower())
        if cask is None:
            continue
        matched += 1
        token, cask_version = cask
        latest = app.get("latest") or {}
        installed_version = app["installed"].get("version") or app["installed"].get("build") or "?"
        row = (app["name"], token, cask_version, installed_version, latest.get("version"), latest.get("source"), app["explanation"])
        if app["status"] == "outdated":
            if latest.get("source") != "homebrew-cask":
                review.append(row)
            elif same_version(latest.get("version"), cask_version):
                false_positives.append(row)
            else:
                stale.append(row)
        elif app["status"] == "current":
            current += 1
        elif app["status"] == "unknown":
            unknown[app.get("reason", "unknown")] += 1

    reported = len(false_positives) + len(review)
    lines = [
        "## Ripe accuracy run",
        "",
        f"{len(installed)} casks installed, {matched} found by Ripe ({report.get('ripeVersion')}, {report.get('durationSeconds', 0):.1f} s).",
        "",
        f"- **{len(false_positives)} false positives** (outdated by the very cask just installed)",
        f"- {len(stale)} installed from stale cask data (Homebrew lists a newer version; not Ripe's fault)",
        f"- {len(review)} outdated by the app's own feed, to review (feed ahead of Homebrew, or a false positive)",
        f"- {current} current",
        f"- {sum(unknown.values())} unknown: " + (", ".join(f"{reason} {count}" for reason, count in unknown.most_common()) or "none"),
        "",
    ]
    for title, rows in (("False positives", false_positives), ("To review", review), ("Stale installs", stale)):
        if rows:
            lines += [f"### {title}", "", "| App | Cask | Cask version | Installed | Ripe says | Source | Why |", "|---|---|---|---|---|---|---|"]
            lines += ["| " + " | ".join(str(value).replace("|", "\\|") for value in row) + " |" for row in rows]
            lines.append("")
    if elsewhere:
        lines += [f"Not graded (already installed outside the test folder): {', '.join(sorted(elsewhere))}", ""]
    missing = sorted(set(installed) - {app["name"].lower() for app in report["apps"]})
    if missing:
        lines += [f"Installed but not found by Ripe: {', '.join(missing)}", ""]

    summary = "\n".join(lines)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")
    print(f"precision: {reported - len(false_positives)}/{reported} reported updates not known to be false", file=sys.stderr)
    # A run that installed little proves nothing; never let a broken harness pass as clean.
    if len(installed) < MIN_INSTALLED:
        print(f"only {len(installed)} casks installed (need {MIN_INSTALLED}); the harness itself is broken", file=sys.stderr)
        return 2
    if len(stale) > len(installed) // 10:
        print(f"{len(stale)} stale installs; the machine's cask data is out of date", file=sys.stderr)
        return 2
    return 1 if false_positives else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
