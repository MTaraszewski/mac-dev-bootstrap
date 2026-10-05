#!/usr/bin/env bash
# Bootstrap a Mac dev box. Idempotent: safe to re-run, resumes where it broke.
#
#   ./bootstrap.sh                      # everything
#   ./bootstrap.sh --list               # show the modules, run nothing
#   ./bootstrap.sh --only shell,runtimes
#   ./bootstrap.sh --skip orbstack,ide
#   ./bootstrap.sh --dry-run            # print what each module would do
#
# Escape hatches (env):
#   NO_LOG=1           don't tee to logs/
#   SKIP_TAP_TRUST=1   don't `brew trust` third-party taps
#   SKIP_ZSHRC=1       don't touch ~/.zshrc
#   SKIP_SURVEY=1      don't gate on the preflight survey
#   GIT_USER_NAME= GIT_USER_EMAIL=   set the git identity (otherwise untouched)
#   NODE_VERSION=24    nvm default
#   ORB_MEMORY_MIB=8192 ORB_CPU=6 ORB_K8S=1
#
# NO local models, no GPU tuning, no model weights. That is a separate repo.
set -euo pipefail

# Find the repo root by walking up for a marker, rather than assuming depth.
# Survives being moved or flattened.
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
cd "$REPO_DIR"

# ── console helpers ──────────────────────────────────────────────────────
# DEFINED BEFORE FIRST USE, and `log` deliberately so: on macOS `log` is also
# /usr/bin/log (Apple's system-log tool). Call it as a bare word before this
# function exists and the shell resolves the binary, giving you a cryptic
# "Unknown subcommand" usage dump instead of your message.
log()  { printf "\033[1;34m==>\033[0m %s\n" "$*"; }
step() { printf "\n\033[1;36m━━ %s\033[0m\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m!!!\033[0m %s\n" "$*"; }
die()  { printf "\033[1;31mERR\033[0m %s\n" "$*"; exit 1; }

# ── modules ──────────────────────────────────────────────────────────────
# Order matters: brew provides the tools the rest assume.
MODULES=(brew shell runtimes git orbstack ide iterm)
declare_desc() {
  case "$1" in
    brew)     echo "Homebrew + tap trust + everything in the Brewfile" ;;
    shell)    echo "oh-my-zsh, plugins, login shell, managed ~/.zshrc block" ;;
    runtimes) echo "uv (python), nvm (node), rustup (rust)" ;;
    git)      echo "git defaults + identity (only if GIT_USER_* is set)" ;;
    orbstack) echo "docker CLI + compose plugin, resource caps, k8s off" ;;
    ide)      echo "VSCodium/VS Code settings + extensions, telemetry off" ;;
    iterm)    echo "iTerm2 Dynamic Profile (declarative, read-only in the UI)" ;;
    local-ai) echo "Ollama + local model weights (tens of GB) — OPT-IN" ;;
    openai)   echo "ChatGPT desktop app + Codex CLI — OPT-IN" ;;
  esac
}

# Opt-in modules never run as part of a plain ./bootstrap.sh. They have to be
# named in --only. local-ai downloads tens of gigabytes and sets a user-wide
# launchd environment; that should never happen because someone ran the
# default command.
OPT_IN=(local-ai openai)

ONLY=""; SKIP=""; DRY=0
while (( $# )); do
  case "$1" in
    --list)
      printf "modules (in run order):\n"
      for m in "${MODULES[@]}"; do printf "  %-9s %s\n" "$m" "$(declare_desc "$m")"; done
      printf "\nopt-in (only via --only):\n"
      for m in "${OPT_IN[@]}"; do printf "  %-9s %s\n" "$m" "$(declare_desc "$m")"; done
      exit 0 ;;
    --only) ONLY="${2:-}"; shift ;;
    --only=*) ONLY="${1#*=}" ;;
    --skip) SKIP="${2:-}"; shift ;;
    --skip=*) SKIP="${1#*=}" ;;
    --dry-run|-n) DRY=1 ;;
    --help|-h) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown argument: $1  (try --help)" ;;
  esac
  shift
done

in_list() { # in_list needle csv
  case ",$2," in *",$1,"*) return 0 ;; esac
  return 1
}
is_opt_in() {
  local m
  for m in "${OPT_IN[@]}"; do [[ "$m" == "$1" ]] && return 0; done
  return 1
}
want() {
  # An opt-in module runs only when it is named explicitly in --only.
  if is_opt_in "$1"; then
    [[ -n "$ONLY" ]] && in_list "$1" "$ONLY" || return 1
  else
    [[ -n "$ONLY" ]] && { in_list "$1" "$ONLY" || return 1; }
  fi
  [[ -n "$SKIP" ]] && { in_list "$1" "$SKIP" && return 1; }
  return 0
}

# Validate the names before doing any work — a typo in --only would otherwise
# silently run nothing and look like success.
for given in $(printf '%s' "${ONLY},${SKIP}" | tr ',' ' '); do
  [[ -z "$given" ]] && continue
  found=0
  for m in "${MODULES[@]}" "${OPT_IN[@]}"; do [[ "$m" == "$given" ]] && found=1; done
  (( found )) || die "no such module: $given  (./bootstrap.sh --list)"
done

# ── logging ──────────────────────────────────────────────────────────────
# No 2>/dev/null here: if log.sh is missing or broken we want to KNOW, not
# silently run unlogged. But logging is a convenience, never a prerequisite —
# lift `set -e` around it so broken log plumbing cannot take the run down.
if [[ -f "$REPO_DIR/scripts/lib/log.sh" ]]; then
  set +e
  source "$REPO_DIR/scripts/lib/log.sh" && log_init bootstrap "$@"
  _log_rc=$?
  set -e
  (( _log_rc == 0 )) || warn "logging failed to initialise (rc=$_log_rc) — running unlogged"
else
  warn "scripts/lib/log.sh missing — running unlogged"
fi

echo "==> bootstrap starting (bash $BASH_VERSION)"
(( DRY )) && warn "DRY RUN — nothing will be installed or changed"

# ── sanity, before anything fancy ────────────────────────────────────────
# Bash version first: macOS ships bash 3.2.57 (2007) and everything here is
# written for it. Also check this BEFORE log_init redirects stderr into a file
# where you would never see the error.
[[ -n "${BASH_VERSION:-}" ]] || { echo "ERR: use ./bootstrap.sh, not 'sh bootstrap.sh'" >&2; exit 1; }
case "$BASH_VERSION" in [12].*) die "bash $BASH_VERSION is too old." ;; esac

# Never as root. Homebrew refuses outright, and everything else here writes to
# YOUR home — ~/.oh-my-zsh, ~/.nvm, ~/.local, ~/.cargo. Created as root, those
# are unusable without sudo forever after.
# Individual casks (orbstack, anything with a .pkg) prompt for a password when
# they genuinely need one. That is correct — let them ask.
if [[ "$(id -u)" -eq 0 ]]; then
  echo "ERR: don't run this as root or with sudo." >&2
  echo "     Homebrew refuses to run as root, and the rest writes to your home." >&2
  echo "     Run it as yourself:  ./bootstrap.sh" >&2
  echo "     Some casks will ask for a password on their own. Let them." >&2
  exit 1
fi

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
if [[ "$(uname -m)" != "arm64" ]]; then
  warn "Not arm64 ($(uname -m)). If this is an Apple Silicon Mac you are in a"
  warn "Rosetta shell — run: arch -arm64 zsh  — and start again."
  warn "On a genuine Intel Mac, Homebrew lives in /usr/local, not /opt/homebrew."
fi

log "$(sysctl -n machdep.cpu.brand_string 2>/dev/null), $(( $(sysctl -n hw.memsize) / 1073741824 ))GB RAM, macOS $(sw_vers -productVersion)"

# Xcode CLT: Homebrew cannot install without it, and the installer is a GUI
# prompt, so this must be dealt with by a human before we go further.
if ! xcode-select -p >/dev/null 2>&1; then
  warn "Xcode command line tools missing — Homebrew needs them."
  (( DRY )) || xcode-select --install || true
  die "Finish the CLT install dialog, then re-run ./bootstrap.sh"
fi

# ── preflight ────────────────────────────────────────────────────────────
if [[ -z "${SKIP_SURVEY:-}" && -x "$REPO_DIR/scripts/survey.sh" ]]; then
  if ! "$REPO_DIR/scripts/survey.sh" >/dev/null 2>&1; then
    warn "Preflight found blockers. Showing the survey:"
    "$REPO_DIR/scripts/survey.sh" || true
    die "Fix the blockers above, then re-run. (Override: SKIP_SURVEY=1)"
  fi
  ok "preflight clean"
fi

# The exec bit does not survive a browser download — only git clone preserves
# it. Fix our own scripts rather than dying halfway through.
chmod +x "$REPO_DIR"/scripts/*.sh 2>/dev/null || true

run_module() { # run_module <name> <script> [args...]
  local name="$1"; shift
  if ! want "$name"; then
    # Never announce an opt-in module that was not explicitly named — it was
    # never going to run, so "skipping" would read as though something was
    # wrong. Covers both a default run and `--only <the other opt-in module>`.
    is_opt_in "$name" && ! in_list "$name" "$ONLY" && return 0
    printf "  \033[2m· skipping %s\033[0m\n" "$name"
    return 0
  fi
  step "$name — $(declare_desc "$name")"
  if (( DRY )); then
    echo "  would run: $*"
    return 0
  fi
  "$@" || warn "$name incomplete — see above"
}

# ════════════════════════════════════════════════════════════════════════
# brew
# ════════════════════════════════════════════════════════════════════════
if want brew; then
  step "brew — $(declare_desc brew)"
  if ! command -v brew >/dev/null 2>&1; then
    if (( DRY )); then
      echo "  would install Homebrew"
    else
      log "Installing Homebrew"
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
  else
    ok "brew $(brew --version | head -1 | awk '{print $2}')"
  fi

  # Tap trust. Homebrew 5.1.15+ refuses to load formulae from third-party taps
  # until you explicitly trust them — a tap can run arbitrary code at install
  # time. It becomes the default in 6.0.0, so this is not optional for long.
  # Brewfile-level `trusted: true` only works on 5.1.16+ and has open bugs, so
  # we do it here. Only the taps THIS Brewfile declares.
  if [[ -z "${SKIP_TAP_TRUST:-}" ]] && command -v brew >/dev/null 2>&1 \
     && brew help trust >/dev/null 2>&1; then
    TAPS=$(awk '
      { sub(/#.*/, "") }
      /^[[:space:]]*tap[[:space:]]+"/ {
        if (match($0, /"[^"]+"/)) print substr($0, RSTART+1, RLENGTH-2)
      }' "$REPO_DIR/Brewfile")
    if [[ -n "$TAPS" ]]; then
      (( DRY )) && log "Would trust these third-party taps:" \
               || log "Trusting third-party taps declared in the Brewfile"
      for t in $TAPS; do
        echo "      $t"
        (( DRY )) && continue
        brew tap   "$t" >/dev/null 2>&1 || warn "  tap $t failed"
        brew trust "$t" >/dev/null 2>&1 || warn "  trust $t failed"
      done
    fi
  fi

  if (( DRY )); then
    echo "  would run: brew bundle --file=Brewfile"
    # NOT redirected to /dev/null: showing which packages are missing is the
    # entire reason to run a dry run. `check` exits non-zero when any are.
    command -v brew >/dev/null 2>&1 \
      && { brew bundle check --file="$REPO_DIR/Brewfile" --verbose || true; }
  else
    log "Installing toolchain from Brewfile"
    brew bundle --file="$REPO_DIR/Brewfile" || warn "brew bundle had failures — see above"
    # Machine-specific extras, never committed.
    if [[ -f "$REPO_DIR/Brewfile.local" ]]; then
      log "Installing Brewfile.local"
      brew bundle --file="$REPO_DIR/Brewfile.local" || warn "Brewfile.local had failures"
    fi
  fi
else
  printf "  \033[2m· skipping brew\033[0m\n"
fi

run_module shell    "$REPO_DIR/scripts/setup-shell.sh"
run_module runtimes "$REPO_DIR/scripts/setup-runtimes.sh"
run_module git      "$REPO_DIR/scripts/setup-git.sh"
run_module orbstack "$REPO_DIR/scripts/setup-orbstack.sh"
run_module ide      "$REPO_DIR/scripts/setup-ide.sh"
run_module iterm    "$REPO_DIR/scripts/setup-iterm.sh"
run_module local-ai "$REPO_DIR/scripts/setup-local-ai.sh"
run_module openai   "$REPO_DIR/scripts/setup-openai.sh"

step "done"
if (( DRY )); then
  echo "  Dry run. Nothing changed. Drop --dry-run to apply."
else
  # Only suggest steps that actually apply. An unconditional list ages badly:
  # it told you to merge the zshrc block on an `--only openai` run, long after
  # you had already done it, which trains people to ignore the summary.
  n=0
  _step() { n=$((n+1)); printf "  %d. %s\n" "$n" "$*"; }

  # A new shell only matters if something that touches PATH ran.
  if want shell || want runtimes || want orbstack; then
    _step "Open a NEW terminal  (nvm, uv, cargo, docker land on PATH there)"
  fi

  _step "./scripts/doctor.sh  — verify"

  # The theme/plugins merge is manual and one-time. Check whether it is still
  # outstanding rather than nagging forever: oh-my-zsh sourced, and the two
  # cloned plugins actually enabled in plugins=().
  if want shell; then
    _ZSHRC="$HOME/.zshrc"
    if ! grep -q "oh-my-zsh.sh" "$_ZSHRC" 2>/dev/null \
       || ! grep -q "zsh-syntax-highlighting" "$_ZSHRC" 2>/dev/null; then
      _step "Enable the plugins you just installed: copy the theme/plugins block from zsh/zshrc.template into ~/.zshrc"
      printf "     \033[2m(zsh-autosuggestions and zsh-syntax-highlighting are cloned but not in plugins=() yet)\033[0m\n"
    fi
  fi

  (( n )) || echo "  Nothing further. ./scripts/doctor.sh to verify."
fi
