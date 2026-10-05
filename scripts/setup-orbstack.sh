#!/usr/bin/env bash
# setup-orbstack.sh — make `docker` and `docker compose` actually work, and
# cap what the VM is allowed to take.
#
#   ./scripts/setup-orbstack.sh
#   ORB_MEMORY_MIB=8192 ORB_CPU=6 ORB_K8S=1 ./scripts/setup-orbstack.sh
#
# Only this script is OrbStack-specific — lib/docker.sh finds a docker binary
# from colima or podman too, if you ever swap.
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

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init setup-orbstack "$@"

if [[ ! -d "/Applications/OrbStack.app" ]]; then
  warn "OrbStack not installed — the Brewfile should have installed it."
  warn "  Install it:  brew install --cask orbstack"
  warn "  Then re-run: ./bootstrap.sh --only orbstack"
  exit 0
fi

source "$REPO_DIR/scripts/lib/docker.sh"

# `orb` is not on PATH until OrbStack has run once and linked its helpers.
if ! command -v orb >/dev/null 2>&1; then
  log "Launching OrbStack once to link its CLI"
  open -a OrbStack || warn "couldn't launch OrbStack"
  for _ in $(seq 1 45); do
    command -v orb >/dev/null 2>&1 && break
    for d in "$HOME/.orbstack/bin" "/Applications/OrbStack.app/Contents/MacOS/xbin"; do
      [[ -x "$d/orb" ]] && { export PATH="$d:$PATH"; break 2; }
    done
    sleep 1
  done
fi

if command -v orb >/dev/null 2>&1; then
  # The limit is a CEILING, not a reservation — OrbStack allocates on demand
  # and returns unused memory to macOS. Capping is insurance against a runaway
  # container, not a performance setting.
  log "Capping OrbStack at ${ORB_MEMORY_MIB:-8192} MiB / ${ORB_CPU:-6} CPU"
  orb config set memory_mib "${ORB_MEMORY_MIB:-8192}" 2>/dev/null \
    || warn "orb config set memory_mib failed — cap NOT applied"
  orb config set cpu "${ORB_CPU:-6}" 2>/dev/null || true

  # OrbStack ships with Kubernetes enabled. A k8s control plane you are not
  # using is pure overhead. Off unless asked:  ORB_K8S=1
  if [[ -z "${ORB_K8S:-}" ]]; then
    if [[ "$(orb config get k8s.enable 2>/dev/null)" == "true" ]]; then
      log "Disabling OrbStack Kubernetes (unused, costs RAM)"
      orb config set k8s.enable false 2>/dev/null || warn "couldn't disable k8s"
    fi
  fi
  for k in memory_mib cpu k8s.enable; do
    printf "      %-14s %s\n" "$k" "$(orb config get "$k" 2>/dev/null)"
  done
else
  warn "orb CLI unavailable — resource cap NOT applied."
  warn "  Launch OrbStack.app, finish its setup, then re-run this script."
fi

# ── docker CLI + compose plugin ──────────────────────────────────────────
# The part that is easy to get wrong. See lib/docker.sh for the three traps:
# the CLI is not on PATH, a CLI on disk does not mean a running engine, and
# `docker compose` is a PLUGIN that OrbStack ships as a standalone binary.
log "Wiring up docker"
if ensure_docker; then
  ok "docker: $DOCKER_BIN"
  ok "engine: $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
  if ensure_compose; then
    ok "compose: $(docker compose version --short 2>/dev/null || echo "${COMPOSE[*]}")"
    [[ -L "$HOME/.docker/cli-plugins/docker-compose" ]] \
      && ok "linked ~/.docker/cli-plugins/docker-compose"
  else
    warn "compose unavailable"
  fi
  # PATH persistence is setup-shell.sh's job: the managed block sources
  # zsh/managed.zsh, which finds the docker directory itself. Nothing to nag about.
else
  warn "docker unavailable — open OrbStack.app and finish its setup."
fi
