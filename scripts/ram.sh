#!/usr/bin/env bash
# ram.sh — where is the memory going, and what is left for a model?
#
#   ./scripts/ram.sh
#
# This is the number that decides what you can run. Guessing is how you end
# up silently on the CPU at a tenth of the speed, wondering why it is slow.
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

hdr() { printf "\n\033[1;34m── %s\033[0m\n" "$*"; }
row() { printf "  %-22s %s\n" "$1" "$2"; }

RAM_MB=$(( $(sysctl -n hw.memsize) / 1048576 ))
PAGE=$(sysctl -n hw.pagesize)

hdr "machine"
row "chip"   "$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
row "memory" "$(( RAM_MB / 1024 ))GB"
[[ -n "${HOST_BANDWIDTH:-}" ]] && row "bandwidth" "${HOST_BANDWIDTH} GB/s"

hdr "memory in use"
# vm_stat reports in pages. Free memory alone is misleading on macOS because
# the OS deliberately uses everything for cache; what matters for a model is
# how much is WIRED (unswappable) plus how much is compressed.
vm_stat 2>/dev/null | awk -v page="$PAGE" '
  /Pages free/            { free=$3 }
  /Pages active/          { act=$3 }
  /Pages inactive/        { inact=$3 }
  /Pages wired down/      { wired=$4 }
  /Pages occupied by compressor/ { comp=$5 }
  END {
    gsub(/\./,"",free); gsub(/\./,"",act); gsub(/\./,"",inact)
    gsub(/\./,"",wired); gsub(/\./,"",comp)
    mb = page / 1048576
    printf "  %-22s %dMB\n", "wired (unswappable)", wired*mb
    printf "  %-22s %dMB\n", "active",              act*mb
    printf "  %-22s %dMB\n", "inactive (cache)",    inact*mb
    printf "  %-22s %dMB\n", "compressed",          comp*mb
    printf "  %-22s %dMB\n", "free",                free*mb
  }'

SWAP="$(sysctl -n vm.swapusage 2>/dev/null)"
if [[ -n "$SWAP" ]]; then
  USED="$(printf '%s' "$SWAP" | sed -n 's/.*used = \([0-9.]*[MG]\).*/\1/p')"
  case "$USED" in
    0.00M|"") row "swap used" "none — good" ;;
    *)        printf "  %-22s \033[1;33m%s\033[0m  ← the machine is paging; something is too big\n" "swap used" "$USED" ;;
  esac
fi

hdr "GPU budget"
CUR="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
if [[ "$CUR" == "0" ]]; then
  row "iogpu.wired_limit_mb" "0 (default, roughly $(( RAM_MB * 2 / 3 ))MB)"
  EFFECTIVE=$(( RAM_MB * 2 / 3 ))
else
  row "iogpu.wired_limit_mb" "${CUR}MB (set manually)"
  EFFECTIVE="$CUR"
fi
[[ -n "${HOST_WIRED_MB:-}" ]] && row "computed target" "${HOST_WIRED_MB}MB  (./scripts/gpu-limit.sh)"
# Resident core ~1.3GB + ~2GB KV headroom.
row "room for one model" "~$(( EFFECTIVE / 1024 - 4 ))GB after the resident core"

hdr "loaded right now"
if curl -fsS http://127.0.0.1:11434/api/ps >/dev/null 2>&1; then
  # Parsed with sed rather than jq: this must work before brew bundle.
  OUT="$(curl -fsS http://127.0.0.1:11434/api/ps 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/  \1/p')"
  SIZES="$(curl -fsS http://127.0.0.1:11434/api/ps 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"size":\([0-9]*\).*/\1/p')"
  if [[ -z "$OUT" ]]; then
    printf "  \033[2mnothing loaded\033[0m\n"
  else
    paste <(printf '%s\n' "$OUT") <(printf '%s\n' "$SIZES" \
      | awk '{ printf "%.1fGB\n", $1/1073741824 }') 2>/dev/null \
      || printf '%s\n' "$OUT"
  fi
else
  printf "  \033[2mOllama not answering on :11434\033[0m\n"
fi

hdr "disk"
du -sh "${OLLAMA_MODELS:-$HOME/.ollama/models}" 2>/dev/null \
  | awk '{ printf "  %-22s %s\n", "model weights", $1 }'
df -h / 2>/dev/null | awk 'NR==2 { printf "  %-22s %s free\n", "volume", $4 }'
