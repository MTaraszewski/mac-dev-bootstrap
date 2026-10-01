# zsh/managed.zsh — sourced from ~/.zshrc via the managed block that
# scripts/setup-shell.sh appends.
#
# ONLY order-independent, idempotent things belong here: PATH entries and
# evals that are safe to run from anywhere in a .zshrc. Anything order-
# sensitive or personal (oh-my-zsh, ZSH_THEME, plugins=) stays in
# zshrc.template and stays YOUR decision — see the note at the bottom.
#
# Edit THIS file, not ~/.zshrc. Changes apply to the next shell.

# ── homebrew ─────────────────────────────────────────────────────────────
# Apple Silicon: /opt/homebrew. Intel: /usr/local. Check both so the file
# works on either machine.
if [ -x /opt/homebrew/bin/brew ]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
elif [ -x /usr/local/bin/brew ]; then
  eval "$(/usr/local/bin/brew shellenv)"
fi

# ── docker (orbstack / colima / docker desktop) ──────────────────────────
# OrbStack does NOT put its CLI on the default PATH, and the location has
# moved between versions: on a current install the binaries live ONLY in the
# app bundle (~/.orbstack/ has config/k8s/log/run/ssh and no bin/).
# Add whichever exists rather than betting on one path.
# Symptom when this is missing: "docker: command not found" while the VM runs.
for _d in "$HOME/.orbstack/bin" "/Applications/OrbStack.app/Contents/MacOS/xbin"; do
  [ -d "$_d" ] && export PATH="$_d:$PATH"
done
unset _d
[ -f "$HOME/.orbstack/shell/init.zsh" ] && source "$HOME/.orbstack/shell/init.zsh" 2>/dev/null

# ── uv (owns python: interpreters, venvs, tools) ─────────────────────────
# `uv tool install` puts shims in ~/.local/bin.
export PATH="$HOME/.local/bin:$PATH"

# ── nvm ──────────────────────────────────────────────────────────────────
# Note: sourcing nvm.sh costs ~100-300ms of shell startup. If that starts to
# annoy you, look at a lazy-loading wrapper rather than removing this.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# ── rust ─────────────────────────────────────────────────────────────────
[ -s "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"

# ── direnv ───────────────────────────────────────────────────────────────
# Must come AFTER the PATH edits above, so the hook sees the final PATH.
command -v direnv >/dev/null && eval "$(direnv hook zsh)"

# ── fzf ──────────────────────────────────────────────────────────────────
# Ctrl+R history search, Ctrl+T file search. Keybindings only — no config.
if command -v fzf >/dev/null; then
  if fzf --zsh >/dev/null 2>&1; then
    source <(fzf --zsh)                       # fzf 0.48+
  else
    [ -f "$HOME/.fzf.zsh" ] && source "$HOME/.fzf.zsh"
  fi
fi

# ── aliases ──────────────────────────────────────────────────────────────
# `assume` must be SOURCED, not executed: it exports AWS credentials into the
# current shell, and a subprocess cannot do that to its parent.
alias assume=". assume"          # common-fate/granted

# GNU coreutils are installed g-prefixed on purpose — adding their gnubin to
# PATH would shadow BSD sed/awk, which every script in this repo assumes.
# Reach for them explicitly: gsed, gsort, gfind, gdate.

# ─────────────────────────────────────────────────────────────────────────
# NOT here, on purpose — order-sensitive and personal, so bootstrap will not
# inject them. Copy from zsh/zshrc.template by hand:
#   export ZSH="$HOME/.oh-my-zsh"
#   ZSH_THEME="..."
#   plugins=(git python zsh-autosuggestions zsh-syntax-highlighting)
#   source "$ZSH/oh-my-zsh.sh"
# zsh-syntax-highlighting MUST be last in plugins= — it wraps the ZLE widgets
# that the plugins before it define.
