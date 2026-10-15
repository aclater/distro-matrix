# shellcheck shell=bash
# distro-matrix VM lifecycle library, sourced by run-matrix.sh (and, later,
# spawn-fleet.sh). It owns everything about a VM's life so the drivers only
# decide *what* to run:
#
#   - run IDs: every VM name carries the run ID (dm-<run>-<alias>), so
#     concurrent runs never collide and a run never touches a VM it didn't
#     create (#19);
#   - a cleanup registry plus traps: every VM and work dir a run creates is
#     recorded, and the parent tears all of them down on exit, error or
#     signal (#20);
#   - image resolution: the local cache (~/.cache/pqc-vm-matrix) by alias,
#     then --image-root (#22);
#   - backends: libvirt (virt-install + cloud-localds) and qemu, launched
#     through vm-run (#21) or, with DM_QEMU_DIRECT=1, directly (CI, #46).
#
# Callers set DM_RESULTS_DIR, DM_WORK_DIR, DM_LIBVIRT_URI and DM_SSH_KEY
# (public key path) before calling dm_init.

DM_IMAGE_CACHE=${DM_IMAGE_CACHE:-$HOME/.cache/pqc-vm-matrix}
DM_LIBVIRT_URI=${DM_LIBVIRT_URI:-qemu:///system}
DM_SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
             -o LogLevel=ERROR -o ConnectTimeout=10
             -o BatchMode=yes -o GlobalKnownHostsFile=/dev/null)

dm_log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# First existing default public key, preferring ed25519 (FIPS hosts that
# reject ed25519 need --ssh-key with an RSA key).
dm_default_ssh_key() {
  local k
  for k in id_ed25519 id_ecdsa id_rsa; do
    [[ -r $HOME/.ssh/$k.pub ]] && { echo "$HOME/.ssh/$k.pub"; return 0; }
  done
  return 1
}

# --- Run IDs and the cleanup registry --------------------------------------

dm_new_run_id() {
  printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N2 -tx1 /dev/urandom | tr -d ' \n')"
}

# dm_init: pick a run ID, create the registry and install the traps. The
# EXIT trap runs only in the parent: bash resets traps in async subshells.
dm_init() {
  DM_RUN_ID=${DM_RUN_ID:-$(dm_new_run_id)}
  DM_REGISTRY="$DM_RESULTS_DIR/vms.tsv"
  mkdir -p "$DM_RESULTS_DIR" "$DM_WORK_DIR"
  : >> "$DM_REGISTRY"
  echo "$DM_RUN_ID" > "$DM_RESULTS_DIR/run-id"
  trap dm_cleanup_all EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# VM names: dm-<run>-<alias>, lowercase, [a-z0-9-] only.
dm_vm_name() {
  local a=${1//[^A-Za-z0-9-]/-}
  printf 'dm-%s-%s' "${DM_RUN_ID,,}" "${a,,}"
}

# Guest hostname: no run ID (it would push past 63 chars), no dots.
dm_hostname() { local a=${1//[^A-Za-z0-9-]/-}; printf 'dm-%s' "${a,,}"; }

# Registry rows: backend \t vm \t workdir. Appends are single small writes,
# so concurrent run_one subshells can't interleave a row.
dm_register() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$DM_REGISTRY"; }

dm_destroy_vm() {
  local backend=$1 vm=$2 work=$3
  "dm_${backend}_destroy" "$vm" || true
  if [[ -n $work && -d $work ]]; then
    rm -rf "${work:?}"
  fi
}

# Send SIG to PID and every descendant, children first.
dm_kill_tree() {
  local sig=$1 pid=$2 c
  for c in $(pgrep -P "$pid" 2>/dev/null); do
    dm_kill_tree "$sig" "$c"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
}

# Tear down everything this run registered. Children first, as whole
# process trees: async jobs in a non-interactive shell ignore SIGINT, and
# the ssh/scp they run inherit that, so Ctrl-C reaches none of them. A
# subshell also defers its TERM trap until its foreground ssh exits, which
# can be minutes (a --prepare dnf, a scanner run). Terminating the trees
# makes an interrupt take seconds, not the remaining command time.
dm_cleanup_all() {
  local rc=$?
  trap - EXIT INT TERM
  local pids p _
  pids=$(jobs -p)
  if [[ -n $pids ]]; then
    for p in $pids; do dm_kill_tree TERM "$p"; done
    for _ in $(seq 1 20); do
      jobs -pr | grep -q . || break
      sleep 0.5
    done
    for p in $(jobs -pr); do dm_kill_tree KILL "$p"; done
    wait 2>/dev/null || true
  fi
  if [[ -s ${DM_REGISTRY:-} ]]; then
    local backend vm work
    while IFS=$'\t' read -r backend vm work; do
      [[ -z $vm ]] && continue
      if [[ -e $DM_RESULTS_DIR/keep/$vm ]]; then
        dm_log "[$vm] $(cat "$DM_RESULTS_DIR/keep/$vm" 2>/dev/null || true)"
        continue
      fi
      if "dm_${backend}_exists" "$vm"; then
        dm_log "[$vm] cleanup"
        dm_destroy_vm "$backend" "$vm" "$work"
      elif [[ -n $work && -d $work ]]; then
        rm -rf "${work:?}"
      fi
    done < "$DM_REGISTRY"
  fi
  exit "$rc"
}

# dm_keep VM [REASON]: dm_cleanup_all leaves VM running and logs REASON
# (run-matrix --keep-on-failure keeps failed VMs for debugging; spawn-fleet
# keeps every VM that came up, on purpose).
dm_keep() {
  mkdir -p "$DM_RESULTS_DIR/keep"
  printf '%s\n' "${2:-left running (kept for debugging)}" > "$DM_RESULTS_DIR/keep/$1"
}

# --- Images ----------------------------------------------------------------

# dm_resolve_image ALIAS RELPATH IMAGE_ROOT -> path on stdout.
# Order: cache/images/<alias>.qcow2, the alias without '-'/'.' (rocky-9 ->
# rocky9, the cache's naming), the cache alias whose manifest filename
# matches RELPATH's basename, then IMAGE_ROOT/RELPATH.
dm_resolve_image() {
  local alias=$1 relpath=$2 root=$3 c="$DM_IMAGE_CACHE/images" m
  local stripped=${alias//[-.]/}
  for m in "$c/$alias.qcow2" "$c/$stripped.qcow2"; do
    [[ -r $m ]] && { echo "$m"; return 0; }
  done
  if [[ -r $DM_IMAGE_CACHE/manifest.tsv ]]; then
    m=$(awk -F'\t' -v f="${relpath##*/}" '!/^#/ && $3==f {print $1; exit}' "$DM_IMAGE_CACHE/manifest.tsv")
    [[ -n $m && -r $c/$m.qcow2 ]] && { echo "$c/$m.qcow2"; return 0; }
  fi
  [[ -n $root && -r $root/$relpath ]] && { echo "$root/$relpath"; return 0; }
  return 1
}

# Can a user outside our uid and groups (libvirt's qemu user) read PATH?
# Needs o+x on every directory and o+r on the file, after resolving links.
dm_world_readable() {
  local p d
  p=$(readlink -f "$1") || return 1
  [[ $(stat -c %A "$p") == ???????r?? ]] || return 1
  d=$(dirname "$p")
  while [[ $d != / ]]; do
    [[ $(stat -c %A "$d") == ?????????[xt] ]] || return 1
    d=$(dirname "$d")
  done
}

# --- Guest seed --------------------------------------------------------------

# dm_write_seed WORK HOSTNAME PUBKEY_PATH [EXTRA_USERDATA_FILE]
dm_write_seed() {
  local work=$1 host=$2 pub extra=${4:-}
  pub=$(< "$3")
  cat > "$work/user-data" <<EOF
#cloud-config
hostname: $host
manage_etc_hosts: true
ssh_pwauth: false
users:
  - name: matrix
    groups: [sudo, wheel]
    sudo: 'ALL=(ALL) NOPASSWD:ALL'
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - $pub
EOF
  [[ -n $extra && -r $extra ]] && cat "$extra" >> "$work/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$host" "$(date -u +%s%N)" "$host" > "$work/meta-data"
  cloud-localds "$work/cidata.iso" "$work/user-data" "$work/meta-data"
}

# Virtual size of a disk image in bytes.
dm_image_bytes() {
  qemu-img info --output=json "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["virtual-size"])'
}

# dm_stage_disk BASE WORK DISK_GIB COPY(0|1) -> creates WORK/disk.qcow2
# The disk is DISK_GIB or the base image's own size, whichever is larger. An
# overlay smaller than its backing image truncates the guest's disk: Oracle
# Linux (37 GiB) and Amazon Linux 2023 (25 GiB) then lose the end of their
# root volume and hang in the initramfs (#43); and qemu-img resize refuses
# to shrink a copy.
dm_stage_disk() {
  local base=$1 work=$2 gib=$3 copy=$4 src want have
  src=$(readlink -f "$base")
  want=$(( gib * 1024 * 1024 * 1024 ))
  have=$(dm_image_bytes "$src")
  (( have > want )) && want=$have
  if (( copy )); then
    cp --reflink=auto "$src" "$work/disk.qcow2"
    (( want > have )) && qemu-img resize -q "$work/disk.qcow2" "$want"
  else
    qemu-img create -q -f qcow2 -F qcow2 -b "$src" "$work/disk.qcow2" "$want"
  fi
  return 0
}

# --- libvirt backend -------------------------------------------------------
# The VM's description carries the run ID, so `virsh list` shows whose it is.

dm_libvirt_exists() { virsh -c "$DM_LIBVIRT_URI" dominfo "$1" >/dev/null 2>&1; }

dm_libvirt_create() {
  local vm=$1 work=$2 vcpus=$3 mem=$4
  if dm_libvirt_exists "$vm"; then
    dm_log "[$vm] refusing to reuse an existing domain"
    return 1
  fi
  # cidata as a virtio disk, not a CD-ROM: on q35 a CD-ROM sits on the AHCI
  # SATA controller, and some cloud kernels (Debian 12's linux-image-cloud)
  # have no AHCI driver, so cloud-init never sees the seed (#3).
  virt-install \
    --connect "$DM_LIBVIRT_URI" \
    --name "$vm" \
    --metadata "description=distro-matrix run $DM_RUN_ID" \
    --memory "$mem" \
    --vcpus "$vcpus" \
    --disk "path=$work/disk.qcow2,format=qcow2" \
    --disk "path=$work/cidata.iso,device=disk,bus=virtio,format=raw,readonly=on" \
    --import \
    --os-variant detect=on,name=linux2024 \
    --network network=default \
    --graphics none \
    --noautoconsole
}

# Prints "HOST PORT" once the guest has an address, else nothing.
dm_libvirt_target() {
  virsh -c "$DM_LIBVIRT_URI" domifaddr "$1" 2>/dev/null \
    | awk '/ipv4/ {split($4, a, "/"); print a[1], 22; exit}'
}

dm_libvirt_destroy() {
  local vm=$1
  # Only ever a domain this run created: the caller passes a dm-<run>- name.
  [[ $vm == dm-"${DM_RUN_ID,,}"-* ]] || { dm_log "[$vm] not ours; not destroying"; return 1; }
  virsh -c "$DM_LIBVIRT_URI" destroy "$vm" >/dev/null 2>&1 || true
  virsh -c "$DM_LIBVIRT_URI" undefine "$vm" --remove-all-storage --nvram >/dev/null 2>&1 \
    || virsh -c "$DM_LIBVIRT_URI" undefine "$vm" --remove-all-storage >/dev/null 2>&1 \
    || true
}

# --- qemu backend (through vm-run) -----------------------------------------
# Plain qemu-system-x86_64 launched through ~/.local/bin/vm-run, which admits
# each VM against the host's vCPU budget (and queues it until there's room)
# and runs it in the capped pqc-vms.slice. User-mode networking with an SSH
# port forward on 127.0.0.1: no libvirt, no root, and the base image can stay
# under ~/.cache as an overlay backing file because qemu runs as us. (#21)
#
# State lives in the VM's work dir ($DM_WORK_DIR/<vm>): qemu.pid, ssh-port,
# console.log.

dm_qemu_available() {
  command -v vm-run >/dev/null && command -v qemu-system-x86_64 >/dev/null && [[ -w /dev/kvm ]]
}

# qemu-direct (#46): the same qemu backend without vm-run, for CI runners and
# hosts that don't have it. Opt-in only (--backend qemu-direct); `auto` never
# picks it, because it bypasses the host's vCPU budget. KVM when /dev/kvm is
# writable, else TCG (slow: raise --boot-timeout).
DM_QEMU_DIRECT=${DM_QEMU_DIRECT:-0}
dm_qemu_direct_available() { command -v qemu-system-x86_64 >/dev/null; }

# vm-run's current budget in vCPUs ("vCPU in use: X / N"), or empty.
# awk reads to the end: exiting early would SIGPIPE vm-run, and with
# pipefail + set -e that kills the caller.
dm_vmrun_budget() {
  vm-run --status 2>/dev/null | awk '/vCPU in use:/ {b = $NF} END {print b}'
}

dm_qemu_pid() {
  local f="$DM_WORK_DIR/$1/qemu.pid" pid
  [[ -r $f ]] || return 1
  pid=$(< "$f")
  [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

dm_qemu_exists() { dm_qemu_pid "$1" >/dev/null; }

# A free TCP port on 127.0.0.1 for the SSH forward.
dm_free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

dm_qemu_create() {
  local vm=$1 work=$2 vcpus=$3 mem=$4 port
  if dm_qemu_exists "$vm"; then
    dm_log "[$vm] refusing to reuse a running VM"
    return 1
  fi
  port=$(dm_free_port)
  echo "$port" > "$work/ssh-port"
  local launch=(vm-run --name "$vm") accel=(-machine "q35,accel=kvm" -cpu host)
  if (( DM_QEMU_DIRECT )); then
    launch=()
    [[ -w /dev/kvm ]] || accel=(-machine "q35,accel=tcg" -cpu max)
  fi
  # cidata as a virtio disk, as with libvirt: some cloud kernels (Debian 12)
  # can't see a SATA CD-ROM (#3). vm-run blocks here until the VM fits the
  # budget; the caller's boot timeout starts after this returns.
  "${launch[@]}" qemu-system-x86_64 \
    -name "$vm" \
    "${accel[@]}" \
    -smp "$vcpus" -m "$mem" \
    -drive "file=$work/disk.qcow2,if=virtio,format=qcow2" \
    -drive "file=$work/cidata.iso,if=virtio,format=raw,readonly=on" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$port-:22" \
    -device virtio-net-pci,netdev=n0 \
    -display none -serial "file:$work/console.log" \
    -daemonize -pidfile "$work/qemu.pid"
}

dm_qemu_target() {
  dm_qemu_exists "$1" && [[ -r $DM_WORK_DIR/$1/ssh-port ]] && echo "127.0.0.1 $(< "$DM_WORK_DIR/$1/ssh-port")"
}

dm_qemu_destroy() {
  local vm=$1 pid _
  [[ $vm == dm-"${DM_RUN_ID,,}"-* ]] || { dm_log "[$vm] not ours; not destroying"; return 1; }
  pid=$(dm_qemu_pid "$vm") || return 0
  kill -TERM "$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.5
  done
  kill -KILL "$pid" 2>/dev/null || true
}

# --- SSH -------------------------------------------------------------------

dm_ssh() {
  local host=$1 port=$2; shift 2
  ssh "${DM_SSH_OPTS[@]}" -p "$port" -i "${DM_SSH_KEY%.pub}" "matrix@$host" "$@"
}

dm_scp_to() {
  local host=$1 port=$2 src=$3 dst=$4
  scp "${DM_SSH_OPTS[@]}" -P "$port" -i "${DM_SSH_KEY%.pub}" "$src" "matrix@$host:$dst"
}

dm_scp_from() {
  local host=$1 port=$2 src=$3 dst=$4
  scp "${DM_SSH_OPTS[@]}" -P "$port" -i "${DM_SSH_KEY%.pub}" "matrix@$host:$src" "$dst"
}

# dm_wait_ssh BACKEND VM DEADLINE_SECONDS -> prints "HOST PORT" when ready.
dm_wait_ssh() {
  local backend=$1 vm=$2 deadline=$3 target host port
  while (( SECONDS < deadline )); do
    target=$("dm_${backend}_target" "$vm")
    if [[ -n $target ]]; then
      read -r host port <<< "$target"
      if dm_ssh "$host" "$port" true >/dev/null 2>&1; then
        echo "$host $port"
        return 0
      fi
    fi
    sleep 5
  done
  return 1
}
