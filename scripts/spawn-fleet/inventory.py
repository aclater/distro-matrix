#!/usr/bin/env python3
"""Emit an Ansible INI inventory for a spawn-fleet run.

Reads fleet.tsv (rows: vmname \t alias \t family \t expected_id \t ip)
and writes inventory.ini grouped by distro family and by alias.  Lifted
out of spawn-fleet.sh so the inventory shape can grow (host vars, YAML
form, group_by-distro-minor) without churning the bash driver.

Usage:
    inventory.py --fleet-tsv <path> --output <path> --ssh-user <user>
                 --ssh-key <path> [--group-name <pqc_fleet>]
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path


def _slug(name: str) -> str:
    """Sanitize an alias for use as an Ansible group name (no dots)."""
    return name.replace(".", "_").replace("-", "_")


def render_inventory(
    rows: list[tuple[str, str, str, str, str]],
    ssh_user: str,
    ssh_key: str,
    group_name: str = "pqc_fleet",
) -> str:
    """Build the INI text from (vmname, alias, family, expected, ip) rows.

    Rows whose ip column is FAIL or empty are emitted as comments under
    a [<group>:failed] section so the operator sees them but ansible
    won't try to connect.
    """
    family_aliases: dict[str, set[str]] = defaultdict(set)
    alias_hosts: dict[str, list[tuple[str, str]]] = defaultdict(list)
    failed: list[tuple[str, str, str]] = []

    for vm, alias, family, _expected, ip in rows:
        if ip and ip != "FAIL":
            family_aliases[family].add(alias)
            alias_hosts[alias].append((vm, ip))
        else:
            failed.append((vm, alias, family))

    lines: list[str] = []

    if family_aliases:
        lines.append(f"[{group_name}:children]")
        for family in sorted(family_aliases):
            lines.append(f"family_{_slug(family)}")
        lines.append("")

        for family in sorted(family_aliases):
            lines.append(f"[family_{_slug(family)}:children]")
            for alias in sorted(family_aliases[family]):
                lines.append(f"alias_{_slug(alias)}")
            lines.append("")

        for alias in sorted(alias_hosts):
            lines.append(f"[alias_{_slug(alias)}]")
            for vm, ip in sorted(alias_hosts[alias]):
                lines.append(f"{vm} ansible_host={ip}")
            lines.append("")

        lines.append(f"[{group_name}:vars]")
        lines.append(f"ansible_user={ssh_user}")
        lines.append(f"ansible_ssh_private_key_file={ssh_key}")
        lines.append(
            "ansible_ssh_common_args='-o StrictHostKeyChecking=no "
            "-o UserKnownHostsFile=/dev/null'"
        )
        lines.append("ansible_become=true")
        lines.append("ansible_python_interpreter=auto_silent")
        lines.append("")

    if failed:
        lines.append(f"# {group_name}: {len(failed)} VM(s) failed to come up")
        for vm, alias, family in failed:
            lines.append(f"# FAILED  {vm}  alias={alias}  family={family}")
        lines.append("")

    return "\n".join(lines)


def parse_fleet_tsv(path: Path) -> list[tuple[str, str, str, str, str]]:
    rows: list[tuple[str, str, str, str, str]] = []
    for line in path.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) != 5:
            print(
                f"inventory.py: skipping malformed row in {path}: {line!r}",
                file=sys.stderr,
            )
            continue
        rows.append(tuple(fields))  # type: ignore[arg-type]
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--fleet-tsv", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--ssh-user", default="matrix")
    ap.add_argument("--ssh-key", required=True)
    ap.add_argument("--group-name", default="pqc_fleet")
    args = ap.parse_args()

    rows = parse_fleet_tsv(args.fleet_tsv)
    text = render_inventory(rows, args.ssh_user, args.ssh_key, args.group_name)
    args.output.write_text(text)
    print(f"inventory: {args.output} ({sum(1 for r in rows if r[4] not in ('', 'FAIL'))} hosts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
