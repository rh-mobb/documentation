#!/usr/bin/env python3
"""Merge static Amplify rules (customRules.json) with Hugo _redirects alias entries."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REDIRECT_LINE = re.compile(r"^(\S+)\s+(\S+)\s*$")


def load_static_rules(path: Path) -> list[dict]:
    with path.open(encoding="utf-8") as handle:
        rules = json.load(handle)
    if not isinstance(rules, list):
        raise SystemExit(f"{path}: expected a JSON array")
    return rules


def load_hugo_rules(path: Path) -> list[dict]:
    rules: list[dict] = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            match = REDIRECT_LINE.match(stripped)
            if not match:
                raise SystemExit(f"{path}: could not parse redirect line: {line.rstrip()}")
            source, target = match.groups()
            rules.append(
                {
                    "source": source,
                    "status": "301",
                    "target": target,
                    "condition": None,
                }
            )
    return rules


def merge_rules(static_rules: list[dict], hugo_rules: list[dict]) -> list[dict]:
    seen = {rule["source"] for rule in static_rules}
    merged = list(static_rules)
    for rule in hugo_rules:
        if rule["source"] in seen:
            continue
        merged.append(rule)
        seen.add(rule["source"])
    return merged


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: merge-amplify-redirects.py customRules.json public/experts/_redirects",
            file=sys.stderr,
        )
        return 2

    static_path = Path(sys.argv[1])
    hugo_path = Path(sys.argv[2])

    if not static_path.is_file():
        raise SystemExit(f"Static rules file not found: {static_path}")
    if not hugo_path.is_file():
        raise SystemExit(f"Hugo redirects file not found: {hugo_path}")

    static_rules = load_static_rules(static_path)
    hugo_rules = load_hugo_rules(hugo_path)
    merged = merge_rules(static_rules, hugo_rules)

    json.dump(merged, sys.stdout, indent=2)
    sys.stdout.write("\n")
    print(
        f"Merged {len(static_rules)} static + {len(hugo_rules)} Hugo "
        f"({len(merged)} total after dedupe by source)",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
