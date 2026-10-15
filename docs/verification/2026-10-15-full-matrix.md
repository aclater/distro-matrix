# Verification: 2026-10-15, full matrix and the FIPS check

Run at home after copying the store-only images (rhel8, rhel9, rhel10,
debian13, ubuntu2404) from the shared image store into the local cache, so
all 23 distros in `distros.tsv` were available. Laptop: Framework, 24 cores,
62 GiB, Fedora 44; qemu backend through vm-run, 18-vCPU budget (OpenShift
Local stopped). Runner at main `01b43a5`.

Scanners: pqc-readiness **2.4.0** (scanner) and **2.3.0** (compare build),
downloaded from the GitHub releases and checked against their published
`.sha256`.

## FIPS algorithm-fence divergence (#38): holds

```bash
scripts/fips-divergence.sh --pqc-readiness pqc-readiness-2.4.0.pyz
```

| Host | OpenSSL | FIPS provider active | PQC KEMs | PQC signatures |
| --- | --- | --- | --- | --- |
| RHEL 10.1 (Coughlan) | 3.5.1 | yes | 0 | 0 |
| Rocky Linux 10.2 (Red Quartz) | 3.5.5 | yes | 3 (ML-KEM-512, -768, -1024) | 15 |

`check-fips-divergence.py`: "OK: divergence holds in both directions",
exit 0. Both VMs were up with FIPS enabled in under 2 minutes (RHEL 104 s,
Rocky 112 s), the whole check took 2 min 1 s, and teardown removed both VMs.
This is the first run of the RHEL half since the check moved off the
never-registered self-hosted runner.

Caveat: the two hosts run different OpenSSL point releases (3.5.1 vs 3.5.5).
The documented cause of the divergence is RHEL's downstream FIPS-provider
gating, not the version; a future run with matching versions would rule the
version out completely.

## All 23 distros: 22 PASS, 1 FAIL

```bash
scripts/run-matrix.sh --scanner pqc-readiness-2.4.0.pyz --scanner-args '--json --scan-services' \
  --compare-scanner pqc-readiness-2.3.0.pyz \
  --schema schemas/pqc-readiness-report.schema.json \
  --ground-truth ground-truth/pqc-readiness.tsv \
  --prepare prepare/pqc-readiness.tsv \
  --parallel auto
```

23 distros in flight (budget-limited), **3 min 46 s** wall clock.

| Alias | Expected ID | Detected ID | Exit | Duration | Verdict | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| al2023 | amzn | amzn | 3 | 90s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| alma10 | almalinux | almalinux | 3 | 96s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| alma8 | almalinux | almalinux | 3 | 169s | PASS | schema A ok; schema B ok; compare: 3 difference(s) |
| alma9 | almalinux | almalinux | 3 | 94s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| debian12 | debian | debian | 3 | 63s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| debian13 | debian | debian | 3 | 70s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| fedora43 | fedora | fedora | 3 | 112s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| fedora44 | fedora | fedora | 3 | 93s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| leap156 | opensuse-leap | opensuse-leap | 3 | 184s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| leap16 | opensuse-leap | opensuse-leap | 3 | 137s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| ol8 | ol | ol | 3 | 225s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| ol9 | ol | ol | 3 | 101s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| rhel10 | rhel | rhel | 3 | 113s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| rhel8 | rhel | - | ? | 100s | FAIL | prepare failed: dnf -y -q install python3.11 && echo /usr/bin/python3.11 > /etc/distro-matrix/interpreter (no enabled repositories; #58) |
| rhel9 | rhel | rhel | 3 | 110s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| rocky10 | rocky | rocky | 3 | 116s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| rocky8 | rocky | rocky | 3 | 196s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| rocky9 | rocky | rocky | 3 | 122s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| stream10 | centos | centos | 3 | 83s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| stream9 | centos | centos | 3 | 86s | PASS | schema A ok; schema B ok; compare: 1 difference(s) |
| tumbleweed | opensuse-tumbleweed | opensuse-tumbleweed | 3 | 93s | PASS | schema A ok; schema B ok; compare: 3 difference(s) |
| ubuntu2404 | ubuntu | ubuntu | 3 | 73s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |
| ubuntu2604 | ubuntu | ubuntu | 3 | 85s | PASS | schema A ok; schema B ok; compare: 2 difference(s) |


- **rhel8:** the unregistered RHEL 8.10 cloud image has no enabled
  repositories, so the prepare step's `dnf install python3.11` fails
  ("There are no enabled repositories"). RHEL 8's own Python 3.6 can't run
  pqc-readiness. #58 proposes the UBI 8 repositories (no subscription) or an
  activation key. rhel9 and rhel10 need no preparation and pass.
- **Exit 3** is pqc-readiness's "poor" performance tier on a 2-vCPU guest, not
  a failure; the runner treats 0-123 as a clean run.

### What changed between 2.3.0 and 2.4.0 on these hosts

Across the 22 passing distros, the compare diffs contain only:

| Path | Distros | Meaning |
| --- | --- | --- |
| `schema_version` | 22 | 1.7 → 1.8, expected for the release |
| `service_crypto_linkage.scanned_pids` | 10 | process count differs by one or two between the two scanner runs (run-to-run noise, not a scanner change) |
| `nss.tool` | 4 (alma8, rocky8, leap16, tumbleweed) | the NSS version is now read from the rpm database directly (`rpmdb (bdb)`) instead of running `rpm -q`; same version reported |

No PQC capability, configuration or verdict field changed on a booted stock
host, which matches pqc-readiness's own finding: its 2.3/2.4 accuracy fixes
change results only for `--host-mount` and offline scans.
