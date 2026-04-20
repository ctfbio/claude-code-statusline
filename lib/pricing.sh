#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/pricing.sh — model pricing lookup + effort reader.
#
# Pricing table is data/anthropic-pricing.json, extracted from the Claude Code
# CLI's own modelCost.ts. A weekly GitHub Action re-runs the extraction against
# the newest npm release and opens a PR if numbers drift.
#
# Public functions:
#   pricing_load                    -> caches the JSON into a shell var
#   pricing_rate_for_model MODELID  -> echoes "INPUT OUTPUT CACHE_WRITE CACHE_READ" (space-separated)
#   pricing_format_rate MODELID     -> echoes "$X/$Y MTok" for the display
#   read_effort_level               -> echoes low|medium|high|xhigh (default "high" if unset)

set -o pipefail

PRICING_PATH="${PRICING_PATH:-$HOME/.claude/statusline/data/anthropic-pricing.json}"
CLAUDE_SETTINGS_PATH="${CLAUDE_SETTINGS_PATH:-$HOME/.claude/settings.json}"

# Resolve an arbitrary model string (display name or ID) to the canonical model
# key in anthropic-pricing.json. Matches against .models[*].aliases.
pricing_canonical_model() {
  local query="$1" canonical
  [ ! -r "$PRICING_PATH" ] && return 1

  # Normalise: lowercase and strip common suffixes/prefixes the CLI may tack on.
  # Some CLI display names look like "Opus 4.7" — map them heuristically.
  local norm
  norm=$(printf '%s\n' "$query" | tr '[:upper:]' '[:lower:]')
  # Specific-before-generic: "opus 4" glob matches "opus 4.7", so the 4.x
  # branches must be evaluated first.
  case "$norm" in
    *"opus 4.7"*|*"opus-4-7"*|*"opus4.7"*) echo "claude-opus-4-6"; return 0 ;;
    *"opus 4.6"*|*"opus-4-6"*|*"opus4.6"*) echo "claude-opus-4-6"; return 0 ;;
    *"opus 4.5"*|*"opus-4-5"*|*"opus4.5"*) echo "claude-opus-4-5"; return 0 ;;
    *"opus 4.1"*|*"opus-4-1"*|*"opus4.1"*) echo "claude-opus-4-1"; return 0 ;;
    *"opus 4"*|*"opus-4"*|*"opus4"*)       echo "claude-opus-4";   return 0 ;;
    *"sonnet 4.6"*|*"sonnet-4-6"*)         echo "claude-sonnet-4-6"; return 0 ;;
    *"sonnet 4.5"*|*"sonnet-4-5"*)         echo "claude-sonnet-4-5"; return 0 ;;
    *"sonnet 4"*|*"sonnet-4"*)             echo "claude-sonnet-4";   return 0 ;;
    *"3.7 sonnet"*|*"3-7-sonnet"*)         echo "claude-3-7-sonnet"; return 0 ;;
    *"3.5 sonnet"*|*"3-5-sonnet"*)         echo "claude-3-5-sonnet"; return 0 ;;
    *"haiku 4.5"*|*"haiku-4-5"*)           echo "claude-haiku-4-5";  return 0 ;;
    *"3.5 haiku"*|*"3-5-haiku"*)           echo "claude-3-5-haiku";  return 0 ;;
  esac

  # Exact alias match via jq as the fallback / primary path for API IDs.
  canonical=$(jq -r --arg q "$query" '
    .models | to_entries[] | select(.value.aliases | index($q)) | .key
  ' "$PRICING_PATH" 2>/dev/null | head -1)
  if [ -n "$canonical" ]; then
    echo "$canonical"
    return 0
  fi

  return 1
}

pricing_rate_for_model() {
  # Returns "INPUT OUTPUT CACHE_WRITE CACHE_READ" from the pricing table.
  # Falls back to default_unknown_model if nothing matches.
  local canonical
  canonical=$(pricing_canonical_model "$1" 2>/dev/null || true)
  if [ -z "$canonical" ]; then
    jq -r '[.default_unknown_model.input, .default_unknown_model.output,
             .default_unknown_model.cache_creation_5m, .default_unknown_model.cache_read] | @tsv' \
      "$PRICING_PATH" 2>/dev/null | tr '\t' ' '
    return 0
  fi
  jq -r --arg k "$canonical" '
    .models[$k] | [.input, .output, .cache_creation_5m, .cache_read] | @tsv
  ' "$PRICING_PATH" 2>/dev/null | tr '\t' ' '
}

pricing_format_rate() {
  # "$15/$75 MTok" — standard compact form.
  local rates input output
  rates=$(pricing_rate_for_model "$1")
  input=$(echo "$rates" | awk '{print $1}')
  output=$(echo "$rates" | awk '{print $2}')
  # Strip trailing .0 for cleanliness ($15 not $15.00).
  input=$(awk -v n="$input" 'BEGIN { if (n == int(n)) printf "%d", n; else printf "%.2f", n }')
  output=$(awk -v n="$output" 'BEGIN { if (n == int(n)) printf "%d", n; else printf "%.2f", n }')
  printf '$%s/$%s MTok' "$input" "$output"
}

read_effort_level() {
  # Reads effortLevel from ~/.claude/settings.json. Defaults to empty (= don't display).
  if [ ! -r "$CLAUDE_SETTINGS_PATH" ]; then
    return 0
  fi
  jq -r '.effortLevel // empty' "$CLAUDE_SETTINGS_PATH" 2>/dev/null
}

read_statusline_config() {
  # Echoes the full statusline config object from settings.json, or {} if missing.
  if [ ! -r "$CLAUDE_SETTINGS_PATH" ]; then
    printf '{}'
    return 0
  fi
  jq -c '.statusline // {}' "$CLAUDE_SETTINGS_PATH" 2>/dev/null || printf '{}'
}

# ─── Plan detection ───────────────────────────────────────────────────────
# Max / Pro plans include a generous token allowance — users do not pay per
# token. The numbers the CLI emits in `cost.total_cost_usd` are the equivalent
# pay-as-you-go API price (useful for seeing plan value, but NOT a real charge).
# When plan != "api", the statusline labels cost fields as "API-equivalent".
#
# Sources:
#   1. settings.json:statusline.plan  ("api"|"pro"|"max"|"auto"). Default "auto".
#   2. If "auto", try best-effort detection from files under ~/.claude/.
#   3. Fall back to "api" (no label) if nothing conclusive is found — the safer
#      default for people who are actually on PAYG.
resolve_plan() {
  local cfg explicit
  cfg=$(read_statusline_config)
  explicit=$(printf '%s\n' "$cfg" | jq -r '.plan // "auto"' 2>/dev/null)
  case "$explicit" in
    api|pro|max|free) printf '%s' "$explicit"; return 0 ;;
  esac

  # Auto-detection — three sources, tried in order:
  #
  # 1. macOS Keychain (claude.ai logins on macOS store credentials here, NOT
  #    in a file). Key name is "Claude Code-credentials", entry shape is
  #    { claudeAiOauth: { subscriptionType: "max"|"pro"|..., rateLimitTier: ... } }.
  # 2. ~/.claude/ JSON credential files (possible on Linux / Windows Git Bash
  #    or in older CLI versions that write to disk).
  # 3. Fallback: "api" (show raw cost, no label).
  local p

  # macOS Keychain.
  if command -v security >/dev/null 2>&1; then
    p=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null \
      | jq -r '.claudeAiOauth.subscriptionType // empty' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')
    case "$p" in
      *max*) printf 'max'; return 0 ;;
      *pro*) printf 'pro'; return 0 ;;
      *team*|*console*|*api*) printf 'api'; return 0 ;;
    esac
  fi

  # Linux libsecret (best effort — schema may differ across distros).
  if command -v secret-tool >/dev/null 2>&1; then
    p=$(secret-tool lookup service "Claude Code-credentials" 2>/dev/null \
      | jq -r '.claudeAiOauth.subscriptionType // empty' 2>/dev/null \
      | tr '[:upper:]' '[:lower:]')
    case "$p" in
      *max*) printf 'max'; return 0 ;;
      *pro*) printf 'pro'; return 0 ;;
      *team*|*console*|*api*) printf 'api'; return 0 ;;
    esac
  fi

  # File-based credentials (Git Bash / older CLI / custom installs).
  local auth_candidates=(
    "$HOME/.claude/.credentials.json"
    "$HOME/.claude/credentials.json"
    "$HOME/.claude/auth.json"
  )
  local f content
  for f in "${auth_candidates[@]}"; do
    [ -r "$f" ] || continue
    jq empty "$f" >/dev/null 2>&1 || continue
    content=$(cat "$f" 2>/dev/null)
    p=$(printf '%s\n' "$content" | jq -r '
      .claudeAiOauth.subscriptionType //
      .subscription.plan //
      .account.plan //
      .plan //
      .subscriptionType //
      empty
    ' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    case "$p" in
      *max*) printf 'max'; return 0 ;;
      *pro*) printf 'pro'; return 0 ;;
      *team*|*console*|*api*) printf 'api'; return 0 ;;
    esac
  done

  # Default: api (show raw cost, no label).
  printf 'api'
}
