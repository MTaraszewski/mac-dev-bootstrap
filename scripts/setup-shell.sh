#!/usr/bin/env bash
# setup-shell.sh — oh-my-zsh, plugins, login shell, and ONE managed block in
# ~/.zshrc. Idempotent. Never overwrites your .zshrc.
#
#   ./scripts/setup-shell.sh
#   SKIP_ZSHRC=1 ./scripts/setup-shell.sh    # install omz, leave .zshrc alone
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

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-shell "$@"

# ── oh-my-zsh ────────────────────────────────────────────────────────────
if [[ -d "$HOME/.oh-my-zsh" ]]; then
  ok "oh-my-zsh present"
else
  log "Installing oh-my-zsh"
  # RUNZSH=no   stops it dropping you into a subshell mid-script.
  # CHSH=no     stops it changing your login shell behind your back (we do it
  #             explicitly below, so the change is visible in this script).
  # KEEP_ZSHRC  stops it renaming your existing .zshrc to .pre-oh-my-zsh.
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" \
    || warn "oh-my-zsh install failed"
fi

# ── custom plugins (not bundled with oh-my-zsh) ──────────────────────────
ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
clone_plugin() {
  local name="$1" url="$2"
  if [[ -d "$ZC/plugins/$name" ]]; then
    ok "$name present"
  else
    log "Cloning $name"
    git clone --depth=1 "$url" "$ZC/plugins/$name" || warn "  $name clone failed"
  fi
}
clone_plugin zsh-autosuggestions     https://github.com/zsh-users/zsh-autosuggestions
clone_plugin zsh-syntax-highlighting https://github.com/zsh-users/zsh-syntax-highlighting

# ── login shell ──────────────────────────────────────────────────────────
# On a managed Mac this may be set by policy; chsh then fails harmlessly.
if [[ "$SHELL" == "/bin/zsh" ]]; then
  ok "login shell already zsh"
else
  log "Setting login shell to zsh (was $SHELL)"
  chsh -s /bin/zsh || warn "chsh failed — may be managed by policy. Harmless: macOS defaults to zsh."
fi

# ── ~/.zshrc: ONE managed block ──────────────────────────────────────────
# We do NOT rewrite your .zshrc. We append a single sourcing line between
# sentinels and only ever touch what is between them — the same pattern nvm
# and rbenv use. Re-running REPLACES the block instead of stacking duplicates.
BEGIN="# >>> mac-dev-bootstrap >>>"
END="# <<< mac-dev-bootstrap <<<"
ZSHRC="$HOME/.zshrc"

if [[ -n "${SKIP_ZSHRC:-}" ]]; then
  warn "SKIP_ZSHRC set — not touching ~/.zshrc"
  warn "  add this yourself:  source $REPO_DIR/zsh/managed.zsh"
else
  BLOCK="$(cat <<BLOCKEOF
$BEGIN
# Managed by mac-dev-bootstrap. Do not edit between these markers —
# edit $REPO_DIR/zsh/managed.zsh instead, then open a new shell.
[ -f "$REPO_DIR/zsh/managed.zsh" ] && source "$REPO_DIR/zsh/managed.zsh"
$END
BLOCKEOF
)"
  touch "$ZSHRC"
  if grep -qF "$BEGIN" "$ZSHRC" 2>/dev/null; then
    # Replace the existing block. awk, not sed -i: BSD sed needs a backup-suffix
    # argument and misbehaves silently without one.
    log "Updating managed block in ~/.zshrc"
    cp "$ZSHRC" "$ZSHRC.bak.$(date +%s)"
    awk -v b="$BEGIN" -v e="$END" -v repl="$BLOCK" '
      $0 == b { print repl; skip=1; next }
      $0 == e { skip=0; next }
      !skip   { print }
    ' "$ZSHRC" > "$ZSHRC.tmp" && mv "$ZSHRC.tmp" "$ZSHRC"
  else
    log "Appending managed block to ~/.zshrc"
    [[ -s "$ZSHRC" ]] && cp "$ZSHRC" "$ZSHRC.bak.$(date +%s)"
    printf '\n%s\n' "$BLOCK" >> "$ZSHRC"
  fi
  ok "sources zsh/managed.zsh (PATH, nvm, uv, cargo, direnv, docker, fzf)"

  # oh-my-zsh + theme + plugins=() are ORDER-SENSITIVE and personal, so we
  # refuse to inject them. Tell the human what is left to do.
  if ! grep -q "oh-my-zsh.sh" "$ZSHRC" 2>/dev/null; then
    warn "oh-my-zsh is NOT wired into ~/.zshrc — that part is still manual."
    warn "  Copy the theme/plugins section from zsh/zshrc.template."
    warn "  (zsh-syntax-highlighting MUST be last in plugins=)"
  fi
fi

log "Done. Open a new terminal."
