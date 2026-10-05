#!/usr/bin/env bash
# pull-models.sh — pull every uncommented model in a manifest. Idempotent.
#
#   ./scripts/pull-models.sh                      # auto-pick by RAM
#   ./scripts/pull-models.sh models.big.conf      # explicit manifest
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

command -v ollama >/dev/null 2>&1 || {
  echo "ollama not on PATH — run ./scripts/setup-local-ai.sh first" >&2; exit 1; }

# Manifest: explicit argument, else by RAM, else the conservative default.
if [[ -n "${1:-}" && -f "$1" ]]; then
  CONF="$1"
else
  source "$REPO_DIR/scripts/lib/host.sh" 2>/dev/null && load_host_profile 2>/dev/null
  CONF="$REPO_DIR/models.${HOST_MODELS_TAG:-}.conf"
  [[ -n "${HOST_MODELS_TAG:-}" && -f "$CONF" ]] || CONF="$REPO_DIR/models.conf"
fi
[[ -f "$CONF" ]] || { echo "no manifest at $CONF" >&2; exit 1; }

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init pull-models "$@"

echo "manifest: $(basename "$CONF")"

# Strip comments and blank lines, take the first field.
awk '{ sub(/#.*/, "") } NF { print $1 }' "$CONF" | while read -r tag; do
  [[ -z "$tag" ]] && continue

  # `ollama list` always shows a tag. An untagged manifest entry (e.g.
  # "nomic-embed-text") is really "nomic-embed-text:latest" on disk, so an
  # exact match never fires and it re-downloads on EVERY run. Normalise.
  want="$tag"
  case "$tag" in *:*) ;; *) want="$tag:latest" ;; esac

  if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$want"; then
    printf "  \033[2m· %s (present)\033[0m\n" "$tag"
  else
    printf "  ↓ pulling %s\n" "$tag"
    ollama pull "$tag" \
      || printf "  \033[1;31m✗\033[0m %s failed — tag renamed? check ollama.com/library\n" "$tag"
  fi
done

echo
echo "Disk used by models:"
du -sh "${OLLAMA_MODELS:-$HOME/.ollama/models}" 2>/dev/null || true
