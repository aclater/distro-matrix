#!/usr/bin/env bash
# spawn-fleet.sh — boot a fleet of libvirt VMs from distro-matrix's distros.tsv,
# leave them running, and emit an ansible inventory pointing at them.
#
# Reuses distro-matrix's virt-install + cloud-localds pattern. Unlike
# run-matrix.sh, this does NOT run a scanner and does NOT clean up — the VMs
# stay alive so an external orchestrator (ansible) can drive them.
#
# Fleet manifest is read from --manifest (one line per "alias COUNT"), e.g.
#   rhel-9    3
#   rhel-10   3
#   rocky-9   2
#
# Output files in --results-dir:
#   inventory.ini   — ansible inventory grouped by distro family + alias
#   fleet.tsv       — vmname \t alias \t expected_id \t ip
#   <vmname>/       — per-VM cidata + virt logs
set -euo pipefail

DISTROS_FILE="${HOME}/git/distro-matrix/distros.tsv"
IMAGE_ROOT=/mnt/media/iso/linux
MANIFEST=""
RESULTS_DIR=""
WORK_DIR=/var/lib/libvirt/images/pqc-fleet-work
VCPUS=2
MEMORY=2048
DISK=12
BOOT_TIMEOUT=300
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
PARALLEL=6
LIBVIRT_URI=qemu:///system
FIPS=0

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
    --fips) FIPS=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -r $MANIFEST ]] || { echo "manifest required: --manifest" >&2; exit 2; }
[[ -r $DISTROS_FILE ]] || { echo "distros.tsv missing: $DISTROS_FILE" >&2; exit 2; }
# FIPS mode rejects ed25519 keys — fall back to RSA if user didn't override.
if (( FIPS )) && [[ $SSH_KEY == *"id_ed25519.pub" ]] && [[ -r $HOME/.ssh/id_rsa.pub ]]; then
  SSH_KEY="$HOME/.ssh/id_rsa.pub"
fi
[[ -r $SSH_KEY ]] || { echo "ssh pubkey missing: $SSH_KEY" >&2; exit 2; }
[[ -d $IMAGE_ROOT ]] || { echo "image root missing: $IMAGE_ROOT" >&2; exit 2; }

# Pre-flight: warn if libvirtd is configured with --timeout.  systemd-
# managed libvirtd that idles out mid-cloud-init will kill VMs that
# happen to reboot during first-boot configuration (FIPS regenerate,
# kernel-cmdline edits, etc.) and the VMs end up in shut-off state
# without an obvious cause.  We can't auto-install the drop-in (no
# privilege model for that), so surface the diagnostic and the fix.
if systemctl cat libvirtd.service 2>/dev/null | grep -qE 'ExecStart=.*--timeout'; then
  cat <<EOF >&2
[spawn-fleet] WARNING: libvirtd.service is configured with --timeout.
Long-running fleets (especially under --fips, which triggers cloud-init
reboots) can be killed mid-bringup.  Install the no-timeout drop-in:

  sudo install -d /etc/systemd/system/libvirtd.service.d
  sudo tee /etc/systemd/system/libvirtd.service.d/no-timeout.conf <<DROPIN
  [Service]
  ExecStart=
  ExecStart=/usr/bin/libvirtd
  DROPIN
  sudo systemctl daemon-reload
  sudo systemctl restart libvirtd

EOF
fi

if [[ -z $RESULTS_DIR ]]; then
  RESULTS_DIR="$HOME/pqc-fleet-run/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RESULTS_DIR"
sudo mkdir -p "$WORK_DIR"
sudo chown "$(id -u):$(id -g)" "$WORK_DIR"

PUBKEY_CONTENT=$(< "$SSH_KEY")
SSH_KEY_PRIV="${SSH_KEY%.pub}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10 -o BatchMode=yes
          -o GlobalKnownHostsFile=/dev/null)

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# Look up alias in distros.tsv → family, expected_os_id, qcow2 path
lookup_distro() {
  local needle=$1
  awk -F'\t' -v n="$needle" '
    !/^#/ && NF>=4 && $1==n { print $2"\t"$3"\t"$4; found=1; exit }
    END { if (!found) exit 1 }
  ' "$DISTROS_FILE"
}

# Build target list from manifest
declare -a VM_NAMES VM_ALIASES VM_FAMILIES VM_EXPECTED VM_QCOWS
while read -r alias count; do
  [[ -z $alias || $alias =~ ^# ]] && continue
  info=$(lookup_distro "$alias") || { echo "unknown alias: $alias" >&2; exit 1; }
  family=$(echo "$info" | cut -f1)
  expected=$(echo "$info" | cut -f2)
  qcow_rel=$(echo "$info" | cut -f3)
  qcow="$IMAGE_ROOT/$qcow_rel"
  [[ -r $qcow ]] || { echo "qcow missing for $alias: $qcow" >&2; exit 1; }
  for i in $(seq 1 "$count"); do
    VM_NAMES+=("dm-fleet-$alias-$(printf '%02d' "$i")")
    VM_ALIASES+=("$alias")
    VM_FAMILIES+=("$family")
    VM_EXPECTED+=("$expected")
    VM_QCOWS+=("$qcow")
  done
done < "$MANIFEST"

TOTAL=${#VM_NAMES[@]}
log "fleet: $TOTAL VM(s) — ${VM_NAMES[*]}"
log "results: $RESULTS_DIR"
log "work:    $WORK_DIR"
log "concurrency: $PARALLEL"

vm_ipv4() {
  sudo virsh -c "$LIBVIRT_URI" domifaddr "$1" 2>/dev/null \
    | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

write_userdata() {
  local hostname=$1 path=$2
  cat > "$path" <<EOF
#cloud-config
hostname: $hostname
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: matrix
    groups: [sudo, wheel]
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $PUBKEY_CONTENT
EOF
  if (( FIPS )); then
    # Portable across EL9 (has fips-mode-setup) and EL10 (script removed —
    # crypto-policies-scripts only ships update-crypto-policies; we have to
    # apply the FIPS policy, set fips=1 on the kernel cmdline, and rebuild
    # the initramfs with the FIPS dracut module ourselves).
    cat >> "$path" <<'EOF'
write_files:
  - path: /usr/local/sbin/enable-fips.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -eux
      if command -v fips-mode-setup >/dev/null 2>&1; then
        fips-mode-setup --enable
      else
        # EL10 path: crypto-policies-scripts no longer ships fips-mode-setup.
        # Replicate what it did: switch crypto policy, add fips=1 to kernel
        # cmdline (and boot=UUID=... if /boot is its own filesystem, so the
        # dracut FIPS module can mount it pre-pivot to find the kernel HMAC),
        # rebuild initramfs, drop the legacy /etc/system-fips marker.
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
}

boot_one() {
  local idx=$1
  local vm=${VM_NAMES[$idx]}
  local alias=${VM_ALIASES[$idx]}
  local qcow=${VM_QCOWS[$idx]}
  local out_dir="$RESULTS_DIR/$vm"
  local work="$WORK_DIR/$vm"
  local started=$SECONDS

  mkdir -p "$out_dir" "$work"
  log "[$vm] start"

  # Cleanup any stale VM with same name
  sudo virsh -c "$LIBVIRT_URI" destroy "$vm" >/dev/null 2>&1 || true
  sudo virsh -c "$LIBVIRT_URI" undefine "$vm" --remove-all-storage --nvram >/dev/null 2>&1 \
    || sudo virsh -c "$LIBVIRT_URI" undefine "$vm" --remove-all-storage >/dev/null 2>&1 || true

  # Thin overlay backed by upstream qcow2 (work dir is libvirt-readable)
  log "[$vm] backing-file overlay"
  qemu-img create -f qcow2 -F qcow2 -b "$qcow" "$work/disk.qcow2" "${DISK}G" \
    >>"$out_dir/virt.log" 2>&1

  write_userdata "$vm" "$work/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$vm" "$(date -u +%s)" "$vm" \
    > "$work/meta-data"
  cloud-localds "$work/cidata.iso" "$work/user-data" "$work/meta-data" \
    >>"$out_dir/virt.log" 2>&1

  log "[$vm] virt-install"
  if ! sudo virt-install \
        --connect "$LIBVIRT_URI" \
        --name "$vm" \
        --memory "$MEMORY" \
        --vcpus "$VCPUS" \
        --disk "path=$work/disk.qcow2,format=qcow2" \
        --disk "path=$work/cidata.iso,device=cdrom" \
        --import \
        --os-variant detect=on,name=linux2024 \
        --network network=default \
        --graphics none \
        --noautoconsole \
        >>"$out_dir/virt.log" 2>&1; then
    echo "FAIL virt-install" > "$out_dir/status"
    return 1
  fi

  # Wait for IPv4
  local deadline=$(( SECONDS + BOOT_TIMEOUT ))
  local ip=""
  while (( SECONDS < deadline )); do
    ip=$(vm_ipv4 "$vm")
    [[ -n $ip ]] && break
    sleep 5
  done
  if [[ -z $ip ]]; then
    echo "FAIL no-ipv4 after ${BOOT_TIMEOUT}s" > "$out_dir/status"
    return 1
  fi
  log "[$vm] ip=$ip"

  # Wait for SSH. With --fips, also wait for fips=1 in /proc, since cloud-init
  # triggers a reboot after enabling FIPS — connecting during the brief window
  # before reboot returns success but the host is about to drop the connection.
  local ready_check='true'
  if (( FIPS )); then
    ready_check='[ "$(cat /proc/sys/crypto/fips_enabled 2>/dev/null)" = 1 ]'
  fi
  # Re-resolve IP each iteration; cloud-init reboot can yield a new DHCP lease.
  while (( SECONDS < deadline )); do
    local cur_ip
    cur_ip=$(vm_ipv4 "$vm")
    [[ -z $cur_ip ]] && { sleep 5; continue; }
    if ssh "${SSH_OPTS[@]}" -i "$SSH_KEY_PRIV" "matrix@$cur_ip" "$ready_check" >/dev/null 2>&1; then
      echo "$cur_ip" > "$out_dir/ip"
      echo "OK $((SECONDS - started))s" > "$out_dir/status"
      log "[$vm] ssh ready ($((SECONDS - started))s) ip=$cur_ip"
      return 0
    fi
    sleep 5
  done
  echo "FAIL no-ssh after ${BOOT_TIMEOUT}s" > "$out_dir/status"
  return 1
}

# Drive in parallel
for i in "${!VM_NAMES[@]}"; do
  while (( $(jobs -p -r | wc -l) >= PARALLEL )); do
    wait -n 2>/dev/null || true
  done
  boot_one "$i" &
done
wait

# Aggregate fleet.tsv (the inventory shape lives in the Python helper
# next to this script — easier to extend to YAML inventory, host vars,
# or finer-grained group_by-distro-minor without churning bash).
fleet_tsv="$RESULTS_DIR/fleet.tsv"
inv="$RESULTS_DIR/inventory.ini"
: > "$fleet_tsv"
for i in "${!VM_NAMES[@]}"; do
  vm=${VM_NAMES[$i]}
  alias=${VM_ALIASES[$i]}
  family=${VM_FAMILIES[$i]}
  expected=${VM_EXPECTED[$i]}
  ip_file="$RESULTS_DIR/$vm/ip"
  if [[ -r $ip_file ]]; then
    ip=$(cat "$ip_file")
    printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "$alias" "$family" "$expected" "$ip" >> "$fleet_tsv"
  else
    printf '%s\t%s\t%s\t%s\t%s\n' "$vm" "$alias" "$family" "$expected" "FAIL" >> "$fleet_tsv"
  fi
done

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
"$script_dir/inventory.py" \
  --fleet-tsv "$fleet_tsv" \
  --output "$inv" \
  --ssh-user matrix \
  --ssh-key "$SSH_KEY_PRIV"

log "fleet.tsv: $fleet_tsv"
log "inventory: $inv"
echo "RESULTS_DIR=$RESULTS_DIR"
