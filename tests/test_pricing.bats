#!/usr/bin/env bats
# Tests for lib/pricing.sh — model lookup, effort reader, plan detection.

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  export PRICING_PATH="$ROOT/data/anthropic-pricing.json"
  export CLAUDE_SETTINGS_PATH="$BATS_TEST_TMPDIR/settings.json"
  # shellcheck source=../lib/pricing.sh
  source "$ROOT/lib/pricing.sh"
}

@test "pricing_canonical_model: exact API id" {
  run pricing_canonical_model "claude-opus-4-6-20260101"
  # Falls through to default since that exact ID isn't an alias.
  # But "claude-opus-4-6" IS an alias.
  run pricing_canonical_model "claude-opus-4-6"
  [ "$output" = "claude-opus-4-6" ]
}

@test "pricing_canonical_model: display name 'Opus 4.6'" {
  run pricing_canonical_model "Opus 4.6"
  [ "$output" = "claude-opus-4-6" ]
}

@test "pricing_canonical_model: display name 'Opus 4.7' maps to 4.6 (current latest)" {
  run pricing_canonical_model "Opus 4.7"
  [ "$output" = "claude-opus-4-6" ]
}

@test "pricing_canonical_model: 'Sonnet 4.6'" {
  run pricing_canonical_model "Sonnet 4.6"
  [ "$output" = "claude-sonnet-4-6" ]
}

@test "pricing_canonical_model: 'Haiku 4.5'" {
  run pricing_canonical_model "Haiku 4.5"
  [ "$output" = "claude-haiku-4-5" ]
}

@test "pricing_rate_for_model: opus-4-6 returns 5 25 6.25 0.5" {
  run pricing_rate_for_model "claude-opus-4-6"
  [ "$output" = "5.0 25.0 6.25 0.5" ]
}

@test "pricing_rate_for_model: sonnet-4-6 returns 3 15 3.75 0.3" {
  run pricing_rate_for_model "claude-sonnet-4-6"
  [ "$output" = "3.0 15.0 3.75 0.3" ]
}

@test "pricing_rate_for_model: unknown model falls back to default ($5/$25)" {
  run pricing_rate_for_model "claude-fictitious-99"
  [ "$output" = "5.0 25.0 6.25 0.5" ]
}

@test "pricing_format_rate: opus-4-6" {
  run pricing_format_rate "claude-opus-4-6"
  [ "$output" = "\$5/\$25 MTok" ]
}

@test "pricing_format_rate: sonnet-4-6" {
  run pricing_format_rate "claude-sonnet-4-6"
  [ "$output" = "\$3/\$15 MTok" ]
}

@test "read_effort_level: missing settings returns empty" {
  run read_effort_level
  [ "$output" = "" ]
}

@test "read_effort_level: from settings.json" {
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"effortLevel": "xhigh"}
EOF
  run read_effort_level
  [ "$output" = "xhigh" ]
}

@test "resolve_plan: respects explicit 'api' in settings" {
  # Without this explicit override, auto-detect tries the macOS Keychain /
  # Linux libsecret which may succeed on real machines but returns different
  # values per environment — not a stable CI assertion.
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"statusline": {"plan": "api"}}
EOF
  run resolve_plan
  [ "$output" = "api" ]
}

@test "resolve_plan: respects explicit 'max' in settings" {
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"statusline": {"plan": "max"}}
EOF
  run resolve_plan
  [ "$output" = "max" ]
}

@test "resolve_plan: respects explicit 'pro' in settings" {
  cat > "$CLAUDE_SETTINGS_PATH" <<'EOF'
{"statusline": {"plan": "pro"}}
EOF
  run resolve_plan
  [ "$output" = "pro" ]
}
