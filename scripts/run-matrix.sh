#!/usr/bin/env bash
# distro-matrix runner — boot a fresh libvirt VM per distro from a local cloud
# qcow2, inject a NoCloud cidata.iso so cloud-init creates a `matrix` user with
# our SSH key, run the scanner over SSH, pull JSON output back, and emit a
# markdown report.
#
# Why libvirt + cloud-localds (not Incus): the Incus path required either
# Incus-flavored stripped images (no cloud-init, defeats the purpose) or
# wrestling with Incus-side cloud-init injection that silently no-ops on
# hand-imported qcow2s. The cloud-localds + virt-install flow is what every
# upstream cloud image is tested against, so it just works.
#
# Usage:
#   scripts/run-matrix.sh --scanner /path/to/scanner [opts]
#
# Required:
#   --scanner PATH            Local path to the scanner. Pushed to the VM at
#                             /usr/local/bin/scanner and invoked as root via
#                             sudo. stdout → result.json, stderr → stderr.log.
#
# Optional:
#   --scanner-args 'STR'      Extra args to pass to the scanner (e.g. '--json').
#
# Optional:
#   --distros PATH            distros.tsv (default: <repo>/distros.tsv)
#   --image-root PATH         Where qcow2s live (default: /mnt/media/iso/linux)
#   --results-dir PATH        Where reports land (default: <repo>/results/<UTC ts>)
#   --work-dir PATH           Per-VM disk + cidata staging (default: /tmp/distro-matrix-work)
#   --only LIST               Comma-separated alias subset (e.g. debian-13,rhel-9)
#   --skip LIST               Comma-separated aliases to skip
#   --vcpus N                 vCPUs per VM (default: 1)
#   --memory MIB              RAM per VM in MiB (default: 1536)
#   --disk GIB                Resize qcow2 to this GiB before boot (default: 10)
#   --boot-timeout SEC        Max seconds for IP + SSH (default: 240)
#   --scanner-timeout SEC     Max seconds for the scanner itself (default: 300)
#   --ssh-key PATH            SSH pubkey to inject (default: ~/.ssh/id_rsa.pub)
#   --parallel N              Run N distros in parallel (default: 1)
#   --no-backing              Copy qcow2 instead of using qemu-img backing-file overlay.
#                             Use this if --image-root isn't libvirt-readable.
#   --keep-on-failure         Leave the VM + workdir for the failed distro (debug)
#   --connect URI             libvirt URI (default: qemu:///system)
#   --help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Defaults
DISTROS_FILE="$REPO_ROOT/distros.tsv"
IMAGE_ROOT=/mnt/media/iso/linux
RESULTS_DIR=""
WORK_DIR=/tmp/distro-matrix-work
SCANNER=""
SCANNER_ARGS=""
ONLY=""
SKIP=""
VCPUS=1
MEMORY=1536
DISK=10
BOOT_TIMEOUT=240
SCANNER_TIMEOUT=300
SSH_KEY="$HOME/.ssh/id_rsa.pub"
PARALLEL=1
NO_BACKING=0
KEEP_ON_FAILURE=0
LIBVIRT_URI=qemu:///system

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scanner) SCANNER=$2; shift 2 ;;
    --scanner-args) SCANNER_ARGS=$2; shift 2 ;;
    --distros) DISTROS_FILE=$2; shift 2 ;;
    --image-root) IMAGE_ROOT=$2; shift 2 ;;
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --work-dir) WORK_DIR=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --skip) SKIP=$2; shift 2 ;;
    --vcpus) VCPUS=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT=$2; shift 2 ;;
    --scanner-timeout) SCANNER_TIMEOUT=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    --parallel) PARALLEL=$2; shift 2 ;;
    --no-backing) NO_BACKING=1; shift ;;
    --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
    --connect) LIBVIRT_URI=$2; shift 2 ;;
    --help|-h) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 2 ;;
  esac
done

[[ -n $SCANNER ]] || { echo "--scanner is required" >&2; usage 2; }
[[ -r $SCANNER ]] || { echo "scanner not readable: $SCANNER" >&2; exit 2; }
[[ -r $DISTROS_FILE ]] || { echo "distros file not readable: $DISTROS_FILE" >&2; exit 2; }
[[ -r $SSH_KEY ]] || { echo "ssh pubkey not readable: $SSH_KEY" >&2; exit 2; }
[[ -d $IMAGE_ROOT ]] || { echo "image-root not a directory: $IMAGE_ROOT" >&2; exit 2; }
for cmd in virsh virt-install cloud-localds qemu-img jq ssh scp; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 2; }
done

if [[ -z $RESULTS_DIR ]]; then
  RESULTS_DIR="$REPO_ROOT/results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RESULTS_DIR" "$WORK_DIR"

REPORT="$RESULTS_DIR/report.md"
SUMMARY_JSON="$RESULTS_DIR/summary.json"
SSH_KEY_PRIV="${SSH_KEY%.pub}"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR -o ConnectTimeout=10
          -o BatchMode=yes -o GlobalKnownHostsFile=/dev/null)

# --- Parse distros.tsv -----------------------------------------------------
declare -a ALIASES FAMILIES EXPECTED_OS QCOW_PATHS
while IFS=$'\t' read -r alias family expected_os qcow_relpath; do
  [[ $alias =~ ^# ]] && continue
  [[ -z $alias ]] && continue
  if [[ -n $ONLY && ",$ONLY," != *",$alias,"* ]]; then continue; fi
  if [[ -n $SKIP && ",$SKIP," == *",$alias,"* ]]; then continue; fi
  ALIASES+=("$alias")
  FAMILIES+=("$family")
  EXPECTED_OS+=("$expected_os")
  QCOW_PATHS+=("$IMAGE_ROOT/$qcow_relpath")
done < "$DISTROS_FILE"

if [[ ${#ALIASES[@]} -eq 0 ]]; then
  echo "no distros selected (check --only/--skip and distros.tsv)" >&2
  exit 1
fi

log "matrix: ${#ALIASES[@]} distro(s) — ${ALIASES[*]}"
log "results dir: $RESULTS_DIR"
log "work dir: $WORK_DIR"

PUBKEY_CONTENT=$(< "$SSH_KEY")

# --- Per-distro state ------------------------------------------------------
# Parallel runs write their record to $RESULTS_DIR/<alias>/record.tsv so the
# parent doesn't have to share an in-memory array (subshells can't write back).

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
}

vm_ipv4() {
  virsh -c "$LIBVIRT_URI" domifaddr "$1" 2>/dev/null \
    | awk '/ipv4/ {split($4, a, "/"); print a[1]; exit}'
}

cleanup_vm() {
  local vm=$1 work=$2 verdict=$3
  if [[ $verdict == "FAIL" && $KEEP_ON_FAILURE -eq 1 ]]; then
    log "[$vm] keeping VM + work dir (debug)"
    return
  fi
  virsh -c "$LIBVIRT_URI" destroy "$vm" >/dev/null 2>&1 || true
  virsh -c "$LIBVIRT_URI" undefine "$vm" --remove-all-storage --nvram >/dev/null 2>&1 \
    || virsh -c "$LIBVIRT_URI" undefine "$vm" --remove-all-storage >/dev/null 2>&1 \
    || true
  rm -rf "$work"
}

record() {
  # alias \t expected \t detected \t exit \t duration \t verdict \t notes
  local out_dir="$RESULTS_DIR/$1"
  mkdir -p "$out_dir"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    > "$out_dir/record.tsv"
}

run_one() {
  local idx=$1
  local alias=${ALIASES[$idx]}
  local family=${FAMILIES[$idx]}
  local expected=${EXPECTED_OS[$idx]}
  local qcow=${QCOW_PATHS[$idx]}
  local vm="dm-$alias"
  local work="$WORK_DIR/$alias"
  local out_dir="$RESULTS_DIR/$alias"
  local notes=""
  local detected_id=""
  local exit_code="?"
  local verdict="FAIL"
  local started=$SECONDS

  mkdir -p "$out_dir" "$work"
  log "[$alias] start"

  if [[ ! -r $qcow ]]; then
    notes="qcow2 missing: $qcow"
    log "[$alias] $notes"
    record "$alias" "$expected" "" "?" "0" "FAIL" "$notes"
    return
  fi

  # Make sure no leftover VM by this name
  virsh -c "$LIBVIRT_URI" destroy "$vm" >/dev/null 2>&1 || true
  virsh -c "$LIBVIRT_URI" undefine "$vm" --remove-all-storage >/dev/null 2>&1 || true

  # Stage disk + cidata.iso. By default, create a thin qcow2 overlay backed
  # by the upstream qcow2 — qemu reads the base over NFS, writes to the
  # local overlay (typically tens of MB). --no-backing falls back to a full
  # copy for setups where qemu can't reach the image-root.
  if (( NO_BACKING )); then
    log "[$alias] copying qcow2 ($(du -h "$qcow" | cut -f1))"
    cp "$qcow" "$work/disk.qcow2"
    qemu-img resize "$work/disk.qcow2" "${DISK}G" >>"$out_dir/virt.log" 2>&1
  else
    log "[$alias] backing-file overlay over $qcow"
    qemu-img create -f qcow2 -F qcow2 -b "$qcow" "$work/disk.qcow2" "${DISK}G" \
      >>"$out_dir/virt.log" 2>&1
  fi
  write_userdata "$vm" "$work/user-data"
  printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$vm" "$(date -u +%s)" "$vm" > "$work/meta-data"
  cloud-localds "$work/cidata.iso" "$work/user-data" "$work/meta-data" \
    >>"$out_dir/virt.log" 2>&1

  # Boot
  log "[$alias] virt-install"
  if ! virt-install \
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
    notes="virt-install failed (see $out_dir/virt.log)"
    cleanup_vm "$vm" "$work" "FAIL"
    record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$notes"
    return
  fi

  # Wait for IPv4 from libvirt's default network DHCP
  local deadline=$(( SECONDS + BOOT_TIMEOUT ))
  local ip=""
  while (( SECONDS < deadline )); do
    ip=$(vm_ipv4 "$vm")
    [[ -n $ip ]] && break
    sleep 5
  done
  if [[ -z $ip ]]; then
    notes="no IPv4 within ${BOOT_TIMEOUT}s"
    cleanup_vm "$vm" "$work" "FAIL"
    record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$notes"
    return
  fi
  log "[$alias] ip=$ip"

  # Wait for SSH (cloud-init may still be applying user keys)
  local ssh_ready=0
  while (( SECONDS < deadline )); do
    if ssh "${SSH_OPTS[@]}" -i "$SSH_KEY_PRIV" "matrix@$ip" true >/dev/null 2>&1; then
      ssh_ready=1
      break
    fi
    sleep 5
  done
  if (( ! ssh_ready )); then
    notes="SSH never ready within ${BOOT_TIMEOUT}s"
    cleanup_vm "$vm" "$work" "FAIL"
    record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$notes"
    return
  fi

  # Push scanner and run as root
  log "[$alias] pushing scanner + running"
  scp "${SSH_OPTS[@]}" -i "$SSH_KEY_PRIV" "$SCANNER" "matrix@$ip:/tmp/scanner" \
    >>"$out_dir/virt.log" 2>&1
  ssh "${SSH_OPTS[@]}" -i "$SSH_KEY_PRIV" "matrix@$ip" "
    sudo install -m 0755 /tmp/scanner /usr/local/bin/scanner
    timeout ${SCANNER_TIMEOUT}s sudo /usr/local/bin/scanner $SCANNER_ARGS > /tmp/result.json 2> /tmp/stderr.log
    echo \$? > /tmp/exit-code
    sudo cp /etc/os-release /tmp/os-release
    sudo chown matrix:matrix /tmp/result.json /tmp/stderr.log /tmp/exit-code /tmp/os-release
  " 2>>"$out_dir/virt.log" || true

  # Pull artifacts
  for f in result.json stderr.log exit-code os-release; do
    scp "${SSH_OPTS[@]}" -i "$SSH_KEY_PRIV" "matrix@$ip:/tmp/$f" "$out_dir/$f" \
      >>"$out_dir/virt.log" 2>&1 || true
  done

  exit_code=$(tr -d '[:space:]' < "$out_dir/exit-code" 2>/dev/null || echo "?")
  if [[ -r $out_dir/os-release ]]; then
    detected_id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' "$out_dir/os-release")
  fi

  # Verdict: did the scanner RUN (vs crash)? We don't care what verdict the
  # scanner itself reached. Treat 0-123 as "ran cleanly" (124 = `timeout`
  # tripped, 125-128 / 137 / 143 = signals or wrapper errors).
  local ran_cleanly=0
  if [[ $exit_code =~ ^[0-9]+$ ]] && (( exit_code < 124 )); then
    ran_cleanly=1
  fi
  if (( ran_cleanly )) && [[ -s $out_dir/result.json ]] && [[ $detected_id == "$expected" ]]; then
    verdict=PASS
  elif (( ran_cleanly )) && [[ $detected_id != "$expected" ]]; then
    verdict=FAIL
    notes="os-id mismatch: expected=$expected detected=${detected_id:-<unread>}"
  elif (( ran_cleanly )) && [[ ! -s $out_dir/result.json ]]; then
    verdict=FAIL
    notes="scanner exited cleanly but produced empty stdout"
  else
    verdict=FAIL
    notes="scanner did not run cleanly (exit=$exit_code)"
  fi

  cleanup_vm "$vm" "$work" "$verdict"
  record "$alias" "$expected" "$detected_id" "$exit_code" "$((SECONDS - started))" "$verdict" "$notes"
}

# --- Drive the matrix (sequential or parallel) -----------------------------
log "concurrency: $PARALLEL"
for i in "${!ALIASES[@]}"; do
  while (( $(jobs -p -r | wc -l) >= PARALLEL )); do
    # `wait -n` exits 127 if no children (race: job finished between the
    # count check and the wait). Swallow that under set -e.
    wait -n 2>/dev/null || true
  done
  run_one "$i" &
done
wait

# --- Aggregate per-distro records ------------------------------------------
declare -i N_PASS=0 N_FAIL=0
declare -a ROW_ALIAS ROW_EXPECTED ROW_DETECTED ROW_EXIT ROW_DURATION ROW_VERDICT ROW_NOTES
for alias in "${ALIASES[@]}"; do
  rec="$RESULTS_DIR/$alias/record.tsv"
  if [[ ! -r $rec ]]; then
    ROW_ALIAS+=("$alias"); ROW_EXPECTED+=("?"); ROW_DETECTED+=(""); ROW_EXIT+=("?")
    ROW_DURATION+=("0"); ROW_VERDICT+=("FAIL"); ROW_NOTES+=("no record file (run_one crashed)")
    N_FAIL+=1
    continue
  fi
  IFS=$'\t' read -r r_alias r_exp r_det r_exit r_dur r_verd r_notes < "$rec"
  ROW_ALIAS+=("$r_alias"); ROW_EXPECTED+=("$r_exp"); ROW_DETECTED+=("$r_det")
  ROW_EXIT+=("$r_exit"); ROW_DURATION+=("$r_dur"); ROW_VERDICT+=("$r_verd")
  ROW_NOTES+=("$r_notes")
  if [[ $r_verd == PASS ]]; then N_PASS+=1; else N_FAIL+=1; fi
done

# --- Render report ---------------------------------------------------------
{
  echo "# distro-matrix report"
  echo
  echo "- timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- scanner: \`$SCANNER\`"
  echo "- concurrency: $PARALLEL"
  echo "- distros: ${#ALIASES[@]} (pass: $N_PASS, fail: $N_FAIL)"
  echo
  echo "| Alias | Expected ID | Detected ID | Exit | Duration | Verdict | Notes |"
  echo "| --- | --- | --- | --- | --- | --- | --- |"
  for i in "${!ROW_ALIAS[@]}"; do
    printf '| %s | %s | %s | %s | %ss | %s | %s |\n' \
      "${ROW_ALIAS[$i]}" "${ROW_EXPECTED[$i]}" "${ROW_DETECTED[$i]:--}" \
      "${ROW_EXIT[$i]}" "${ROW_DURATION[$i]}" "${ROW_VERDICT[$i]}" "${ROW_NOTES[$i]:--}"
  done
} > "$REPORT"

# --- summary.json ----------------------------------------------------------
{
  printf '{"timestamp":"%s","scanner":"%s","concurrency":%d,"total":%d,"pass":%d,"fail":%d,"results":[' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCANNER" "$PARALLEL" "${#ALIASES[@]}" "$N_PASS" "$N_FAIL"
  for i in "${!ROW_ALIAS[@]}"; do
    [[ $i -gt 0 ]] && printf ','
    jq -nc --arg a "${ROW_ALIAS[$i]}" --arg e "${ROW_EXPECTED[$i]}" \
           --arg d "${ROW_DETECTED[$i]}" --arg x "${ROW_EXIT[$i]}" \
           --argjson dur "${ROW_DURATION[$i]}" \
           --arg v "${ROW_VERDICT[$i]}" --arg n "${ROW_NOTES[$i]}" \
           '{alias:$a, expected_id:$e, detected_id:$d, exit:$x, duration_s:$dur, verdict:$v, notes:$n}'
  done
  printf ']}\n'
} > "$SUMMARY_JSON"

log "report: $REPORT"
log "summary: $SUMMARY_JSON"
log "results: pass=$N_PASS fail=$N_FAIL"

[[ $N_FAIL -eq 0 ]] || exit 1
