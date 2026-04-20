#!/usr/bin/env bash
# shellcheck shell=bash
#
# install.sh — idempotent installer for claude-code-statusline.
#
# Usage:
#   bash install.sh            # install or update
#   bash install.sh --uninstall
#   bash install.sh --check    # print current state, no changes
#
# What it does:
#   1. Verifies jq and curl are on PATH (prompts to install if missing).
#   2. Merges the statusLine block into ~/.claude/settings.json. Creates
#      a timestamped backup first.
#   3. Seeds data/fx-cache.json with a first fetch if missing.
#   4. Prints next steps.
#
# Re-running is safe — changes are idempotent.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HOME/.claude/settings.json"
BACKUP="$SETTINGS.bak.$(date +%Y%m%d-%H%M%S)"

MODE="${1:-install}"

log()  { printf '\033[0;36m→\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m⚠\033[0m %s\n' "$*"; }
ok()   { printf '\033[0;32m✓\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

detect_platform() {
  case "$(uname -s)" in
    Darwin*)           echo "macos" ;;
    Linux*)            echo "linux" ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows-gitbash" ;;
    *)                 echo "unknown" ;;
  esac
}

require_tool() {
  local t=$1 install_hint=$2
  if ! command -v "$t" >/dev/null 2>&1; then
    die "Missing dependency: $t. Install with: $install_hint"
  fi
}

check_deps() {
  local platform; platform=$(detect_platform)
  case "$platform" in
    macos)           require_tool jq "brew install jq"; require_tool curl "brew install curl" ;;
    linux)           require_tool jq "sudo apt-get install jq (or equivalent)"; require_tool curl "sudo apt-get install curl" ;;
    windows-gitbash) require_tool jq "choco install jq (or download from https://jqlang.github.io/jq/)"; require_tool curl "ships with Git Bash" ;;
    *)               require_tool jq "consult your package manager"; require_tool curl "consult your package manager" ;;
  esac
  ok "Dependencies: jq + curl present."
}

merge_settings() {
  if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo "{}" > "$SETTINGS"
    ok "Created new $SETTINGS"
  else
    cp "$SETTINGS" "$BACKUP"
    ok "Backed up existing settings → $BACKUP"
  fi

  # Merge our statusLine block + default statusline config. Preserves every
  # other setting the user already has (permissions, hooks, mcp config, etc.).
  local tmp="$SETTINGS.tmp.$$"
  jq --arg cmd "bash $ROOT/statusline.sh" '
    .statusLine = {
      "type": "command",
      "command": $cmd,
      "refreshInterval": 5
    }
    | .statusline = (.statusline // {})
    | .statusline.mode = (.statusline.mode // "compact")
    | .statusline.currencies = (.statusline.currencies // ["USD"])
    | .statusline.plan = (.statusline.plan // "auto")
  ' "$SETTINGS" > "$tmp"

  if ! jq empty "$tmp" >/dev/null 2>&1; then
    die "Generated settings.json is invalid — aborting. Backup preserved at $BACKUP"
  fi
  mv "$tmp" "$SETTINGS"
  ok "Merged statusLine config into $SETTINGS"
}

seed_cache() {
  local cache="$ROOT/data/fx-cache.json"
  if [ -r "$cache" ]; then
    ok "FX cache already present."
    return 0
  fi
  log "Seeding FX cache with a first fetch…"
  # shellcheck source=lib/fx.sh
  source "$ROOT/lib/fx.sh"
  # shellcheck source=lib/gold.sh
  source "$ROOT/lib/gold.sh"
  if fx_fetch && gold_fetch_and_merge; then
    ok "FX cache seeded."
  else
    warn "FX fetch failed; cache will fill on next statusline render."
  fi
}

uninstall() {
  if [ ! -f "$SETTINGS" ]; then
    warn "No $SETTINGS to modify."
    return 0
  fi
  cp "$SETTINGS" "$BACKUP"
  local tmp="$SETTINGS.tmp.$$"
  jq 'del(.statusLine) | del(.statusline)' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  ok "Removed statusLine + statusline from $SETTINGS"
  ok "Backup at $BACKUP"
  log "Leaving $ROOT in place — delete manually if desired."
}

show_state() {
  log "Package path: $ROOT"
  log "Settings file: $SETTINGS"
  if [ -r "$SETTINGS" ]; then
    jq -r '
      "Current statusLine.command: " + (.statusLine.command // "<none>"),
      "Current statusline.mode: "    + (.statusline.mode    // "<default>"),
      "Current statusline.plan: "    + (.statusline.plan    // "<default>"),
      "Current statusline.currencies: " + ((.statusline.currencies // ["USD"]) | join(", "))
    ' "$SETTINGS"
  fi
  if [ -r "$ROOT/data/fx-cache.json" ]; then
    log "FX cache: $(jq -r '.source + " @ " + .fetched_at' "$ROOT/data/fx-cache.json")"
  else
    log "FX cache: not yet populated"
  fi
}

case "$MODE" in
  --uninstall|uninstall) uninstall ;;
  --check|check)         show_state ;;
  *)
    check_deps
    merge_settings
    seed_cache
    echo
    ok "Installation complete."
    show_state
    echo
    log "Open a new Claude Code session — the statusline should appear at the bottom."
    log "Edit $SETTINGS to customize mode / currencies / plan."
    log "Run: bash install.sh --uninstall  to revert."
    ;;
esac
