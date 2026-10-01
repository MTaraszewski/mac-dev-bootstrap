#!/usr/bin/env bash
# survey.sh — inventory a Mac BEFORE installing anything.
#
# Deliberately zero-dependency: pure bash 3.2 + macOS built-ins. No brew, no
# jq. This must run on a machine where literally nothing is installed yet,
# and it must not change a single thing.
#
#   ./scripts/survey.sh              # human-readable report
#   ./scripts/survey.sh --json       # machine-readable
#   ./scripts/survey.sh --save       # write state/survey-<host>-<date>.json
#   ./scripts/survey.sh --diff       # what changed since the last snapshot?
#
# Exit codes:  0 = ready to bootstrap   1 = blockers found
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

MODE="human"
case "${1:-}" in
  --json) MODE="json" ;;
  --save) MODE="save" ;;
  --diff) MODE="diff" ;;
  --help|-h) sed -n '2,14p' "$0"; exit 0 ;;
esac

BLOCKERS=0
JSON_ITEMS=()

# ── tiny helpers ─────────────────────────────────────────────────────────
c_ok="\033[1;32m"; c_no="\033[1;31m"; c_wr="\033[1;33m"; c_in="\033[1;34m"; c_dim="\033[2m"; c_z="\033[0m"
say() { [[ "$MODE" == "human" ]] && printf "$@"; return 0; }
hdr() { say "\n${c_in}── %s${c_z}\n" "$1"; }

# jq-free JSON string escape
esc() { printf '%s' "${1:-}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/	/\\t/g'; }

# record a fact:  key, status(ok|missing|warn|info), value, note
rec() {
  local key="$1" status="$2" value="${3:-}" note="${4:-}"
  JSON_ITEMS+=("{\"key\":\"$(esc "$key")\",\"status\":\"$status\",\"value\":\"$(esc "$value")\",\"note\":\"$(esc "$note")\"}")
  case "$status" in
    ok)      say "  ${c_ok}✓${c_z} %-24s %s\n" "$key" "$value" ;;
    missing) say "  ${c_no}✗${c_z} %-24s %s\n" "$key" "${value:-not installed}${note:+  — $note}" ;;
    warn)    say "  ${c_wr}!${c_z} %-24s %s\n" "$key" "${value}${note:+  — $note}" ;;
    info)    say "  ${c_in}i${c_z} %-24s %s\n" "$key" "$value" ;;
  esac
}

# check a binary on PATH; prints its version if a version command is given
have() {
  local key="$1" bin="$2" vercmd="${3:-}"
  if command -v "$bin" >/dev/null 2>&1; then
    local v=""
    [[ -n "$vercmd" ]] && v="$(eval "$vercmd" 2>/dev/null | head -1 | tr -d '\r')"
    rec "$key" ok "${v:-$(command -v "$bin")}"
    return 0
  fi
  rec "$key" missing "" "${4:-}"
  return 1
}

# ── hardware & OS ────────────────────────────────────────────────────────
hdr "hardware"
CHIP="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"
ARCH="$(uname -m)"
RAM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
rec chip      info "$CHIP"
rec arch      "$([[ "$ARCH" == arm64 ]] && echo ok || echo warn)" "$ARCH" \
              "$([[ "$ARCH" == arm64 ]] || echo 'Rosetta shell? run: arch -arm64 zsh')"
rec ram_gb    info "${RAM_GB}GB"
rec cpu_cores info "$(sysctl -n hw.ncpu)"
rec macos     info "$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
DISK_FREE_GB=$(df -g / 2>/dev/null | awk 'NR==2{print $4}')
if [[ -n "${DISK_FREE_GB:-}" ]] && (( DISK_FREE_GB < 20 )); then
  rec disk_free warn "${DISK_FREE_GB}GB free" "brew + runtimes want ~15GB"
else
  rec disk_free ok "${DISK_FREE_GB:-?}GB free"
fi

# ── managed-machine reality check ────────────────────────────────────────
# On a company Mac these decide whether half of bootstrap.sh can even run.
# Read-only: no profile is installed, nothing is changed.
hdr "managed machine"
if /usr/bin/profiles status -type enrollment 2>/dev/null | grep -qi "MDM enrollment: Yes"; then
  rec mdm warn "enrolled (MDM)" "config profiles may override shell/git/app settings"
else
  rec mdm ok "not MDM-enrolled"
fi
if id -Gn 2>/dev/null | tr ' ' '\n' | grep -qx admin; then
  rec admin_rights ok "you are in the admin group"
else
  rec admin_rights warn "NOT an admin" "Homebrew install and casks with a .pkg will fail"
fi
rec filevault info "$(fdesetup status 2>/dev/null | head -1 || echo unknown)"

# A corporate proxy or TLS-inspecting middlebox breaks `brew`, `curl | sh`
# installers and `git clone` in ways whose error messages never say "proxy".
PROXY_SET=""
for v in HTTPS_PROXY https_proxy HTTP_PROXY http_proxy ALL_PROXY; do
  [[ -n "${!v:-}" ]] && PROXY_SET="$PROXY_SET $v"
done
if [[ -n "$PROXY_SET" ]]; then
  rec proxy_env warn "set:$PROXY_SET" "make sure NO_PROXY covers localhost"
else
  rec proxy_env ok "no proxy env vars"
fi
if scutil --proxy 2>/dev/null | grep -qE 'HTTPSEnable : 1|ProxyAutoConfigEnable : 1'; then
  rec proxy_system warn "system proxy / PAC active" "brew and curl installers may need HTTPS_PROXY"
else
  rec proxy_system ok "no system proxy"
fi

# ── prerequisites for bootstrap ──────────────────────────────────────────
hdr "prerequisites"
if xcode-select -p >/dev/null 2>&1; then
  rec xcode_clt ok "$(xcode-select -p)"
else
  rec xcode_clt missing "" "run: xcode-select --install  (Homebrew needs this)"
  BLOCKERS=$((BLOCKERS+1))
fi
rec shell info "$SHELL"
have git  git  "git --version"  >/dev/null
have curl curl "curl --version | head -1 | cut -d' ' -f1-2" >/dev/null

if command -v brew >/dev/null 2>&1; then
  rec homebrew ok "$(brew --version 2>/dev/null | head -1)"
  rec brew_prefix info "$(brew --prefix)"
  # Two brew installs (one per arch, or one from IT) is a genuinely bad time.
  for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$p" && "$p" != "$(command -v brew)" ]] \
      && rec brew_second warn "$p" "a second Homebrew — PATH decides which you get"
  done
else
  rec homebrew missing "" "bootstrap.sh installs it"
fi

# ── what the Brewfile asks for ───────────────────────────────────────────
hdr "Brewfile"
rec repo_root info "$REPO_DIR"
if [[ -f "$REPO_DIR/Brewfile" ]]; then
  NF_=$(awk '{sub(/#.*/,"")} /^[[:space:]]*brew[[:space:]]+"/ {n++} END{print n+0}' "$REPO_DIR/Brewfile")
  NC_=$(awk '{sub(/#.*/,"")} /^[[:space:]]*cask[[:space:]]+"/ {n++} END{print n+0}' "$REPO_DIR/Brewfile")
  NT_=$(awk '{sub(/#.*/,"")} /^[[:space:]]*tap[[:space:]]+"/  {n++} END{print n+0}' "$REPO_DIR/Brewfile")
  rec brewfile ok "$NF_ formulae, $NC_ casks, $NT_ taps"
  if command -v brew >/dev/null 2>&1; then
    if brew bundle check --file="$REPO_DIR/Brewfile" >/dev/null 2>&1; then
      rec brewfile_satisfied ok "all present"
    else
      rec brewfile_satisfied info "some missing" "bootstrap will install them"
    fi
  fi
  [[ -f "$REPO_DIR/Brewfile.local" ]] && rec brewfile_local info "present (gitignored)"
else
  rec brewfile missing "" "wrong directory?"
  BLOCKERS=$((BLOCKERS+1))
fi

# ── shell ────────────────────────────────────────────────────────────────
hdr "shell"
[[ -d "$HOME/.oh-my-zsh" ]] && rec omz ok "installed" || rec omz missing "" "setup-shell.sh"
ZC="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
for pl in zsh-autosuggestions zsh-syntax-highlighting; do
  [[ -d "$ZC/plugins/$pl" ]] && rec "zsh:$pl" ok "cloned" || rec "zsh:$pl" missing "" "setup-shell.sh"
done
if [[ -f "$HOME/.zshrc" ]]; then
  th="$(grep -m1 '^ZSH_THEME=' "$HOME/.zshrc" 2>/dev/null | cut -d'"' -f2)"
  if [[ -n "$th" ]]; then rec zshrc ok "theme=$th"
  else rec zshrc warn "exists, no ZSH_THEME" "merge zsh/zshrc.template by hand"; fi
  grep -qF ">>> mac-dev-bootstrap >>>" "$HOME/.zshrc" 2>/dev/null \
    && rec zshrc_managed ok "managed block present" \
    || rec zshrc_managed missing "" "setup-shell.sh adds it"
else
  rec zshrc missing "" "setup-shell.sh creates it"
fi
[[ -d "/Applications/iTerm.app" ]] && rec iterm2 ok "installed" || rec iterm2 missing "" "brew bundle"

# ── runtimes ─────────────────────────────────────────────────────────────
hdr "runtime managers"
if command -v uv >/dev/null 2>&1; then
  rec uv ok "$(uv --version 2>/dev/null)"
  # `uv python list` prints one row per alias/path, so the same interpreter
  # appears several times. Reduce to a sorted set of major.minor versions.
  vs="$(uv python list --only-installed 2>/dev/null \
        | awk '{print $1}' \
        | sed -E 's/^[a-z]+-([0-9]+\.[0-9]+)\..*/\1/' \
        | sort -u -t. -k1,1n -k2,2n | tr '\n' ' ')"
  rec "uv:pythons" info "${vs:-none installed}"
else
  rec uv missing "" "brew bundle"
fi
# pyenv/pipx should NOT be here — uv owns python. Flag them if present.
command -v pyenv >/dev/null 2>&1 && rec pyenv warn "$(pyenv --version 2>/dev/null)" "uv owns python now — pyenv will fight it"
command -v pipx  >/dev/null 2>&1 && rec pipx  warn "installed" "superseded by 'uv tool'"
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  rec nvm ok "$HOME/.nvm"
  rec "nvm:default" info "$(cat "$HOME/.nvm/alias/default" 2>/dev/null || echo unset)"
else
  rec nvm missing "" "setup-runtimes.sh"
fi
command -v rustc >/dev/null 2>&1 && rec rust ok "$(rustc --version 2>/dev/null)" || rec rust missing "" "setup-runtimes.sh"

# ── containers ───────────────────────────────────────────────────────────
hdr "containers"
DOCKER_SEEN=0
if command -v docker >/dev/null 2>&1; then
  rec docker ok "$(command -v docker)"; DOCKER_SEEN=1
  docker version >/dev/null 2>&1 \
    && rec docker_engine ok "$(docker version --format '{{.Server.Version}}' 2>/dev/null)" \
    || rec docker_engine warn "CLI present, engine not answering" "the VM is not running"
elif [[ -x "/Applications/OrbStack.app/Contents/MacOS/xbin/docker" ]]; then
  rec docker warn "installed, not on PATH" "zsh/managed.zsh adds it — open a new shell"; DOCKER_SEEN=1
else
  rec docker missing "" "brew bundle installs orbstack"
fi
# More than one runtime providing `docker` is a classic socket fight.
RUNTIMES=""
[[ -d /Applications/OrbStack.app ]]  && RUNTIMES="$RUNTIMES orbstack"
[[ -d /Applications/Docker.app ]]    && RUNTIMES="$RUNTIMES docker-desktop"
command -v colima >/dev/null 2>&1    && RUNTIMES="$RUNTIMES colima"
command -v podman >/dev/null 2>&1    && RUNTIMES="$RUNTIMES podman"
case "$(printf '%s' "$RUNTIMES" | wc -w | tr -d ' ')" in
  0) (( DOCKER_SEEN )) || rec runtimes info "none" ;;
  1) rec runtimes ok "${RUNTIMES# }" ;;
  *) rec runtimes warn "${RUNTIMES# }" "pick ONE — they fight over the docker socket" ;;
esac

# ── editors + AI tooling ─────────────────────────────────────────────────
hdr "editor"
IDE_FOUND=0
if [[ -d "/Applications/VSCodium.app" ]] || command -v codium >/dev/null 2>&1; then
  rec ide:vscodium ok "$(codium --version 2>/dev/null | head -1 || echo installed)"; IDE_FOUND=1
fi
if [[ -d "/Applications/Visual Studio Code.app" ]] || command -v code >/dev/null 2>&1; then
  rec ide:vscode info "$(code --version 2>/dev/null | head -1 || echo installed)" ; IDE_FOUND=1
  S="$HOME/Library/Application Support/Code/User/settings.json"
  if [[ -f "$S" ]] && grep -q '"telemetry.telemetryLevel"[[:space:]]*:[[:space:]]*"off"' "$S"; then
    rec ide:vscode_telemetry ok "telemetryLevel=off"
  else
    rec ide:vscode_telemetry warn "telemetry NOT disabled" "run scripts/setup-ide.sh"
  fi
fi
for app in Cursor Windsurf Zed; do
  [[ -d "/Applications/${app}.app" ]] && { rec "ide:${app}" info "installed"; IDE_FOUND=1; }
done
(( IDE_FOUND )) || rec ide:any missing "" "no editor at all — clean machine"

if command -v claude >/dev/null 2>&1; then
  rec claude ok "$(claude --version 2>/dev/null | head -1)"
  # Dedupe: a PATH with repeated entries makes `which -a` print the same
  # binary several times, which is not the problem we are looking for.
  _paths="$(which -a claude 2>/dev/null | sort -u)"
  if [[ "$(printf '%s\n' "$_paths" | wc -l | tr -d ' ')" -gt 1 ]]; then
    rec claude:installs warn "$(printf '%s' "$_paths" | tr '\n' ' ')" "more than one install — PATH decides, unpredictably"
  fi
else
  rec claude missing "" "brew bundle installs the cask"
fi

# ── verdict ──────────────────────────────────────────────────────────────
if [[ "$MODE" == "human" ]]; then
  echo
  if (( BLOCKERS == 0 )); then
    printf "${c_ok}Ready.${c_z} Nothing blocking — run ./bootstrap.sh\n"
    printf "Anything marked ${c_no}✗${c_z} above is expected on a clean Mac; bootstrap installs it.\n"
    printf "Anything marked ${c_wr}!${c_z} is worth reading before you start.\n"
  else
    printf "${c_no}%d blocker(s).${c_z} Fix the ✗ items that carry a note, then re-run.\n" "$BLOCKERS"
  fi
  echo
fi

# ── JSON emit ────────────────────────────────────────────────────────────
# Records hardware and installed tooling. Deliberately NOT your name, email,
# SSH keys or host aliases — this file is safe to keep, but state/ is
# gitignored anyway because it names the machine.
emit_json() {
  printf '{\n'
  printf '  "surveyed_at": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '  "host": "%s",\n' "$(esc "$(scutil --get LocalHostName 2>/dev/null || hostname)")"
  printf '  "chip": "%s",\n' "$(esc "$CHIP")"
  printf '  "ram_gb": %s,\n' "$RAM_GB"
  printf '  "macos": "%s",\n' "$(sw_vers -productVersion)"
  printf '  "blockers": %s,\n' "$BLOCKERS"
  printf '  "items": [\n'
  local n=${#JSON_ITEMS[@]} i=0 it
  for it in "${JSON_ITEMS[@]}"; do
    i=$((i+1))
    printf '    %s%s\n' "$it" "$([[ $i -lt $n ]] && echo ,)"
  done
  printf '  ]\n}\n'
}

# Compare this run against the most recent saved snapshot.
# awk, not jq — survey.sh must run on a machine with nothing installed.
diff_against_last() {
  local last
  last=$(ls -t "$REPO_DIR"/state/survey-*.json 2>/dev/null | head -1)
  if [[ -z "$last" ]]; then
    echo "No previous snapshot in state/. Run --save first."
    return 0
  fi
  printf "\n${c_in}── diff vs %s${c_z}\n" "$(basename "$last")"
  local tmp_now; tmp_now=$(mktemp)
  emit_json > "$tmp_now"

  extract() {
    awk '
      /"key":/ {
        k=""; st=""; v=""
        if (match($0, /"key":"[^"]*"/))    k  = substr($0, RSTART+7,  RLENGTH-8)
        if (match($0, /"status":"[^"]*"/)) st = substr($0, RSTART+10, RLENGTH-11)
        if (match($0, /"value":"[^"]*"/))  v  = substr($0, RSTART+9,  RLENGTH-10)
        if (k != "") printf "%s\t%s\t%s\n", k, st, v
      }
    ' "$1" | sort -u
  }
  local a b; a=$(mktemp); b=$(mktemp)
  extract "$last" > "$a"; extract "$tmp_now" > "$b"

  local changes=0 k st v old ost ov
  while IFS=$'\t' read -r k st v; do
    old=$(awk -F'\t' -v key="$k" '$1==key {print $2"\t"$3; exit}' "$a")
    if [[ -z "$old" ]]; then
      printf "  ${c_ok}+${c_z} %-26s %s\n" "$k" "${v:-$st}"; changes=$((changes+1))
    else
      ost="${old%%$'\t'*}"; ov="${old#*$'\t'}"
      if [[ "$ost" != "$st" || "$ov" != "$v" ]]; then
        printf "  ${c_wr}~${c_z} %-26s %s ${c_dim}→${c_z} %s\n" "$k" "${ov:-$ost}" "${v:-$st}"
        changes=$((changes+1))
      fi
    fi
  done < "$b"
  while IFS=$'\t' read -r k st v; do
    awk -F'\t' -v key="$k" '$1==key {found=1} END {exit !found}' "$b" || {
      printf "  ${c_no}-${c_z} %-26s %s\n" "$k" "${v:-$st}"; changes=$((changes+1)); }
  done < "$a"
  (( changes )) || printf "  ${c_dim}no changes${c_z}\n"
  rm -f "$tmp_now" "$a" "$b"
}

case "$MODE" in
  json) emit_json ;;
  save)
    mkdir -p "$REPO_DIR/state"
    OUT="$REPO_DIR/state/survey-$(scutil --get LocalHostName 2>/dev/null || hostname)-$(date +%Y%m%d-%H%M%S).json"
    emit_json > "$OUT"
    echo "wrote $OUT"
    ;;
  diff) diff_against_last ;;
esac

exit $(( BLOCKERS > 0 ))
