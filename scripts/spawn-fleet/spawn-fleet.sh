#!/usr/bin/env bash
# spawn-fleet.sh — boot a fleet of VMs from distros.tsv, leave them running,
# and emit an Ansible inventory pointing at them.
#
# Built on scripts/lib/vm.sh, like run-matrix.sh: VM names carry a run ID
# (dm-<run>-<alias>-NN), images resolve from the local cache before
# --image-root, and no sudo is needed. The default qemu backend launches
# each VM through ~/.local/bin/vm-run, inside the host's vCPU budget, with an
# SSH port forward on 127.0.0.1; --backend libvirt uses virt-install (the
# user must be in the libvirt group, and those VMs bypass the budget). Unlike run-matrix.sh, it runs no scanner and leaves every VM that
# came up running; VMs that fail to come up, and everything on an interrupt,
# are torn down. Remove a fleet with scripts/teardown-fleet.sh.
#
# Usage:
#   spawn-fleet.sh --manifest FILE [--fips] [opts]
#
# Fleet manifest (--manifest), one "alias COUNT" per line, aliases from
# distros.tsv:
#   rocky9     2
#   ubuntu2604 1
#
# Options:
#   --distros PATH        distros.tsv (default: <repo>/distros.tsv)
#   --image-root PATH     shared image store (default: /mnt/media/iso/linux)
#   --results-dir PATH    default: <repo>/results/fleet-<UTC ts>
#   --work-dir PATH       per-VM disks (default: /tmp/distro-matrix-work)
#   --backend B           qemu (through vm-run), libvirt, or auto (default:
#                         qemu when vm-run, qemu-system-x86_64 and /dev/kvm
#                         are available, else libvirt)
#   --vcpus N             vCPUs per VM (default: 2)
#   --memory MIB          RAM per VM (default: 2048)
#   --disk GIB            disk size (default: 12)
#   --boot-timeout SEC    per VM, including the FIPS reboot (default: 300)
#   --ssh-key PATH        public key (default: first of id_ed25519/ecdsa/rsa;
#                         FIPS guests reject ed25519, see --fips)
#   --parallel N|auto     VMs booting at once (default: auto: the vm-run
#                         budget / --vcpus with qemu, 2 with libvirt)
#   --connect URI         libvirt URI (default: qemu:///system)
#   --fips                enable FIPS mode in each guest (EL9 and EL10)
#
# Output in --results-dir:
#   inventory.ini   Ansible inventory grouped by distro family and alias
#   fleet.tsv       vm \t alias \t family \t expected_id \t host[:port] (or FAIL)
#   vms.tsv, run-id the lib's registry; teardown-fleet.sh reads them
#   <vm>/           per-VM virt.log and status
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
# shellcheck source=../lib/vm.sh disable=SC1091
source "$REPO_ROOT/scripts/lib/vm.sh"

DISTROS_FILE="$REPO_ROOT/distros.tsv"
IMAGE_ROOT=/mnt/media/iso/linux
MANIFEST=""
RESULTS_DIR=""
WORK_DIR=/tmp/distro-matrix-work
VCPUS=2
MEMORY=2048
DISK=12
BOOT_TIMEOUT=300
SSH_KEY=$(dm_default_ssh_key || echo "$HOME/.ssh/id_ed25519.pub")
PARALLEL=auto
BACKEND=auto
LIBVIRT_URI=qemu:///system
FIPS=0

usage() { sed -n '/^# Usage:/,/^# Output/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distros) DISTROS_FILE=$2; shift 2 ;;
    --image-root) IMAGE_ROOT=$2; shift 2 ;;
    --manifest) MANIFEST=$2; shift 2 ;;
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --work-dir) WORK_DIR=$2; shift 2 ;;
    --vcpus) VCPUS=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    --parallel) PARALLEL=$2; shift 2 ;;
    --connect) LIBVIRT_URI=$2; shift 2 ;;
    --backend) BACKEND=$2; shift 2 ;;
    --fips) FIPS=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 2 ;;
  esac
done

[[ -r $MANIFEST ]] || { echo "manifest required: --manifest" >&2; exit 2; }
[[ -r $DISTROS_FILE ]] || { echo "distros.tsv missing: $DISTROS_FILE" >&2; exit 2; }
if (( FIPS )) && [[ $SSH_KEY == *ed25519* ]]; then
  echo "--fips: FIPS guests reject ed25519 keys; pass --ssh-key with an RSA or ECDSA key" >&2
  exit 2
fi
[[ -r $SSH_KEY ]] || { echo "ssh pubkey missing: $SSH_KEY" >&2; exit 2; }
for cmd in virsh virt-install cloud-localds qemu-img ssh; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 2; }
done

# A monolithic libvirtd started with --timeout can exit while a guest is
# mid cloud-init reboot (--fips reboots once), leaving it shut off with no
# obvious cause. Only a warning: installing the drop-in needs root.
if systemctl cat libvirtd.service 2>/dev/null | grep -qE 'ExecStart=.*--timeout'; then
  echo "[spawn-fleet] WARNING: libvirtd.service runs with --timeout; long fleets (especially --fips) can be killed mid-boot. See README, 'FIPS infrastructure fixes'." >&2
fi

RESULTS_DIR=${RESULTS_DIR:-$REPO_ROOT/results/fleet-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$RESULTS_DIR" "$WORK_DIR"
log() { dm_log "$@"; }

# Read by lib/vm.sh.
# shellcheck disable=SC2034
DM_RESULTS_DIR=$RESULTS_DIR
# shellcheck disable=SC2034
DM_WORK_DIR=$WORK_DIR
# shellcheck disable=SC2034
DM_LIBVIRT_URI=$LIBVIRT_URI
# shellcheck disable=SC2034
DM_SSH_KEY=$SSH_KEY
case $BACKEND in
  auto) if dm_qemu_available; then BACKEND=qemu; else BACKEND=libvirt; fi ;;
  qemu) dm_qemu_available || { echo "qemu backend needs vm-run, qemu-system-x86_64 and a writable /dev/kvm" >&2; exit 2; } ;;
  libvirt) ;;
  *) echo "unknown --backend: $BACKEND (qemu|libvirt|auto)" >&2; exit 2 ;;
esac
if [[ $PARALLEL == auto ]]; then
  if [[ $BACKEND == qemu ]]; then
    budget=$(dm_vmrun_budget)
    PARALLEL=$(( ${budget:-$VCPUS} / VCPUS ))
    (( PARALLEL >= 1 )) || PARALLEL=1
  else
    PARALLEL=2
  fi
fi
[[ $PARALLEL =~ ^[1-9][0-9]*$ ]] || { echo "--parallel must be a positive integer or auto" >&2; exit 2; }
dm_init

# alias -> "family \t expected_os_id \t qcow2_relpath"
lookup_distro() {
  awk -F'\t' -v n="$1" '
    !/^#/ && NF>=4 && $1==n { print $2"\t"$3"\t"$4; found=1; exit }
    END { if (!found) exit 1 }
  ' "$DISTROS_FILE"
}

declare -a VM_NAMES VM_ALIASES VM_FAMILIES VM_EXPECTED VM_RELPATHS
while read -r alias count; do
  [[ -z $alias || $alias =~ ^# ]] && continue
  info=$(lookup_distro "$alias") || { echo "unknown alias: $alias (see $DISTROS_FILE)" >&2; exit 1; }
  IFS=$'\t' read -r family expected relpath <<< "$info"
  for i in $(seq 1 "$count"); do
    VM_NAMES+=("$(dm_vm_name "$alias")-$(printf '%02d' "$i")")
    VM_ALIASES+=("$alias")
    VM_FAMILIES+=("$family")
    VM_EXPECTED+=("$expected")
    VM_RELPATHS+=("$relpath")
  done
done < "$MANIFEST"
(( ${#VM_NAMES[@]} > 0 )) || { echo "manifest selects no VMs" >&2; exit 1; }

log "fleet: ${#VM_NAMES[@]} VM(s), run $DM_RUN_ID: ${VM_NAMES[*]}"
log "results: $RESULTS_DIR (backend $BACKEND, vcpus $VCPUS, memory ${MEMORY}M, parallel $PARALLEL)"

# FIPS: portable across EL9 (fips-mode-setup) and EL10 (script removed:
# apply the policy, add fips=1 to the kernel cmdline, and rebuild the
# initramfs with the FIPS dracut module ourselves). cloud-init reboots once.
FIPS_USERDATA=""
if (( FIPS )); then
  FIPS_USERDATA="$RESULTS_DIR/fips-user-data.yaml"
  cat > "$FIPS_USERDATA" <<'EOF'
write_files:
  - path: /usr/local/sbin/enable-fips.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -eux
      if command -v fips-mode-setup >/dev/null 2>&1; then
        fips-mode-setup --enable
      else
        # EL10: crypto-policies-scripts no longer ships fips-mode-setup.
        # boot=UUID=... lets the dracut FIPS module find the kernel HMAC
        # pre-pivot when /boot is its own filesystem.
        update-crypto-policies --set FIPS
        args="fips=1"
        if mountpoint -q /boot; then
          boot_uuid=$(findmnt -no UUID /boot)
          [ -n "$boot_uuid" ] && args="$args boot=UUID=$boot_uuid"
        fi
        grubby --update-kernel=ALL --args="$args"
        dracut -f --regenerate-all
        : >/etc/system-fips || true
      fi
runcmd:
  - [ /usr/local/sbin/enable-fips.sh ]
power_state:
  mode: reboot
  delay: now
  message: enabling FIPS mode
  condition: True
EOF
fi

boot_one() {
  local idx=$1
  local vm=${VM_NAMES[$idx]} alias=${VM_ALIASES[$idx]}
  local out_dir="$RESULTS_DIR/$vm" work="$WORK_DIR/$vm" started=$SECONDS
  mkdir -p "$out_dir"
  log "[$vm] start"

  local qcow
  if ! qcow=$(dm_resolve_image "$alias" "${VM_RELPATHS[$idx]}" "$IMAGE_ROOT"); then
    echo "FAIL image not found for $alias" > "$out_dir/status"
    log "[$vm] image not found"
    return 1
  fi
  local copy=0
  if [[ $BACKEND == libvirt ]] && ! dm_world_readable "$qcow"; then
    log "[$vm] base image isn't readable by libvirt's qemu user; copying"
    copy=1
  fi
  mkdir -p "$work"
  dm_register "$BACKEND" "$vm" "$work"
  if ! { dm_stage_disk "$qcow" "$work" "$DISK" "$copy" \
         && dm_write_seed "$work" "$(dm_hostname "$alias")" "$SSH_KEY" "$FIPS_USERDATA" \
         && "dm_${BACKEND}_create" "$vm" "$work" "$VCPUS" "$MEMORY"; } >>"$out_dir/virt.log" 2>&1; then
    echo "FAIL create (see virt.log)" > "$out_dir/status"
    dm_destroy_vm "$BACKEND" "$vm" "$work"
    return 1
  fi

  # Ready when SSH works (and, with --fips, the kernel reports FIPS on).
  # Re-resolve the address each time: the FIPS reboot can bring a new lease.
  local ready='true'
  # shellcheck disable=SC2016  # expands on the guest, not here
  (( FIPS )) && ready='[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]'
  local deadline=$(( SECONDS + BOOT_TIMEOUT )) target host port
  while (( SECONDS < deadline )); do
    target=$("dm_${BACKEND}_target" "$vm")
    if [[ -n $target ]]; then
      read -r host port <<< "$target"
      if dm_ssh "$host" "$port" "$ready" </dev/null >/dev/null 2>&1; then
        if [[ $port == 22 ]]; then echo "$host" > "$out_dir/target"; else echo "$host:$port" > "$out_dir/target"; fi
        echo "OK $((SECONDS - started))s" > "$out_dir/status"
        dm_keep "$vm" "left running (fleet member; remove with teardown-fleet.sh)"
        log "[$vm] ready in $((SECONDS - started))s at $host:$port"
        return 0
      fi
    fi
    sleep 5
  done
  echo "FAIL not ready after ${BOOT_TIMEOUT}s" > "$out_dir/status"
  log "[$vm] not ready after ${BOOT_TIMEOUT}s; tearing it down"
  dm_destroy_vm "$BACKEND" "$vm" "$work"
  return 1
}

for i in "${!VM_NAMES[@]}"; do
  while (( $(jobs -p -r | wc -l) >= PARALLEL )); do
    wait -n 2>/dev/null || true
  done
  boot_one "$i" &
done
wait || true

fleet_tsv="$RESULTS_DIR/fleet.tsv"
: > "$fleet_tsv"
for i in "${!VM_NAMES[@]}"; do
  vm=${VM_NAMES[$i]}
  target=FAIL
  [[ -r $RESULTS_DIR/$vm/target ]] && target=$(< "$RESULTS_DIR/$vm/target")
  printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "${VM_ALIASES[$i]}" "${VM_FAMILIES[$i]}" \
    "${VM_EXPECTED[$i]}" "$target" >> "$fleet_tsv"
done

"$SCRIPT_DIR/inventory.py" --fleet-tsv "$fleet_tsv" --output "$RESULTS_DIR/inventory.ini" \
  --ssh-user matrix --ssh-key "${SSH_KEY%.pub}"

log "fleet.tsv: $fleet_tsv"
log "inventory: $RESULTS_DIR/inventory.ini"
echo "RESULTS_DIR=$RESULTS_DIR"
