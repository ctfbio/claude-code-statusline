#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/fx.sh — FX rate fetching + caching.
# Primary:  Frankfurter (ECB proxy, MIT, no key)
# Fallback: ECB eurofxref-daily.xml direct
# Combines with lib/gold.sh output into a single USD-base cache.
#
# Cache schema:  data/fx-cache.json
#   {
#     "base": "USD",
#     "fetched_at": "ISO-8601",
#     "source": "frankfurter|ecb-xml",
#     "rates": { "EUR": 0.92, "JPY": 152.3, ... }
#   }
#
# Public functions:
#   fx_cache_path           -> echoes cache path
#   fx_cache_age_seconds    -> echoes age in seconds (or 99999999 if missing)
#   fx_cache_stale          -> returns 0 if cache is older than FX_TTL_SECONDS
#   fx_fetch_frankfurter    -> writes cache atomically from api.frankfurter.dev
#   fx_fetch_ecb_xml        -> writes cache atomically from ECB XML
#   fx_fetch                -> primary + fallback wrapper
#   fx_refresh_async        -> triggers fx_fetch in background if stale
#   fx_convert_amount usd currency -> echoes converted amount (unformatted float)

set -o pipefail

FX_TTL_SECONDS="${FX_TTL_SECONDS:-86400}"   # 24h
FX_CACHE_PATH="${FX_CACHE_PATH:-$HOME/.claude/statusline/data/fx-cache.json}"
FX_LOCK_PATH="${FX_CACHE_PATH}.lock"
FX_LOG_PATH="${FX_LOG_PATH:-$HOME/.claude/statusline/data/fx-refresh.log}"

fx_cache_path() { printf '%s\n' "$FX_CACHE_PATH"; }

fx_cache_age_seconds() {
  if [ ! -r "$FX_CACHE_PATH" ]; then
    printf '%s\n' 99999999
    return
  fi
  local mtime now
  # macOS (BSD stat) and Linux (GNU stat) differ; try both.
  mtime=$(stat -f %m "$FX_CACHE_PATH" 2>/dev/null || stat -c %Y "$FX_CACHE_PATH" 2>/dev/null || echo 0)
  now=$(date +%s)
  printf '%s\n' "$(( now - mtime ))"
}

fx_cache_stale() {
  local age
  age=$(fx_cache_age_seconds)
  [ "$age" -gt "$FX_TTL_SECONDS" ]
}

_fx_write_atomic() {
  # $1 = JSON payload on stdin, writes to $FX_CACHE_PATH atomically.
  local tmp="${FX_CACHE_PATH}.tmp.$$"
  mkdir -p "$(dirname "$FX_CACHE_PATH")"
  cat > "$tmp"
  # Validate JSON before replacing cache — protect against half-written file.
  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$FX_CACHE_PATH"
}

fx_fetch_frankfurter() {
  local now json
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  json=$(curl -fsSL --max-time 8 'https://api.frankfurter.dev/v1/latest?base=USD' 2>/dev/null) || return 1
  printf '%s\n' "$json" | jq empty 2>/dev/null || return 1
  printf '%s\n' "$json" \
    | jq --arg now "$now" '{base: "USD", fetched_at: $now, source: "frankfurter", rates: .rates}' \
    | _fx_write_atomic
}

fx_fetch_ecb_xml() {
  # ECB publishes EUR-based rates. Invert + re-base to USD.
  local xml now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  xml=$(curl -fsSL --max-time 8 'https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml' 2>/dev/null) || return 1
  # Parse <Cube currency='XXX' rate='N.N'/> pairs. EUR→USD is the anchor; all other rates become (ccy/EUR) * (1/USD_per_EUR) ⇒ ccy/USD inverse.
  # We emit "how much CCY = 1 USD" to match Frankfurter's convention.
  local usd_per_eur
  usd_per_eur=$(printf '%s\n' "$xml" | grep -oE "currency='USD' rate='[0-9.]+'" | grep -oE '[0-9.]+' | head -1)
  [ -z "$usd_per_eur" ] && return 1
  local pairs
  pairs=$(printf '%s\n' "$xml" \
    | grep -oE "currency='[A-Z]+' rate='[0-9.]+'" \
    | awk -F"'" -v usdeur="$usd_per_eur" '
        BEGIN { first=1; printf "{" }
        {
          ccy=$2; rate=$4;
          inv = rate / usdeur;
          if (!first) printf ",";
          printf "\"%s\":%s", ccy, inv;
          first=0;
        }
        END {
          if (!first) printf ",";
          printf "\"EUR\":%s}", (1 / usdeur);
        }
      ')
  printf '{"base":"USD","fetched_at":"%s","source":"ecb-xml","rates":%s}\n' "$now" "$pairs" \
    | jq '.' \
    | _fx_write_atomic
}

fx_fetch() {
  # Primary + fallback. Returns 0 if cache was written, 1 if both failed.
  if fx_fetch_frankfurter; then
    printf '[%s] frankfurter ok\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FX_LOG_PATH" 2>/dev/null || true
    return 0
  fi
  printf '[%s] frankfurter failed, trying ecb\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FX_LOG_PATH" 2>/dev/null || true
  if fx_fetch_ecb_xml; then
    printf '[%s] ecb-xml ok\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FX_LOG_PATH" 2>/dev/null || true
    return 0
  fi
  printf '[%s] all FX sources failed\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$FX_LOG_PATH" 2>/dev/null || true
  return 1
}

fx_refresh_async() {
  # Fire and forget. Uses a lock file to prevent concurrent refreshes.
  if [ -f "$FX_LOCK_PATH" ]; then
    # Lock exists — check if stale (>60s = previous run crashed).
    local lock_age
    lock_age=$(( $(date +%s) - $(stat -f %m "$FX_LOCK_PATH" 2>/dev/null || stat -c %Y "$FX_LOCK_PATH" 2>/dev/null || date +%s) ))
    [ "$lock_age" -lt 60 ] && return 0
  fi
  (
    touch "$FX_LOCK_PATH"
    fx_fetch || true
    # If gold.sh is available, refresh gold too.
    if declare -f gold_fetch_and_merge >/dev/null; then
      gold_fetch_and_merge || true
    fi
    rm -f "$FX_LOCK_PATH"
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

fx_convert_amount() {
  # $1 = amount in USD, $2 = target currency. Echoes float (unformatted).
  local usd="$1" ccy="$2" rate
  if [ "$ccy" = "USD" ]; then
    printf '%s\n' "$usd"
    return 0
  fi
  if [ ! -r "$FX_CACHE_PATH" ]; then
    return 1
  fi
  rate=$(jq -r --arg c "$ccy" '.rates[$c] // empty' "$FX_CACHE_PATH" 2>/dev/null)
  [ -z "$rate" ] && return 1
  # bc for portable floating-point math.
  printf '%s\n' "$(echo "$usd * $rate" | bc -l 2>/dev/null || awk "BEGIN {printf \"%.6f\", $usd * $rate}")"
}
