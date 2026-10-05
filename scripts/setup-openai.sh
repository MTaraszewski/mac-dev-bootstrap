#!/usr/bin/env bash
# setup-openai.sh — ChatGPT desktop app + Codex CLI. OPT-IN.
#
#   ./scripts/setup-openai.sh          # install both
#   ./bootstrap.sh --only openai       # same thing through bootstrap
#   ./scripts/setup-openai.sh --plan   # print the plan, change nothing
#
# Not part of ./bootstrap.sh's default run: these are cloud AI tools, and
# which assistant you want is a preference, not a dependency. The default
# run installs claude-code; this adds the OpenAI side alongside it. They do
# not conflict.
#
# Nothing here authenticates you — sign-in is interactive and yours to do.
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

case "${1:-}" in
  --plan)
    echo "Would run: brew bundle --file=Brewfile.openai"
    echo "  cask chatgpt   → /Applications/ChatGPT.app"
    echo "  cask codex     → the codex CLI on PATH"
    echo "Then print sign-in instructions. No credentials are touched."
    exit 0 ;;
  --help|-h) sed -n '2,15p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-openai "$@"

command -v brew >/dev/null 2>&1 || die "Homebrew missing — run ./bootstrap.sh first"

log "Installing from Brewfile.openai"
brew bundle --file="$REPO_DIR/Brewfile.openai" || warn "some installs failed — see above"

# ── verify ───────────────────────────────────────────────────────────────
[[ -d "/Applications/ChatGPT.app" ]] \
  && ok "ChatGPT.app installed" \
  || warn "ChatGPT.app not found — brew install --cask chatgpt"

if command -v codex >/dev/null 2>&1; then
  ok "codex $(codex --version 2>/dev/null | head -1)"
else
  warn "codex not on PATH yet — open a new terminal, or:"
  warn "  brew install --cask codex"
fi

# A second Codex install is the same trap as a second claude-code: PATH
# decides which one you get, and the two can be different versions.
if npm ls -g --depth=0 2>/dev/null | grep -q "@openai/codex"; then
  warn "codex is ALSO installed via npm — two installs will fight over PATH."
  warn "  npm uninstall -g @openai/codex    # keep the brew cask"
fi

cat <<'TXT'

  Sign in (interactive, not scripted):
    codex                 → follow the prompt; sign in with your ChatGPT
                            account, or set OPENAI_API_KEY for API billing
    open -a ChatGPT       → sign in in the app

  The two are billed differently: a ChatGPT subscription covers the app and
  (depending on plan) Codex; OPENAI_API_KEY bills per token instead. Picking
  one is yours to do — this script deliberately sets no key.

  If you do use an API key, put it in a per-project .envrc rather than your
  shell profile, so it loads on cd and unloads on the way out:
    echo 'export OPENAI_API_KEY=...' > .envrc && direnv allow
TXT

log "Done."
