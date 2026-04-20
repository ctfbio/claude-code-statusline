#!/usr/bin/env bats
# Tests for lib/usage.sh — transcript JSONL parsing + cost computation.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export USAGE_CURSOR_DIR="$BATS_TEST_TMPDIR"
  # shellcheck source=../lib/usage.sh
  source "$ROOT/lib/usage.sh"
}

@test "usage_parse: sums tokens across turns" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
{"type":"user"}
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000}}}
{"type":"assistant","message":{"usage":{"input_tokens":800,"output_tokens":1200,"cache_creation_input_tokens":100,"cache_read_input_tokens":4500}}}
EOF
  run usage_parse "$tmp" "sid-abc"
  [ "$status" -eq 0 ]
  # Expect: 1800 1700 300 7500 0 (web_search)
  [ "$output" = "1800 1700 300 7500 0" ]
  rm -f "$tmp"
}

@test "usage_parse: incremental parsing preserves running totals" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":200,"cache_read_input_tokens":3000}}}
EOF
  run usage_parse "$tmp" "sid-inc"
  [ "$output" = "1000 500 200 3000 0" ]

  # Append a second turn — totals should accumulate.
  echo '{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":500}}}' >> "$tmp"
  run usage_parse "$tmp" "sid-inc"
  [ "$output" = "1100 550 200 3500 0" ]
  rm -f "$tmp"
}

@test "usage_parse: web_search_requests counted" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"server_tool_use":{"web_search_requests":5}}}}
{"type":"assistant","message":{"usage":{"input_tokens":200,"output_tokens":100,"server_tool_use":{"web_search_requests":2}}}}
EOF
  run usage_parse "$tmp" "sid-ws"
  [ "$output" = "300 150 0 0 7" ]
  rm -f "$tmp"
}

@test "usage_parse: transcript shrink triggers reset" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":5000,"output_tokens":2000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
  run usage_parse "$tmp" "sid-shrink"
  [ "$output" = "5000 2000 0 0 0" ]

  # Truncate transcript to nothing + write a new, smaller one.
  cat > "$tmp" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
EOF
  run usage_parse "$tmp" "sid-shrink"
  [ "$output" = "100 50 0 0 0" ]
  rm -f "$tmp"
}

@test "usage_compute_costs: opus-4-6 rates" {
  # input=1M out=1M cw=1M cr=1M @ 5/25/6.25/0.5 → non_cache = 30, cache = 6.75, total = 36.75
  run usage_compute_costs 1000000 1000000 1000000 1000000 5 25 6.25 0.5
  [ "$output" = "30.000000 6.750000 36.750000" ]
}

@test "usage_compute_costs: cache-only session" {
  # All cache reads; non_cache = 0
  run usage_compute_costs 0 0 0 2000000 5 25 6.25 0.5
  [ "$output" = "0.000000 1.000000 1.000000" ]
}

@test "usage_parse: missing transcript returns error" {
  run usage_parse "/nonexistent/path" "sid"
  [ "$status" -ne 0 ]
}
