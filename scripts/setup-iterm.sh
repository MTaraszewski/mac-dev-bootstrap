#!/usr/bin/env bash
# setup-iterm.sh — install iTerm2 Dynamic Profiles from this repo.
#
#   ./scripts/setup-iterm.sh
#
# WHY DYNAMIC PROFILES, and not a copied plist:
#   iterm/DynamicProfiles/*.json is real, declarative, diffable config that
#   iTerm reads LIVE — no restart, no `killall cfprefsd`, no shipping a binary
#   plist between machines. Profiles defined this way are READ-ONLY in the UI,
#   so they cannot drift out of sync with git.
#
# We symlink rather than copy: edit the JSON in the repo and iTerm picks the
# change up instantly.
#
# What is deliberately NOT here: pointing iTerm at a custom prefs folder
# (`defaults write com.googlecode.iterm2 PrefsCustomFolder`). It is the only
# way to version app-level settings like a global hotkey, but it trades a text
# file for a binary plist and has a nasty self-reference failure mode. If you
# need it, do it knowingly, by hand.
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

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-iterm "$@"

if [[ ! -d "/Applications/iTerm.app" ]]; then
  warn "iTerm2 not installed — skipping. (brew bundle installs it)"
  exit 0
fi

SRC="$REPO_DIR/iterm/DynamicProfiles"
DYN_DIR="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
[[ -d "$SRC" ]] || { warn "no iterm/DynamicProfiles in repo"; exit 0; }

mkdir -p "$DYN_DIR"
n=0
for f in "$SRC"/*.json; do
  [[ -e "$f" ]] || continue
  ln -sf "$f" "$DYN_DIR/$(basename "$f")"
  ok "linked $(basename "$f")"
  n=$((n+1))
done

if (( n == 0 )); then
  warn "no profiles found in $SRC"
  exit 0
fi

log "iTerm reads these live — no restart needed."
echo
echo "  A profile named 'dev' is now in iTerm2 -> Settings -> Profiles."
echo "  Make it the default: select it -> 'Other Actions...' -> 'Set as Default'."
echo "  It is read-only in the UI on purpose — edit the JSON in git instead."
echo
echo "  The font is FiraCode-Retina 13, which the Brewfile installs as"
echo "  font-fira-code. If iTerm shows a fallback font, the cask did not land."
