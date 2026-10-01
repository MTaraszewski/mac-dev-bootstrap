#!/usr/bin/env bash
# setup-ide.sh — settings + extensions for whichever VS Code-family editor is
# installed. Telemetry off in both.
#
#   ./scripts/setup-ide.sh             # configure + install extensions
#   ./scripts/setup-ide.sh --settings  # settings only, no extension installs
#   ./scripts/setup-ide.sh --list      # show what would be installed
#
# NO model/assistant configuration here — this repo has no local-model stack.
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

log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mERR\033[0m %s\n" "$*"; exit 1; }

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-ide "$@"

MODE="${1:-all}"

# ── which editor(s) are here? ────────────────────────────────────────────
# VSCodium and VS Code keep their user settings in DIFFERENT directories and
# use DIFFERENT extension registries (Open VSX vs the MS Marketplace). Handle
# whichever exists rather than assuming.
declare -a EDITORS=()
if command -v codium >/dev/null 2>&1 || [[ -d /Applications/VSCodium.app ]]; then
  EDITORS+=("codium:$HOME/Library/Application Support/VSCodium/User")
fi
if command -v code >/dev/null 2>&1 || [[ -d "/Applications/Visual Studio Code.app" ]]; then
  EDITORS+=("code:$HOME/Library/Application Support/Code/User")
fi

if (( ${#EDITORS[@]} == 0 )); then
  warn "No VS Code-family editor found."
  warn "  brew install --cask vscodium    (telemetry-free build)"
  exit 0
fi

# The CLI may not be on PATH even when the app is installed (VS Code only
# installs `code` when you run "Shell Command: Install 'code' command").
cli_for() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 && { echo "$name"; return 0; }
  case "$name" in
    codium) [[ -x "/Applications/VSCodium.app/Contents/Resources/app/bin/codium" ]] \
              && { echo "/Applications/VSCodium.app/Contents/Resources/app/bin/codium"; return 0; } ;;
    code)   [[ -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]] \
              && { echo "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"; return 0; } ;;
  esac
  return 1
}

for entry in "${EDITORS[@]}"; do
  BIN="${entry%%:*}"; USER_DIR="${entry#*:}"
  log "$BIN"

  # ── settings.json ──────────────────────────────────────────────────────
  # We do NOT merge JSON (no jq dependency, and settings.json allows comments
  # which most JSON parsers reject). We back yours up and write ours, then
  # tell you where the old one is so you can pull anything back.
  mkdir -p "$USER_DIR"
  if [[ -f "$USER_DIR/settings.json" ]]; then
    if cmp -s "$REPO_DIR/ide/settings.json" "$USER_DIR/settings.json"; then
      ok "settings.json already current"
    else
      BK="$USER_DIR/settings.json.bak.$(date +%s)"
      cp "$USER_DIR/settings.json" "$BK"
      cp "$REPO_DIR/ide/settings.json" "$USER_DIR/settings.json"
      ok "settings.json written  (yours: $(basename "$BK"))"
    fi
  else
    cp "$REPO_DIR/ide/settings.json" "$USER_DIR/settings.json"
    ok "settings.json written"
  fi

  [[ "$MODE" == "--settings" ]] && continue

  # ── extensions ─────────────────────────────────────────────────────────
  CLI="$(cli_for "$BIN")" || {
    warn "$BIN CLI not on PATH — cannot install extensions."
    [[ "$BIN" == "code" ]] && warn "  In VS Code: Cmd+Shift+P -> Shell Command: Install 'code' command in PATH"
    continue
  }

  INSTALLED="$("$CLI" --list-extensions 2>/dev/null | tr '[:upper:]' '[:lower:]')"
  # strip comments and blanks, take the first field
  EXTS="$(awk '{ sub(/#.*/, "") } NF { print $1 }' "$REPO_DIR/ide/extensions.txt")"

  if [[ "$MODE" == "--list" ]]; then
    echo "$EXTS" | sed 's/^/      /'
    continue
  fi

  for ext in $EXTS; do
    if printf '%s\n' "$INSTALLED" | grep -qix "$ext"; then
      printf "  \033[2m· %s\033[0m\n" "$ext"
      continue
    fi
    # Not suppressed: when an extension is missing from Open VSX you want to
    # SEE which one and why, not discover it later as a silently absent feature.
    if "$CLI" --install-extension "$ext" --force >/dev/null 2>&1; then
      ok "$ext"
    else
      warn "$ext — not available for $BIN (Open VSX vs Marketplace?)"
    fi
  done
done

log "Done. Restart the editor."
