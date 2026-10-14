#!/usr/bin/env bash
# fips-divergence.sh: run the FIPS algorithm-fence divergence check locally.
#
# Boots one RHEL 10 and one rebuild distro 10 with FIPS enabled through
# spawn-fleet, runs the pqc-readiness zipapp (--json) on each, asserts the
# divergence with check-fips-divergence.py, and tears the fleet down on
# exit. Replaces the scheduled workflow, which needed a self-hosted libvirt
# runner that never existed (#28).
#
# Usage:
#   scripts/fips-divergence.sh [--pqc-readiness PYZ] [--results-dir DIR]
#                              [--image-root DIR] [--keep]
#
#   --pqc-readiness PYZ  zipapp to run. Default: build it from a sibling
#                        ../pqc-readiness checkout, else download the latest
#                        release and verify its .sha256.
#   --results-dir DIR    default: results/fips-<UTC timestamp>
#   --image-root DIR     passed to spawn-fleet (images not in the local cache)
#   --keep               leave the fleet running (tear down later with
#                        scripts/teardown-fleet.sh --results-dir DIR)
#
# RHEL images need a Red Hat login and usually live only on the shared image
# store. Without one, the RHEL half is skipped with a message and only the
# rebuild half runs, which still proves the plumbing but can't detect a RHEL
# regression; the script exits 3 in that case so a partial run isn't
# mistaken for a pass.
#
# Exit: 0 divergence holds; 1/2 divergence broken (see check-fips-divergence.py);
#       3 partial run (RHEL skipped); 4 setup or fleet failure.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
CACHE=${DM_IMAGE_CACHE:-$HOME/.cache/pqc-vm-matrix}

PYZ=""
RESULTS_DIR=""
IMAGE_ROOT=""
KEEP=0
RHEL_ALIAS=rhel10
REBUILD_ALIAS=rocky10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pqc-readiness) PYZ=$2; shift 2 ;;
    --results-dir) RESULTS_DIR=$2; shift 2 ;;
    --image-root) IMAGE_ROOT=$2; shift 2 ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 4 ;;
  esac
done

log() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }

RESULTS_DIR=${RESULTS_DIR:-$REPO_ROOT/results/fips-$(date -u +%Y%m%dT%H%M%SZ)}
mkdir -p "$RESULTS_DIR"

# --- The scanner -----------------------------------------------------------
if [[ -z $PYZ ]]; then
  if [[ -f $REPO_ROOT/../pqc-readiness/scripts/build_zipapp.py ]]; then
    log "building pqc-readiness.pyz from ../pqc-readiness"
    (cd "$REPO_ROOT/../pqc-readiness" && python3 scripts/build_zipapp.py >&2)
    PYZ=$REPO_ROOT/../pqc-readiness/dist/pqc-readiness.pyz
  else
    log "downloading the latest pqc-readiness release"
    gh release download -R aclater/pqc-readiness -p 'pqc-readiness.pyz*' \
      -D "$RESULTS_DIR" --clobber
    (cd "$RESULTS_DIR" && sha256sum -c pqc-readiness.pyz.sha256 >&2)
    PYZ=$RESULTS_DIR/pqc-readiness.pyz
  fi
fi
[[ -r $PYZ ]] || { echo "pqc-readiness zipapp not readable: $PYZ" >&2; exit 4; }

# --- Which hosts can run ---------------------------------------------------
# An alias is available when the local cache has it or --image-root has its
# distros.tsv path.
available() {
  local alias=$1 rel
  [[ -r $CACHE/images/$alias.qcow2 ]] && return 0
  [[ -n $IMAGE_ROOT ]] || return 1
  rel=$(awk -F'\t' -v a="$alias" '!/^#/ && $1==a {print $4; exit}' "$REPO_ROOT/distros.tsv")
  [[ -n $rel && -r $IMAGE_ROOT/$rel ]]
}

: > "$RESULTS_DIR/manifest.txt"
partial=0
if available "$RHEL_ALIAS"; then
  echo "$RHEL_ALIAS 1" >> "$RESULTS_DIR/manifest.txt"
else
  log "SKIP $RHEL_ALIAS: no image in $CACHE/images or --image-root (needs a Red Hat login; usually on the shared image store). Only the rebuild half will run."
  partial=1
fi
if available "$REBUILD_ALIAS"; then
  echo "$REBUILD_ALIAS 1" >> "$RESULTS_DIR/manifest.txt"
else
  echo "no image for $REBUILD_ALIAS; nothing to run" >&2
  exit 4
fi

# FIPS sshd rejects ed25519 keys; use a throwaway RSA key for this run.
ssh-keygen -q -t rsa -b 3072 -N '' -C "distro-matrix fips $(date -u +%s)" -f "$RESULTS_DIR/id_rsa"

# shellcheck disable=SC2329  # invoked via the EXIT trap
teardown() {
  if (( KEEP )); then
    log "--keep: fleet left running; tear down with: scripts/teardown-fleet.sh --results-dir $RESULTS_DIR"
  else
    "$SCRIPT_DIR/teardown-fleet.sh" --results-dir "$RESULTS_DIR" || true
  fi
}
trap teardown EXIT

# --- Boot the fleet --------------------------------------------------------
fleet_args=(--manifest "$RESULTS_DIR/manifest.txt" --fips --vcpus 2 --memory 4096
            --ssh-key "$RESULTS_DIR/id_rsa.pub" --results-dir "$RESULTS_DIR")
[[ -n $IMAGE_ROOT ]] && fleet_args+=(--image-root "$IMAGE_ROOT")
log "booting FIPS fleet: $(tr '\n' ' ' < "$RESULTS_DIR/manifest.txt")"
"$SCRIPT_DIR/spawn-fleet/spawn-fleet.sh" "${fleet_args[@]}" || true
[[ -s $RESULTS_DIR/fleet.tsv ]] || { echo "spawn-fleet produced no fleet.tsv" >&2; exit 4; }

# --- Scan every host -------------------------------------------------------
ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
          -o BatchMode=yes -o ConnectTimeout=10 -i "$RESULTS_DIR/id_rsa")
scanned=0
# fd 3 keeps ssh/scp from reading the loop's input.
while IFS=$'\t' read -r -u 3 vm _alias _family _expected target; do
  [[ -z $vm || $vm == \#* ]] && continue
  if [[ -z $target || $target == FAIL ]]; then
    log "[$vm] did not come up; see $RESULTS_DIR/$vm/"
    continue
  fi
  host=${target%:*} port=22
  [[ $target == *:* ]] && port=${target##*:}
  mkdir -p "$RESULTS_DIR/$vm"
  scp "${ssh_opts[@]}" -P "$port" "$PYZ" "matrix@$host:/tmp/pqc-readiness.pyz"
  if ssh -n "${ssh_opts[@]}" -p "$port" "matrix@$host" \
       "sudo python3 /tmp/pqc-readiness.pyz --json" > "$RESULTS_DIR/$vm/result.json"; then
    :
  fi
  # pqc-readiness exits 0-3 for its performance tier; a report is what counts.
  if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$RESULTS_DIR/$vm/result.json" 2>/dev/null; then
    scanned=$((scanned + 1))
  else
    log "[$vm] no valid JSON report"
  fi
done 3< "$RESULTS_DIR/fleet.tsv"
(( scanned > 0 )) || { echo "no host produced a report" >&2; exit 4; }

# --- Assert ----------------------------------------------------------------
set +e
"$SCRIPT_DIR/check-fips-divergence.py" "$RESULTS_DIR"
rc=$?
set -e
if (( rc == 0 && partial )); then
  log "rebuild half passed; RHEL half skipped, so this is not a full pass"
  exit 3
fi
exit "$rc"
