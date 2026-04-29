#!/usr/bin/env python3
"""Assert the FIPS algorithm-fence divergence still holds.

Reads result.json files from a spawn-fleet results directory, classifies
each host into "rhel-family-with-gating-patches" or "other-rebuild" by
os_release.id, and asserts:

  - hosts with the gating patches expose zero PQC KEMs and zero PQC
    signature algorithms while FIPS is active
  - hosts without them expose a non-zero count of either

Either failure is interesting and surfaces as a non-zero exit:

  rc=1: the rebuild stopped exposing PQC (rebuild started carrying the
        gating patches; investigate, possibly relax this test)
  rc=2: RHEL started exposing PQC (regression in RHEL's gating patches;
        file a bug)
  rc=3: per-host expectation file format unrecognized
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Distros that ship the downstream FIPS-provider gating patches.  Kept
# narrow on purpose: this list is the canonical answer to "which distro
# IDs do we expect zero-PQC under FIPS from?"  Adding to this list is a
# claim about a build, not a marketing statement.
HOSTS_WITH_GATING_PATCHES = frozenset({"rhel"})


def classify(os_release_id: str) -> str:
    if os_release_id in HOSTS_WITH_GATING_PATCHES:
        return "with_gating"
    return "without_gating"


def count_pqc(report: dict) -> tuple[int, int]:
    openssl = report.get("openssl") or {}
    return (
        len(openssl.get("kem_algorithms") or []),
        len(openssl.get("sig_algorithms") or []),
    )


def main(results_dir: Path) -> int:
    fleet_tsv = results_dir / "fleet.tsv"
    if not fleet_tsv.is_file():
        print(f"missing fleet.tsv at {fleet_tsv}", file=sys.stderr)
        return 3

    with_gating_failures: list[str] = []
    without_gating_failures: list[str] = []

    rows = [
        line.split("\t")
        for line in fleet_tsv.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    ]

    for row in rows:
        if len(row) < 5:
            continue
        vm = row[0]
        result_path = results_dir / vm / "result.json"
        if not result_path.is_file():
            print(f"[{vm}] no result.json — skipping")
            continue
        report = json.loads(result_path.read_text())
        os_id = (report.get("os_release") or {}).get("id", "unknown")
        klass = classify(os_id)
        kem_count, sig_count = count_pqc(report)

        fips_active = (report.get("fips") or {}).get("openssl_provider")
        if not fips_active:
            print(f"[{vm}] FIPS not active — skipping")
            continue

        print(
            f"[{vm}] os_id={os_id} class={klass} "
            f"kems={kem_count} sigs={sig_count}"
        )

        if klass == "with_gating" and (kem_count or sig_count):
            with_gating_failures.append(
                f"{vm} ({os_id}): exposed {kem_count} KEMs / "
                f"{sig_count} sigs under FIPS"
            )
        if klass == "without_gating" and not (kem_count or sig_count):
            without_gating_failures.append(
                f"{vm} ({os_id}): zero PQC KEMs and sigs under FIPS — "
                "did the rebuild start carrying the gating patches?"
            )

    if with_gating_failures:
        print("\nFAIL: gating-patch host(s) exposed PQC under FIPS:")
        for f in with_gating_failures:
            print(f"  - {f}")
        return 2
    if without_gating_failures:
        print("\nFAIL: non-gating-patch host(s) did NOT expose PQC under FIPS:")
        for f in without_gating_failures:
            print(f"  - {f}")
        return 1
    print("\nOK: divergence holds in both directions")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <results-dir>", file=sys.stderr)
        sys.exit(64)
    sys.exit(main(Path(sys.argv[1])))
