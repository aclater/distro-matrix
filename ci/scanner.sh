#!/bin/sh
# Minimal scanner for distro-matrix's CI boot test (#46): prints a JSON
# object with the guest's os-release identity and kernel. POSIX sh only, so it
# runs on any cloud image without Python.
set -eu
# shellcheck source=/dev/null
. /etc/os-release
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
printf '{"scanner":"distro-matrix-ci","os_release":{"id":"%s","version_id":"%s","pretty_name":"%s"},"kernel":"%s"}\n' \
  "$(esc "${ID:-}")" "$(esc "${VERSION_ID:-}")" "$(esc "${PRETTY_NAME:-}")" "$(esc "$(uname -r)")"
