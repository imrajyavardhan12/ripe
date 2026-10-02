"""Grades an accuracy run: Ripe's report on freshly installed casks.

    python3 scripts/accuracy/evaluate.py installed.tsv report.json

Every app was just installed at the cask's current version, so:
- outdated, decided by the Homebrew cask itself: impossible unless Ripe misread a version. A
  false positive; the run fails.
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


def main(installed_path: str, report_path: str) -> int:
    installed = {}
    with open(installed_path, encoding="utf-8") as handle:
        for line in handle:
            token, app, version = line.rstrip("\n").split("\t")
            installed[app.lower()] = (token, version)
    report = json.load(open(report_path, encoding="utf-8"))

    false_positives, review, unknown, current = [], [], collections.Counter(), 0
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
            (false_positives if latest.get("source") == "homebrew-cask" else review).append(row)
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
        f"- {len(review)} outdated by the app's own feed, to review (feed ahead of Homebrew, or a false positive)",
        f"- {current} current",
        f"- {sum(unknown.values())} unknown: " + (", ".join(f"{reason} {count}" for reason, count in unknown.most_common()) or "none"),
        "",
    ]
    for title, rows in (("False positives", false_positives), ("To review", review)):
        if rows:
            lines += [f"### {title}", "", "| App | Cask | Cask version | Installed | Ripe says | Source | Why |", "|---|---|---|---|---|---|---|"]
            lines += ["| " + " | ".join(str(value).replace("|", "\\|") for value in row) + " |" for row in rows]
            lines.append("")
    missing = sorted(set(installed) - {app["name"].lower() for app in report["apps"]})
    if missing:
        lines += [f"Installed but not found by Ripe: {', '.join(missing)}", ""]

    summary = "\n".join(lines)
    print(summary)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(summary + "\n")
    print(f"precision: {reported - len(false_positives)}/{reported} reported updates not known to be false", file=sys.stderr)
    return 1 if false_positives else 0


if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:3]))
