#!/usr/bin/env bash
# check-no-secrets.sh DIR... : fail if the RHSM activation key or org ID (#58)
# appears anywhere under DIR (e.g. a run's results and work dirs). Reads the
# credentials the same way run-matrix does (env, else keyring); the search
# pattern goes to grep through a file descriptor, never argv.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/vm.sh disable=SC1091
source "$here/lib/vm.sh"
(( $# )) || { echo "usage: check-no-secrets.sh DIR..." >&2; exit 2; }
dm_rhsm_load || { echo "no RHSM credentials configured; nothing to check"; exit 0; }
found=0
for d in "$@"; do
  [[ -e $d ]] || continue
  # -a: search binary files too (disk images, logs with control characters).
  if grep -rlaF -f <(printf '%s\n%s\n' "$DMR_KEY" "$DMR_ORG") -- "$d"; then
    found=1
  fi
done
if (( found )); then
  echo "FAIL: RHSM credentials found in the files listed above" >&2
  exit 1
fi
echo "ok: no RHSM credentials under $*"
