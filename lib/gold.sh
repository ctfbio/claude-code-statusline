#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/gold.sh — Gold spot price (XAU) via gold-api.com.
# Merges the XAU rate into the same fx-cache.json produced by lib/fx.sh.
#
# API:  https://api.gold-api.com/price/XAU
#       { "name": "Gold", "price": 2345.67, "symbol": "XAU", "updatedAt": "...", "updatedAtReadable": "..." }
# The "price" field is USD per troy ounce of gold.
# We emit XAU-per-USD (1/price) into rates.XAU for symmetry with fiat rates.
#
# NOTE: gold-api.com is not LBMA-authoritative. For an authoritative daily fix,
# LBMA or Reuters require a commercial license that's incompatible with OSS
# redistribution. gold-api.com aggregates retail spot — accurate to basis
# points, but document the caveat.

set -o pipefail

GOLD_CACHE_PATH="${FX_CACHE_PATH:-$HOME/.claude/statusline/data/fx-cache.json}"

gold_fetch_price_usd_per_oz() {
  # Echoes the USD-per-ounce price, or returns non-zero on failure.
  local json price
  json=$(curl -fsSL --max-time 8 'https://api.gold-api.com/price/XAU' 2>/dev/null) || return 1
  price=$(printf '%s\n' "$json" | jq -r '.price // empty' 2>/dev/null)
  [ -z "$price" ] && return 1
  # Basic sanity bounds: gold historically has traded 300-5000 USD/oz.
  # Reject clearly broken responses (e.g. 0 or tens of thousands).
  local int_part
  int_part=$(printf '%s\n' "$price" | cut -d. -f1)
  if [ "$int_part" -lt 100 ] || [ "$int_part" -gt 20000 ]; then
    return 1
  fi
  printf '%s\n' "$price"
}

gold_fetch_and_merge() {
  # Pulls XAU spot and writes it into the existing fx-cache.json's .rates.XAU.
  # Safe to call independently of fx_fetch — creates an fx-only file if FX
  # sources weren't available (rates will just have XAU alone).
  local price_usd xau_rate tmp
  price_usd=$(gold_fetch_price_usd_per_oz) || return 1
  xau_rate=$(awk "BEGIN { printf \"%.10f\", 1 / $price_usd }")

  if [ -r "$GOLD_CACHE_PATH" ]; then
    tmp="${GOLD_CACHE_PATH}.tmp.$$"
    jq --argjson xau "$xau_rate" \
       --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.rates.XAU = $xau | .gold_fetched_at = $now' \
       "$GOLD_CACHE_PATH" > "$tmp" && mv "$tmp" "$GOLD_CACHE_PATH"
  else
    # No FX cache yet — create a minimal file with XAU only.
    mkdir -p "$(dirname "$GOLD_CACHE_PATH")"
    cat > "$GOLD_CACHE_PATH" <<EOF
{
  "base": "USD",
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "gold-api-only",
  "rates": { "XAU": $xau_rate },
  "gold_fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
  fi
}
