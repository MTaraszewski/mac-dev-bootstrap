#!/usr/bin/env bash
# lib/log.sh — shared logging. Source it, don't run it.
#
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/log.sh"
#   log_init bootstrap "$@"
#
# Gives you:
#   • everything on stdout/stderr ALSO written to logs/<name>-<ts>.log
#   • colors stripped from the file, kept on your terminal
#   • progress bars collapsed (brew/curl would otherwise write MBs of \r)
#   • obvious secrets redacted
#   • an append-only ledger at logs/history.jsonl: what ran, when, exit code
#
# logs/ is gitignored — it has hostnames, paths, and possibly things the
# redactor missed. Never commit it.

# NOTE: the awk program below is wrapped in SINGLE QUOTES. Do not put an
# apostrophe in its comments — "brew's" once closed the quote and broke the
# whole file. Use plain words.
#
# Filter applied to the FILE copy only. awk, not sed: BSD sed silently
# no-ops on GNU escapes, and this must behave identically everywhere.
_log_filter() {
  awk '
    {
      gsub(/\033\[[0-9;?]*[a-zA-Z]/, "")        # ANSI escapes
      n = split($0, parts, "\r")                 # progress bars: keep final state
      line = parts[n]
      # Redact KEY=value where KEY looks secret. .env style is uppercase.
      gsub(/[A-Za-z_]*(PASSWORD|PASSWD|SECRET|TOKEN|APIKEY|API_KEY|AUTH|CREDENTIAL)[A-Za-z_]*[=:][^ ]*/, "***REDACTED***", line)
      # NOTE: "sk" is deliberately NOT in this list. It used to be, for OpenAI
      # keys, and it silently corrupted real output: "machine.docker.disk_size_gb"
      # matched di|sk_size_gb and logged as "machine.docker.di***REDACTED***".
      # Same for "task", "ask", "risk". OpenAI keys realistically appear as
      # OPENAI_API_KEY=sk-... which the KEY=value rule above already catches.
      # A redactor that mangles legitimate text is worse than no redactor:
      # you stop trusting the log.
      # Separators differ by vendor: GitHub uses _, GitLab/Slack use -.
      # One combined rule with [-_] is what let "di|sk_size_gb" through.
      gsub(/(ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]+/, "***REDACTED***", line)
      gsub(/(glpat|xoxb|xoxp|xapp|xoxa|xoxr)-[A-Za-z0-9_-]+/, "***REDACTED***", line)
      gsub(/[Bb]earer[[:space:]]+[A-Za-z0-9._-]+/, "Bearer ***REDACTED***", line)
      gsub(/-----BEGIN[A-Z ]*PRIVATE KEY-----/, "***REDACTED PRIVATE KEY***", line)

      # ── progress bars ───────────────────────────────────────────────
      # Some installers animate with ANSI CURSOR CONTROL rather than \r.
      # Stripping the escapes above therefore CONCATENATES every frame instead
      # of collapsing them, which once turned one download into 1720 lines of
      # unreadable mush. Keep the 100% line, drop the rest — nobody debugs
      # from a half-finished progress bar.
      if (line ~ /^[#[:space:]]*[0-9.]+%[[:space:]]*$/) next   # brew download bars
      if (line ~ /[0-9]+%.*(ETA|eta)/ && line !~ /100%/) next

      print line
      fflush()                                   # so `tail -f` works live
    }
  '
}

log_init() {
  # Escape hatch. Logging redirects stdout/stderr through a process
  # substitution, which is exactly the machinery that makes a failure
  # invisible. If anything is behaving strangely:
  #     NO_LOG=1 ./bootstrap.sh
  # If that fixes it, the logging is the bug — not your machine.
  if [[ -n "${NO_LOG:-}" ]]; then
    return 0
  fi

  # Already inside a logged run? The parent's tee is capturing us. Nesting
  # would duplicate every line and tangle the pipes.
  if [[ -n "${_LOG_ACTIVE:-}" ]]; then
    return 0
  fi
  export _LOG_ACTIVE=1

  LOG_NAME="${1:-script}"; shift || true
  LOG_DIR="${REPO_DIR:-$PWD}/logs"
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/${LOG_NAME}-$(date +%Y%m%d-%H%M%S).log"
  LOG_START=$(date +%s)
  LOG_ARGS="$*"

  {
    echo "# script   : $LOG_NAME"
    echo "# args     : ${LOG_ARGS:-none}"
    echo "# started  : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# host     : $(scutil --get LocalHostName 2>/dev/null || hostname)"
    echo "# user     : $(whoami)"
    echo "# repo     : ${REPO_DIR:-$PWD}"
    echo "# git      : $(git -C "${REPO_DIR:-$PWD}" rev-parse --short HEAD 2>/dev/null || echo 'not a git repo')"
    echo "# macos    : $(sw_vers -productVersion 2>/dev/null)"
    echo "# ---"
    echo
  } >> "$LOG_FILE"

  # Route everything through tee: terminal keeps colors, file gets filtered.
  exec > >(tee >(_log_filter >> "$LOG_FILE")) 2>&1
  trap '_log_finish $?' EXIT

  printf "\033[2m  log: %s\033[0m\n" "${LOG_FILE#$REPO_DIR/}"
}

_log_finish() {
  local rc="${1:-0}" dur=$(( $(date +%s) - ${LOG_START:-0} ))

  # Close our end of the pipe and let the tee/awk subshell drain. Without
  # this the footer below races ahead of the body it's summarising.
  exec 1>&- 2>&-
  sleep 0.2

  {
    echo
    echo "# ---"
    echo "# finished : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# duration : ${dur}s"
    echo "# exit     : $rc"
  } >> "$LOG_FILE"

  # Append-only ledger — the "what did I run" index.
  printf '{"ts":"%s","script":"%s","args":"%s","exit":%d,"duration_s":%d,"log":"%s","git":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "$LOG_NAME" \
    "$(printf '%s' "${LOG_ARGS:-}" | sed 's/"/\\"/g')" \
    "$rc" "$dur" \
    "$(basename "$LOG_FILE")" \
    "$(git -C "${REPO_DIR:-$PWD}" rev-parse --short HEAD 2>/dev/null || echo '')" \
    >> "$LOG_DIR/history.jsonl"
}
