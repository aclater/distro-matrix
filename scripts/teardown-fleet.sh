#!/usr/bin/env bash
# teardown-fleet.sh — destroy + undefine every VM listed in a spawn-fleet
# results directory's fleet.tsv, then remove the disk overlays.
#
# Idempotent: VMs that no longer exist are silently skipped.  Disk
# overlays are removed last; the script does not touch the upstream
# qcow2 backing files.
set -euo pipefail

RESULTS_DIR=""
WORK_DIR=/var/lib/libvirt/images/pqc-fleet-work
LIBVIRT_URI=qemu:///system

while [[ $# -gt 0 ]]; do
  case "$1" in
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --workdir)     RESULTS_DIR=$2; shift 2 ;;  # alias for symmetry
    --work-dir)    WORK_DIR=$2; shift 2 ;;
    --connect)     LIBVIRT_URI=$2; shift 2 ;;
    -h|--help)
      cat <<EOF
Usage: teardown-fleet.sh --results-dir <DIR> [--work-dir <DIR>] [--connect <URI>]
EOF
      exit 0
      ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -d $RESULTS_DIR ]] || { echo "results dir missing: $RESULTS_DIR" >&2; exit 2; }
fleet_tsv="$RESULTS_DIR/fleet.tsv"
[[ -r $fleet_tsv ]] || { echo "fleet.tsv missing: $fleet_tsv" >&2; exit 2; }

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Read first column (vm name) of every non-comment row
mapfile -t vms < <(awk -F'\t' '!/^#/ && NF>=1 && $1 { print $1 }' "$fleet_tsv")

log "tearing down ${#vms[@]} VM(s) from $fleet_tsv"
for vm in "${vms[@]}"; do
  if virsh --connect "$LIBVIRT_URI" dominfo "$vm" >/dev/null 2>&1; then
    state=$(virsh --connect "$LIBVIRT_URI" domstate "$vm" 2>/dev/null || echo unknown)
    if [[ $state == "running" ]]; then
      virsh --connect "$LIBVIRT_URI" destroy "$vm" >/dev/null || true
    fi
    virsh --connect "$LIBVIRT_URI" undefine "$vm" --remove-all-storage >/dev/null 2>&1 \
      || virsh --connect "$LIBVIRT_URI" undefine "$vm" >/dev/null 2>&1 \
      || true
    log "  removed: $vm"
  else
    log "  not defined: $vm"
  fi
  # Remove any leftover overlay/cidata artifacts.  The :? guard makes
  # rm refuse to expand WORK_DIR/$vm to "/" if either side is somehow
  # empty — defense in depth for shellcheck SC2115.
  if [[ -n $vm && -d $WORK_DIR/$vm ]]; then
    rm -rf "${WORK_DIR:?}/${vm:?}" || true
  fi
done

log "done"
