#!/usr/bin/env bash
# shellcheck shell=bash
#
# bin/refresh-pricing.sh — weekly drift check against @anthropic-ai/claude-code
#
# Run by .github/workflows/drift-check-pricing.yml. Downloads the latest
# published Claude Code CLI from npm, extracts its internal pricing table,
# and diffs against data/anthropic-pricing.json.
#
# Exit codes:
#   0  no drift
#   1  drift detected — caller should open a PR with the new table
#   2  extraction failed — caller should alert

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CURRENT="$ROOT/data/anthropic-pricing.json"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

echo "→ Fetching latest @anthropic-ai/claude-code version…"
LATEST=$(npm view @anthropic-ai/claude-code version 2>/dev/null) || {
  echo "ERROR: could not query npm" >&2
  exit 2
}
echo "  latest version: $LATEST"

CURRENT_CLI_VER=$(jq -r '.cli_version // ""' "$CURRENT" 2>/dev/null | sed 's/ .*//')
echo "  pinned version: $CURRENT_CLI_VER"

echo "→ Downloading tarball…"
cd "$TMP_DIR"
npm pack "@anthropic-ai/claude-code@$LATEST" >/dev/null 2>&1 || {
  echo "ERROR: npm pack failed" >&2
  exit 2
}
TARBALL=$(find . -maxdepth 1 -name '*.tgz' -print -quit)
tar xf "$TARBALL"
PKG_DIR=$(find . -maxdepth 2 -type d -name 'package' | head -1)
[ -z "$PKG_DIR" ] && { echo "ERROR: package dir not found"; exit 2; }

BUNDLE=$(find "$PKG_DIR" -name '*.js' -size +100k | head -1)
[ -z "$BUNDLE" ] && { echo "ERROR: bundle not found"; exit 2; }
echo "  bundle: $BUNDLE ($(wc -c < "$BUNDLE") bytes)"

echo "→ Extracting pricing table…"
# Extraction uses Node's String.prototype.match — no child_process calls.
# Each known model ID is searched for nearby inputTokens/outputTokens/
# promptCacheWriteTokens/promptCacheReadTokens numeric literals.
cat > "$TMP_DIR/extract.mjs" <<'NODE'
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[2], 'utf8');

const modelIds = [
  'claude-opus-4-6', 'claude-opus-4-5', 'claude-opus-4-1', 'claude-opus-4',
  'claude-sonnet-4-6', 'claude-sonnet-4-5', 'claude-sonnet-4',
  'claude-3-7-sonnet', 'claude-3-5-sonnet',
  'claude-haiku-4-5', 'claude-3-5-haiku'
];

const out = {};
for (const id of modelIds) {
  const pattern = new RegExp(
    `"${id}"\\s*:\\s*\\{[^}]*?inputTokens\\s*:\\s*([\\d.]+)[^}]*?outputTokens\\s*:\\s*([\\d.]+)[^}]*?promptCacheWriteTokens\\s*:\\s*([\\d.]+)[^}]*?promptCacheReadTokens\\s*:\\s*([\\d.]+)`
  );
  const m = src.match(pattern);
  if (m) {
    out[id] = {
      input: Number(m[1]),
      output: Number(m[2]),
      cache_creation_5m: Number(m[3]),
      cache_read: Number(m[4])
    };
  }
}
console.log(JSON.stringify(out, null, 2));
NODE

EXTRACTED_JSON=$(node "$TMP_DIR/extract.mjs" "$BUNDLE" 2>/dev/null || echo "{}")
FOUND_COUNT=$(printf '%s\n' "$EXTRACTED_JSON" | jq 'length' 2>/dev/null || echo 0)
echo "  extracted $FOUND_COUNT models"

if [ "$FOUND_COUNT" -lt 5 ]; then
  echo "ERROR: extraction returned too few models ($FOUND_COUNT). Bundle format may have changed." >&2
  exit 2
fi

NEW_FILE="$TMP_DIR/updated.json"
jq --argjson new "$EXTRACTED_JSON" \
   --arg ver "$LATEST" \
   --arg now "$(date -u +%Y-%m-%d)" '
     .cli_version = $ver
   | .extracted_at = $now
   | ($new | to_entries) as $pairs
   | reduce $pairs[] as $p (.; .models[$p.key].input = $p.value.input
                           | .models[$p.key].output = $p.value.output
                           | .models[$p.key].cache_creation_5m = $p.value.cache_creation_5m
                           | .models[$p.key].cache_read = $p.value.cache_read)
   ' "$CURRENT" > "$NEW_FILE"

if diff -q "$CURRENT" "$NEW_FILE" >/dev/null 2>&1; then
  echo "✓ No drift — pricing table matches upstream CLI v$LATEST."
  exit 0
fi

echo "⚠ Drift detected. Diff:"
diff -u "$CURRENT" "$NEW_FILE" || true

if [ "${CI:-}" = "true" ]; then
  cp "$NEW_FILE" "$CURRENT"
  echo "  (CI mode — updated in place; caller should commit + PR)"
fi

exit 1
