# Reproducible toolchain:  brew bundle --file=Brewfile
#
# Scope: a general-purpose Mac dev box. NO local-model stack — that lives in
# a separate repo. Nothing here downloads GBs of weights or touches the GPU.
#
# POLICY, so re-adding is deliberate rather than accidental:
#   * one tool per job (no pyenv AND uv, no docker-desktop AND orbstack)
#   * nothing EOL
#   * no personal/desktop apps — a work Mac usually has those managed for you
#   * optional things are COMMENTED, with a note on when to want them
#
# Machine-specific extras go in Brewfile.local (gitignored, auto-installed).

# ── taps ─────────────────────────────────────────────────────────────────
# Homebrew 5.1.15+ refuses to load formulae from third-party taps until you
# explicitly trust them — a tap can run arbitrary code at install time.
# bootstrap.sh runs `brew tap` + `brew trust` on each of these first.
# Manually:  brew trust common-fate/granted hashicorp/tap
#
# Fewer taps = less to trust. Drop hashicorp/tap entirely by switching to
# OpenTofu (same CLI, MPL-2.0, lives in homebrew/core) — see below.
tap "common-fate/granted"
tap "hashicorp/tap"

# ═════════════════════════════════════════════════════════════════════════
# CORE CLI + SHELL
# ═════════════════════════════════════════════════════════════════════════
brew "git"               # newer than the Xcode CLT git
brew "gh"                # GitHub CLI — auth, PRs, and `gh repo create`
brew "jq"
brew "tree"
brew "wget"
brew "httpie"
brew "htop"
brew "watch"
brew "make"              # macOS ships GNU make 3.81 (2006); this is 4.x
brew "direnv"            # per-directory env; hooked into zsh by zsh/managed.zsh
brew "ripgrep"           # rg — what every editor's "find in files" uses
brew "fzf"

# GNU userland, installed WITHOUT shadowing BSD tools: brew keeps these
# g-prefixed (gsed, gsort, gfind) unless you add their gnubin to PATH.
# Do NOT add gnubin — scripts in this repo are written for BSD sed/awk.
brew "coreutils"
brew "gnu-sed"

cask "iterm2"
cask "font-fira-code"

# ═════════════════════════════════════════════════════════════════════════
# LANGUAGE RUNTIMES
# ═════════════════════════════════════════════════════════════════════════
# uv owns Python — interpreters, venvs, and standalone tools. No pyenv, no
# pipx, no brew python@3.x fighting over PATH.
#   uv python install 3.12     (interpreters — prebuilt, seconds not minutes)
#   uv venv / uv sync          (per-project envs; replaces virtualenv+poetry)
#   uv tool install <cli>      (replaces pipx)
# macOS ships /usr/bin/python3 = 3.9.x — leave it alone, macOS depends on it.
brew "uv"

# nvm owns node, installed by scripts/setup-runtimes.sh (it is a shell
# function, not a binary, so it is deliberately NOT a brew formula).
# No `brew "node"` either — it would shadow nvm depending on the caller.

# rust comes from rustup, also in setup-runtimes.sh.

brew "php"               # drop if you do not write PHP

# ═════════════════════════════════════════════════════════════════════════
# CONTAINERS
# ═════════════════════════════════════════════════════════════════════════
# OrbStack: lighter and faster than Docker Desktop on Apple Silicon, and free
# for personal use.
#
# ONE runtime only. docker-desktop + orbstack + podman all provide `docker`
# and fight over the socket. (If you ever do swap, scripts/lib/docker.sh finds
# a docker binary from colima or podman too — only setup-orbstack.sh is
# OrbStack-specific.)
cask "orbstack"

# ═════════════════════════════════════════════════════════════════════════
# CLOUD / INFRA
# ═════════════════════════════════════════════════════════════════════════
# Check what IT already provides before installing these — a second copy of
# the AWS tooling on a managed Mac is a real source of confusion.
brew "hashicorp/tap/terraform"
# brew "opentofu"        # MPL-2.0 fork, no tap needed. Then drop hashicorp/tap.
brew "terraformer"
brew "sops"
brew "common-fate/granted/granted"   # `assume` — aliased in zsh/managed.zsh
cask "aws-vault-binary"              # NOT `aws-vault`; that name is a
                                     # deprecated alias and brew warns loudly
# brew "awscli"          # uncomment if you are not getting it from IT

# ═════════════════════════════════════════════════════════════════════════
# AI CODING TOOLS  (cloud-based; no local models, no GPU, no weights)
# ═════════════════════════════════════════════════════════════════════════
# ⚠ POLICY: running any AI coding tool against company code usually needs
#   sign-off. Worth knowing for that conversation: Claude Code sends the code
#   it is asked about to Anthropic's API — it is NOT local. Comment both of
#   these out until you have the go-ahead.
#
# NOT via npm: an npm-installed `claude` lives inside nvm's version directory,
# so `nvm use 20` makes it vanish. The cask is independent of node.
# Tradeoff: casks do not auto-update — `brew upgrade claude-code` now and then.
cask "claude-code"

# Editor. VSCodium is the MIT VS Code source built without Microsoft's
# telemetry endpoints (which are injected at BUILD time, so the official
# binary cannot be had clean).
# Cost of VSCodium: Open VSX only — no Pylance, no Copilot, no MS Remote-SSH.
# On a work Mac, VS Code is often already managed/installed; in that case
# comment this out and let scripts/setup-ide.sh configure the official build
# instead (it detects whichever is present and turns telemetry off).
cask "vscodium"

# ═════════════════════════════════════════════════════════════════════════
# OPTIONAL — uncomment what you actually use
# ═════════════════════════════════════════════════════════════════════════
# brew "bat"             # cat with syntax highlighting
# brew "fd"              # friendlier find
# brew "eza"             # ls with git status
# brew "mongosh"         # needs: tap "mongodb/brew"
# brew "rabbitmq"
# brew "tcptraceroute"
# brew "openvpn"         # usually a managed client on a work Mac
# cask "rectangle"       # window manager
# cask "postman"
#
# Deliberately absent: native postgres/mysql clients (run them in containers),
# docker-desktop, podman, pyenv, pipx, poetry-via-brew, nvm-via-brew.
