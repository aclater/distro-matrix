#!/usr/bin/env python3
"""Diff two scanner result.json files from the same VM (run-matrix --compare-scanner).

Prints a JSON document {"differences": N, "changes": [...]} where each change
is {"path", "kind": "added"|"removed"|"changed", "a", "b"}. Paths are
dotted, list indexes in brackets. Keys matching --ignore (glob, repeatable,
matched against the full path and the last key) are skipped: timestamps and
benchmark numbers differ between any two runs on the same host.

Usage: json_diff.py A.json B.json [--ignore GLOB ...]
Exit: 0 identical (after ignores), 1 different, 2 usage/IO error.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from pathlib import Path
from typing import Any

DEFAULT_IGNORE = [
    "generated_at", "benchmark", "benchmark_tls_handshake", "per_algo",
    "production_estimate", "memory_bandwidth_gb_s", "mem_avail_gb",
    "cpu_freq_mhz", "*.duration*", "*.elapsed*",
]


def _ignored(path: str, patterns: list[str]) -> bool:
    last = path.rsplit(".", 1)[-1].split("[", 1)[0]
    return any(fnmatch.fnmatch(path.lstrip("."), p) or fnmatch.fnmatch(last, p) for p in patterns)


def diff(a: Any, b: Any, ignore: list[str], path: str = "") -> list[dict]:
    if path and _ignored(path, ignore):
        return []
    if isinstance(a, dict) and isinstance(b, dict):
        out: list[dict] = []
        for k in sorted(set(a) | set(b)):
            sub = f"{path}.{k}"
            if _ignored(sub, ignore):
                continue
            if k not in a:
                out.append({"path": sub.lstrip("."), "kind": "added", "b": b[k]})
            elif k not in b:
                out.append({"path": sub.lstrip("."), "kind": "removed", "a": a[k]})
            else:
                out.extend(diff(a[k], b[k], ignore, sub))
        return out
    if isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        out = []
        for i, (x, y) in enumerate(zip(a, b)):
            out.extend(diff(x, y, ignore, f"{path}[{i}]"))
        return out
    if a != b:
        return [{"path": path.lstrip("."), "kind": "changed", "a": a, "b": b}]
    return []


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("a", type=Path)
    ap.add_argument("b", type=Path)
    ap.add_argument("--ignore", action="append", default=None,
                    help="glob of paths/keys to skip (default: timestamps and benchmarks)")
    args = ap.parse_args()
    try:
        a = json.loads(args.a.read_text())
        b = json.loads(args.b.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        print(f"json_diff: {exc}", file=sys.stderr)
        return 2
    changes = diff(a, b, DEFAULT_IGNORE if args.ignore is None else args.ignore)
    json.dump({"differences": len(changes), "changes": changes}, sys.stdout, indent=2, default=str)
    print()
    return 1 if changes else 0


if __name__ == "__main__":
    sys.exit(main())
