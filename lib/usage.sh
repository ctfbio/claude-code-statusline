#!/usr/bin/env bash
# shellcheck shell=bash
#
# lib/usage.sh — Parse the transcript JSONL for per-tier token counts.
#
# The statusline JSON payload only exposes `cost.total_cost_usd` — it does NOT
# break cost down into cache-vs-non-cache. But the transcript JSONL (at
# `.transcript_path` in the payload) contains raw Anthropic API responses with
# a per-turn `usage` block:
#   { "usage": {
#       "input_tokens": 1234,
#       "output_tokens": 567,
#       "cache_read_input_tokens": 8901,
#       "cache_creation_input_tokens": 234,
#       "server_tool_use": { "web_search_requests": 3 }
#   }}
#
# Naive parse-every-render would re-scan a growing JSONL on every statusline
# refresh (expensive at scale — sessions can reach 5-20 MB). Instead, we store
# a per-session sidecar cursor that remembers:
#   - byte offset last parsed
#   - running totals across all turns so far
#
# On each render we read from the cursor forward, update totals, write back.
# Incremental parse is essentially free — a handful of new lines per render.
#
# Sidecar path: data/usage-cursor-<session_id>.json
#
# Public functions:
#   usage_parse TRANSCRIPT_PATH SESSION_ID
#       → echoes: INPUT_TOKENS OUTPUT_TOKENS CACHE_WRITE CACHE_READ WEB_SEARCH
#         (all cumulative for the session, space-separated)

set -o pipefail

USAGE_CURSOR_DIR="${USAGE_CURSOR_DIR:-$HOME/.claude/statusline/data}"

usage_cursor_path() {
  local sid="$1"
  # Sanitise session id to a safe filename.
  local safe
  safe=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9._-' '_')
  printf '%s/usage-cursor-%s.json\n' "$USAGE_CURSOR_DIR" "$safe"
}

usage_parse() {
  local transcript="$1" sid="$2"
  [ -z "$transcript" ] || [ ! -r "$transcript" ] && return 1
  [ -z "$sid" ] && return 1

  local cursor
  cursor=$(usage_cursor_path "$sid")
  mkdir -p "$USAGE_CURSOR_DIR"

  # Current file size (macOS BSD / GNU Linux).
  local size
  size=$(stat -f %z "$transcript" 2>/dev/null || stat -c %s "$transcript" 2>/dev/null || echo 0)

  # Read previous cursor state or initialise.
  local prev_offset=0 in_sum=0 out_sum=0 cw_sum=0 cr_sum=0 ws_sum=0
  if [ -r "$cursor" ]; then
    prev_offset=$(jq -r '.offset // 0' "$cursor" 2>/dev/null || echo 0)
    in_sum=$(jq -r '.input // 0' "$cursor" 2>/dev/null || echo 0)
    out_sum=$(jq -r '.output // 0' "$cursor" 2>/dev/null || echo 0)
    cw_sum=$(jq -r '.cache_write // 0' "$cursor" 2>/dev/null || echo 0)
    cr_sum=$(jq -r '.cache_read // 0' "$cursor" 2>/dev/null || echo 0)
    ws_sum=$(jq -r '.web_search // 0' "$cursor" 2>/dev/null || echo 0)
  fi

  # If the transcript shrunk (rotated? new session wrote over?), reset.
  if [ "$size" -lt "$prev_offset" ]; then
    prev_offset=0 in_sum=0 out_sum=0 cw_sum=0 cr_sum=0 ws_sum=0
  fi

  # Parse only the new bytes. Use tail -c for byte-offset seeking.
  if [ "$size" -gt "$prev_offset" ]; then
    local new_bytes
    new_bytes=$(( size - prev_offset ))
    # tail -c N gets the last N bytes — we want from offset to end.
    # `dd` with skip is portable but slow for big files; tail -c from end is simpler.
    local deltas
    deltas=$(tail -c "$new_bytes" "$transcript" 2>/dev/null \
      | jq -r --slurp '
          [ .[]
            | (.message.usage // .usage // {})
            | select(type == "object")
            | {
                input: (.input_tokens // 0),
                output: (.output_tokens // 0),
                cache_write: (.cache_creation_input_tokens // 0),
                cache_read: (.cache_read_input_tokens // 0),
                web_search: (.server_tool_use.web_search_requests // 0)
              }
          ]
          | reduce .[] as $x ({input:0,output:0,cache_write:0,cache_read:0,web_search:0};
              .input += $x.input | .output += $x.output |
              .cache_write += $x.cache_write | .cache_read += $x.cache_read |
              .web_search += $x.web_search)
          | [.input, .output, .cache_write, .cache_read, .web_search]
          | @tsv
        ' 2>/dev/null)
    # jq --slurp requires every line to be valid JSON. If the tail hit a
    # partial line (truncated first line after seek), reads may fail. On
    # failure, do a full re-scan from 0.
    if [ -z "$deltas" ]; then
      deltas=$(jq -r --slurp '
          [ .[]
            | (.message.usage // .usage // {})
            | select(type == "object")
            | {
                input: (.input_tokens // 0),
                output: (.output_tokens // 0),
                cache_write: (.cache_creation_input_tokens // 0),
                cache_read: (.cache_read_input_tokens // 0),
                web_search: (.server_tool_use.web_search_requests // 0)
              }
          ]
          | reduce .[] as $x ({input:0,output:0,cache_write:0,cache_read:0,web_search:0};
              .input += $x.input | .output += $x.output |
              .cache_write += $x.cache_write | .cache_read += $x.cache_read |
              .web_search += $x.web_search)
          | [.input, .output, .cache_write, .cache_read, .web_search]
          | @tsv
        ' "$transcript" 2>/dev/null)
      # Reset running totals (full rescan replaces them).
      in_sum=0 out_sum=0 cw_sum=0 cr_sum=0 ws_sum=0
    fi

    if [ -n "$deltas" ]; then
      local d_in d_out d_cw d_cr d_ws
      # shellcheck disable=SC2034
      d_in=$(echo "$deltas"  | awk '{print $1}')
      d_out=$(echo "$deltas" | awk '{print $2}')
      d_cw=$(echo "$deltas"  | awk '{print $3}')
      d_cr=$(echo "$deltas"  | awk '{print $4}')
      d_ws=$(echo "$deltas"  | awk '{print $5}')
      in_sum=$(( in_sum  + d_in  ))
      out_sum=$((out_sum + d_out ))
      cw_sum=$(( cw_sum  + d_cw  ))
      cr_sum=$(( cr_sum  + d_cr  ))
      ws_sum=$(( ws_sum  + d_ws  ))
    fi
  fi

  # Write cursor state.
  jq -n --argjson offset "$size" \
        --argjson input "$in_sum" \
        --argjson output "$out_sum" \
        --argjson cw "$cw_sum" \
        --argjson cr "$cr_sum" \
        --argjson ws "$ws_sum" \
        --arg sid "$sid" \
        '{session_id: $sid, offset: $offset, input: $input, output: $output,
          cache_write: $cw, cache_read: $cr, web_search: $ws}' \
        > "$cursor" 2>/dev/null || true

  printf '%d %d %d %d %d\n' "$in_sum" "$out_sum" "$cw_sum" "$cr_sum" "$ws_sum"
}

# Given token counts + per-million rates, compute USD costs.
# Echoes "NON_CACHE_USD CACHE_USD TOTAL_USD" as floats.
usage_compute_costs() {
  # $1 in $2 out $3 cw $4 cr | $5 rate_in $6 rate_out $7 rate_cw $8 rate_cr
  awk -v in_t="$1" -v out_t="$2" -v cw_t="$3" -v cr_t="$4" \
      -v ri="$5" -v ro="$6" -v rw="$7" -v rr="$8" \
      'BEGIN {
         non_cache = (in_t * ri + out_t * ro) / 1000000;
         cache     = (cw_t * rw + cr_t * rr) / 1000000;
         total     = non_cache + cache;
         printf "%.6f %.6f %.6f", non_cache, cache, total;
       }'
}
