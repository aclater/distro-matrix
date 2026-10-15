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
#   --image-root PATH         Where qcow2s live, tried after the local cache
#                             (~/.cache/pqc-vm-matrix/images, by alias; override
#                             with DM_IMAGE_CACHE). Default: /mnt/media/iso/linux
#   --results-dir PATH        Where reports land (default: <repo>/results/<UTC ts>)
#   --work-dir PATH           Per-VM disk + cidata staging (default: /tmp/distro-matrix-work)
#   --only LIST               Comma-separated alias subset (e.g. debian13,rocky9)
#   --skip LIST               Comma-separated aliases to skip
#   --vcpus N                 vCPUs per VM (default: 1)
#   --memory MIB              RAM per VM in MiB (default: 1536)
#   --disk GIB                Resize qcow2 to this GiB before boot (default: 10)
#   --boot-timeout SEC        Max seconds for IP + SSH (default: 240)
#   --scanner-timeout SEC     Max seconds for the scanner itself (default: 300)
#   --schema PATH             Validate each result.json against this JSON Schema;
#                             a violation fails that distro. Bundled:
#                             schemas/pqc-readiness-report.schema.json. Uses
#                             python3-jsonschema when importable (DM_PYTHON picks
#                             the interpreter), else a built-in subset validator.
#   --compare-scanner PATH    Also run this second scanner build on the same VM
#                             (result-b.json) and write <alias>/compare.json, a diff
#                             that ignores timestamps and benchmark numbers. The
#                             difference count goes in the report; it doesn't
#                             change the verdict.
#   --compare-args 'STR'      Args for the compare scanner (default: --scanner-args)
#   --prepare FILE            alias|family|*<TAB>command lines run as root on
#                             each matching guest after SSH is up and before
#                             the scanner (output: <alias>/prepare.log). A
#                             command may write an interpreter path to
#                             /etc/distro-matrix/interpreter; both scanners
#                             then run as `<interpreter> scanner`. Example:
#                             prepare/pqc-readiness.tsv (Python 3.9+ on EL8,
#                             Leap 15.6). A failing command fails the distro.
#   --prepare-timeout SEC     Max seconds per prepare command (default: 900)
#   --ground-truth FILE       name<TAB>command lines run as root on each guest
#                             after the scan; output saved to
#                             <alias>/ground-truth/<name>.txt. Example:
#                             ground-truth/pqc-readiness.tsv
#   --ssh-key PATH            SSH pubkey to inject (default: first of
#                             ~/.ssh/id_ed25519.pub, id_ecdsa.pub, id_rsa.pub)
#   --backend B               qemu (VMs launched through vm-run, inside the host's
#                             vCPU budget), libvirt (virt-install on --connect), or
#                             auto (default: qemu when vm-run, qemu-system-x86_64 and
#                             /dev/kvm are available, else libvirt)
#   --parallel N|auto         Distros in flight at once. auto (default): with qemu,
#                             vm-run's budget / --vcpus (vm-run still queues anything
#                             over budget); with libvirt, 1. libvirt VMs bypass
#                             vm-run, so keep libvirt runs at 1-2.
#   --no-backing              Copy qcow2 instead of using qemu-img backing-file overlay.
#                             Done automatically when libvirt's qemu user can't read
#                             the base image (e.g. it lives under ~/.cache).
#   --keep-on-failure         Leave the VM + workdir for the failed distro (debug)
#
# Every VM is named dm-<run-id>-<alias>; concurrent runs never collide, and a
# run only ever destroys VMs it created. Interrupting a run (Ctrl-C, TERM) or
# an error tears down everything it started.
#   --connect URI             libvirt URI (default: qemu:///system)
#   --help

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
# Followed with `shellcheck -x`; plain runs (pre-commit) skip the sourced file.
# shellcheck source=lib/vm.sh disable=SC1091
source "$SCRIPT_DIR/lib/vm.sh"

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
SCHEMA=""
COMPARE_SCANNER=""
COMPARE_ARGS=__same__
GROUND_TRUTH=""
DM_PYTHON=${DM_PYTHON:-python3}
SSH_KEY=$(dm_default_ssh_key || echo "$HOME/.ssh/id_ed25519.pub")
PARALLEL=auto
BACKEND=auto
NO_BACKING=0
KEEP_ON_FAILURE=0
PREPARE=""
PREPARE_TIMEOUT=900
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
    --schema) SCHEMA=$2; shift 2 ;;
    --compare-scanner) COMPARE_SCANNER=$2; shift 2 ;;
    --compare-args) COMPARE_ARGS=$2; shift 2 ;;
    --ground-truth) GROUND_TRUTH=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    --parallel) PARALLEL=$2; shift 2 ;;
    --backend) BACKEND=$2; shift 2 ;;
    --no-backing) NO_BACKING=1; shift ;;
    --keep-on-failure) KEEP_ON_FAILURE=1; shift ;;
    --prepare) PREPARE=$2; shift 2 ;;
    --prepare-timeout) PREPARE_TIMEOUT=$2; shift 2 ;;
    --connect) LIBVIRT_URI=$2; shift 2 ;;
    --help|-h) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 2 ;;
  esac
done

[[ -n $SCANNER ]] || { echo "--scanner is required" >&2; usage 2; }
[[ -r $SCANNER ]] || { echo "scanner not readable: $SCANNER" >&2; exit 2; }
[[ -z $SCHEMA || -r $SCHEMA ]] || { echo "schema not readable: $SCHEMA" >&2; exit 2; }
[[ -z $COMPARE_SCANNER || -r $COMPARE_SCANNER ]] || { echo "compare scanner not readable: $COMPARE_SCANNER" >&2; exit 2; }
[[ -z $GROUND_TRUTH || -r $GROUND_TRUTH ]] || { echo "ground-truth file not readable: $GROUND_TRUTH" >&2; exit 2; }
[[ $COMPARE_ARGS == __same__ ]] && COMPARE_ARGS=$SCANNER_ARGS
[[ -r $DISTROS_FILE ]] || { echo "distros file not readable: $DISTROS_FILE" >&2; exit 2; }
[[ -r $SSH_KEY ]] || { echo "ssh pubkey not readable: $SSH_KEY" >&2; exit 2; }
[[ -d $IMAGE_ROOT ]] || echo "note: image-root $IMAGE_ROOT not present; using the local cache only" >&2
case $BACKEND in
  auto) if dm_qemu_available; then BACKEND=qemu; else BACKEND=libvirt; fi ;;
  qemu) dm_qemu_available || { echo "qemu backend needs vm-run, qemu-system-x86_64 and a writable /dev/kvm" >&2; exit 2; } ;;
  libvirt) ;;
  *) echo "unknown --backend: $BACKEND (qemu|libvirt|auto)" >&2; exit 2 ;;
esac
need=(cloud-localds qemu-img jq ssh scp python3)
[[ $BACKEND == libvirt ]] && need+=(virsh virt-install)
if [[ $PARALLEL == auto ]]; then
  if [[ $BACKEND == qemu ]]; then
    budget=$(dm_vmrun_budget)
    PARALLEL=$(( ${budget:-$VCPUS} / VCPUS ))
    (( PARALLEL >= 1 )) || PARALLEL=1
  else
    PARALLEL=1
  fi
fi
[[ $PARALLEL =~ ^[1-9][0-9]*$ ]] || { echo "--parallel must be a positive integer or auto" >&2; exit 2; }
[[ -z $PREPARE || -r $PREPARE ]] || { echo "prepare file not readable: $PREPARE" >&2; exit 2; }
[[ $PREPARE_TIMEOUT =~ ^[1-9][0-9]*$ ]] || { echo "--prepare-timeout must be a positive integer" >&2; exit 2; }
for cmd in "${need[@]}"; do
  command -v "$cmd" >/dev/null || { echo "missing required tool: $cmd" >&2; exit 2; }
done

if [[ -z $RESULTS_DIR ]]; then
  RESULTS_DIR="$REPO_ROOT/results/$(date -u +%Y%m%dT%H%M%SZ)"
fi
mkdir -p "$RESULTS_DIR" "$WORK_DIR"

REPORT="$RESULTS_DIR/report.md"
SUMMARY_JSON="$RESULTS_DIR/summary.json"
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
dm_init

# --- Parse distros.tsv -----------------------------------------------------
declare -a ALIASES FAMILIES EXPECTED_OS QCOW_RELPATHS
while IFS=$'\t' read -r alias family expected_os qcow_relpath; do
  [[ $alias =~ ^# ]] && continue
  [[ -z $alias ]] && continue
  if [[ -n $ONLY && ",$ONLY," != *",$alias,"* ]]; then continue; fi
  if [[ -n $SKIP && ",$SKIP," == *",$alias,"* ]]; then continue; fi
  ALIASES+=("$alias")
  FAMILIES+=("$family")
  EXPECTED_OS+=("$expected_os")
  QCOW_RELPATHS+=("$qcow_relpath")
done < "$DISTROS_FILE"

if [[ ${#ALIASES[@]} -eq 0 ]]; then
  echo "no distros selected (check --only/--skip and distros.tsv)" >&2
  exit 1
fi

log "run: $DM_RUN_ID"
log "matrix: ${#ALIASES[@]} distro(s) — ${ALIASES[*]}"
log "results dir: $RESULTS_DIR"
log "work dir: $WORK_DIR"

record() {
  # alias \t expected \t detected \t exit \t duration \t verdict \t notes
  # Empty fields are written as "-": the reader splits on tabs with
  # `IFS=$'\t' read`, and tab is IFS whitespace, so an empty field would
  # collapse and shift every column after it.
  local out_dir="$RESULTS_DIR/$1"
  mkdir -p "$out_dir"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${1:--}" "${2:--}" "${3:--}" "${4:--}" "${5:--}" "${6:--}" "${7:--}" \
    > "$out_dir/record.tsv"
}

# run_one runs in its own subshell. Any failing step lands in the EXIT trap,
# which records FAIL with the step name and tears down this distro's VM; the
# parent's trap only has to mop up after signals.
run_one() {
  # Not `local`: the EXIT trap below runs after this function returns, and
  # each run_one already has its own subshell.
  idx=$1
  alias=${ALIASES[$idx]}
  expected=${EXPECTED_OS[$idx]}
  started=$SECONDS step="start" recorded=0
  vm=$(dm_vm_name "$alias")
  work="$WORK_DIR/$vm"
  out_dir="$RESULTS_DIR/$alias"
  mkdir -p "$out_dir" "$work"

  fail() {
    record "$alias" "$expected" "" "?" "$((SECONDS - started))" "FAIL" "$1"
    recorded=1
  }
  # shellcheck disable=SC2329  # invoked by the EXIT trap below
  on_exit() {
    local rc=$?
    if (( ! recorded )); then
      fail "aborted during: $step (exit $rc; see $out_dir/virt.log)"
    fi
    # The guest's serial console is the only way to see why a VM never came
    # up (#43); keep it with the results before the work dir goes.
    [[ -s $work/console.log ]] && cp "$work/console.log" "$out_dir/console.log" 2>/dev/null
    if [[ $(cut -f6 "$out_dir/record.tsv" 2>/dev/null) == FAIL && $KEEP_ON_FAILURE -eq 1 ]]; then
      dm_keep "$vm"
      log "[$alias] keeping $vm + $work (debug)"
    elif "dm_${BACKEND}_exists" "$vm" || [[ -d $work ]]; then
      dm_destroy_vm "$BACKEND" "$vm" "$work"
    fi
  }
  trap on_exit EXIT
  trap 'exit 143' TERM

  log "[$alias] start ($vm)"
  local qcow
  step="resolve image"
  if ! qcow=$(dm_resolve_image "$alias" "${QCOW_RELPATHS[$idx]}" "$IMAGE_ROOT"); then
    fail "image not found: $alias (cache $DM_IMAGE_CACHE/images, root $IMAGE_ROOT/${QCOW_RELPATHS[$idx]})"
    return
  fi
  log "[$alias] image $qcow"

  local copy=$NO_BACKING
  if (( ! copy )) && [[ $BACKEND == libvirt ]] && ! dm_world_readable "$qcow"; then
    log "[$alias] base image isn't readable by libvirt's qemu user; copying instead of overlaying"
    copy=1
  fi
  step="stage disk"
  dm_register "$BACKEND" "$vm" "$work"
  dm_stage_disk "$qcow" "$work" "$DISK" "$copy" >>"$out_dir/virt.log" 2>&1
  step="build cloud-init seed"
  dm_write_seed "$work" "$(dm_hostname "$alias")" "$SSH_KEY" >>"$out_dir/virt.log" 2>&1

  step="boot"
  log "[$alias] boot ($BACKEND)"
  if ! "dm_${BACKEND}_create" "$vm" "$work" "$VCPUS" "$MEMORY" >>"$out_dir/virt.log" 2>&1; then
    fail "VM create failed (see $out_dir/virt.log)"
    return
  fi

  step="wait for SSH"
  local target host port
  if ! target=$(dm_wait_ssh "$BACKEND" "$vm" $(( SECONDS + BOOT_TIMEOUT ))); then
    fail "no SSH within ${BOOT_TIMEOUT}s"
    return
  fi
  read -r host port <<< "$target"
  log "[$alias] ssh $host:$port"

  if [[ -n $PREPARE ]]; then
    step="prepare guest"
    local p_key p_cmd
    while IFS=$'\t' read -r p_key p_cmd; do
      [[ -z $p_key || $p_key == \#* || -z $p_cmd ]] && continue
      [[ $p_key == "$alias" || $p_key == "${FAMILIES[$idx]}" || $p_key == '*' ]] || continue
      log "[$alias] prepare: $p_cmd"
      printf '### %s\n' "$p_cmd" >> "$out_dir/prepare.log"
      # base64 so the command reaches the guest's bash byte for byte; stdin
      # from /dev/null so ssh doesn't swallow the rest of the file.
      if ! dm_ssh "$host" "$port" "sudo mkdir -p /etc/distro-matrix && echo $(printf '%s' "$p_cmd" | base64 -w0) | base64 -d | sudo timeout ${PREPARE_TIMEOUT}s bash" \
          < /dev/null >> "$out_dir/prepare.log" 2>&1; then
        fail "prepare failed: $p_cmd (see $out_dir/prepare.log)"
        return
      fi
    done < "$PREPARE"
  fi

  step="run scanner"
  log "[$alias] pushing scanner + running"
  dm_scp_to "$host" "$port" "$SCANNER" /tmp/scanner >>"$out_dir/virt.log" 2>&1
  dm_ssh "$host" "$port" "
    sudo install -m 0755 /tmp/scanner /usr/local/bin/scanner
    timeout ${SCANNER_TIMEOUT}s sudo \$(cat /etc/distro-matrix/interpreter 2>/dev/null) /usr/local/bin/scanner $SCANNER_ARGS > /tmp/result.json 2> /tmp/stderr.log
    echo \$? > /tmp/exit-code
    sudo cp /etc/os-release /tmp/os-release
    sudo chown matrix: /tmp/result.json /tmp/stderr.log /tmp/exit-code /tmp/os-release
  " 2>>"$out_dir/virt.log" || true

  step="collect results"
  local f
  for f in result.json stderr.log exit-code os-release; do
    dm_scp_from "$host" "$port" "/tmp/$f" "$out_dir/$f" >>"$out_dir/virt.log" 2>&1 || true
  done

  if [[ -n $COMPARE_SCANNER ]]; then
    step="run compare scanner"
    log "[$alias] running compare scanner"
    dm_scp_to "$host" "$port" "$COMPARE_SCANNER" /tmp/scanner-b >>"$out_dir/virt.log" 2>&1
    dm_ssh "$host" "$port" "
      sudo install -m 0755 /tmp/scanner-b /usr/local/bin/scanner-b
      timeout ${SCANNER_TIMEOUT}s sudo \$(cat /etc/distro-matrix/interpreter 2>/dev/null) /usr/local/bin/scanner-b $COMPARE_ARGS > /tmp/result-b.json 2> /tmp/stderr-b.log
      echo \$? > /tmp/exit-code-b
      sudo chown matrix: /tmp/result-b.json /tmp/stderr-b.log /tmp/exit-code-b
    " 2>>"$out_dir/virt.log" || true
    for f in result-b.json stderr-b.log exit-code-b; do
      dm_scp_from "$host" "$port" "/tmp/$f" "$out_dir/$f" >>"$out_dir/virt.log" 2>&1 || true
    done
  fi

  if [[ -n $GROUND_TRUTH ]]; then
    step="collect ground truth"
    mkdir -p "$out_dir/ground-truth"
    local gt_name gt_cmd
    while IFS=$'\t' read -r gt_name gt_cmd; do
      [[ -z $gt_name || $gt_name == \#* || -z $gt_cmd ]] && continue
      [[ $gt_name =~ ^[A-Za-z0-9._-]+$ ]] || { log "[$alias] skipping ground-truth entry with unsafe name: $gt_name"; continue; }
      # base64 so the command reaches the guest's bash byte for byte; stdin
      # from /dev/null so ssh doesn't swallow the rest of the list.
      dm_ssh "$host" "$port" "echo $(printf '%s' "$gt_cmd" | base64 -w0) | base64 -d | sudo bash 2>&1; echo \"# exit: \$?\"" \
        < /dev/null > "$out_dir/ground-truth/$gt_name.txt" 2>>"$out_dir/virt.log" || true
    done < "$GROUND_TRUTH"
  fi

  local exit_code detected_id="" verdict=FAIL notes=""
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
    notes="os-id mismatch: expected=$expected detected=${detected_id:-<unread>}"
  elif (( ran_cleanly )); then
    notes="scanner exited cleanly but produced empty stdout"
  else
    notes="scanner did not run cleanly (exit=$exit_code)"
  fi

  step="validate output"
  local checks=()
  if [[ -n $SCHEMA ]]; then
    local label n
    for f in result.json result-b.json; do
      [[ -s $out_dir/$f ]] || continue
      label=A; [[ $f == result-b.json ]] && label=B
      if "$DM_PYTHON" "$REPO_ROOT/tools/validate_result.py" "$SCHEMA" "$out_dir/$f" \
           > "$out_dir/schema-$label.txt" 2>>"$out_dir/virt.log"; then
        checks+=("schema $label ok")
      else
        n=$(grep -c . "$out_dir/schema-$label.txt" || true)
        checks+=("schema $label: $n error(s), see schema-$label.txt")
        verdict=FAIL
      fi
    done
  fi
  if [[ -n $COMPARE_SCANNER ]]; then
    if [[ -s $out_dir/result.json && -s $out_dir/result-b.json ]]; then
      "$DM_PYTHON" "$REPO_ROOT/tools/json_diff.py" "$out_dir/result.json" "$out_dir/result-b.json" \
        > "$out_dir/compare.json" 2>>"$out_dir/virt.log" || true
      checks+=("compare: $(jq -r '.differences' "$out_dir/compare.json" 2>/dev/null || echo '?') difference(s)")
    else
      checks+=("compare: no output from $([[ -s $out_dir/result.json ]] && echo B || echo A)")
    fi
  fi
  if (( ${#checks[@]} )); then
    local joined
    joined=$(IFS=';'; echo "${checks[*]}")
    notes="${notes:+$notes; }${joined//;/; }"
  fi

  record "$alias" "$expected" "$detected_id" "$exit_code" "$((SECONDS - started))" "$verdict" "$notes"
  recorded=1
}

# --- Drive the matrix (sequential or parallel) -----------------------------
log "backend: $BACKEND, concurrency: $PARALLEL"
for i in "${!ALIASES[@]}"; do
  while (( $(jobs -p -r | wc -l) >= PARALLEL )); do
    # `wait -n` exits 127 if no children (race: job finished between the
    # count check and the wait). Swallow that under set -e.
    wait -n 2>/dev/null || true
  done
  ( run_one "$i" ) &
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
  [[ $r_det == - ]] && r_det=""
  [[ $r_notes == - ]] && r_notes=""
  [[ $r_dur =~ ^[0-9]+$ ]] || r_dur=0
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
  echo "- backend: $BACKEND"
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
