#!/usr/bin/env bats
# Tests for lib/format.sh — duration, colors, currency formatting.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export CURRENCIES_PATH="$ROOT/data/currencies.json"
  # shellcheck source=../lib/format.sh
  source "$ROOT/lib/format.sh"
}

@test "format_duration_ms: sub-minute shows seconds" {
  run format_duration_ms 42000
  [ "$status" -eq 0 ]
  [ "$output" = "42s" ]
}

@test "format_duration_ms: minutes + seconds" {
  run format_duration_ms 125000
  [ "$status" -eq 0 ]
  [ "$output" = "2m05s" ]
}

@test "format_duration_ms: hours + minutes" {
  run format_duration_ms 3725000
  [ "$status" -eq 0 ]
  [ "$output" = "1h02m" ]
}

@test "format_ansi_for_color: known colors emit ANSI" {
  run format_ansi_for_color orange
  [ "$output" = $'\033[38;5;208m' ]
}

@test "format_ansi_for_color: unknown color emits empty" {
  run format_ansi_for_color unknown_color
  [ "$output" = "" ]
}

@test "format_currency_amount: USD prefixes \$" {
  run format_currency_amount 1.46 USD
  [ "$output" = "\$1.46" ]
}

@test "format_currency_amount: JPY has zero decimals" {
  run format_currency_amount 232.17 JPY
  [ "$output" = "¥232" ]
}

@test "format_currency_amount: XAU uses oz suffix + 4 decimals" {
  run format_currency_amount 0.00042 XAU
  [ "$output" = "0.0004 oz" ]
}

@test "format_plan_prefix: api plan emits nothing" {
  run format_plan_prefix api
  [ "$output" = "" ]
}

@test "format_plan_prefix: max plan emits API-eq marker" {
  run format_plan_prefix max
  [[ "$output" == *"API≡"* ]]
}

@test "format_plan_prefix: pro plan emits API-eq marker" {
  run format_plan_prefix pro
  [[ "$output" == *"API≡"* ]]
}

@test "format_read_session_color: last-wins from transcript" {
  tmp=$(mktemp)
  cat > "$tmp" <<'EOF'
{"type":"agent-color","agentColor":"blue","sessionId":"x"}
{"type":"user"}
{"type":"agent-color","agentColor":"orange","sessionId":"x"}
EOF
  run format_read_session_color "$tmp"
  [ "$output" = "orange" ]
  rm -f "$tmp"
}

@test "format_read_session_color: empty transcript returns empty" {
  run format_read_session_color "/nonexistent"
  [ "$output" = "" ]
}
