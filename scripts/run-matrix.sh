#!/usr/bin/env bash
# distro-matrix runner — launch a fresh Incus VM per distro, run a scanner
# script inside, pull the JSON output back, validate, emit a markdown report.
#
# Assumes the host running this script has the `incus` CLI configured to talk
# to a daemon that can read qcow2 paths under --image-root. Easiest setup:
# run this on the TrueNAS host where Incus owns /mnt/pool0/media/iso/linux/
# directly. From a workstation, you can also point `incus remote` at TrueNAS
# but qcow2s will be uploaded over the network at import time.
#
# Usage:
#   scripts/run-matrix.sh --scanner /path/to/scanner.sh [opts]
#
# Required:
#   --scanner PATH            Local path to the scanner script (any executable
#                             that prints JSON to stdout). Pushed into each VM
#                             at /usr/local/bin/scanner and invoked as root.
#
# Optional:
#   --distros PATH            distros.tsv (default: ./distros.tsv)
#   --image-root PATH         Where qcow2s live (default: /mnt/pool0/media/iso/linux,
#                             falls back to /mnt/media/iso/linux if the first is absent)
#   --results-dir PATH        Where reports land (default: ./results/<UTC ts>)
#   --only LIST               Comma-separated alias subset (e.g. debian-13,rhel-9)
#   --skip LIST               Comma-separated aliases to skip
#   --vcpus N                 vCPUs per VM (default: 1)
#   --memory MIB              RAM per VM in MiB (default: 1536)
#   --disk GIB                Disk per VM in GiB (default: 10)
#   --boot-timeout SEC        Max seconds to wait for incus-agent + scanner (default: 300)
#   --keep-on-failure         Don't delete VMs whose scanner failed (debug)
#   --reuse-images            Don't reimport an image if dm/<alias> already exists
#   --help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

# Defaults
DISTROS_FILE="$REPO_ROOT/distros.tsv"
IMAGE_ROOT=""
RESULTS_DIR=""
SCANNER=""
ONLY=""
SKIP=""
VCPUS=1
MEMORY=1536
DISK=10
BOOT_TIMEOUT=300
KEEP_ON_FAILURE=0
REUSE_IMAGES=0

usage() { sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scanner) SCANNER=$2; shift 2 ;;
    --distros) DISTROS_FILE=$2; shift 2 ;;
    --image-root) IMAGE_ROOT=$2; shift 2 ;;
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --only) ONLY=$2; shift 2 ;;
    --skip) SKIP=$2; shift 2 ;;
    --vcpus) VCPUS=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --boot-timeout) BOOT_TIMEOUT=$2; shift 2 ;;
    --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
    --reuse-images) REUSE_IMAGES=1; shift ;;
    --help|-h) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 2 ;;
  esac
done

[[ -n $SCANNER ]] || { echo "--scanner is required" >&2; usage 2; }
[[ -x $SCANNER || -r $SCANNER ]] || { echo "scanner not found or unreadable: $SCANNER" >&2; exit 2; }
[[ -r $DISTROS_FILE ]] || { echo "distros file not readable: $DISTROS_FILE" >&2; exit 2; }
command -v incus >/dev/null || { echo "incus CLI not found in PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq not found in PATH" >&2; exit 2; }

if [[ -z $IMAGE_ROOT ]]; then
  if [[ -d /mnt/pool0/media/iso/linux ]]; then
    IMAGE_ROOT=/mnt/pool0/media/iso/linux
  elif [[ -d /mnt/media/iso/linux ]]; then
    IMAGE_ROOT=/mnt/media/iso/linux
  else
    echo "--image-root not given and no default path exists" >&2
    exit 2
  fi
fi
[[ -d $IMAGE_ROOT ]] || { echo "image-root not a directory: $IMAGE_ROOT" >&2; exit 2; }

if [[ -z $RESULTS_DIR ]]; then
  RESULTS_DIR="$REPO_ROOT/results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RESULTS_DIR"

REPORT="$RESULTS_DIR/report.md"
SUMMARY_JSON="$RESULTS_DIR/summary.json"

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

# --- Parse distros.tsv into parallel arrays --------------------------------
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

# --- Cloud-init user-data --------------------------------------------------
# We bake the scanner into write_files (base64) so we don't need network or
# SSH inside the guest. runcmd executes it, captures stdout/stderr/exit, and
# touches a marker file we poll for via `incus file pull`.
SCANNER_B64=$(base64 -w0 < "$SCANNER")

render_userdata() {
  local hostname=$1
  cat <<EOF
#cloud-config
hostname: $hostname
manage_etc_hosts: true
write_files:
  - path: /usr/local/bin/scanner
    permissions: '0755'
    encoding: b64
    content: $SCANNER_B64
runcmd:
  - mkdir -p /var/run/distro-matrix
  - bash -c '/usr/local/bin/scanner > /var/run/distro-matrix/result.json 2> /var/run/distro-matrix/stderr.log; echo \$? > /var/run/distro-matrix/exit-code'
  - touch /var/run/distro-matrix/done
EOF
}

# --- Per-distro work -------------------------------------------------------
declare -a ROW_ALIAS ROW_EXPECTED ROW_DETECTED ROW_EXIT ROW_DURATION ROW_VERDICT ROW_NOTES
declare -i N_PASS=0 N_FAIL=0

run_one() {
  local idx=$1
  local alias=${ALIASES[$idx]}
  local family=${FAMILIES[$idx]}
  local expected=${EXPECTED_OS[$idx]}
  local qcow=${QCOW_PATHS[$idx]}
  local image="dm/$alias"
  local vm="dm-$alias"
  local out_dir="$RESULTS_DIR/$alias"
  local notes=""
  local detected_id=""
  local exit_code="?"
  local verdict="FAIL"
  local started=$SECONDS

  mkdir -p "$out_dir"
  log "[$alias] start"

  if [[ ! -r $qcow ]]; then
    notes="qcow2 missing: $qcow"
    log "[$alias] $notes"
    record "$alias" "$expected" "" "?" "0" "FAIL" "$notes"
    return
  fi

  # Import (idempotent if --reuse-images and image already cached)
  if (( REUSE_IMAGES )) && incus image show "$image" >/dev/null 2>&1; then
    log "[$alias] reuse cached image $image"
  else
    incus image show "$image" >/dev/null 2>&1 && incus image delete "$image" >/dev/null 2>&1 || true
    log "[$alias] importing $qcow → $image"
    if ! incus image import "$qcow" --alias "$image" >>"$out_dir/incus.log" 2>&1; then
      notes="image import failed (see $out_dir/incus.log)"
      record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$notes"
      return
    fi
  fi

  # Init VM with cloud-init
  render_userdata "$vm" > "$out_dir/user-data.yaml"
  if ! incus init "$image" "$vm" --vm \
        -c limits.cpu="$VCPUS" \
        -c limits.memory="${MEMORY}MiB" \
        -d root,size="${DISK}GiB" \
        >>"$out_dir/incus.log" 2>&1; then
    notes="incus init failed"
    record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$notes"
    return
  fi
  incus config set "$vm" user.user-data - < "$out_dir/user-data.yaml"
  incus start "$vm" >>"$out_dir/incus.log" 2>&1

  # Wait for cloud-init to finish (marker file appears)
  local deadline=$(( SECONDS + BOOT_TIMEOUT ))
  local marker_seen=0
  while (( SECONDS < deadline )); do
    if incus file pull "$vm/var/run/distro-matrix/done" - >/dev/null 2>&1; then
      marker_seen=1
      break
    fi
    sleep 5
  done

  if (( ! marker_seen )); then
    notes="boot/scanner timeout after ${BOOT_TIMEOUT}s"
    cleanup_vm "$vm" "$out_dir" "FAIL"
    record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$notes"
    return
  fi

  # Pull artifacts
  incus file pull "$vm/var/run/distro-matrix/result.json" "$out_dir/result.json" 2>>"$out_dir/incus.log" || true
  incus file pull "$vm/var/run/distro-matrix/stderr.log" "$out_dir/stderr.log" 2>>"$out_dir/incus.log" || true
  incus file pull "$vm/var/run/distro-matrix/exit-code" "$out_dir/exit-code" 2>>"$out_dir/incus.log" || true
  exit_code=$(tr -d '[:space:]' < "$out_dir/exit-code" 2>/dev/null || echo "?")

  # Pull the guest's /etc/os-release for ground-truth comparison
  incus file pull "$vm/etc/os-release" "$out_dir/os-release" 2>>"$out_dir/incus.log" || true
  if [[ -r $out_dir/os-release ]]; then
    detected_id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2); print $2}' "$out_dir/os-release")
  fi

  # Verdict: scanner exit 0 + os-release ID matches expected
  if [[ $exit_code == "0" && $detected_id == "$expected" ]]; then
    verdict=PASS
  elif [[ $exit_code == "0" ]]; then
    verdict=FAIL
    notes="os-id mismatch: expected=$expected detected=${detected_id:-<unread>}"
  else
    verdict=FAIL
    notes="scanner exit=$exit_code"
  fi

  cleanup_vm "$vm" "$out_dir" "$verdict"
  record "$alias" "$expected" "$detected_id" "$exit_code" "$((SECONDS - started))" "$verdict" "$notes"
}

cleanup_vm() {
  local vm=$1 out_dir=$2 verdict=$3
  if [[ $verdict == "FAIL" && $KEEP_ON_FAILURE -eq 1 ]]; then
    log "[$vm] keeping VM (debug)"
    return
  fi
  incus delete --force "$vm" >>"$out_dir/incus.log" 2>&1 || true
}

record() {
  ROW_ALIAS+=("$1")
  ROW_EXPECTED+=("$2")
  ROW_DETECTED+=("$3")
  ROW_EXIT+=("$4")
  ROW_DURATION+=("$5")
  ROW_VERDICT+=("$6")
  ROW_NOTES+=("$7")
  if [[ $6 == PASS ]]; then N_PASS+=1; else N_FAIL+=1; fi
}

# --- Run sequentially (parallelism deferred) -------------------------------
for i in "${!ALIASES[@]}"; do
  run_one "$i"
done

# --- Render report ---------------------------------------------------------
{
  echo "# distro-matrix report"
  echo
  echo "- timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "- scanner: \`$SCANNER\`"
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
  printf '{"timestamp":"%s","scanner":"%s","total":%d,"pass":%d,"fail":%d,"results":[' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SCANNER" "${#ALIASES[@]}" "$N_PASS" "$N_FAIL"
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
