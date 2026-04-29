# distro-matrix

Local CI for host-level scanners across upstream Linux cloud images.

Spin up a fresh libvirt VM per distro (RHEL / Rocky / AlmaLinux / CentOS Stream / Fedora / Ubuntu / Debian / SLES), run an arbitrary scanner script inside as root, pull JSON output back, and report per-distro pass/fail. The same matrix runner backs the `test-on-distros` wrapper that agents call before submitting PRs that touch host-level behavior.

## Why

The Tier 1 / Tier 2 distro list in projects like [pqc-readiness](https://github.com/aclater/pqc-readiness) is a promise: *"this script works on these distros."* Verifying that promise means actually booting each distro and running the script, not just running pytest in CI. This repo is the harness.

`virt-install` + `cloud-localds` is what every upstream cloud image is tested against — it just works. (We tried Incus first; the public `images:` distros are stripped down without `cloud-init` or `sshd`, and Incus-side cloud-init injection silently no-ops on hand-imported qcow2s. See PR #2 commit history.)

## Quick start

On a host with `libvirt`, `virt-install`, `cloud-localds`, `qemu-img`, `jq`, `ssh`, and the user in the `libvirt` group:

```
git clone https://github.com/aclater/distro-matrix
cd distro-matrix
./scripts/run-matrix.sh \
  --scanner ./your-script.sh \
  --scanner-args '--json' \
  --image-root /mnt/media/iso/linux \
  --only debian-13 \
  --parallel 1
```

The runner stages a thin qcow2 overlay, builds a NoCloud cidata.iso with cloud-init that creates a `matrix` user (sudo NOPASSWD + your SSH pubkey), boots the VM via `virt-install --import`, waits for IPv4 + SSH, SCPs your scanner in, runs it as root, pulls `result.json` + `stderr.log` + `exit-code` + `/etc/os-release` back, and writes a markdown report to `results/<UTC ts>/report.md`.

## Two ways to use it

### Direct — for matrix runs you control

`scripts/run-matrix.sh` is the workhorse. Configure `distros.tsv` with the distros you care about (alias, family, expected `os-release` ID, qcow2 path relative to `--image-root`), point at a scanner, run.

### Via wrapper — for agent CI

`~/.local/bin/test-on-distros` (lives outside this repo, in your `$PATH`) is a thin SSH wrapper that pushes a local scanner to a remote host running this repo and prints the report back. Designed for the "before I open a PR, does my change still work on rhel-9 and debian-13?" workflow:

```
test-on-distros --scanner ./pqc_readiness.py --scanner-args '--json' --only rhel-9,debian-13 --parallel 4
```

See `~/.claude/CLAUDE.md` for the agent integration story (when to invoke, when not to, how to handle failures).

## Keep-alive fleets — `spawn-fleet.sh`

`run-matrix.sh` is one-shot: boot, scan, destroy. For workflows that want VMs to *stay alive* — driving them with Ansible, running multi-step playbooks, comparing per-host results across reboots — use `scripts/spawn-fleet/spawn-fleet.sh`. It reuses the same `virt-install` + `cloud-localds` primitives, but:

- Reads a manifest of `alias COUNT` pairs (one line per distro, one VM per count) instead of the `--only` filter.
- Does **not** run a scanner. Boot completes, IP is captured, the VM is left running.
- Emits `inventory.ini` (Ansible INI format, grouped by distro family and alias) and `fleet.tsv` (vmname / alias / family / expected_id / ip).
- Names VMs `dm-fleet-<alias>-NN` so multiple fleets coexist on one hypervisor.

```bash
cat > fleet.tsv <<'EOF'
rhel-10    1
rocky-10   1
EOF

scripts/spawn-fleet/spawn-fleet.sh \
  --manifest ./fleet.tsv \
  --memory 18432 \
  --vcpus 2 \
  --fips \
  --results-dir ./fleet-fips/

ansible -i ./fleet-fips/inventory.ini all -m ping
```

The inventory emitter is a small Python helper at `scripts/spawn-fleet/inventory.py`; the bash script invokes it after IP capture. Easier to extend to YAML inventory or richer host vars later than to grow the bash.

When you're done, `scripts/teardown-fleet.sh --results-dir ./fleet-fips/` destroys + undefines every VM listed in `fleet.tsv`. Idempotent; VMs that no longer exist are silently skipped.

### Three FIPS infrastructure fixes baked in

The FIPS path on EL10 hit three landmines during the fleet test that motivated this script. All three are handled inline:

1. **`fips-mode-setup` removed from EL10's `crypto-policies-scripts`.** When `--fips` is set and the binary is absent, cloud-init falls back to `update-crypto-policies --set FIPS` + `grubby --update-kernel=ALL --args="fips=1"` + `dracut -f --regenerate-all` + `:>/etc/system-fips`.
2. **libvirtd `--timeout` killing VMs mid-cloud-init reboot.** Pre-flight in `spawn-fleet.sh` detects a `--timeout` flag in `libvirtd.service` and prints the no-timeout drop-in for the operator to install. Not auto-installed (no privilege model for that).
3. **Separate `/boot` partition on LVM cloud images.** When `--fips` is set, the kernel cmdline gets `boot=UUID=$(findmnt -no UUID /boot)` if `/boot` is its own filesystem, so the dracut FIPS integrity check can find `/boot/.vmlinuz-*.hmac` pre-pivot.

The libvirtd drop-in:

```ini
# /etc/systemd/system/libvirtd.service.d/no-timeout.conf
[Service]
ExecStart=
ExecStart=/usr/bin/libvirtd
```

`sudo systemctl daemon-reload && sudo systemctl restart libvirtd` after.

## How a VM is built

```
upstream qcow2 (NFS, read-only)
        │
        │  qemu-img create -F qcow2 -b ...   (thin overlay; fast)
        ▼
   work/disk.qcow2  ──┐
                      │
   user-data ──┐      │
   meta-data ──┴──> cloud-localds cidata.iso
                      │
                      ▼
   virt-install --import \
     --disk path=work/disk.qcow2 \
     --disk path=work/cidata.iso,device=cdrom \
     --network network=default
                      │
                      ▼
   libvirt boots VM ──> cloud-init reads cidata.iso (NoCloud datasource)
                                │
                                ▼
                        creates `matrix` user (sudo NOPASSWD, our SSH key)
                                │
                                ▼
                        runner waits for IPv4, SSHes in, runs scanner
                                │
                                ▼
                        SCP result.json / stderr.log / exit-code back
                                │
                                ▼
                        cleanup: virsh destroy + undefine, rm work dir
```

## Verdict semantics

| Verdict | Condition |
| --- | --- |
| `PASS` | Scanner exit ∈ [0, 124) **and** `result.json` is non-empty **and** the guest's `/etc/os-release` `ID` matches the expected value |
| `FAIL` | Scanner exit 124+ (timeout / SIGKILL / signal / wrapper error), OR empty `result.json`, OR os-id mismatch |

The matrix's job is *"did the script run on this OS"*, not *"what verdict did the script reach."* A scanner that exits 3 because it found a host with low capability is still a `PASS` — the script worked. A scanner that crashes (exit 137 from OOM, exit 124 from `timeout`, exit 127 from missing interpreter) is a `FAIL`.

## Wall-clock (lennon: AMD Ryzen 9 3950X, 32 threads, 128 GiB)

| Mode | Distros | Time |
| --- | --- | --- |
| sequential | 1 | ~18s |
| `--parallel 4` | 4 | ~25s |
| `--parallel 8` | 15 | ~1m08s |

NFS-mounted qcow2s, 10 GbE direct between lennon and the storage host. The thin backing-file overlay means VM startup reads the base image lazily over NFS — no per-VM copy.

## Supported distros

| Family | Aliases |
| --- | --- |
| EL | `rhel-{8,9,10}`, `rocky-{8,9,10}`, `alma-{8,9,10}`, `centos-stream-{9,10}`, `fedora-44` |
| Debian | `debian-13` (debian-12 disabled — see [#3](https://github.com/aclater/distro-matrix/issues/3)) |
| Ubuntu | `ubuntu-24.04`, `ubuntu-25.10` |
| SUSE | slot reserved (needs SCC qcow2 download — see below) |

`distros.tsv` is the source of truth. CentOS Stream 8 is excluded (EOL 2024-05-31).

## How to add a distro

1. Download the upstream cloud qcow2 to `<image-root>/<distro-dir>/`. Use the dated filename so on-disk provenance is intact.
2. Append a row to `distros.tsv`:
   ```
   <alias>	<family>	<expected_os_id>	<distro-dir>/<filename>.qcow2
   ```
   - `family` is informational (`rhel`, `debian`, `suse`)
   - `expected_os_id` is the `ID=` value the scanner-side `awk` will read from `/etc/os-release` inside the VM (`debian`, `ubuntu`, `rhel`, `rocky`, `almalinux`, `centos`, `fedora`, `sles`)
3. Run `./scripts/run-matrix.sh --only <alias>` to verify.

## SLES 15 SP6+

Reserved slot — populate by hand (SCC registration required, can't be scripted):

1. Sign in to <https://scc.suse.com> with a free Developer subscription
2. Download the SLES 15 SP6 (or SP7) JeOS qcow2 to `<image-root>/sles/`
3. Uncomment and adjust the `sles-15` line in `distros.tsv`

## Regression tests

### FIPS algorithm-fence divergence

`.github/workflows/fips-divergence-regression.yml` boots a 2-VM fleet (one RHEL 10, one rebuild distro 10) under FIPS, runs `pqc_readiness.py --json` on each, and asserts the divergence documented in [pqc-readiness/docs/findings/fips-algorithm-fence.md](https://github.com/aclater/pqc-readiness/blob/main/docs/findings/fips-algorithm-fence.md) holds in both directions:

- The RHEL host must report **zero PQC KEMs and zero PQC signature algorithms** while FIPS is active. If it does not, RHEL's downstream FIPS-provider gating patches have regressed.
- The rebuild host must report **non-zero PQC KEMs or signatures** while FIPS is active. If it does not, the rebuild started carrying the gating patches; investigate before relaxing the test.

The assertion script is `scripts/check-fips-divergence.py`. The classifier (which distro IDs ship the patches) is a single frozenset at the top of that script — adding to it is a claim about a build, not a marketing statement.

The workflow runs weekly (Mondays 07:00 UTC) and on demand via `workflow_dispatch`. It does not run on every PR — libvirt + a self-hosted runner are the assumption. On failure, both VMs' `result.json` files are uploaded as workflow artifacts.

## Known issues

- **debian-12** boots but never acquires a DHCPv4 lease — root cause TBD. Tracked in [#3](https://github.com/aclater/distro-matrix/issues/3). Currently commented out in `distros.tsv`.
- **EL8 family** scanners that use `#!/usr/bin/env python3` will exit 127 — RHEL/Rocky/AlmaLinux 8 cloud images ship `python3.6`/`python3.8` without the `/usr/bin/python3` symlink (operator must `dnf install python3` or `alternatives --set python3`). Not a `distro-matrix` bug, but matrix runs against scanners with this assumption will FAIL on EL8 — see [pqc-readiness#36](https://github.com/aclater/pqc-readiness/issues/36) for the canonical bug-report shape.

## Output layout

```
results/
  20260429T011526Z/
    report.md            ← the markdown table you read first
    summary.json         ← machine-readable per-distro records
    rhel-9/
      result.json        ← scanner stdout
      stderr.log         ← scanner stderr
      exit-code          ← scanner exit code
      os-release         ← guest /etc/os-release (ground truth)
      virt.log           ← virt-install + virsh + scp output
      record.tsv         ← per-distro tab-separated record (parallelism-safe aggregation)
```

## Repository layout

```
.
├── CLAUDE.md                  agent instructions for this repo (and the rest of aclater/*)
├── README.md                  this file
├── distros.tsv                source of truth for the matrix
├── scripts/run-matrix.sh      the runner
├── .github/workflows/         shellcheck CI, Trivy, OpenSSF Scorecard, Dependabot
├── .pre-commit-config.yaml    detect-secrets + shellcheck + hygiene hooks
└── .secrets.baseline
```

## Contributing

- File an issue first (the agent CLAUDE.md insists on this for any work).
- One logical change per commit. Reference the issue (`Closes #N` / `Refs #N`).
- Run `pre-commit run --all-files` and `shellcheck scripts/*.sh` locally.
- For changes to runner behavior, exercise it on at least one EL distro (rhel-9 is fast) and one Debian-family distro (debian-13).

## License

[Apache-2.0](LICENSE).
