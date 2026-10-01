# mac-dev-bootstrap

Reproducible setup for a macOS development machine. Clone it, run one script,
get a working toolchain. Re-run it any time — it is idempotent, and it resumes
rather than restarting.

Built to be safe on a **company-managed Mac**: it never touches credentials,
never commits an identity, and every step says what it changes before it
changes it.

**What it is not:** a local-model / GPU stack. No Ollama, no model weights, no
`iogpu.wired_limit_mb`. That belongs in its own repo.

---

## Quick start

```sh
git clone <this repo> ~/mac-dev-bootstrap
cd ~/mac-dev-bootstrap

./scripts/survey.sh          # read-only: what is on this Mac, what will block
./bootstrap.sh --dry-run     # read-only: what would happen
./bootstrap.sh               # do it
# open a NEW terminal
./scripts/doctor.sh          # does it work?
```

`survey.sh` has no dependencies at all — pure bash 3.2 and macOS built-ins —
so it runs on a Mac where nothing is installed yet. Start there.

### Running less than everything

```sh
./bootstrap.sh --list                  # the modules
./bootstrap.sh --only shell,runtimes   # just those
./bootstrap.sh --skip orbstack,ide     # everything else
```

| module | what it does |
|--------|--------------|
| `brew` | Homebrew, `brew trust` on the declared taps, the whole Brewfile, then `Brewfile.local` if present |
| `shell` | oh-my-zsh, `zsh-autosuggestions`, `zsh-syntax-highlighting`, `chsh -s /bin/zsh`, one managed block in `~/.zshrc` |
| `runtimes` | `uv` (Python interpreters + tools), `nvm` + Node LTS, `rustup`, `corepack` |
| `git` | safe global defaults — only where you have not set a value yourself |
| `orbstack` | resource caps, Kubernetes off, `docker` on PATH, `docker compose` plugin linked |
| `ide` | `settings.json` + extensions for whichever of VSCodium / VS Code is installed, telemetry off |
| `iterm` | symlinks the `dev` Dynamic Profile into iTerm2 |

Environment escape hatches: `NO_LOG=1`, `SKIP_SURVEY=1`, `SKIP_TAP_TRUST=1`,
`SKIP_ZSHRC=1`, `NODE_VERSION=`, `UV_PYTHONS=`, `ORB_MEMORY_MIB=`, `ORB_CPU=`,
`ORB_K8S=1`, `GIT_USER_NAME=`, `GIT_USER_EMAIL=`.

---

## Exactly what it changes

Outside the repo, nothing else:

```
~/.zshrc                    one sentinel-delimited block appended (+ .bak.<epoch>)
~/.oh-my-zsh/               framework + 2 cloned plugins
~/.nvm/ ~/.cargo/ ~/.local/ runtimes and uv tool shims
~/.docker/cli-plugins/      docker-compose symlink
login shell                 chsh -s /bin/zsh
/opt/homebrew               everything in the Brewfile
~/Library/Application Support/{VSCodium,Code}/User/settings.json   (+ .bak.<epoch>)
~/Library/Application Support/iTerm2/DynamicProfiles/mac-dev-bootstrap.json  symlink
git --global                only keys you had not already set
```

Three promises the scripts actually keep:

- **Your `~/.zshrc` is never rewritten.** One block between `# >>> mac-dev-bootstrap >>>`
  markers is added or replaced; everything else is left alone, and a timestamped
  backup is made first. The order-sensitive, personal part — `ZSH_THEME`,
  `plugins=()` — is deliberately *not* injected. Copy it from
  [`zsh/zshrc.template`](zsh/zshrc.template) yourself.
- **Your git config is never overwritten.** `setup-git.sh` guards every write
  with a `--get` check and prints `(yours — leaving it)` when you already
  decided.
- **No credentials, anywhere.** Nothing reads or writes `~/.ssh`, `~/.aws`,
  `~/.netrc`, `~/.pgpass`, `~/.gnupg`. No identity is committed: name and email
  come from `GIT_USER_NAME` / `GIT_USER_EMAIL` at run time, or not at all.
  `logs/` and `state/` are gitignored because they name the machine.

---

## On a company-managed Mac

Clear these before you run anything:

- **OrbStack needs a paid licence for commercial use** beyond a small-company
  exemption. Free alternatives with the same `docker` CLI: `colima`, `podman` —
  [`scripts/lib/docker.sh`](scripts/lib/docker.sh) finds a docker binary from any
  of them, so only `setup-orbstack.sh` is OrbStack-specific.
- **AI coding tools on company code usually need sign-off.** `claude-code` is in
  the Brewfile and `anthropic.claude-code` in the extension list. Both are
  cloud-based — code they are asked about goes to Anthropic's API. Comment them
  out until you have the go-ahead.
- **Homebrew needs admin rights** for its first install, and some fleets manage
  brew centrally. A second Homebrew is a genuinely bad time; `survey.sh` checks
  for one.
- **A proxy or TLS-inspecting middlebox** breaks `brew`, `curl | sh` installers
  and `git clone` with errors that never mention a proxy. `survey.sh` reports
  proxy env vars and system/PAC settings.
- **MDM config profiles can override** your shell, git and app settings after
  the fact. `survey.sh` reports enrollment status.

`survey.sh` checks all of the above read-only, and `./bootstrap.sh --dry-run`
prints the plan without touching anything. Use both before you ask IT anything —
the answers are easier to get when you can say precisely what will change.

---

## Customising

| want to change | edit |
|----------------|------|
| packages | [`Brewfile`](Brewfile) — or `Brewfile.local` for machine-specific extras (gitignored, auto-installed) |
| PATH, shell hooks, aliases | [`zsh/managed.zsh`](zsh/managed.zsh) — takes effect in the next shell, no re-run needed |
| prompt, theme, plugins | your own `~/.zshrc`, starting from [`zsh/zshrc.template`](zsh/zshrc.template) |
| editor settings | [`ide/settings.json`](ide/settings.json), then `./scripts/setup-ide.sh` |
| editor extensions | [`ide/extensions.txt`](ide/extensions.txt) — one id per line |
| terminal colours/font | [`iterm/DynamicProfiles/mac-dev-bootstrap.json`](iterm/DynamicProfiles/mac-dev-bootstrap.json) — iTerm re-reads it **live**, no restart |
| python/node versions | `UV_PYTHONS="3.12 3.13"`, `NODE_VERSION=22` |

### Decisions worth knowing about

- **One tool per job.** `uv` owns Python — no pyenv, no pipx, no `brew python@3.x`
  fighting over PATH. `nvm` owns Node, which is why there is no `brew "node"`.
  One container runtime, not three providing `docker` and fighting over the socket.
- **GNU coreutils installed, but `g`-prefixed.** `gsed`, `gfind`, `gsort`. Their
  `gnubin` is deliberately **not** on PATH: every script here is written for BSD
  userland, and BSD `sed` silently no-ops on GNU-only regex instead of erroring,
  which makes the bug invisible.
- **VSCodium over VS Code**, because Microsoft injects telemetry endpoints at
  *build* time — the official binary cannot be had clean. The cost is real:
  Open VSX only, so no Pylance, Copilot, or MS Remote-SSH. `setup-ide.sh`
  configures whichever you have and turns telemetry off in both.
- **iTerm2 Dynamic Profiles, not a copied `.plist`.** Declarative, diffable,
  read-only in the UI so it cannot drift, and iTerm reads it live.
- **Everything is logged** to `logs/<script>-<timestamp>.log` with an append-only
  ledger in `logs/history.jsonl`. Secret-shaped strings are redacted. `NO_LOG=1`
  turns it off — and if something behaves strangely, try that first: logging
  redirects stdout/stderr through a process substitution, which is exactly the
  machinery that can make a failure invisible.

---

## Troubleshooting

| symptom | cause |
|---------|-------|
| `docker: command not found` while the VM is running | OrbStack does not put its CLI on the default PATH. `zsh/managed.zsh` adds it — open a new shell. |
| `unknown shorthand flag: 'd' in -d` | `docker compose` is a *plugin*; OrbStack ships compose as a standalone binary. `setup-orbstack.sh` links it. |
| `node: command not found` in a new terminal | the managed block is missing from `~/.zshrc`, or you have not opened a new shell. `./scripts/doctor.sh` says which. |
| syntax highlighting half-works | `zsh-syntax-highlighting` is not **last** in `plugins=()`. It wraps widgets the earlier plugins define. |
| an extension "installs" but is absent | Marketplace-only, so unavailable on VSCodium. `ide/extensions.txt` lists the known ones. |
| `Unknown subcommand` from a script | on macOS `log` is also `/usr/bin/log`. Every script defines its own `log()` before first use for this reason. |
| iTerm shows a fallback font | the `font-fira-code` cask did not install; the `dev` profile asks for `FiraCode-Retina 13`. |

`./scripts/doctor.sh` prints the fixing command next to every failure. Every
script is idempotent, so re-running one is always safe.

Every run is logged. To find out what happened:

```sh
./scripts/logs.sh          # the ledger: what ran, when, exit code
./scripts/logs.sh fails    # only the runs that failed
./scripts/logs.sh last     # dump the most recent log
./scripts/logs.sh tail     # follow the newest log live
```

## Scripts

Every one is standalone and idempotent — run it directly, any time.

| script | |
|--------|--|
| [`scripts/survey.sh`](scripts/survey.sh) | read-only inventory + blockers. Zero dependencies; `--json`, `--save`, `--diff` |
| [`scripts/doctor.sh`](scripts/doctor.sh) | does it *work*? Tests in a real zsh shell, prints the fix next to each failure |
| [`scripts/logs.sh`](scripts/logs.sh) | the run ledger |
| [`scripts/setup-*.sh`](scripts/) | the individual modules from the table above |
| [`scripts/lib/`](scripts/lib/) | `log.sh` (logging + redaction), `docker.sh` (finding docker, and why that is hard) |
