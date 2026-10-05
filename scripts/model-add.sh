#!/usr/bin/env bash
# model-add.sh — pull a model, but check it FITS first.
#
#   ./scripts/model-add.sh qwen3-coder:30b     # fit-check, then pull
#   ./scripts/model-add.sh --check gpt-oss:20b # check only, pull nothing
#
# WHY: `ollama pull` on something too large succeeds, then the model either
# refuses to load or silently runs partly on the CPU — after you have waited
# for tens of gigabytes. Cheaper to find out first.
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

ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mERR\033[0m %s\n" "$*"; exit 1; }

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && { CHECK_ONLY=1; shift; }
TAG="${1:-}"
[[ -n "$TAG" ]] || { sed -n '2,10p' "$0"; exit 1; }

command -v ollama >/dev/null 2>&1 || die "ollama not on PATH — ./scripts/setup-local-ai.sh"
source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init model-add "$@"

want="$TAG"; case "$TAG" in *:*) ;; *) want="$TAG:latest" ;; esac
if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$want"; then
  ok "$TAG is already local"; exit 0
fi

echo "Checking $TAG"

# ── 1. does the tag exist? ───────────────────────────────────────────────
# Ollama's registry answers a HEAD on the manifest. A 404 here means a
# renamed or cloud-only model, which is the usual cause of a failed pull.
NAME="${TAG%%:*}"; VER="${TAG#*:}"; [[ "$VER" == "$TAG" ]] && VER="latest"
case "$NAME" in */*) PATHPART="$NAME" ;; *) PATHPART="library/$NAME" ;; esac
URL="https://registry.ollama.ai/v2/${PATHPART}/manifests/${VER}"

CODE="$(curl -s -o /dev/null -w '%{http_code}' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$URL" 2>/dev/null || echo 000)"
case "$CODE" in
  200) ok "tag exists in the registry" ;;
  404) die "no such tag: $TAG  — renamed, or cloud-only. Check ollama.com/library" ;;
  000) warn "could not reach the registry (offline?) — skipping the existence check" ;;
  *)   warn "registry returned HTTP $CODE — continuing anyway" ;;
esac

# ── 2. how big is it? ────────────────────────────────────────────────────
# Sum the layer sizes from the manifest. sed, not jq: this has to work on a
# machine where brew has not run.
SIZE_B="$(curl -s -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "$URL" 2>/dev/null \
  | tr ',' '\n' | sed -n 's/.*"size":[[:space:]]*\([0-9]*\).*/\1/p' \
  | awk '{ s += $1 } END { print s+0 }')"

if [[ -z "$SIZE_B" || "$SIZE_B" == "0" ]]; then
  warn "could not determine the download size — proceeding blind"
  SIZE_GB=0
else
  SIZE_GB=$(( SIZE_B / 1073741824 ))
  ok "download size ~${SIZE_GB}GB"
fi

# ── 3. does it fit on disk? ──────────────────────────────────────────────
FREE_GB="$(df -g / 2>/dev/null | awk 'NR==2 { print $4 }')"
if [[ -n "$FREE_GB" ]] && (( SIZE_GB > 0 )); then
  if (( SIZE_GB + 5 > FREE_GB )); then
    die "needs ~${SIZE_GB}GB but only ${FREE_GB}GB is free. Free space, or set OLLAMA_MODELS_DIR."
  fi
  ok "disk: ${FREE_GB}GB free"
fi

# ── 4. does it fit in the GPU budget? ────────────────────────────────────
# Weights are only part of it: the KV cache is extra, and grows with context.
BUDGET_GB="${HOST_BIG_SLOT_GB:-0}"
CUR="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
if [[ "$CUR" != "0" ]]; then BUDGET_GB=$(( CUR / 1024 - 4 )); fi

if (( SIZE_GB > 0 && BUDGET_GB > 0 )); then
  if (( SIZE_GB > BUDGET_GB )); then
    warn "~${SIZE_GB}GB vs a ~${BUDGET_GB}GB big slot — it will spill to the CPU."
    RAM_GB="${HOST_RAM_GB:-$(( $(sysctl -n hw.memsize) / 1073741824 ))}"
    if (( SIZE_GB + 4 <= RAM_GB )); then
      warn "raise the cap first:  ./scripts/gpu-limit.sh ${HOST_WIRED_MB:-}"
    else
      die "this machine (${RAM_GB}GB) cannot run it usefully."
    fi
  else
    ok "fits the ~${BUDGET_GB}GB big slot"
  fi
  # Decode is bandwidth-bound: tok/s ceiling is bandwidth / model size.
  if [[ -n "${HOST_BANDWIDTH:-}" ]] && (( SIZE_GB > 0 )); then
    printf "  \033[2m· speed ceiling ~%d tok/s (%s GB/s ÷ %sGB)\033[0m\n" \
      $(( HOST_BANDWIDTH / SIZE_GB )) "$HOST_BANDWIDTH" "$SIZE_GB"
  fi
fi

(( CHECK_ONLY )) && { echo; echo "Check only — nothing pulled."; exit 0; }

echo
echo "Pulling $TAG"
ollama pull "$TAG" || die "pull failed"
ok "done — load it with: ./scripts/model.sh load $TAG"
