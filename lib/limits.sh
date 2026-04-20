#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/limits.sh — per-session + cumulative daily spending/token ledger.
#
# Design: zero-hook. The statusline upserts the current session's cost into
# a monthly ledger file on every render. No SessionEnd plumbing needed — the
# ledger converges to the final value once the session goes idle.
#
# Ledger schema (data/spending-YYYY-MM.json):
#   {
#     "month": "2026-04",
#     "sessions": {
#       "<session_id>": {
#         "cost_usd": 1.46,
#         "total_tokens": 123456,
#         "first_seen":   "2026-04-19T12:34:56Z",
#         "last_updated": "2026-04-19T13:45:10Z"
#       },
#       ...
#     }
#   }
#
# Daily total = sum of sessions where date(last_updated) == today.
# Monthly total = sum of all sessions in the file.

set -o pipefail

LIMITS_DATA_DIR="${LIMITS_DATA_DIR:-$HOME/.claude/statusline/data}"

_limits_ledger_path() {
  local month; month=$(date -u +%Y-%m)
  printf '%s/spending-%s.json\n' "$LIMITS_DATA_DIR" "$month"
}

_limits_today() { date -u +%Y-%m-%d; }

# Upsert the current session's cost + tokens into the ledger.
# Called once per render from statusline.sh.
#   $1 = session_id
#   $2 = total_cost_usd (float)
#   $3 = total_tokens   (int; sum of input+output+cache_write+cache_read)
limits_record_session() {
  local sid="$1" cost="$2" tokens="${3:-0}"
  [ -z "$sid" ] && return 1
  mkdir -p "$LIMITS_DATA_DIR"
  local ledger; ledger=$(_limits_ledger_path)
  local now; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local month; month=$(date -u +%Y-%m)
  local tmp="${ledger}.tmp.$$"

  if [ -r "$ledger" ]; then
    jq --arg sid "$sid" --argjson cost "$cost" --argjson tokens "$tokens" \
       --arg now "$now" --arg month "$month" '
         .month = $month
       | .sessions = (.sessions // {})
       | .sessions[$sid] = {
           cost_usd:     $cost,
           total_tokens: $tokens,
           first_seen:   (.sessions[$sid].first_seen // $now),
           last_updated: $now
         }
       ' "$ledger" > "$tmp" 2>/dev/null || return 1
  else
    jq -n --arg sid "$sid" --argjson cost "$cost" --argjson tokens "$tokens" \
         --arg now "$now" --arg month "$month" '
           {
             month: $month,
             sessions: {
               ($sid): {
                 cost_usd: $cost,
                 total_tokens: $tokens,
                 first_seen: $now,
                 last_updated: $now
               }
             }
           }
         ' > "$tmp" 2>/dev/null || return 1
  fi

  jq empty "$tmp" >/dev/null 2>&1 || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$ledger"
}

# Sum today's session costs in the current ledger. Echoes USD float.
limits_daily_total_usd() {
  local ledger; ledger=$(_limits_ledger_path)
  [ ! -r "$ledger" ] && { printf '0'; return 0; }
  local today; today=$(_limits_today)
  jq -r --arg today "$today" '
    [ .sessions // {} | to_entries[]
      | select(.value.last_updated | startswith($today))
      | .value.cost_usd ]
    | add // 0
  ' "$ledger" 2>/dev/null || printf '0'
}

limits_daily_total_tokens() {
  local ledger; ledger=$(_limits_ledger_path)
  [ ! -r "$ledger" ] && { printf '0'; return 0; }
  local today; today=$(_limits_today)
  jq -r --arg today "$today" '
    [ .sessions // {} | to_entries[]
      | select(.value.last_updated | startswith($today))
      | .value.total_tokens ]
    | add // 0
  ' "$ledger" 2>/dev/null || printf '0'
}

# Percentage of cap reached. Echoes integer 0..999. Returns 0 if cap is null.
#   $1 = numerator (current value), $2 = cap (or empty/null)
limits_pct() {
  local cur="$1" cap="$2"
  [ -z "$cap" ] || [ "$cap" = "null" ] || [ "$cap" = "0" ] && { printf '0'; return 0; }
  awk -v cur="$cur" -v cap="$cap" 'BEGIN {
    pct = (cur / cap) * 100;
    if (pct < 0) pct = 0;
    if (pct > 999) pct = 999;
    printf "%d", pct + 0.5;   # round to nearest
  }'
}

# Read a limits.<key> config value. Prints empty if missing.
#   $1 = dotted path (e.g. "session.usd", "daily.usd", "warn_at_pct")
limits_config_value() {
  local path="$1"
  local cfg; cfg=$(read_statusline_config 2>/dev/null || printf '{}')
  printf '%s\n' "$cfg" \
    | jq -r --arg p "$path" '
        (getpath(["limits"] + ($p | split("."))) // empty) | tostring
      ' 2>/dev/null \
    | sed 's/^null$//'
}
