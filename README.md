# distro-matrix

Local CI for host-level scanners across upstream Linux cloud images.

Spin up a fresh libvirt VM per distro (RHEL, Rocky, AlmaLinux, CentOS Stream, Fedora, Oracle Linux, Amazon Linux, Ubuntu, Debian, openSUSE), run an arbitrary scanner as root, pull its output back, and report per-distro pass/fail. A distro passes when the scanner ran cleanly, produced output, and the guest's `/etc/os-release` ID matches the expected one; the runner doesn't validate the output's content (schema checks and a before/after compare mode are tracked in #24). The same matrix runner backs the `test-on-distros` wrapper that agents call before submitting PRs that touch host-level behavior.

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
  --only debian13 \
  --parallel 1
```

The runner stages a thin qcow2 overlay, builds a NoCloud cidata.iso with cloud-init that creates a `matrix` user (sudo NOPASSWD + your SSH pubkey), boots the VM via `virt-install --import`, waits for IPv4 + SSH, SCPs your scanner in, runs it as root, pulls `result.json` + `stderr.log` + `exit-code` + `/etc/os-release` back, and writes a markdown report to `results/<UTC ts>/report.md`.

## Two ways to use it

### Direct — for matrix runs you control

`scripts/run-matrix.sh` is the workhorse. Configure `distros.tsv` with the distros you care about (alias, family, expected `os-release` ID, qcow2 path relative to `--image-root`), point at a scanner, run.

### Via wrapper — for agent CI

`~/.local/bin/test-on-distros` (lives outside this repo, in your `$PATH`) is a thin SSH wrapper that pushes a local scanner to a remote host running this repo and prints the report back. Designed for the "before I open a PR, does my change still work on rhel9 and debian13?" workflow:

```
test-on-distros --scanner ./dist/pqc-readiness.pyz --scanner-args '--json' --only rhel9,debian13 --parallel 4
```

`test-on-distros` isn't part of this repo, and isn't installed on every host.

### Backends, images and the host's VM budget

- **`--backend qemu`** (the default when `~/.local/bin/vm-run`, `qemu-system-x86_64` and `/dev/kvm` are available) launches each VM through `vm-run`. Every VM is admitted against the host's vCPU budget and queued until it fits, and it runs in the capped `pqc-vms.slice`. Networking is user-mode with an SSH forward on `127.0.0.1`, so there's no libvirt and no root. `--parallel auto` (the default) is the budget divided by `--vcpus`.
- **`--backend libvirt`** uses `virt-install` on `--connect` (default `qemu:///system`) and the default network, as before. These VMs bypass `vm-run`, so `--parallel auto` means 1; keep it at 1-2 on a shared workstation.
- **Images** resolve from the local cache first (`~/.cache/pqc-vm-matrix/images/<alias>.qcow2`, override with `DM_IMAGE_CACHE`), then from `--image-root`, which is optional. With libvirt, a base image its qemu user can't read (such as anything under `~/.cache`) is copied instead of overlaid automatically.
- **Disks** are `--disk` GiB or the base image's own size, whichever is larger. Some vendor images are big (Oracle Linux 37 GiB, Amazon Linux 2023 25 GiB); a smaller overlay would truncate them and the guest would hang in its initramfs (#43).
- **The SSH key** defaults to the first of `~/.ssh/id_ed25519.pub`, `id_ecdsa.pub` and `id_rsa.pub`.
- **Every VM is named `dm-<run-id>-<alias>`.** Concurrent runs never collide, and a run only ever destroys VMs it created. Ctrl-C, TERM or an error tears down everything the run started, and each unfinished distro is recorded as FAIL with the step it was in.

### Validating output and comparing builds

- **`--schema schemas/pqc-readiness-report.schema.json`** validates each `result.json`; a violation fails that distro and the errors land in `<alias>/schema-A.txt`. The bundled schema is structural: it checks the fields the matrix and its consumers rely on, since pqc-readiness doesn't publish a report schema. It uses `python3-jsonschema` when importable (set `DM_PYTHON` to choose the interpreter), else a small built-in validator for the subset the schema uses.
- **`--compare-scanner PATH`** runs a second scanner build on the same booted VM and writes `<alias>/compare.json`, a JSON diff that ignores timestamps and benchmark numbers. The difference count goes in the report's Notes; it doesn't change the verdict. This is the before/after check for a scanner change.
- **`--prepare prepare/pqc-readiness.tsv`** runs each matching `key<TAB>command` line as root after SSH is up and before the scanner; `key` is an alias, a family from `distros.tsv`, or `*`. Output goes to `<alias>/prepare.log`, and a failing command fails the distro with its own reason. A command may write an interpreter path to `/etc/distro-matrix/interpreter`; both scanners then run as `<interpreter> scanner` instead of through their shebang. The pqc-readiness file installs Python 3.11 on EL8 (alma8, rocky8, ol8, rhel8) and Leap 15.6, whose Python 3.6 (or missing `python3`) can't run it. Preparation adds 3-5 minutes per guest, mostly package metadata. `--prepare-timeout` caps each command (default 900 s).
- **`--ground-truth ground-truth/pqc-readiness.tsv`** runs each `name<TAB>command` line as root on the guest after the scan and saves `<alias>/ground-truth/<name>.txt`: `ssh -Q kex`, `sshd -T`, `openssl list`, the crypto policy, rpm/dpkg package lists. That's what the scanner's output should agree with.

## Keep-alive fleets — `spawn-fleet.sh`

`run-matrix.sh` is one-shot: boot, scan, destroy. For workflows that want VMs to *stay alive* (driving them with Ansible, running multi-step playbooks, comparing per-host results across reboots), use `scripts/spawn-fleet/spawn-fleet.sh`. It's built on the same `scripts/lib/vm.sh` as the runner, so VMs carry a run ID, images come from the local cache before `--image-root`, and no `sudo` is needed. It takes the same `--backend`: the default qemu backend runs every fleet VM through `vm-run` inside the host's budget, with targets like `127.0.0.1:37191`; `--backend libvirt` needs the `libvirt` group and bypasses the budget. Unlike the runner, it:

- reads a manifest of `alias COUNT` pairs (aliases from `distros.tsv`) instead of `--only`;
- runs no scanner: each VM that comes up is left running, and a VM that doesn't is torn down;
- writes `inventory.ini` (Ansible INI, grouped by distro family and alias) and `fleet.tsv` (vm / alias / family / expected_id / host[:port]);
- names VMs `dm-<run-id>-<alias>-NN`, so fleets and matrix runs coexist on one hypervisor.

Defaults are 2 vCPU and 2 GiB per VM; `--parallel auto` follows the `vm-run` budget with qemu and means 2 with libvirt. VMs that came up are logged as "left running (fleet member; remove with teardown-fleet.sh)" when the script exits. FIPS guests reject ed25519 keys, so `--fips` needs an RSA or ECDSA `--ssh-key` (`scripts/fips-divergence.sh` generates one per run).

```bash
printf 'rocky9 2\ndebian12 1\n' > fleet.txt
scripts/spawn-fleet/spawn-fleet.sh --manifest ./fleet.txt --results-dir ./fleet/
ansible -i ./fleet/inventory.ini all -m ping
scripts/teardown-fleet.sh --results-dir ./fleet/
```

`teardown-fleet.sh` reads the run's registry (`vms.tsv`, `run-id`) and only removes VMs from that run. It's idempotent. The inventory emitter is `scripts/spawn-fleet/inventory.py`; a forwarded SSH port becomes `ansible_port`.

### Three FIPS infrastructure fixes baked in

The FIPS path on EL10 hit three landmines during the fleet test that motivated this script. All three are handled inline:

1. **`fips-mode-setup` removed from EL10's `crypto-policies-scripts`.** When `--fips` is set and the binary is absent, cloud-init falls back to `update-crypto-policies --set FIPS` + `grubby --update-kernel=ALL --args="fips=1"` + `dracut -f --regenerate-all` + `:>/etc/system-fips`.
2. **libvirtd `--timeout` killing VMs mid-cloud-init reboot.** On hosts running the monolithic `libvirtd`, `spawn-fleet.sh` warns when `libvirtd.service` has a `--timeout` flag. Install the drop-in below (needs root; not done automatically). The modular `virtqemud` daemons stay up while any domain runs.
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
base image (local cache, or the shared store)
        │
        │  qemu-img create -F qcow2 -b ...  (thin overlay, never smaller than the base;
        │                                     a full copy with libvirt if its qemu user
        ▼                                     can't read the base)
   work/disk.qcow2 ──┐
                     │
   user-data ──┐     │
   meta-data ──┴──> cloud-localds cidata.iso (attached as a read-only virtio disk:
                     │                        some cloud kernels have no SATA/AHCI driver, #3)
                     ▼
   qemu backend:    vm-run qemu-system-x86_64 -machine q35,accel=kvm ...
                    (user-mode network, SSH forwarded to 127.0.0.1:<port>,
                     serial console to work/console.log)
   libvirt backend: virt-install --import ... --network network=default
                     │
                     ▼
   cloud-init reads the seed (NoCloud) ──> `matrix` user, sudo NOPASSWD, our SSH key
                     │
                     ▼
   runner waits for SSH ──> --prepare ──> scanner (and --compare-scanner) ──> --ground-truth
                     │
                     ▼
   copy results back, plus console.log ──> destroy the VM, remove its work dir
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

On a laptop (24-core Framework, local images, qemu backend, 18-vCPU vm-run budget), all 18 cached distros ran with a compare build, schema checks, ground truth and `--prepare` in 4 min 27 s (2026-10-15); most distros take 20-45 s, and the four that need `--prepare` 3-5 minutes. The full results and the rest of the checklist are in [docs/verification/2026-10-15.md](docs/verification/2026-10-15.md). With every image in the local cache (RHEL and the other store-only images copied in), **22 of the 23 distros in `distros.tsv` pass** in 3 min 46 s; `rhel8` fails in preparation until #58 lands ([docs/verification/2026-10-15-full-matrix.md](docs/verification/2026-10-15-full-matrix.md)).

## Supported distros

| Family | Aliases |
| --- | --- |
| EL | `rhel{8,9,10}`, `rocky{8,9,10}`, `alma{8,9,10}`, `stream{9,10}`, `fedora{43,44}`, `ol{8,9}`, `al2023` |
| Debian | `debian13`, `ubuntu2404`, `ubuntu2604` (`debian12` disabled, see [#3](https://github.com/aclater/distro-matrix/issues/3)) |
| SUSE | `leap156`, `leap16`, `tumbleweed` (SLES needs a manual SCC download, see below) |

`distros.tsv` is the source of truth. It's generated by `tools/gen-distros-tsv.py` from the image-cache manifest, and aliases match the cache's `<alias>.qcow2` names.

## How to add a distro

1. Download the upstream cloud image into the image cache and record it in `~/.cache/pqc-vm-matrix/manifest.tsv` (alias, distro-dir, dated filename, sha256 verified against the publisher's checksum, source URL). The hourly saturn sync files it on the shared store under `<distro-dir>/<dated filename>`.
2. If the alias prefix is new, add its family and `os-release` `ID=` to `IDS` in `tools/gen-distros-tsv.py`. Images that can't be cached (e.g. RHEL, which needs a Red Hat login) go in its `EXTRA` list.
3. Run `tools/gen-distros-tsv.py` and commit the regenerated `distros.tsv`.
4. Run `./scripts/run-matrix.sh --only <alias>` to verify it boots and passes.

## SLES 15 SP6+

Reserved slot — populate by hand (SCC registration required, can't be scripted):

1. Sign in to <https://scc.suse.com> with a free Developer subscription
2. Download the SLES 15 SP6 (or SP7) JeOS qcow2 to `<image-root>/sles/`
3. Add it to `EXTRA` in `tools/gen-distros-tsv.py` (alias `sles15`) and regenerate `distros.tsv`

## Regression tests

### CI boot test

`.github/workflows/boot-test.yml` boots one cloud image through `scripts/run-matrix.sh` on every PR and push to main (#46), so regressions in the VM lifecycle (disk staging, cloud-init seed, SSH, cleanup) fail CI instead of surfacing on a local matrix run, as #43 did.

- **Image:** a dated Debian 13 genericcloud build, pinned by its SHA-512 from Debian's `SHA512SUMS` (the workflow checks the publisher's file lists the pinned hash, then the image against it) and cached between runs.
- **Backend:** `--backend qemu-direct`, because runners have no `vm-run`. It launches qemu directly, with KVM when the runner exposes `/dev/kvm` (the workflow opens up its permissions) and TCG otherwise, with a 900 s boot timeout instead of 240 s. `auto` never picks it: it bypasses the host's vCPU budget.
- **Scanner:** `ci/scanner.sh`, a POSIX-sh stand-in that prints the guest's os-release identity as JSON, validated with `--schema schemas/ci-scanner.schema.json`. CI doesn't depend on pqc-readiness.
- **Asserts:** PASS, `os_release.id == debian` and `version_id == 13`, a non-empty `console.log`, and no qemu process or work dir left behind. The report goes to the job summary; the guest console is printed on failure.

The same run locally (wrap it in `vm-run` so it stays inside the host budget; the debian12 image works too):

```bash
vm-run --name dm-ci bash scripts/run-matrix.sh --backend qemu-direct \
  --scanner ci/scanner.sh --schema schemas/ci-scanner.schema.json \
  --only debian13 --vcpus 1 --memory 2048
```

### FIPS algorithm-fence divergence

`scripts/fips-divergence.sh` boots a 2-VM fleet (`rhel10` and `rocky10`, 2 vCPU / 4 GiB each) with FIPS enabled through `spawn-fleet`, runs the pqc-readiness zipapp (`pqc-readiness.pyz --json`) on each, and asserts that the divergence documented in [pqc-readiness/docs/findings/fips-algorithm-fence.md](https://github.com/aclater/pqc-readiness/blob/main/docs/findings/fips-algorithm-fence.md) holds in both directions:

- The RHEL host must report **zero PQC KEMs and zero PQC signature algorithms** while FIPS is active. If it does not, RHEL's downstream FIPS-provider gating patches have regressed.
- The rebuild host must report **non-zero PQC KEMs or signatures** while FIPS is active. If it does not, the rebuild started carrying the gating patches; investigate before relaxing the test.

The assertion script is `scripts/check-fips-divergence.py`. The classifier (which distro IDs ship the patches) is a single frozenset at the top of that script — adding to it is a claim about a build, not a marketing statement.

Run it on demand; it tears the fleet down on exit (`--keep` leaves it running):

```bash
scripts/fips-divergence.sh                          # builds the zipapp from ../pqc-readiness, or downloads the latest release
scripts/fips-divergence.sh --pqc-readiness ./pqc-readiness.pyz --image-root /mnt/media/iso/linux
```

FIPS sshd rejects ed25519 keys, so each run generates a throwaway RSA key in its results directory. RHEL images need a Red Hat login and usually live only on the shared image store. Without one, the RHEL half is skipped with a message, and the script exits 3 so a partial run isn't mistaken for a pass. Exit codes: 0 divergence holds; 1 or 2 divergence broken (see the assertion script); 3 partial run; 4 setup or fleet failure.

**Last verified 2026-10-15** with pqc-readiness 2.4.0 ([details](docs/verification/2026-10-15-full-matrix.md)): RHEL 10.1 under FIPS reported 0 PQC KEMs and 0 PQC signatures; Rocky Linux 10.2 under FIPS reported 3 KEMs (ML-KEM-512/768/1024) and 15 signature algorithms. The divergence holds in both directions (exit 0).

This used to be a scheduled workflow, but it needed a self-hosted libvirt runner that was never registered, so every run was cancelled (#28).

## Known issues

- **RHEL images need a Red Hat login to download** and live on the shared image store. Copy them once into the local cache (`~/.cache/pqc-vm-matrix/images/rhel8.qcow2` etc.) and they work anywhere, or pass `--image-root /mnt/media/iso/linux` at home. Without either, `rhel8`, `rhel9` and `rhel10` fail at once with "image not found locally".
- **`rhel8` preparation fails on the unregistered cloud image:** it has no enabled repositories, so `dnf install python3.11` can't run (#58, which proposes the UBI 8 repositories or an activation key). `rhel9` and `rhel10` need no preparation and pass.

## Output layout

```
results/
  20260429T011526Z/
    report.md            ← the markdown table you read first
    summary.json         ← machine-readable per-distro records
    rocky9/
      result.json        ← scanner stdout
      stderr.log         ← scanner stderr
      exit-code          ← scanner exit code
      os-release         ← guest /etc/os-release (ground truth)
      virt.log           ← disk staging, VM creation and scp output
      console.log        ← the guest's serial console (qemu backend); read this when a VM never comes up
      prepare.log        ← --prepare commands and their output
      result-b.json      ← --compare-scanner stdout (also stderr-b.log, exit-code-b)
      compare.json       ← --compare-scanner diff
      schema-A.txt       ← --schema result (schema-B.txt for the compare build)
      ground-truth/      ← --ground-truth command output, one file per name
      record.tsv         ← per-distro tab-separated record (parallelism-safe aggregation)
```

## Repository layout

```
.
├── CLAUDE.md                  instructions for coding agents working in this repo
├── README.md                  this file
├── distros.tsv                the matrix (generated; see tools/)
├── scripts/run-matrix.sh      the one-shot runner
├── scripts/lib/vm.sh          shared VM lifecycle: backends, run IDs, cleanup, image lookup
├── scripts/spawn-fleet/       keep-alive fleets + Ansible inventory
├── scripts/teardown-fleet.sh  destroys a spawn-fleet run
├── scripts/fips-divergence.sh FIPS fleet + scan + assertion, run locally
├── scripts/check-fips-divergence.py  FIPS algorithm-fence assertion
├── ci/scanner.sh              stand-in scanner for the CI boot test
├── schemas/                   report schemas for --schema (pqc-readiness; CI scanner)
├── ground-truth/              command lists for --ground-truth
├── prepare/                   guest preparation for --prepare
├── tests/                     offline tests (tests/*.sh; need qemu-img)
├── docs/verification/         dated end-to-end verification runs
├── tools/gen-distros-tsv.py   regenerates distros.tsv from the image-cache manifest
├── .github/                   CI (shellcheck, pre-commit, offline tests, boot test), Trivy + CodeQL, Scorecard, Dependabot
├── .pre-commit-config.yaml    detect-secrets + shellcheck + hygiene hooks
└── .secrets.baseline
```

## Contributing

- File an issue first (see CLAUDE.md).
- One logical change per commit. Reference the issue (`Closes #N` / `Refs #N`).
- Run `pre-commit run --all-files` and `shellcheck scripts/*.sh` locally.
- For changes to runner behavior, exercise it on at least one EL distro (rocky9 is fast) and one Debian-family distro (ubuntu2604 or debian13).

## License

[Apache-2.0](LICENSE).
