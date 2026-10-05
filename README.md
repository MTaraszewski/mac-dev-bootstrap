# mac-dev-bootstrap

Reproducible setup for a macOS development machine. Idempotent — safe to re-run.

Local models (Ollama) and the OpenAI tools (ChatGPT app, Codex) are **opt-in
modules** — `./bootstrap.sh` alone installs neither.
See [opt-in modules](#opt-in-modules).

```sh
./scripts/survey.sh          # read-only: what's here, what will block
./bootstrap.sh --dry-run     # read-only: what would happen
./bootstrap.sh               # do it
# open a NEW terminal
./scripts/doctor.sh          # verify
```

---

## What gets installed

**Formulae** (20)

```
git  gh  jq  tree  wget  httpie  htop  watch  make  direnv
ripgrep  fzf  coreutils  gnu-sed  uv  php
hashicorp/tap/terraform  terraformer  sops  common-fate/granted/granted
```

**Casks** (6) — `iterm2` `font-fira-code` `orbstack` `aws-vault-binary` `claude-code` `vscodium`

**Taps** (2) — `common-fate/granted` `hashicorp/tap` (each gets `brew trust`)

**Runtimes** — not brew, installed by `setup-runtimes.sh`:

| | |
|---|---|
| Python | `uv` + interpreters **3.11, 3.12, 3.13** (`UV_PYTHONS=` to change) |
| Node | `nvm` cloned to `~/.nvm` + Node **24** as default (`NODE_VERSION=`) |
| Rust | `rustup` |
| npm globals | `corepack` only — npm globals vanish on `nvm use` |

**Shell** — oh-my-zsh, `zsh-autosuggestions`, `zsh-syntax-highlighting`, `chsh -s /bin/zsh`

**Editor extensions** (23, into VSCodium and/or VS Code — whichever is present):

```
anthropic.claude-code
ms-python.python  ms-python.debugpy  charliermarsh.ruff
njpwerner.autodocstring  kevinrose.vsc-python-indent
ms-toolsai.jupyter  ms-toolsai.jupyter-keymap  ms-toolsai.jupyter-renderers
dbaeumer.vscode-eslint  esbenp.prettier-vscode  rust-lang.rust-analyzer
hashicorp.terraform  github.vscode-github-actions  ms-azuretools.vscode-containers
mtxr.sqltools  mtxr.sqltools-driver-pg  eamodio.gitlens
yzhang.markdown-all-in-one  davidanson.vscode-markdownlint
redhat.vscode-yaml  tamasfe.even-better-toml  PKief.material-icon-theme
```

Commented out and ready in the Brewfile: `bat` `fd` `eza` `mongosh` `rabbitmq`
`tcptraceroute` `openvpn` `rectangle` `postman` `opentofu` `awscli`.
Machine-specific extras go in `Brewfile.local` (gitignored, installed
automatically).

---

## Modules

`./bootstrap.sh --list` · `--only shell,runtimes` · `--skip iterm`

| module | does |
|---|---|
| `brew` | Homebrew, tap trust, the Brewfile, then `Brewfile.local` |
| `shell` | oh-my-zsh + plugins, `chsh`, one managed block in `~/.zshrc` |
| `runtimes` | uv, nvm + Node, rustup |
| `git` | global defaults — only keys you haven't set yourself |
| `orbstack` | resource caps, k8s off, `docker` on PATH, compose plugin linked |
| `ide` | `settings.json` + extensions, telemetry off |
| `iterm` | symlinks the `dev` Dynamic Profile |

Env opt-outs: `NO_LOG` `SKIP_SURVEY` `SKIP_TAP_TRUST` `SKIP_ZSHRC`
`UV_PYTHONS` `NODE_VERSION` `ORB_MEMORY_MIB` `ORB_CPU` `ORB_K8S`
`GIT_USER_NAME` `GIT_USER_EMAIL`.

---

## Opt-in modules

Never run by a plain `./bootstrap.sh` — they only run when named in `--only`,
and the default run doesn't even mention them.

| module | installs |
|---|---|
| `local-ai` | Ollama + model weights, GPU/memory tooling — tens of GB |
| `openai` | ChatGPT desktop app + Codex CLI |

```sh
./bootstrap.sh --only openai           # or: ./scripts/setup-openai.sh
./bootstrap.sh --only local-ai
```

### openai

`cask "chatgpt"` + `cask "codex"` from `Brewfile.openai`. Codex is a cask
rather than `npm i -g @openai/codex` for the same reason as `claude-code`: an
npm global lives inside the active nvm version's directory, so `nvm use 22`
makes the command vanish.

Authentication is interactive and the script deliberately sets no key — run
`codex` and follow the prompt (ChatGPT account, or `OPENAI_API_KEY` for
per-token billing). If you use a key, put it in a per-project `.envrc` so
`direnv` loads it on `cd` and unloads it on the way out.

This sits alongside `claude-code` from the default run; they don't conflict.

### local-ai

Downloads tens of GB and sets a user-wide launchd environment — neither
should happen because someone ran the default command. It only runs when
named:

```sh
./scripts/setup-local-ai.sh --plan     # print the plan, change nothing
./bootstrap.sh --only local-ai         # install Ollama, tune, pull models
./scripts/setup-local-ai.sh --no-pull  # install + tune, skip the weights
```

Installs `ollama-app` (from `Brewfile.local-ai`, kept separate so the main
Brewfile stays model-free), sets six `OLLAMA_*` vars via `launchctl`, pulls a
model manifest, and builds the derived models in `modelfiles/`.

Which manifest is picked from RAM, by `lib/host.sh`: `models.conf` (~10GB,
fits 24GB) or `models.big.conf` (~48GB, machines with 48GB+ RAM). Override with
`MODELS_CONF=`.

| script | |
|---|---|
| `ram.sh` | Where memory went and what's left for a model |
| `gpu-limit.sh` | Raise the GPU wired limit. Needs sudo, **resets on reboot** |
| `model.sh` | `status` · `code` · `reason` · `agent` · `free` — swap the big slot |
| `model-add.sh` | Pull a model, but check it exists and fits first |
| `bench.sh` | Real tok/s per model |
| `pull-models.sh` | Pull a manifest |

Two things that decide whether this works at all, both handled here:
**context is RAM** (the KV cache is ~100KB/token on top of the weights), and
**Ollama silently truncates** past `num_ctx` instead of erroring — which makes
an agent loop and look stupid. `modelfiles/agent.Modelfile` is the fix.

Decode is bandwidth-bound: tok/s ≈ memory bandwidth ÷ model size. A big model
cannot be fast, however you configure it.

---

## What it changes outside the repo

```
~/.zshrc                    one sentinel-delimited block (+ .bak.<epoch>)
~/.oh-my-zsh/               framework + 2 plugins
~/.nvm/ ~/.cargo/ ~/.local/ runtimes, uv tool shims
~/.docker/cli-plugins/      docker-compose symlink
/opt/homebrew               the Brewfile
login shell                 chsh -s /bin/zsh
.../{VSCodium,Code}/User/settings.json       (+ .bak.<epoch>)
.../iTerm2/DynamicProfiles/                  symlink into this repo
git --global                only keys you had not already set
```

**No credentials, anywhere.** Nothing reads or writes `~/.ssh`, `~/.aws`,
`~/.netrc`, `~/.pgpass`, `~/.gnupg`. No identity is committed — git name and
email come from `GIT_USER_NAME` / `GIT_USER_EMAIL` at run time. `logs/` and
`state/` are gitignored.

Your `~/.zshrc` is never rewritten, only the block between the markers; the
theme and `plugins=()` are deliberately left to you (`zsh/zshrc.template`).

---

## Customising

| | |
|---|---|
| packages | `Brewfile`, or `Brewfile.local` |
| PATH, hooks, aliases | `zsh/managed.zsh` — next shell, no re-run |
| prompt, theme, plugins | your `~/.zshrc`, from `zsh/zshrc.template` |
| editor | `ide/settings.json`, `ide/extensions.txt` → `./scripts/setup-ide.sh` |
| terminal | `iterm/DynamicProfiles/mac-dev-bootstrap.json` — read live, no restart |

---

## Troubleshooting

| symptom | cause |
|---|---|
| `docker: command not found` | OrbStack isn't on the default PATH. `managed.zsh` adds it — new shell. |
| `unknown shorthand flag: 'd' in -d` | compose is a plugin; OrbStack ships it standalone. `setup-orbstack.sh` links it. |
| `node: command not found` | no managed block in `~/.zshrc`, or no new shell yet. |
| highlighting half-works | `zsh-syntax-highlighting` isn't **last** in `plugins=()`. |
| extension "installs" but is absent | Marketplace-only, so unavailable on VSCodium. |

`./scripts/doctor.sh` prints the fix next to each failure.
`./scripts/logs.sh` (`fails`, `last`, `tail`) is the run ledger.
