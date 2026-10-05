#!/usr/bin/env bash
# model.sh — swap the "big slot" by task, explicitly.
#
#   ./scripts/model.sh status      what is loaded, and what fits
#   ./scripts/model.sh list        every local model
#   ./scripts/model.sh code        load the coding model
#   ./scripts/model.sh reason      load the reasoning model
#   ./scripts/model.sh agent       load the agent model (big context)
#   ./scripts/model.sh load <tag>  load anything by name
#   ./scripts/model.sh free        unload everything
#
# WHY: you have room for exactly ONE large model plus the tiny resident core.
# Letting Ollama work that out by eviction means it thrashes — unloading and
# reloading gigabytes while you wait. Switching deliberately is faster and
# makes the memory behaviour predictable.
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

ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mERR\033[0m %s\n" "$*"; exit 1; }

command -v ollama >/dev/null 2>&1 || die "ollama not on PATH — ./scripts/setup-local-ai.sh"
api() { curl -fsS "http://127.0.0.1:11434/api/$1" 2>/dev/null; }
api version >/dev/null || die "Ollama not answering on :11434. Open Ollama.app."

have() { ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }

# Resolve a role to the first locally-present candidate. Order is preference.
# Deliberately a list rather than a pinned name: which model is best changes
# every few months, and a hardcoded tag rots into a confusing error.
resolve() {
  local role="$1" candidates c
  case "$role" in
    code)   candidates="qwen3-coder:30b qwen2.5-coder:14b dev-assistant:latest qwen2.5-coder:7b" ;;
    reason) candidates="deepseek-r1:70b gpt-oss:20b deepseek-r1:14b" ;;
    agent)  candidates="agent-big:latest agent:latest devstral:24b qwen3-coder:30b qwen2.5-coder:14b" ;;
    *) return 1 ;;
  esac
  for c in $candidates; do
    have "$c" && { echo "$c"; return 0; }
    have "${c%:*}:latest" && { echo "${c%:*}:latest"; return 0; }
  done
  return 1
}

loaded() { api ps | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p'; }

unload_big() {
  # Keep the resident core; drop anything large. `keep_alive: 0` is how you
  # ask Ollama to release a model immediately.
  local m
  for m in $(loaded); do
    case "$m" in
      *1.5b*|*embed*) continue ;;   # resident core, leave it
    esac
    printf "  releasing %s\n" "$m"
    curl -fsS http://127.0.0.1:11434/api/generate \
      -d "{\"model\":\"$m\",\"keep_alive\":0}" >/dev/null 2>&1 || true
  done
}

load() {
  local tag="$1"
  have "$tag" || have "${tag%:*}:latest" || die "not local: $tag  (./scripts/model-add.sh $tag)"
  unload_big
  printf "  loading %s" "$tag"
  # An empty prompt with keep_alive set loads the weights without generating.
  curl -fsS http://127.0.0.1:11434/api/generate \
    -d "{\"model\":\"$tag\",\"prompt\":\"\",\"keep_alive\":\"30m\"}" >/dev/null 2>&1 \
    && { printf "\n"; ok "$tag resident (30m idle timeout)"; } \
    || { printf "\n"; die "failed to load $tag"; }
}

case "${1:-status}" in
  status)
    printf "\n\033[1;34m── loaded\033[0m\n"
    L="$(loaded)"
    if [[ -z "$L" ]]; then printf "  \033[2mnothing\033[0m\n"; else printf '  %s\n' $L; fi
    printf "\n\033[1;34m── roles available locally\033[0m\n"
    for r in code reason agent; do
      if m="$(resolve "$r")"; then printf "  %-8s %s\n" "$r" "$m"
      else printf "  %-8s \033[2mnone local\033[0m\n" "$r"; fi
    done
    echo
    "$REPO_DIR/scripts/ram.sh" 2>/dev/null | sed -n '/GPU budget/,/^$/p'
    ;;
  list) ollama list ;;
  code|reason|agent)
    m="$(resolve "$1")" || die "no local model for role '$1' — see models.conf"
    load "$m" ;;
  load) [[ -n "${2:-}" ]] || die "usage: $0 load <tag>"; load "$2" ;;
  free) unload_big; ok "big slot free" ;;
  --help|-h|help) sed -n '2,18p' "$0" ;;
  *) die "unknown command: $1  (try: status)" ;;
esac
