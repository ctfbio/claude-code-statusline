#!/usr/bin/env bash
# shellcheck shell=bash source=lib/fx.sh source=lib/gold.sh source=lib/pricing.sh source=lib/usage.sh source=lib/format.sh
#
# statusline.sh — entry point for Claude Code's statusLine.
#
# Claude Code pipes a JSON payload to stdin on every render. We extract the
# signals we care about, consult cached FX / pricing data, and emit one line
# of ANSI-colored text to stdout.
#
# Zero synchronous network. When the FX cache is stale we spawn a detached
# background refresh and continue with the (still usable) cached rates.
#
# Configuration lives in ~/.claude/settings.json under the top-level
# "statusline" key (see README.md for the full schema).

set -o pipefail

STATUSLINE_HOME="${STATUSLINE_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# shellcheck disable=SC1091
source "$STATUSLINE_HOME/lib/fx.sh"
# shellcheck disable=SC1091
source "$STATUSLINE_HOME/lib/gold.sh"
# shellcheck disable=SC1091
source "$STATUSLINE_HOME/lib/pricing.sh"
# shellcheck disable=SC1091
source "$STATUSLINE_HOME/lib/usage.sh"
# shellcheck disable=SC1091
source "$STATUSLINE_HOME/lib/format.sh"
# shellcheck disable=SC1091
source "$STATUSLINE_HOME/lib/limits.sh"

export CURRENCIES_PATH="$STATUSLINE_HOME/data/currencies.json"
export PRICING_PATH="$STATUSLINE_HOME/data/anthropic-pricing.json"
export FX_CACHE_PATH="$STATUSLINE_HOME/data/fx-cache.json"
export USAGE_CURSOR_DIR="$STATUSLINE_HOME/data"
export LIMITS_DATA_DIR="$STATUSLINE_HOME/data"

# ─── Input ────────────────────────────────────────────────────────────────
INPUT=$(cat)

SESSION_ID=$(printf '%s\n' "$INPUT" | jq -r '.session_id // ""')
TRANSCRIPT=$(printf '%s\n' "$INPUT" | jq -r '.transcript_path // ""')
MODEL_NAME=$(printf '%s\n' "$INPUT" | jq -r '.model.display_name // .model.id // "claude"')
MODEL_ID=$(printf '%s\n' "$INPUT" | jq -r '.model.id // .model.display_name // "claude"')
CWD=$(printf '%s\n' "$INPUT" | jq -r '.workspace.current_dir // .cwd // ""')
TOTAL_DURATION_MS=$(printf '%s\n' "$INPUT" | jq -r '.cost.total_duration_ms // 0')
TOTAL_COST_USD=$(printf '%s\n' "$INPUT" | jq -r '.cost.total_cost_usd // 0')

# ─── Config ───────────────────────────────────────────────────────────────
CONFIG=$(read_statusline_config)
MODE=$(printf '%s\n' "$CONFIG" | jq -r '.mode // "compact"')
SHOW_EFFORT=$(printf '%s\n' "$CONFIG" | jq -r '.show_effort // true')
SHOW_RATE=$(printf '%s\n' "$CONFIG" | jq -r '.show_rate // empty')
SHOW_CWD=$(printf '%s\n' "$CONFIG" | jq -r '.show_cwd // true')
SHOW_CACHE_SPLIT=$(printf '%s\n' "$CONFIG" | jq -r '.show_cache_split // empty')
SHOW_TOKENS=$(printf '%s\n' "$CONFIG" | jq -r '.show_tokens // empty')
SHOW_LIMITS=$(printf '%s\n' "$CONFIG" | jq -r '.show_limits // true')
# Default show_rate/show_cache_split/show_tokens depend on mode.
if [ "$SHOW_RATE" = "" ]; then
  case "$MODE" in
    wide) SHOW_RATE=true ;;
    *)    SHOW_RATE=false ;;
  esac
fi
if [ "$SHOW_CACHE_SPLIT" = "" ]; then
  case "$MODE" in
    wide|compact) SHOW_CACHE_SPLIT=true ;;
    *)            SHOW_CACHE_SPLIT=false ;;
  esac
fi
if [ "$SHOW_TOKENS" = "" ]; then
  case "$MODE" in
    wide) SHOW_TOKENS=true ;;
    *)    SHOW_TOKENS=false ;;
  esac
fi

WARN_AT_PCT=$(limits_config_value "warn_at_pct")
[ -z "$WARN_AT_PCT" ] && WARN_AT_PCT=80
SESSION_USD_CAP=$(limits_config_value "session.usd")
DAILY_USD_CAP=$(limits_config_value "daily.usd")
SESSION_TOK_CAP=$(limits_config_value "session.tokens")
DAILY_TOK_CAP=$(limits_config_value "daily.tokens")

# Currencies: respect user's ordering. Dedupe in place, preserve first occurrence.
CURRENCIES=$(printf '%s\n' "$CONFIG" | jq -r '
  (.currencies // ["USD"])
  | map(ascii_upcase)
  | reduce .[] as $c ([]; if any(.[]; . == $c) then . else . + [$c] end)
  | .[]
')

PLAN=$(resolve_plan)
PLAN_PREFIX=$(format_plan_prefix "$PLAN")

# ─── FX cache refresh if stale (non-blocking) ─────────────────────────────
if fx_cache_stale; then
  fx_refresh_async
fi

# ─── Session color ────────────────────────────────────────────────────────
SESSION_COLOR=$(format_read_session_color "$TRANSCRIPT")
ANSI=$(format_ansi_for_color "$SESSION_COLOR")
DIM=$(format_ansi_dim)
RESET=$(format_ansi_reset)

# ─── Duration ─────────────────────────────────────────────────────────────
ELAPSED=$(format_duration_ms "$TOTAL_DURATION_MS")

# ─── Token parse (once — used by cache split, tokens segment, and limits) ──
IN_T=0; OUT_T=0; CW_T=0; CR_T=0
if [ -n "$SESSION_ID" ] && [ -r "$TRANSCRIPT" ]; then
  TOKENS=$(usage_parse "$TRANSCRIPT" "$SESSION_ID" 2>/dev/null || true)
  if [ -n "$TOKENS" ]; then
    IN_T=$(echo "$TOKENS" | awk '{print $1}')
    OUT_T=$(echo "$TOKENS" | awk '{print $2}')
    CW_T=$(echo "$TOKENS" | awk '{print $3}')
    CR_T=$(echo "$TOKENS" | awk '{print $4}')
  fi
fi
TOTAL_TOKENS=$(( IN_T + OUT_T + CW_T + CR_T ))

# ─── Cache vs non-cache breakdown ─────────────────────────────────────────
NON_CACHE_USD=""
CACHE_USD=""
if [ "$SHOW_CACHE_SPLIT" = "true" ] && [ "$TOTAL_TOKENS" -gt 0 ]; then
  RATES=$(pricing_rate_for_model "$MODEL_ID")
  R_IN=$(echo "$RATES" | awk '{print $1}')
  R_OUT=$(echo "$RATES" | awk '{print $2}')
  R_CW=$(echo "$RATES" | awk '{print $3}')
  R_CR=$(echo "$RATES" | awk '{print $4}')
  COSTS=$(usage_compute_costs "$IN_T" "$OUT_T" "$CW_T" "$CR_T" "$R_IN" "$R_OUT" "$R_CW" "$R_CR")
  NON_CACHE_USD=$(echo "$COSTS" | awk '{print $1}')
  CACHE_USD=$(echo "$COSTS" | awk '{print $2}')
fi

# ─── Ledger upsert (for daily cumulative tracking) ────────────────────────
# Fire-and-forget. Any failure leaves the ledger alone for next render.
if [ -n "$SESSION_ID" ]; then
  limits_record_session "$SESSION_ID" "$TOTAL_COST_USD" "$TOTAL_TOKENS" 2>/dev/null || true
fi

# ─── Currency formatting ──────────────────────────────────────────────────
# Emit primary (first currency) as the main amount. Extras appear in parens.
fmt_amount_all() {
  local usd="$1" first=1 out=""
  local code formatted converted
  while IFS= read -r code; do
    [ -z "$code" ] && continue
    if [ "$code" = "USD" ]; then
      formatted=$(format_currency_amount "$usd" "USD")
    else
      converted=$(fx_convert_amount "$usd" "$code" 2>/dev/null || echo "")
      [ -z "$converted" ] && continue
      formatted=$(format_currency_amount "$converted" "$code")
    fi
    if [ "$first" -eq 1 ]; then
      out="$formatted"
      first=0
    else
      out="$out • $formatted"
    fi
  done <<< "$CURRENCIES"
  printf '%s' "$out"
}

COST_MAIN=$(fmt_amount_all "$TOTAL_COST_USD")

# ─── Compose output by mode ───────────────────────────────────────────────
EFFORT=$(read_effort_level)
MODEL_SEG="$MODEL_NAME"
if [ "$SHOW_EFFORT" = "true" ] && [ -n "$EFFORT" ]; then
  MODEL_SEG="$MODEL_NAME • $EFFORT"
fi

RATE_SEG=""
if [ "$SHOW_RATE" = "true" ]; then
  RATE_SEG=" | 💰 ${PLAN_PREFIX}$(pricing_format_rate "$MODEL_ID")"
fi

CACHE_SEG=""
if [ "$SHOW_CACHE_SPLIT" = "true" ] && [ -n "$CACHE_USD" ] && [ -n "$NON_CACHE_USD" ]; then
  NC_STR=$(format_currency_amount "$NON_CACHE_USD" "USD")
  C_STR=$(format_currency_amount "$CACHE_USD" "USD")
  CACHE_SEG=" ${DIM}(${NC_STR} + ${C_STR} cache)${RESET}${ANSI}"
fi

TOKENS_SEG=""
if [ "$SHOW_TOKENS" = "true" ] && [ "$TOTAL_TOKENS" -gt 0 ]; then
  TOKENS_SEG=" | $(format_tokens_segment "$IN_T" "$OUT_T" "$CW_T" "$CR_T")"
fi

# ─── Limit bars ───────────────────────────────────────────────────────────
# Rendered when any cap is configured. Daily tracked across sessions in the
# monthly ledger; session tracked from the incoming cost.
LIMITS_SEG=""
if [ "$SHOW_LIMITS" = "true" ]; then
  bars=()
  # Session USD
  if [ -n "$SESSION_USD_CAP" ] && [ "$SESSION_USD_CAP" != "0" ]; then
    pct=$(limits_pct "$TOTAL_COST_USD" "$SESSION_USD_CAP")
    bars+=("$(format_limit_bar "$pct" "$WARN_AT_PCT" "s\$")")
  fi
  # Session tokens
  if [ -n "$SESSION_TOK_CAP" ] && [ "$SESSION_TOK_CAP" != "0" ]; then
    pct=$(limits_pct "$TOTAL_TOKENS" "$SESSION_TOK_CAP")
    bars+=("$(format_limit_bar "$pct" "$WARN_AT_PCT" "s⭾")")
  fi
  # Daily USD
  if [ -n "$DAILY_USD_CAP" ] && [ "$DAILY_USD_CAP" != "0" ]; then
    DAILY_USD=$(limits_daily_total_usd)
    pct=$(limits_pct "$DAILY_USD" "$DAILY_USD_CAP")
    bars+=("$(format_limit_bar "$pct" "$WARN_AT_PCT" "d\$")")
  fi
  # Daily tokens
  if [ -n "$DAILY_TOK_CAP" ] && [ "$DAILY_TOK_CAP" != "0" ]; then
    DAILY_TOK=$(limits_daily_total_tokens)
    pct=$(limits_pct "$DAILY_TOK" "$DAILY_TOK_CAP")
    bars+=("$(format_limit_bar "$pct" "$WARN_AT_PCT" "d⭾")")
  fi
  if [ ${#bars[@]} -gt 0 ]; then
    LIMITS_SEG=" | "
    for b in "${bars[@]}"; do
      LIMITS_SEG="${LIMITS_SEG}${b} "
    done
    LIMITS_SEG="${LIMITS_SEG%% }${ANSI}"   # trim trailing space, reapply session color
  fi
fi

CWD_SEG=""
if [ "$SHOW_CWD" = "true" ] && [ -n "$CWD" ]; then
  CWD_SEG=" 📁 $(basename "$CWD")"
fi

case "$MODE" in
  minimal)
    printf '%s⏱ %s  %s%s%s%s' \
      "$ANSI" "$ELAPSED" "$PLAN_PREFIX" "$COST_MAIN" "$LIMITS_SEG" "$RESET"
    ;;
  wide)
    printf '%s[%s] ⏱ %s  %s%s%s%s%s%s%s' \
      "$ANSI" "$MODEL_SEG" "$ELAPSED" "$PLAN_PREFIX" "$COST_MAIN" \
      "$CACHE_SEG" "$TOKENS_SEG" "$RATE_SEG" "$LIMITS_SEG" "$CWD_SEG" \
      && printf '%s' "$RESET"
    ;;
  compact|*)
    printf '%s[%s] ⏱ %s  %s%s%s%s%s%s%s' \
      "$ANSI" "$MODEL_SEG" "$ELAPSED" "$PLAN_PREFIX" "$COST_MAIN" \
      "$CACHE_SEG" "$TOKENS_SEG" "$RATE_SEG" "$LIMITS_SEG" "$CWD_SEG" \
      && printf '%s' "$RESET"
    ;;
esac
