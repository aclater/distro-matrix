#!/usr/bin/env bash
# teardown-fleet.sh — destroy the VMs a spawn-fleet run created, and their
# disks.
#
# Reads the run's registry (vms.tsv) and run ID from --results-dir and only
# touches VMs named dm-<that run>-*, so it can't remove another run's VMs.
# Idempotent: VMs that no longer exist are skipped. Upstream base images are
# never touched.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/vm.sh disable=SC1091
source "$SCRIPT_DIR/lib/vm.sh"

RESULTS_DIR=""
LIBVIRT_URI=qemu:///system

while [[ $# -gt 0 ]]; do
  case "$1" in
    --results-dir|--workdir) RESULTS_DIR=$2; shift 2 ;;
    --connect) LIBVIRT_URI=$2; shift 2 ;;
    -h|--help)
      echo "Usage: teardown-fleet.sh --results-dir <DIR> [--connect <URI>]"
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d $RESULTS_DIR ]] || { echo "results dir missing: $RESULTS_DIR" >&2; exit 2; }
[[ -r $RESULTS_DIR/run-id && -r $RESULTS_DIR/vms.tsv ]] \
  || { echo "no run-id/vms.tsv in $RESULTS_DIR (not a spawn-fleet results dir?)" >&2; exit 2; }

# Read by lib/vm.sh.
# shellcheck disable=SC2034
DM_LIBVIRT_URI=$LIBVIRT_URI
DM_RUN_ID=$(< "$RESULTS_DIR/run-id")

n=0
while IFS=$'\t' read -r backend vm work; do
  [[ -z $vm ]] && continue
  if "dm_${backend}_exists" "$vm"; then
    dm_destroy_vm "$backend" "$vm" "$work"
    dm_log "removed: $vm"
    n=$((n + 1))
  else
    [[ -n $work && -d $work ]] && rm -rf "${work:?}"
    dm_log "not defined: $vm"
  fi
  rm -f "$RESULTS_DIR/keep/$vm"
done < "$RESULTS_DIR/vms.tsv"

dm_log "done: removed $n VM(s) from run $DM_RUN_ID"
