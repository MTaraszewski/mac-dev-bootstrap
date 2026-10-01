#!/usr/bin/env bash
# logs.sh — what ran, when, and did it work?
#
#   ./scripts/logs.sh              # recent runs (the ledger), newest first
#   ./scripts/logs.sh fails        # only non-zero exits — start here when broken
#   ./scripts/logs.sh last         # dump the most recent log
#   ./scripts/logs.sh last shell   # most recent log for one script
#   ./scripts/logs.sh tail         # follow the newest log live
#   ./scripts/logs.sh prune        # delete logs older than 30 days
#
# No jq: this has to work before `brew bundle` has run. awk parses the ledger,
# which is a flat one-object-per-line JSON file written by lib/log.sh.
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
LOG_DIR="$REPO_DIR/logs"
LEDGER="$LOG_DIR/history.jsonl"

c_dim="\033[2m"; c_z="\033[0m"
[[ -d "$LOG_DIR" ]] || { echo "No logs yet. Run something first."; exit 0; }
newest() { ls -t "$LOG_DIR"/*.log 2>/dev/null | head -1; }

# field <json-line> <key>  — flat objects only, which is all lib/log.sh writes
field() {
  awk -v k="$2" '
    { if (match($0, "\"" k "\":\"[^\"]*\"")) {
        s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":"/, "", s); sub(/"$/, "", s); print s; next }
      if (match($0, "\"" k "\":[0-9]+")) {
        s = substr($0, RSTART, RLENGTH); sub(/^"[^"]*":/, "", s); print s } }
  ' <<<"$1"
}

case "${1:-list}" in
  list)
    [[ -f "$LEDGER" ]] || { echo "No history yet."; exit 0; }
    printf "%-20s %-14s %-5s %7s  %s\n" "WHEN" "SCRIPT" "EXIT" "TOOK" "LOG"
    # tail -r, not tac: macOS has no tac.
    tail -40 "$LEDGER" | tail -r | while IFS= read -r line; do
      [[ "$line" == \{* ]] || continue
      ex="$(field "$line" exit)"
      col="\033[1;32m"; [[ "$ex" != "0" ]] && col="\033[1;31m"
      printf "%-20s %-14s ${col}%-5s${c_z} %6ss  ${c_dim}%s${c_z}\n" \
        "$(field "$line" ts)" "$(field "$line" script)" "$ex" \
        "$(field "$line" duration_s)" "$(field "$line" log)"
    done ;;

  fails)
    [[ -f "$LEDGER" ]] || exit 0
    echo "Runs that exited non-zero:"
    grep -v '"exit":0,' "$LEDGER" | tail -20 | while IFS= read -r line; do
      printf "  %s  %s (exit %s)  → logs/%s\n" \
        "$(field "$line" ts)" "$(field "$line" script)" \
        "$(field "$line" exit)" "$(field "$line" log)"
    done
    echo
    echo "Read one:  ./scripts/logs.sh last <script>" ;;

  last)
    if [[ -n "${2:-}" ]]; then
      f=$(ls -t "$LOG_DIR/$2"-*.log 2>/dev/null | head -1)
      [[ -n "$f" ]] || { echo "no logs for '$2'"; exit 1; }
    else
      f=$(newest)
    fi
    [[ -n "$f" ]] || { echo "no logs"; exit 1; }
    printf "${c_dim}%s${c_z}\n\n" "$f"
    cat "$f" ;;

  tail)
    f=$(newest); [[ -n "$f" ]] || { echo "no logs"; exit 1; }
    echo "following $f"; tail -f "$f" ;;

  prune)
    n=$(find "$LOG_DIR" -name '*.log' -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    find "$LOG_DIR" -name '*.log' -mtime +30 -delete 2>/dev/null
    echo "deleted $n logs older than 30 days (history.jsonl kept)" ;;

  *) sed -n '2,12p' "$0" ;;
esac
