#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/format.sh — Color, duration, currency amount, and mode-specific layout.

set -o pipefail

# ─── Color ────────────────────────────────────────────────────────────────
# Map Claude Code's /color names → ANSI escape sequences.
# Orange and pink use 256-color codes since they aren't in the base 8/16 palette.
format_ansi_for_color() {
  case "$1" in
    red)    printf '\033[91m' ;;
    blue)   printf '\033[94m' ;;
    green)  printf '\033[92m' ;;
    yellow) printf '\033[93m' ;;
    purple) printf '\033[95m' ;;
    orange) printf '\033[38;5;208m' ;;
    pink)   printf '\033[38;5;213m' ;;
    cyan)   printf '\033[96m' ;;
    *)      printf '' ;;
  esac
}
format_ansi_dim() { printf '\033[2m'; }
format_ansi_reset() { printf '\033[0m'; }

# Resolve current session color from the transcript JSONL.
# /color blue appends a line like:
#   {"type":"agent-color","agentColor":"blue","sessionId":"..."}
# Last wins.
format_read_session_color() {
  local transcript="$1"
  [ -z "$transcript" ] || [ ! -r "$transcript" ] && return 0
  grep '"type":"agent-color"' "$transcript" 2>/dev/null \
    | tail -n 1 \
    | jq -r '.agentColor // ""' 2>/dev/null
}

# ─── Duration ─────────────────────────────────────────────────────────────
format_duration_ms() {
  local ms="${1:-0}"
  local h m s
  h=$(( ms / 3600000 ))
  m=$(( (ms % 3600000) / 60000 ))
  s=$(( (ms % 60000) / 1000 ))
  if [ "$h" -gt 0 ]; then
    printf '%dh%02dm' "$h" "$m"
  elif [ "$m" -gt 0 ]; then
    printf '%dm%02ds' "$m" "$s"
  else
    printf '%ds' "$s"
  fi
}

# ─── Currency amount ──────────────────────────────────────────────────────
# Formats a number with the right number of decimals + symbol.
# Uses currencies.json for metadata.
format_currency_amount() {
  # $1 = amount, $2 = ISO code
  local amount="$1" code="$2"
  local currencies_path="${CURRENCIES_PATH:-$HOME/.claude/statusline/data/currencies.json}"
  local decimals symbol
  if [ -r "$currencies_path" ]; then
    decimals=$(jq -r --arg c "$code" '.currencies[$c].decimals // 2' "$currencies_path" 2>/dev/null)
    symbol=$(jq -r --arg c "$code" '.currencies[$c].symbol // $c' "$currencies_path" 2>/dev/null)
  else
    decimals=2
    symbol="$code"
  fi
  # Scaled numeric formatting.
  local formatted
  formatted=$(awk -v n="$amount" -v d="$decimals" 'BEGIN { printf "%." d "f", n }')
  # USD-family symbols prefix; others postfix with a space; XAU uses "oz" suffix.
  case "$code" in
    USD|EUR|GBP|JPY|CNY|KRW|INR|ILS|THB|PHP|BRL|MXN|TRY|CHF|CAD|AUD|NZD|HKD|SGD)
      printf '%s%s' "$symbol" "$formatted"
      ;;
    XAU)
      printf '%s oz' "$formatted"
      ;;
    *)
      printf '%s %s' "$formatted" "$symbol"
      ;;
  esac
}

# ─── Plan-aware cost label ────────────────────────────────────────────────
# When the user is on a Max/Pro plan, Claude Code still emits a USD cost
# in its statusline payload — but it's the pay-as-you-go API equivalent,
# not a real charge. Users need this labeled unambiguously.
#
#   format_plan_prefix api  → ""        (no prefix; raw cost is real)
#   format_plan_prefix pro  → "API≡ "    (triple-bar equivalence)
#   format_plan_prefix max  → "API≡ "
format_plan_prefix() {
  case "$1" in
    pro|max|free) printf 'API≡ ' ;;
    *) printf '' ;;
  esac
}

# ─── Token short-form ─────────────────────────────────────────────────────
format_tokens_short() {
  # 12345 → 12.3k ; 1234567 → 1.2M
  local n="${1:-0}"
  awk -v n="$n" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000;
    else if (n >= 1000) printf "%.1fk", n/1000;
    else printf "%d", n;
  }'
}

# ─── Token segment ────────────────────────────────────────────────────────
# Shows the user how the session's tokens are split:
#   📊 15.8k in + 107k cache   (compact — non-cache vs cache reads)
# Uses the values produced by lib/usage.sh.
#   $1 = input tokens, $2 = output tokens, $3 = cache write, $4 = cache read
format_tokens_segment() {
  local in_t="${1:-0}" out_t="${2:-0}" cw_t="${3:-0}" cr_t="${4:-0}"
  local non_cache=$(( in_t + out_t ))
  local cache=$(( cw_t + cr_t ))
  printf '📊 %s in + %s cache' \
    "$(format_tokens_short "$non_cache")" \
    "$(format_tokens_short "$cache")"
}

# ─── Limit progress bar ───────────────────────────────────────────────────
# Compact 5-cell bar with color transitions at warn_at_pct and 100%.
# Caller supplies the current value + cap + warn_at_pct; callers may render
# multiple bars (e.g. session + daily, USD + tokens).
#
#   $1 = pct (0-999), $2 = warn_at_pct (default 80), $3 = label (e.g. "d")
# Emits: "▓▓▓░░ 62%d"   (with color)  — label suffix makes the unit clear.
# Color: green < warn_pct; yellow warn_pct..99; red >= 100.
format_limit_bar() {
  local pct="${1:-0}" warn="${2:-80}" label="${3:-}"
  local color_code
  if   [ "$pct" -ge 100 ]; then color_code=$'\033[91m'     # red
  elif [ "$pct" -ge "$warn" ]; then color_code=$'\033[93m'  # yellow
  else color_code=$'\033[92m'                                # green
  fi
  local reset=$'\033[0m'
  local filled=$(( pct / 20 )); [ "$filled" -gt 5 ] && filled=5
  local empty=$(( 5 - filled ))
  local bar=""
  local i
  for ((i=0; i<filled; i++)); do bar="${bar}▓"; done
  for ((i=0; i<empty;  i++)); do bar="${bar}░"; done
  if [ -n "$label" ]; then
    printf '%s%s %d%%%s%s' "$color_code" "$bar" "$pct" "$label" "$reset"
  else
    printf '%s%s %d%%%s' "$color_code" "$bar" "$pct" "$reset"
  fi
}
