#!/usr/bin/env bash
# setup-runtimes.sh — Python via uv, Node via nvm, Rust via rustup.
#
# One manager per language. The failure mode this avoids: pyenv AND brew
# python AND pipx all on PATH, where which interpreter you get depends on
# which shell rc file won.
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

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-runtimes "$@"

# ── python (uv) ──────────────────────────────────────────────────────────
# uv replaces pyenv + virtualenv + pip + pipx + poetry. It downloads
# standalone interpreter builds rather than compiling like pyenv, so this
# takes seconds, not the twenty minutes pyenv needs for a handful of versions.
UV_PYTHONS=(${UV_PYTHONS:-3.11 3.12 3.13})

if command -v uv >/dev/null 2>&1; then
  log "uv $(uv --version 2>/dev/null | awk '{print $2}')"
  for v in "${UV_PYTHONS[@]}"; do
    log "python $v"
    uv python install "$v" || warn "python $v failed"
  done
  uv python list --only-installed 2>/dev/null || true
  uv tool update-shell 2>/dev/null || true
else
  warn "uv missing — run: brew bundle --file=Brewfile"
fi

# ── node (nvm) ───────────────────────────────────────────────────────────
# nvm is a shell function, not a binary, which is why it is cloned here rather
# than installed by brew. Node itself is NOT a brew formula either — it would
# shadow nvm's node depending on PATH order.
NODE_VERSION="${NODE_VERSION:-24}"   # 24 = current LTS line
export NVM_DIR="$HOME/.nvm"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  log "Installing nvm"
  git clone https://github.com/nvm-sh/nvm.git "$NVM_DIR" 2>/dev/null \
    && (cd "$NVM_DIR" && git checkout -q "$(git describe --abbrev=0 --tags)") \
    || warn "nvm install failed"
fi
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  . "$NVM_DIR/nvm.sh"
  log "node $NODE_VERSION"
  nvm install "$NODE_VERSION" && nvm alias default "$NODE_VERSION" \
    || warn "node $NODE_VERSION failed"
fi

# ── rust ─────────────────────────────────────────────────────────────────
if command -v rustc >/dev/null 2>&1; then
  ok "rust present: $(rustc --version)"
else
  log "Installing rustup"
  # --no-modify-path: zsh/managed.zsh sources ~/.cargo/env itself, so rustup
  # does not need to append its own line to your rc file.
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --no-modify-path || warn "rustup failed"
fi

# ── npm globals ──────────────────────────────────────────────────────────
# Keep this list as close to empty as possible: npm-installed globals live
# under the ACTIVE nvm version, so `nvm use <other>` makes them vanish.
# Anything you want on PATH regardless of node version belongs in the Brewfile.
if command -v npm >/dev/null 2>&1; then
  log "npm globals"
  npm install -g corepack || warn "npm globals failed"
fi

# A second claude-code install is a real and confusing problem: PATH decides
# which one you get, and the two can be different versions.
if npm ls -g --depth=0 2>/dev/null | grep -q "@anthropic-ai/claude-code"; then
  warn "claude-code is ALSO installed via npm — two installs will fight over PATH."
  warn "  npm uninstall -g @anthropic-ai/claude-code    # keep the brew cask"
fi

log "Done. Open a new terminal so nvm/uv/cargo land on PATH."
