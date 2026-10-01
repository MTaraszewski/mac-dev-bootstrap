#!/usr/bin/env bash
# setup-git.sh — git defaults that are safe to apply anywhere.
#
# TWO RULES THIS SCRIPT FOLLOWS:
#   1. It never overwrites a value you already set. Every write is guarded by
#      a --get check, so on a managed Mac it will not fight your org's config.
#   2. No identity is committed to this repo. Name and email come from the
#      environment or not at all:
#          GIT_USER_NAME="Your Name" GIT_USER_EMAIL=you@corp.example \
#            ./scripts/setup-git.sh
#      That keeps a work email out of a repo you push to GitHub.
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

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-git "$@"

command -v git >/dev/null 2>&1 || die "git missing — run brew bundle first"

# Set only if unset. `git config --get` exits 1 when the key is absent.
set_default() {
  local key="$1" val="$2" why="${3:-}"
  local cur
  if cur="$(git config --global --get "$key" 2>/dev/null)" && [[ -n "$cur" ]]; then
    if [[ "$cur" == "$val" ]]; then
      ok "$key = $cur"
    else
      printf "  \033[2m· %s = %s (yours — leaving it)\033[0m\n" "$key" "$cur"
    fi
    return 0
  fi
  git config --global "$key" "$val" && ok "$key = $val${why:+   — $why}"
}

log "git defaults"
set_default init.defaultBranch   main
set_default pull.ff              only          "refuse implicit merge commits on pull"
set_default pull.rebase          false         "explicit: 'git pull --rebase' when you mean it"
set_default fetch.prune          true          "delete local refs for branches gone from the remote"
set_default push.autoSetupRemote true          "first 'git push' on a new branch just works"
set_default rebase.autoStash     true
set_default core.autocrlf        input         "normalise CRLF on commit, never on checkout"
set_default diff.colorMoved      zebra         "distinguish moved code from changed code"
set_default rerere.enabled       true          "remember how you resolved a conflict"
set_default help.autocorrect     0             "do NOT auto-run a guessed command"

# `git parent` — the branch this one was cut from. Genuinely hard to remember.
if ! git config --global --get alias.parent >/dev/null 2>&1; then
  git config --global alias.parent \
    "!git show-branch | sed 's/].*//' | grep '\*' | grep -v \"\$(git rev-parse --abbrev-ref HEAD)\" | head -n1 | sed 's/^.*\[//'"
  ok "alias.parent"
fi

# ── identity ─────────────────────────────────────────────────────────────
log "identity"
if [[ -n "${GIT_USER_NAME:-}" ]]; then
  git config --global user.name  "$GIT_USER_NAME";  ok "user.name  = $GIT_USER_NAME"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  git config --global user.email "$GIT_USER_EMAIL"; ok "user.email = $GIT_USER_EMAIL"
fi

NAME="$(git config --global --get user.name  2>/dev/null || true)"
MAIL="$(git config --global --get user.email 2>/dev/null || true)"
if [[ -z "$NAME" || -z "$MAIL" ]]; then
  warn "No global git identity set. Commits will fail until there is one."
  warn "  GIT_USER_NAME=\"Your Name\" GIT_USER_EMAIL=you@corp.example ./scripts/setup-git.sh"
else
  ok "identity: $NAME <$MAIL>"
fi

# ── one machine, two identities ──────────────────────────────────────────
# If you use this Mac for both work and personal code, do NOT keep flipping
# the global. Point git at a per-directory override instead:
#
#   # ~/.gitconfig
#   [includeIf "gitdir:~/work/"]
#       path = ~/.gitconfig-work
#   [includeIf "gitdir:~/personal/"]
#       path = ~/.gitconfig-personal
#
# Each included file sets its own [user] name/email. The trailing slash on the
# gitdir pattern matters — without it, it matches nothing.
# git/gitconfig-split.example in this repo is a ready-made version.
if ! grep -q 'includeIf' "$HOME/.gitconfig" 2>/dev/null; then
  printf "  \033[2m· tip: see git/gitconfig-split.example for a work/personal identity split\033[0m\n"
fi

log "Done."
