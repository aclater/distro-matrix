#!/usr/bin/env bash
# Offline test for #58: RHSM credentials never land in logs, markers or a
# child process's environment, even when the "guest" echoes them back. No VM:
# dm_ssh is replaced by a fake guest.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../scripts/lib/vm.sh disable=SC1091
source "$here/../scripts/lib/vm.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
DM_RESULTS_DIR=$tmp/results; mkdir -p "$DM_RESULTS_DIR"
fails=0
ok()   { echo "ok   $*"; }
bad()  { echo "FAIL $*"; fails=$((fails + 1)); }

key="test-key-$RANDOM-$RANDOM-0123456789abcdef"
org="99$RANDOM$RANDOM"
export DM_RHSM_ACTIVATION_KEY=$key DM_RHSM_ORG=$org
if dm_rhsm_load; then ok "credentials load from env"; else bad "credentials didn't load from env"; fi
if [[ $DMR_KEY == "$key" && $DMR_ORG == "$org" ]]; then ok "env values used"; else bad "wrong values loaded"; fi
if env | grep -qF -- "$key"; then bad "activation key still exported to child processes"; else ok "env copies un-exported"; fi

# A hostile fake guest: reads stdin and prints everything back, then reports a UUID.
dm_ssh() {
  local cmd=${*: -1}
  case $cmd in
    *"subscription-manager identity"*) echo "system identity: 11111111-2222-3333-4444-555555555555" ;;
    *register*) local o k; IFS= read -r o; IFS= read -r k; echo "registering org=$o key=$k"; echo "The system has been registered with ID: 1111" ;;
  esac
}
log=$tmp/results/prepare.log
if dm_rhsm_register 127.0.0.1 2222 dm-test-rhel8 "$log"; then ok "register succeeds against the fake guest"; else bad "register failed"; fi
if grep -qaF -- "$key" "$log" || grep -qaF -- "$org" "$log"; then bad "credentials leaked into prepare.log"; else ok "prepare.log redacted"; fi
if grep -q 'REDACTED-ACTIVATION-KEY' "$log"; then ok "redaction marker present"; else bad "no redaction marker"; fi
m=$DM_RESULTS_DIR/rhsm/dm-test-rhel8
if [[ -e $m ]]; then ok "registration marker written"; else bad "no marker"; fi
if grep -q 'uuid=11111111-2222-3333-4444-555555555555' "$m"; then ok "marker records the system UUID"; else bad "marker missing UUID"; fi

# The checker must find a planted copy and pass on a clean tree. It reads
# credentials like run-matrix (env, else keyring); dm_rhsm_load un-exported
# ours above, so hand the test values over explicitly.
chk() { DM_RHSM_ACTIVATION_KEY=$key DM_RHSM_ORG=$org "$here/../scripts/check-no-secrets.sh" "$@"; }
if chk "$tmp/results" >/dev/null 2>&1; then ok "checker passes on the redacted results"; else bad "checker flagged clean results"; fi
printf 'oops %s\n' "$key" > "$tmp/results/leak.txt"
if chk "$tmp/results" >/dev/null 2>&1; then bad "checker missed a planted key"; else ok "checker catches a planted key"; fi

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
echo "all RHSM secret-handling checks passed"
