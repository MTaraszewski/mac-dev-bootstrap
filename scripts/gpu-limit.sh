#!/usr/bin/env bash
# gpu-limit.sh — raise how much unified memory the GPU may wire down.
#
#   ./scripts/gpu-limit.sh           # this machine's computed target
#   ./scripts/gpu-limit.sh 40960     # explicit MB
#   ./scripts/gpu-limit.sh reset     # back to the system default
#   ./scripts/gpu-limit.sh show      # read the current value, change nothing
#
# macOS defaults to roughly 2/3 of RAM for the GPU. That is the wall you hit
# when a model that *should* fit refuses to load, or silently runs partly on
# the CPU at a tenth of the speed.
#
# READ THESE:
#   * Needs sudo, and RESETS ON REBOOT. Re-run it, or wire it into a
#     LaunchDaemon if you want it to stick.
#   * Starve macOS and you get beachballs, swap thrash, or a hard freeze.
#     The refusal thresholds below are not decoration.
set -uo pipefail

find_root() {
  local d; d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  while [[ "$d" != "/" ]]; do
    [[ -f "$d/Brewfile" || -f "$d/.repo-root" ]] && { echo "$d"; return 0; }
    d="$(dirname "$d")"
  done
  d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [[ "$(basename "$d")" == "scripts" ]] && dirname "$d" || echo "$d"
}
REPO_DIR="$(find_root)"
source "$REPO_DIR/scripts/lib/host.sh" 2>/dev/null && load_host_profile 2>/dev/null

RAM_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
CUR="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"

show() {
  if [[ "$CUR" == "0" ]]; then
    echo "iogpu.wired_limit_mb = 0  (system default, roughly $(( RAM_MB * 2 / 3 ))MB of ${RAM_MB}MB)"
  else
    echo "iogpu.wired_limit_mb = ${CUR}MB of ${RAM_MB}MB"
  fi
}

case "${1:-}" in
  show) show; exit 0 ;;
  reset)
    source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init gpu-limit "$@"
    sudo sysctl iogpu.wired_limit_mb=0 && echo "Reset to the system default."
    exit $? ;;
  --help|-h) sed -n '2,19p' "$0"; exit 0 ;;
esac

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init gpu-limit "$@"

TARGET="${1:-${HOST_WIRED_MB:-}}"
if [[ -z "$TARGET" || "$TARGET" == "0" ]]; then
  echo "usage: $0 <MB|reset|show>   (this machine has ${RAM_MB}MB)" >&2
  exit 1
fi
[[ "$TARGET" =~ ^[0-9]+$ ]] || { echo "not a number: $TARGET" >&2; exit 1; }
[[ -n "${1:-}" ]] || echo "  no argument given — using the computed target ${TARGET}MB"

# Refuse to leave macOS too little. The cushion scales with RAM: a 40GB model
# inside a 56GB cap on a 64GB machine leaves the OS 8GB, and with apps open
# that swaps hard enough to freeze the machine.
if   (( RAM_MB >= 98304 )); then CUSHION=24576
elif (( RAM_MB >= 65536 )); then CUSHION=16384
elif (( RAM_MB >= 32768 )); then CUSHION=10240
else                             CUSHION=6144
fi
MAX=$(( RAM_MB - CUSHION ))

if (( TARGET > MAX )); then
  echo "Refusing: ${TARGET}MB leaves macOS too little." >&2
  echo "  On a ${RAM_MB}MB machine, cap at most ${MAX}MB (a $(( CUSHION / 1024 ))GB cushion)." >&2
  exit 1
fi

show
sudo sysctl iogpu.wired_limit_mb="$TARGET" || exit 1
echo "GPU wired limit -> ${TARGET}MB of ${RAM_MB}MB. Resets on reboot."
echo "Verify a model is actually fully on the GPU:  ./scripts/ram.sh"
