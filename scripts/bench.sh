#!/usr/bin/env bash
# bench.sh — measure real tok/s for local models.
#
#   ./scripts/bench.sh             # every local model
#   ./scripts/bench.sh qwen3-coder:30b   # just one
#
# Run this after anything that could change performance: an OS update, an
# Ollama update, a different KV cache type, a new GPU cap. A number you
# measured once is worth more than any spec sheet, and this is how you notice
# that an upgrade quietly cost you 30%.
#
# THE CEILING: decode is memory-bandwidth-bound — every token requires reading
# the whole model. tok/s cannot exceed bandwidth / model-size. A big model
# cannot be fast, however it is configured.
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
source "$REPO_DIR/scripts/lib/host.sh" 2>/dev/null && load_host_profile 2>/dev/null

die() { printf "\033[1;31mERR\033[0m %s\n" "$*"; exit 1; }
command -v ollama >/dev/null 2>&1 || die "ollama not on PATH — ./scripts/setup-local-ai.sh"
curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1 \
  || die "Ollama not answering on :11434. Open Ollama.app."

source "$REPO_DIR/scripts/lib/log.sh" 2>/dev/null && log_init bench "$@"

PROMPT="${BENCH_PROMPT:-Write a Python function that reverses a linked list. Code only, no explanation.}"

if [[ -n "${1:-}" ]]; then
  MODELS="$1"
else
  # Skip embedding models: they do not generate, so tok/s is meaningless.
  MODELS="$(ollama list 2>/dev/null | awk 'NR>1 && $1 !~ /embed/ { print $1 }')"
fi
[[ -n "$MODELS" ]] || die "no models to benchmark"

printf "\n\033[1;34m── bench\033[0m  %s\n" "${HOST_LABEL:-$(sysctl -n machdep.cpu.brand_string)}"
[[ -n "${HOST_BANDWIDTH:-}" ]] && printf "   bandwidth %s GB/s — tok/s ceiling is bandwidth ÷ model size\n" "$HOST_BANDWIDTH"
printf "\n%-28s %8s %8s %10s %9s\n" "MODEL" "SIZE" "TOKENS" "TIME" "TOK/S"
printf "%-28s %8s %8s %10s %9s\n" "----------------------------" "--------" "--------" "----------" "---------"

for m in $MODELS; do
  SIZE="$(ollama list 2>/dev/null | awk -v m="$m" '$1==m { print $3 $4 }')"

  # Ollama returns its own timings, which are more honest than wall clock:
  # eval_count is tokens generated, eval_duration is nanoseconds spent
  # generating (excluding prompt processing and model load).
  RESP="$(curl -fsS http://127.0.0.1:11434/api/generate \
            -d "{\"model\":\"$m\",\"prompt\":$(printf '%s' "$PROMPT" | sed 's/"/\\"/g; s/^/"/; s/$/"/'),\"stream\":false,\"options\":{\"num_predict\":200}}" \
            2>/dev/null)"

  if [[ -z "$RESP" ]]; then
    printf "%-28s %8s %8s %10s %9s\n" "$m" "${SIZE:-?}" "-" "-" "FAILED"
    continue
  fi

  COUNT="$(printf '%s' "$RESP" | tr ',' '\n' | sed -n 's/.*"eval_count":[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"
  NS="$(printf '%s' "$RESP"    | tr ',' '\n' | sed -n 's/.*"eval_duration":[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"

  if [[ -z "$COUNT" || -z "$NS" || "$NS" == "0" ]]; then
    printf "%-28s %8s %8s %10s %9s\n" "$m" "${SIZE:-?}" "${COUNT:-?}" "-" "NO DATA"
    continue
  fi

  awk -v m="$m" -v sz="${SIZE:-?}" -v c="$COUNT" -v ns="$NS" \
    'BEGIN { s = ns/1e9; printf "%-28s %8s %8d %9.1fs %9.1f\n", m, sz, c, s, c/s }'
done

echo
echo "Notes:"
echo "  * tok/s here excludes model load and prompt processing — it is pure"
echo "    decode speed, which is what you feel while reading a response."
echo "  * A number far below bandwidth ÷ size means the model is partly on the"
echo "    CPU. Check ./scripts/ram.sh and raise the cap: ./scripts/gpu-limit.sh"
echo "  * Comfortable reading is ~6-8 tok/s. Past that, quality matters more"
echo "    than speed; below it, nothing else matters."
