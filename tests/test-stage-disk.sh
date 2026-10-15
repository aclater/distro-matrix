#!/usr/bin/env bash
# Regression test for #43: dm_stage_disk must never give a guest a disk
# smaller than its base image. Needs only qemu-img; no VM is booted.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Followed with `shellcheck -x`; plain runs (pre-commit) skip the sourced file.
# shellcheck source=../scripts/lib/vm.sh disable=SC1091
source "$here/../scripts/lib/vm.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
qemu-img create -q -f qcow2 "$tmp/base.qcow2" 2G
gib=$((1024 * 1024 * 1024))
fails=0

check() {  # name requested_gib copy expected_bytes
  local name=$1 req=$2 copy=$3 want=$4 got
  rm -rf "$tmp/work" && mkdir "$tmp/work"
  dm_stage_disk "$tmp/base.qcow2" "$tmp/work" "$req" "$copy"
  got=$(dm_image_bytes "$tmp/work/disk.qcow2")
  if [[ $got == "$want" ]]; then
    echo "ok   $name ($got bytes)"
  else
    echo "FAIL $name: expected $want bytes, got $got"
    fails=$((fails + 1))
  fi
}

check "overlay smaller than base keeps base size" 1 0 $((2 * gib))
check "overlay larger than base grows"            3 0 $((3 * gib))
check "copy smaller than base keeps base size"    1 1 $((2 * gib))
check "copy larger than base grows"               3 1 $((3 * gib))
exit "$fails"
