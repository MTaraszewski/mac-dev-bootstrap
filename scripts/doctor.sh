#!/usr/bin/env bash
# doctor.sh — did the bootstrap actually take? Run this in a NEW terminal.
#
#   ./scripts/doctor.sh
#
# The distinction this script exists to make: survey.sh asks "what is on this
# machine", doctor.sh asks "does it WORK". A binary on disk proves nothing —
# docker needs a running engine, nvm needs to be sourced, direnv needs its
# hook. Those only show up in a fresh interactive shell, which is why the
# instruction is "new terminal", not "re-run bootstrap".
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

PASS=0; FAIL=0; SKIP=0
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
bad()  { printf "  \033[1;31m✗\033[0m %s\n" "$*"; FAIL=$((FAIL+1)); }
skip() { printf "  \033[2m· %s\033[0m\n" "$*"; SKIP=$((SKIP+1)); }
hdr()  { printf "\n\033[1;34m── %s\033[0m\n" "$*"; }
hint() { printf "      \033[2m%s\033[0m\n" "$*"; }

# check <label> <command...>  — passes if the command exits 0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; return 1; fi
}

hdr "toolchain"
for b in brew git gh jq rg direnv uv; do
  if command -v "$b" >/dev/null 2>&1; then
    ok "$b  $(command -v "$b")"
  else
    bad "$b not on PATH"
    [[ "$b" == "uv" || "$b" == "direnv" ]] && hint "brew bundle --file=Brewfile"
  fi
done

hdr "zsh wiring"
# Grep the rc file rather than trusting this shell: doctor.sh runs under bash,
# so the zsh hooks are not loaded here even when they are correctly configured.
if grep -qF ">>> mac-dev-bootstrap >>>" "$HOME/.zshrc" 2>/dev/null; then
  ok "managed block in ~/.zshrc"
  if grep -qF "$REPO_DIR/zsh/managed.zsh" "$HOME/.zshrc" 2>/dev/null; then
    ok "points at this repo"
  else
    bad "managed block points somewhere else"
    hint "the repo moved — re-run ./scripts/setup-shell.sh"
  fi
else
  bad "no managed block in ~/.zshrc"
  hint "./scripts/setup-shell.sh"
fi
grep -q "oh-my-zsh.sh" "$HOME/.zshrc" 2>/dev/null \
  && ok "oh-my-zsh sourced" \
  || { bad "oh-my-zsh not sourced in ~/.zshrc"; hint "merge zsh/zshrc.template"; }
# The ordering rule that silently half-breaks highlighting if violated.
if grep -q "zsh-syntax-highlighting" "$HOME/.zshrc" 2>/dev/null; then
  if zsh -ic 'print -r -- ${plugins[-1]}' 2>/dev/null | grep -q "zsh-syntax-highlighting"; then
    ok "zsh-syntax-highlighting is last in plugins="
  else
    bad "zsh-syntax-highlighting is NOT last in plugins="
    hint "it wraps widgets the earlier plugins define — move it to the end"
  fi
fi

hdr "runtimes (in a real zsh login shell)"
# -i: interactive, so ~/.zshrc actually runs. This is the only honest way to
# test PATH wiring — checking from bash would pass or fail for the wrong reason.
zsh_has() { zsh -ic "command -v $1" >/dev/null 2>&1; }
for pair in "node:nvm" "npm:nvm" "cargo:rustup" "uv:brew" "direnv:brew"; do
  b="${pair%%:*}"; src="${pair##*:}"
  if zsh_has "$b"; then
    ok "$b available in zsh  ($(zsh -ic "$b --version" 2>/dev/null | head -1 | tr -d '\r'))"
  else
    bad "$b NOT available in a zsh shell  (from $src)"
    hint "open a new terminal first; then ./scripts/setup-runtimes.sh"
  fi
done
if command -v uv >/dev/null 2>&1; then
  n="$(uv python list --only-installed 2>/dev/null | wc -l | tr -d ' ')"
  (( n > 0 )) && ok "uv has $n interpreter entries" || bad "uv has no interpreters installed"
fi

hdr "containers"
if source "$REPO_DIR/scripts/lib/docker.sh" 2>/dev/null && ensure_docker quiet; then
  ok "docker engine answering  ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
  if ensure_compose; then
    ok "docker compose  ($(docker compose version --short 2>/dev/null || echo "${COMPOSE[*]}"))"
  else
    bad "docker compose unavailable"
    hint "./scripts/setup-orbstack.sh"
  fi
  # Actually run something — a CLI that talks to the engine still does not
  # prove the VM can execute a container. Only uses an image already on disk:
  # a doctor script should not quietly pull from a registry.
  IMG="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
         | grep -vE '<none>' | head -1)"
  if [[ -n "$IMG" ]]; then
    docker run --rm "$IMG" true >/dev/null 2>&1 \
      && ok "ran a container ($IMG)" \
      || bad "engine is up but running a container failed"
  else
    skip "no local image to test with  (docker run --rm hello-world)"
  fi
else
  bad "no docker engine"
  hint "open OrbStack.app and finish its setup, then ./scripts/setup-orbstack.sh"
fi

hdr "git"
NAME="$(git config --global --get user.name 2>/dev/null || true)"
MAIL="$(git config --global --get user.email 2>/dev/null || true)"
[[ -n "$NAME" && -n "$MAIL" ]] \
  && ok "identity: $NAME <$MAIL>" \
  || { bad "no git identity — commits will fail"; hint "GIT_USER_NAME=... GIT_USER_EMAIL=... ./scripts/setup-git.sh"; }
[[ "$(git config --global --get init.defaultBranch 2>/dev/null)" == "main" ]] \
  && ok "init.defaultBranch = main" || skip "init.defaultBranch not set"
if command -v gh >/dev/null 2>&1; then
  gh auth status >/dev/null 2>&1 && ok "gh authenticated" || skip "gh not authenticated  (gh auth login)"
fi

hdr "editor"
IDE=0
for pair in "codium:VSCodium" "code:VS Code"; do
  b="${pair%%:*}"; label="${pair##*:}"
  command -v "$b" >/dev/null 2>&1 || continue
  IDE=1
  n="$("$b" --list-extensions 2>/dev/null | wc -l | tr -d ' ')"
  ok "$label: $n extensions"
  case "$b" in
    codium) S="$HOME/Library/Application Support/VSCodium/User/settings.json" ;;
    code)   S="$HOME/Library/Application Support/Code/User/settings.json" ;;
  esac
  if [[ -f "$S" ]] && grep -q '"telemetry.telemetryLevel"[[:space:]]*:[[:space:]]*"off"' "$S"; then
    ok "$label telemetry off"
  else
    bad "$label telemetry NOT off"
    hint "./scripts/setup-ide.sh"
  fi
done
(( IDE )) || skip "no editor CLI on PATH"

hdr "iterm"
if [[ -d /Applications/iTerm.app ]]; then
  # Check the link TARGET, not just that a file of that name is there. Another
  # repo can have installed a profile and the name alone would pass.
  found=0
  for src in "$REPO_DIR"/iterm/DynamicProfiles/*.json; do
    [[ -e "$src" ]] || continue
    D="$HOME/Library/Application Support/iTerm2/DynamicProfiles/$(basename "$src")"
    found=1
    if [[ ! -e "$D" && ! -L "$D" ]]; then
      bad "$(basename "$src") not installed"; hint "./scripts/setup-iterm.sh"
    elif [[ ! -e "$D" ]]; then
      bad "$(basename "$src") is a BROKEN symlink (repo moved?)"; hint "./scripts/setup-iterm.sh"
    elif [[ "$(cd "$(dirname "$(readlink "$D" 2>/dev/null || echo "$D")")" && pwd)" \
            == "$(cd "$(dirname "$src")" && pwd)" ]]; then
      ok "$(basename "$src") linked to this repo"
    else
      bad "$(basename "$src") points somewhere else: $(readlink "$D")"
      hint "./scripts/setup-iterm.sh  (overwrites the link)"
    fi
  done
  (( found )) || skip "no profiles in iterm/DynamicProfiles"
else
  skip "iTerm2 not installed"
fi

hdr "local ai (opt-in)"
# Silent unless the module was actually run — a machine that never asked for
# local models should not be told it is missing them.
if [[ ! -d /Applications/Ollama.app ]]; then
  skip "not installed  (./bootstrap.sh --only local-ai)"
else
  if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then
    ok "Ollama API on :11434"
  else
    bad "Ollama.app installed but the API is not answering"
    hint "open -a Ollama and finish any first-run prompts"
  fi
  # The launchd env is what Ollama.app reads; a shell export does not reach it.
  for k in OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE OLLAMA_KEEP_ALIVE; do
    v="$(launchctl getenv "$k" 2>/dev/null)"
    [[ -n "$v" ]] && ok "$k=$v" || { bad "$k unset in the launchd env"; hint "./scripts/setup-local-ai.sh"; }
  done
  n="$(ollama list 2>/dev/null | tail -n +2 | grep -c . | tr -d ' ')"
  [[ "${n:-0}" -gt 0 ]] && ok "$n models local" || skip "no models pulled yet"
  # A set cap is optional, but worth saying out loud since it resets on reboot.
  cap="$(sysctl -n iogpu.wired_limit_mb 2>/dev/null || echo 0)"
  [[ "$cap" == "0" ]] \
    && skip "GPU cap at the system default  (./scripts/gpu-limit.sh)" \
    || ok "GPU cap ${cap}MB"
fi

hdr "openai tools (opt-in)"
if [[ ! -d /Applications/ChatGPT.app ]] && ! command -v codex >/dev/null 2>&1; then
  skip "not installed  (./bootstrap.sh --only openai)"
else
  [[ -d /Applications/ChatGPT.app ]] && ok "ChatGPT.app" || skip "ChatGPT.app absent"
  if command -v codex >/dev/null 2>&1; then
    ok "codex $(codex --version 2>/dev/null | head -1)"
    # Same PATH trap as claude-code: two installs, different versions.
    if npm ls -g --depth=0 2>/dev/null | grep -q "@openai/codex"; then
      bad "codex installed via BOTH brew and npm — PATH decides which you get"
      hint "npm uninstall -g @openai/codex"
    fi
  else
    skip "codex CLI absent"
  fi
fi

printf "\n\033[1m%d passed, %d failed, %d skipped\033[0m\n" "$PASS" "$FAIL" "$SKIP"
if (( FAIL )); then
  echo "Each ✗ above carries the command that fixes it. bootstrap.sh is idempotent —"
  echo "re-running it, or just the one module, is always safe."
  exit 1
fi
echo "Healthy."
