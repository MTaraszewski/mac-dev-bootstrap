#!/usr/bin/env bash
# setup-local-ai.sh — add a local-model stack to this machine. OPT-IN.
#
#   ./scripts/setup-local-ai.sh            # install, tune, pull models
#   ./bootstrap.sh --only local-ai         # same thing through bootstrap
#   ./scripts/setup-local-ai.sh --no-pull  # install + tune, skip the weights
#   ./scripts/setup-local-ai.sh --plan     # print the plan, change nothing
#
# This is NOT part of ./bootstrap.sh's default run — it downloads tens of GB
# and changes a user-wide launchd environment, which should never be a
# surprise. Everything else in this repo is a few hundred MB of CLI tools.
#
# Opt out of pieces:  SKIP_MODELFILES=1  MODELS_CONF=path/to/manifest
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

PULL=1; PLAN=0
case "${1:-}" in
  --no-pull) PULL=0 ;;
  --plan)    PLAN=1 ;;
  --help|-h) sed -n '2,16p' "$0"; exit 0 ;;
  "") ;;
  *) die "unknown argument: $1" ;;
esac

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-local-ai "$@"
source "$REPO_DIR/scripts/lib/host.sh" || die "lib/host.sh missing"
load_host_profile

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
[[ "$(uname -m)" == "arm64"  ]] || die "Apple Silicon only — Metal is the whole point."

# ── which manifest ───────────────────────────────────────────────────────
MODELS_CONF="${MODELS_CONF:-}"
if [[ -z "$MODELS_CONF" ]]; then
  MODELS_CONF="$REPO_DIR/models.${HOST_MODELS_TAG}.conf"
  [[ -n "$HOST_MODELS_TAG" && -f "$MODELS_CONF" ]] || MODELS_CONF="$REPO_DIR/models.conf"
fi
[[ -f "$MODELS_CONF" ]] || die "no model manifest at $MODELS_CONF"

log "Local AI stack"
print_host_profile
printf "  %-18s %s\n" "manifest" "$(basename "$MODELS_CONF")"

# What the manifest asks for, before we touch anything.
TAGS="$(awk '{ sub(/#.*/, "") } NF { print $1 }' "$MODELS_CONF")"
printf "  %-18s %s\n" "models" "$(printf '%s' "$TAGS" | tr '\n' ' ')"

if (( PLAN )); then
  echo
  echo "  Plan only — nothing changed. This would:"
  echo "    1. brew bundle --file=Brewfile.local-ai   (installs ollama-app)"
  echo "    2. launchctl setenv OLLAMA_* x6           (user-wide, GUI-visible)"
  echo "    3. open -a Ollama and wait for :11434"
  echo "    4. ollama pull each model above"
  echo "    5. ollama create the derived models in modelfiles/"
  echo
  echo "  It would NOT raise the GPU cap — that needs sudo and is separate:"
  echo "    ./scripts/gpu-limit.sh ${HOST_WIRED_MB}"
  exit 0
fi

# ── 1. the cask ──────────────────────────────────────────────────────────
if [[ -d "/Applications/Ollama.app" ]]; then
  ok "Ollama.app present"
else
  command -v brew >/dev/null 2>&1 || die "Homebrew missing — run ./bootstrap.sh first"
  log "Installing Ollama from Brewfile.local-ai"
  brew bundle --file="$REPO_DIR/Brewfile.local-ai" || die "ollama-app install failed"
fi

# ── 2. environment ───────────────────────────────────────────────────────
# launchctl setenv, not an export: these must be visible to Ollama.app, which
# is launched by launchd and never sees your shell's environment.
# zsh/managed.zsh exports the same values for anything started from a shell.
log "Configuring Ollama environment (user-wide, via launchctl)"
set_ollama_env() {
  local key="$1" val="$2"
  if [[ "$(launchctl getenv "$key" 2>/dev/null)" != "$val" ]]; then
    launchctl setenv "$key" "$val" && printf "      %-26s %s\n" "$key" "$val"
  else
    printf "      %-26s %s (already)\n" "$key" "$val"
  fi
}

# Flash attention + a quantized KV cache: meaningfully smaller context memory.
# On a tight machine this is the difference between a model fitting and not.
set_ollama_env OLLAMA_FLASH_ATTENTION   1
set_ollama_env OLLAMA_KV_CACHE_TYPE     q8_0
# Unload after 3m idle so your editor and database get the RAM back. Reloading
# from page cache costs a couple of seconds; holding it costs gigabytes.
set_ollama_env OLLAMA_KEEP_ALIVE        3m
# The resident core (FIM + embed) plus one big model.
set_ollama_env OLLAMA_MAX_LOADED_MODELS 3
# One request at a time: higher values multiply KV cache per model.
set_ollama_env OLLAMA_NUM_PARALLEL      1
# Loopback only. Containers still reach it via host.docker.internal.
set_ollama_env OLLAMA_HOST              127.0.0.1:11434

# Keep weights off the internal disk if you want: OLLAMA_MODELS_DIR=/Volumes/...
# Tradeoff: model LOAD gets slower; inference is unaffected once resident.
if [[ -n "${OLLAMA_MODELS_DIR:-}" ]]; then
  set_ollama_env OLLAMA_MODELS "$OLLAMA_MODELS_DIR"
fi

# ── 3. start it ──────────────────────────────────────────────────────────
ollama_up() { curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; }

if ollama_up; then
  ok "Ollama already answering on :11434"
else
  # NOT `open -g`. Ollama's FIRST run shows an onboarding window and asks for
  # a password to install its CLI helper. Launched in the background that
  # window is invisible, nobody clicks it, and the API never binds — which
  # looks exactly like a crash. Bring it to the front.
  log "Launching Ollama"
  open -a Ollama || warn "couldn't launch Ollama.app"
  printf "    waiting for :11434"
  for i in $(seq 1 90); do
    ollama_up && break
    printf "."
    sleep 1
    if (( i == 20 )); then
      printf "\n"
      warn "Still waiting. If an Ollama window is open, click through it —"
      warn "first run asks permission to install the CLI helper."
      printf "    "
    fi
  done
  printf "\n"
fi

if ! ollama_up; then
  warn "Ollama API is not up on :11434."
  warn "  1. Open Ollama.app and finish any first-run prompts"
  warn "  2. Check:  curl -s http://127.0.0.1:11434/api/version"
  warn "  3. Re-run this script — it is idempotent and resumes here"
  die "Cannot pull models without the API."
fi

# ── 4. models ────────────────────────────────────────────────────────────
if (( PULL )); then
  log "Pulling models from $(basename "$MODELS_CONF")"
  "$REPO_DIR/scripts/pull-models.sh" "$MODELS_CONF" || warn "some pulls failed"
else
  warn "--no-pull: skipping model downloads"
fi

# ── 5. derived models ────────────────────────────────────────────────────
# Same weights, different context/temperature. Cheap: Ollama layers these over
# the existing blobs rather than copying gigabytes.
if [[ -z "${SKIP_MODELFILES:-}" ]] && compgen -G "$REPO_DIR/modelfiles/*.Modelfile" >/dev/null 2>&1; then
  log "Building derived models from modelfiles/"
  for mf in "$REPO_DIR"/modelfiles/*.Modelfile; do
    name="$(basename "$mf" .Modelfile)"

    if ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$name:latest"; then
      printf "  \033[2m· %s (present)\033[0m\n" "$name"; continue
    fi

    # CRITICAL: `ollama create` silently PULLS the base model if it is absent.
    # For a 70B that is a ~43GB download with no progress shown — it looks
    # hung. So only build when the FROM base is ALREADY local.
    base="$(awk 'tolower($1)=="from"{print $2; exit}' "$mf")"
    if [[ -n "$base" ]]; then
      want="$base"; case "$base" in *:*) ;; *) want="$base:latest" ;; esac
      if ! ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$want"; then
        printf "  ⊘ %s — needs base '%s' (not local)\n" "$name" "$base"
        printf "      build later:  ollama create %s -f modelfiles/%s\n" \
               "$name" "$(basename "$mf")"
        continue
      fi
    fi

    log "  creating $name (base $base)"
    # Not suppressed — if it does start pulling, you see it.
    ollama create "$name" -f "$mf" && ok "$name" || warn "  $name failed"
  done
fi

# ── done ─────────────────────────────────────────────────────────────────
echo
log "Done."
echo "  Next:"
echo "    ./scripts/ram.sh                  what is left for models"
echo "    ./scripts/bench.sh                real tok/s, per model"
echo "    ./scripts/model.sh status         what is loaded right now"
echo
echo "  The GPU cap is NOT set by this script — it needs sudo and resets on"
echo "  reboot. If a large model is spilling to CPU:"
echo "    ./scripts/gpu-limit.sh ${HOST_WIRED_MB}"
