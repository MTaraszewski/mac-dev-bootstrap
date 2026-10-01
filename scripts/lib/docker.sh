#!/usr/bin/env bash
# lib/docker.sh — find docker, make `docker compose` work. Source it, don't run it.
#
#   source "$REPO_DIR/scripts/lib/docker.sh"
#   ensure_docker  || exit 1      # puts docker on PATH, verifies the ENGINE
#   ensure_compose || exit 1      # links the plugin, sets $COMPOSE
#   "${COMPOSE[@]}" up -d
#
# Why this exists — three separate traps, each of which cost real time:
#
# 1. OrbStack does NOT put its CLI on the default PATH. Verified layout:
#      ~/.orbstack/            -> config k8s log run ssh   (NO bin/)
#      /Applications/OrbStack.app/Contents/MacOS/xbin/ -> docker, docker-compose, ...
#    The CLI lives ONLY in the app bundle. Do not guess ~/.orbstack/bin.
#
# 2. A CLI on disk proves nothing. `docker version` talks to the daemon;
#    `command -v docker` only proves a file exists. Install != initialise.
#
# 3. `docker compose` is resolved as a PLUGIN from ~/.docker/cli-plugins/.
#    OrbStack ships docker-compose as a STANDALONE binary. Unlinked, you get:
#        unknown shorthand flag: 'd' in -d
#    which reads like a flag bug but means docker never recognised `compose`
#    and tried to parse -d as a global flag.

# Every place a docker binary might live, in preference order.
_DOCKER_CANDIDATES=(
  "$HOME/.orbstack/bin/docker"
  "/Applications/OrbStack.app/Contents/MacOS/xbin/docker"
  "/usr/local/bin/docker"
  "/opt/homebrew/bin/docker"
  "$HOME/.docker/bin/docker"
  "/Applications/Docker.app/Contents/Resources/bin/docker"
)

# Echo the path to a docker binary, or return 1.
find_docker() {
  if command -v docker >/dev/null 2>&1; then command -v docker; return 0; fi
  local c
  for c in "${_DOCKER_CANDIDATES[@]}"; do
    [[ -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Put docker on PATH and confirm the engine answers.
#   $1 = "quiet" to suppress the launch attempt (for read-only checks)
ensure_docker() {
  local quiet="${1:-}"
  local bin
  bin="$(find_docker)" || {
    if [[ -d "/Applications/OrbStack.app" ]]; then
      echo "OrbStack.app is installed but has no CLI — its setup never finished." >&2
      echo "  open -a OrbStack, click through, enter your admin password." >&2
    else
      echo "No docker found. brew install --cask orbstack" >&2
    fi
    return 1
  }
  export DOCKER_BIN="$bin"
  export PATH="$(dirname "$bin"):$PATH"

  docker version >/dev/null 2>&1 && return 0
  [[ "$quiet" == "quiet" ]] && return 1

  # CLI present, engine down: start it.
  echo "  engine not answering — launching OrbStack" >&2
  open -a OrbStack 2>/dev/null || return 1
  local i
  for i in $(seq 1 60); do
    docker version >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "  engine still down after 60s. Open OrbStack and finish its setup." >&2
  return 1
}

# Link the compose plugin if needed; set $COMPOSE to a runnable array.
ensure_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose); export COMPOSE; return 0
  fi

  # Find the standalone binary and link it where the docker CLI looks.
  local standalone=""
  standalone="$(command -v docker-compose 2>/dev/null || true)"
  if [[ -z "$standalone" && -n "${DOCKER_BIN:-}" ]]; then
    [[ -x "$(dirname "$DOCKER_BIN")/docker-compose" ]] \
      && standalone="$(dirname "$DOCKER_BIN")/docker-compose"
  fi
  if [[ -z "$standalone" ]]; then
    for c in "/Applications/OrbStack.app/Contents/MacOS/xbin/docker-compose" \
             "$HOME/.orbstack/bin/docker-compose"; do
      [[ -x "$c" ]] && { standalone="$c"; break; }
    done
  fi

  if [[ -n "$standalone" ]]; then
    mkdir -p "$HOME/.docker/cli-plugins"
    ln -sf "$standalone" "$HOME/.docker/cli-plugins/docker-compose"
    if docker compose version >/dev/null 2>&1; then
      COMPOSE=(docker compose); export COMPOSE; return 0
    fi
    # Plugin link didn't take — the standalone still works directly.
    COMPOSE=("$standalone"); export COMPOSE; return 0
  fi

  echo "No compose: neither the plugin nor a standalone binary was found." >&2
  return 1
}
