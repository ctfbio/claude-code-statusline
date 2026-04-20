#!/usr/bin/env bats
# Tests for lib/limits.sh — upsert semantics, daily aggregation, percentage math.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export LIMITS_DATA_DIR="$BATS_TEST_TMPDIR/ledger"
  mkdir -p "$LIMITS_DATA_DIR"
  export CLAUDE_SETTINGS_PATH="$BATS_TEST_TMPDIR/settings.json"
  # shellcheck source=../lib/pricing.sh
  source "$ROOT/lib/pricing.sh"
  # shellcheck source=../lib/limits.sh
  source "$ROOT/lib/limits.sh"
  # shellcheck source=../lib/format.sh
  source "$ROOT/lib/format.sh"
}

@test "limits_record_session: creates fresh ledger" {
  run limits_record_session "sid-A" "1.23" "10000"
  [ "$status" -eq 0 ]
  run limits_daily_total_usd
  [ "$output" = "1.23" ]
  run limits_daily_total_tokens
  [ "$output" = "10000" ]
}

@test "limits_record_session: upserts same session" {
  limits_record_session "sid-A" "1.00" "5000"
  limits_record_session "sid-A" "1.50" "8000"
  run limits_daily_total_usd
  # jq emits trailing zeros when sole input is a single decimal
  [ "$output" = "1.5" ] || [ "$output" = "1.50" ]
  run limits_daily_total_tokens
  [ "$output" = "8000" ]
}

@test "limits_record_session: sums multiple sessions today" {
  limits_record_session "sid-A" "1.00" "5000"
  limits_record_session "sid-B" "2.00" "10000"
  limits_record_session "sid-C" "0.50" "2500"
  run limits_daily_total_usd
  [ "$output" = "3.5" ]
  run limits_daily_total_tokens
  [ "$output" = "17500" ]
}

@test "limits_pct: basic arithmetic" {
  run limits_pct 1.5 5
  [ "$output" = "30" ]
}

@test "limits_pct: rounds to nearest" {
  # 4/6 = 66.66... → rounds to 67
  run limits_pct 4 6
  [ "$output" = "67" ]
}

@test "limits_pct: caps at 999" {
  run limits_pct 100 1
  [ "$output" = "999" ]
}

@test "limits_pct: null cap returns 0" {
  run limits_pct 10 null
  [ "$output" = "0" ]
}

@test "limits_pct: empty cap returns 0" {
  run limits_pct 10 ""
  [ "$output" = "0" ]
}

@test "limits_pct: zero cap returns 0 (avoids div-by-zero)" {
  run limits_pct 10 0
  [ "$output" = "0" ]
}

@test "limits_config_value: reads nested limits.daily.usd" {
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"statusline": {"limits": {"daily": {"usd": 50}, "warn_at_pct": 75}}}
EOF
  run limits_config_value "daily.usd"
  [ "$output" = "50" ]
}

@test "limits_config_value: reads top-level warn_at_pct" {
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"statusline": {"limits": {"warn_at_pct": 90}}}
EOF
  run limits_config_value "warn_at_pct"
  [ "$output" = "90" ]
}

@test "limits_config_value: missing key returns empty" {
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"statusline": {"limits": {}}}
EOF
  run limits_config_value "session.tokens"
  [ "$output" = "" ]
}

@test "format_limit_bar: green below warn_at_pct" {
  run format_limit_bar 50 80 "s\$"
  [[ "$output" == *"[92m"* ]]    # green
  [[ "$output" == *"50%"* ]]
}

@test "format_limit_bar: yellow at/above warn_at_pct" {
  run format_limit_bar 85 80 "s\$"
  [[ "$output" == *"[93m"* ]]    # yellow
}

@test "format_limit_bar: red at/above 100%" {
  run format_limit_bar 110 80 "d\$"
  [[ "$output" == *"[91m"* ]]    # red
  [[ "$output" == *"110%"* ]]
}

@test "format_limit_bar: 5 cells, all filled at 100%+" {
  run format_limit_bar 100 80 ""
  # Count the ▓ characters — should be 5
  filled=$(printf '%s' "$output" | grep -o "▓" | wc -l | tr -d ' ')
  [ "$filled" = "5" ]
}

@test "format_tokens_segment: formats correctly" {
  run format_tokens_segment 12000 3500 8000 45000
  # non_cache = 15500 → "15.5k", cache = 53000 → "53.0k"
  [[ "$output" == *"15.5k in"* ]]
  [[ "$output" == *"53.0k cache"* ]]
}
