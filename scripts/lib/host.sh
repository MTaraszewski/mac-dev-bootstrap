#!/usr/bin/env bash
# lib/host.sh — size the local-model budget for THIS Mac. Source, don't run.
#
#   source "$REPO_DIR/scripts/lib/host.sh" && load_host_profile
#
# Everything here is DERIVED FROM RAM, not from a hardcoded machine list.
# That matters: an earlier version of this matched the chip string and mapped
# anything containing "Pro" to a 24GB profile, so a 36GB or 48GB M4 Pro
# MacBook Pro was handed a 20GB GPU cap and a 14B model slot. RAM is the
# thing that actually constrains you; the chip only tells you bandwidth.
#
# Override anything:
#   HOST_WIRED_MB=40960 HOST_BANDWIDTH=400 ./scripts/setup-local-ai.sh

load_host_profile() {
  local ram_bytes ram_gb chip cushion_gb
  ram_bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  ram_gb=$(( ram_bytes / 1073741824 ))
  (( ram_gb > 0 )) || ram_gb=16          # unknowable: assume small, fail safe
  chip="$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown)"

  HOST_RAM_GB="$ram_gb"
  HOST_CHIP="$chip"

  # ── memory bandwidth, GB/s ─────────────────────────────────────────────
  # This sets the SPEED CEILING for token generation, which is bandwidth-bound:
  # roughly tok/s = bandwidth / model-size-in-GB. A big model cannot be fast.
  case "$chip" in
    *Ultra*) HOST_BANDWIDTH=800 ;;
    *Max*)   HOST_BANDWIDTH=400 ;;
    *Pro*)   HOST_BANDWIDTH=273 ;;
    *)       HOST_BANDWIDTH=120 ;;       # base M-series
  esac

  # ── how much unified memory the GPU may wire down ──────────────────────
  # macOS defaults to about 2/3 of RAM. Raising it lets a bigger model stay
  # fully resident; raising it too far makes the machine swap itself to death.
  # The cushion left for macOS scales with RAM rather than being a flat 4GB:
  # a 40GB model inside a 56GB cap on a 64GB box leaves the OS 8GB, and with
  # apps open that swaps badly.
  if   (( ram_gb >= 96 )); then cushion_gb=24
  elif (( ram_gb >= 64 )); then cushion_gb=16
  elif (( ram_gb >= 32 )); then cushion_gb=10
  else                          cushion_gb=6
  fi
  HOST_WIRED_MB=$(( (ram_gb - cushion_gb) * 1024 ))
  (( HOST_WIRED_MB > 0 )) || HOST_WIRED_MB=0

  # Usable budget for ONE large model: the cap, minus the small resident core
  # (FIM + embeddings, ~1.3GB), minus KV cache headroom (~2GB).
  HOST_BIG_SLOT_GB=$(( (HOST_WIRED_MB / 1024) - 4 ))
  (( HOST_BIG_SLOT_GB > 0 )) || HOST_BIG_SLOT_GB=0

  # ── which model manifest ───────────────────────────────────────────────
  # models.big.conf adds the 30B/70B tier. Only offered where it fits.
  if (( ram_gb >= 48 )); then
    HOST_MODELS_TAG="big"
  else
    HOST_MODELS_TAG=""
  fi

  HOST_LABEL="${chip}, ${ram_gb}GB"

  export HOST_RAM_GB HOST_CHIP HOST_BANDWIDTH HOST_WIRED_MB \
         HOST_BIG_SLOT_GB HOST_MODELS_TAG HOST_LABEL
}

# Pretty-print the budget. Used by setup-local-ai.sh and ram.sh.
print_host_profile() {
  printf "  %-18s %s\n" "machine"      "$HOST_LABEL"
  printf "  %-18s %s GB/s\n" "bandwidth" "$HOST_BANDWIDTH"
  printf "  %-18s %s MB  (macOS keeps %s GB)\n" "gpu cap target" \
         "$HOST_WIRED_MB" "$(( HOST_RAM_GB - HOST_WIRED_MB / 1024 ))"
  printf "  %-18s ~%s GB for one large model\n" "big slot" "$HOST_BIG_SLOT_GB"
}
