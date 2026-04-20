# Design — claude-code-statusline

**Status:** Reference implementation. Pitch candidate for upstream Claude Code.
**License:** MIT.
**Scope:** A replacement for the default statusline that every Claude Code power user ends up wanting — session duration, effort level, cost in their currency, per-token rate, `/color` integration.

## Why this exists

The statusline JSON that Claude Code pipes to a user's bash script already contains the raw data for a great display (`cost.total_duration_ms`, `cost.total_cost_usd`, `model.display_name`, `transcript_path`, etc.) — but Anthropic's stock statusline doesn't surface it. Every serious user ends up writing their own, and every one of those forks re-solves the same subproblems: color detection, pricing lookup, currency conversion, cross-platform path handling.

This package is what that convergence looks like if it's done once, professionally, and shipped under MIT.

## Design principles

1. **Zero render-path network.** The statusline runs on every refresh (often every few seconds). Any synchronous HTTP call here degrades the UX of the entire CLI. All network lives in background refresh jobs; the render path reads cached JSON only.
2. **Authoritative pricing, not memorized pricing.** The pricing table is extracted from the Claude Code CLI's own `modelCost.ts` — the literal numbers the CLI uses to compute `cost.total_cost_usd`. A weekly drift-check Action re-runs the extraction against the newest npm release and opens a PR if anything moved.
3. **Bank-grade FX.** The European Central Bank's daily reference rates are the de-facto source of truth for FX in European fintech. Frankfurter is a thin MIT-licensed proxy over the ECB XML. Both are cited, both are included as primary + fallback.
4. **No API keys.** A package that requires users to sign up somewhere before their statusline works is dead on arrival. Frankfurter, ECB XML, and gold-api.com all work without keys.
5. **Cross-platform by construction.** Pure POSIX-compatible bash + `jq` + `curl`. Tested on macOS, Linux, and Git Bash on Windows. No Node, Python, or compiled binaries.
6. **Respects `/color`.** Reading the transcript JSONL for the last `agent-color` entry is how the CLI itself persists user color preference; we read the same entry.

## Architecture

### Render path (hot)
```
Claude Code pipes JSON → statusline.sh
  → sources lib/*.sh
  → reads ~/.claude/settings.json for mode + currencies
  → reads data/fx-cache.json (may be stale)
  → reads data/anthropic-pricing.json
  → reads transcript JSONL tail for agent-color
  → emits one line of ANSI-colored text
  → if cache stale: spawns background refresh, returns immediately
```

### Background refresh (cold)
```
Spawned detached from statusline.sh OR triggered by GitHub Action
  → fetch Frankfurter USD base (30 currencies)
  → fetch gold-api.com for XAU
  → atomically replace data/fx-cache.json
  → update timestamp, signal done
```

### Drift detection (cron)
```
Weekly GitHub Action
  → npm view @anthropic-ai/claude-code version → compare to last known
  → if changed: download tarball, regex the pricing table
  → diff against data/anthropic-pricing.json
  → open PR with the diff (human review before merge)
```

## Data contracts

### `data/anthropic-pricing.json`
See file. Schema: `{models: {<canonical-id>: {input, output, cache_creation_5m, cache_read, aliases[]}}}`. Unit is USD per million tokens. Extracted once from source; updated by drift-check workflow.

### `data/currencies.json`
Per-ISO-4217-code: display symbol, decimal places, full name. Used for formatting only — not a pricing source.

### `data/fx-cache.json`
Auto-generated. Schema:
```json
{
  "base": "USD",
  "fetched_at": "2026-04-19T16:05:00Z",
  "source": "frankfurter.dev",
  "rates": { "EUR": 0.92, "JPY": 152.3, "CNY": 7.25, "XAU": 0.00042, ... }
}
```
`XAU` is the inverse of the USD-per-ounce spot from gold-api.com, matching the convention of all other rates (how much of this currency equals 1 USD). Gitignored.

### `~/.claude/settings.json` `statusline` block
Top-level key alongside Anthropic's existing `statusLine`. Fields in README. Defaults applied in `statusline.sh` when keys are missing.

## Display modes

| Mode | Example |
|---|---|
| `minimal` | `⏱ 1h02m  $1.46` |
| `compact` (default) | `[Opus 4.7 • high] ⏱ 1h02m  $1.46  📁 .claude` |
| `wide` | `[Opus 4.7 • high] ⏱ 1h02m  $1.46 (¥222 • €1.34) \| 💰 $15/$75 MTok \| 📁 .claude` |

## Extensibility

- **New currencies:** add to `data/currencies.json`. If the ECB covers it, Frankfurter returns it automatically. If not, implement a `lib/<source>.sh` following the `lib/gold.sh` pattern and hook it into `fx_fetch_all`.
- **Other LLM providers:** extend `data/anthropic-pricing.json` to a `data/pricing.json` with top-level provider keys. `lib/pricing.sh` already resolves by model ID — it just needs to search across providers.
- **New display modes:** add a `format_<name>` function in `lib/format.sh` and a case branch in `statusline.sh`.

## Spending limits — architecture

The statusline displays two kinds of limits: **per-session** (reset when a new conversation starts) and **daily cumulative** (summed across every session that rendered today). Both use the same tiny ledger.

**Ledger:** one JSON file per month at `data/spending-YYYY-MM.json`.
```json
{
  "month": "2026-04",
  "sessions": {
    "<session_id>": {
      "cost_usd":     1.46,
      "total_tokens": 68500,
      "first_seen":   "ISO-8601",
      "last_updated": "ISO-8601"
    }
  }
}
```

**Zero-hook design.** On every statusline render, `limits_record_session` upserts the current session's cost into the ledger. Because Claude Code renders the statusline on every turn AND on a `refreshInterval` timer (default 5s), the ledger converges to each session's final value naturally — no `SessionEnd` hook plumbing required. Atomic writes (tmp file → mv) protect against crashes.

**Daily total = sum over entries where `date(last_updated) == today`.** Month rollover is implicit: a new file is created at the start of each UTC month. Old files stay on disk for audit; a cleanup script (TODO, tracked in `bin/archive-ledgers.sh` as future work) can prune files older than N months.

**Color thresholds.** Progress bars graduate green → yellow at `warn_at_pct` (default 80) → red at 100%+. Bars use Unicode block characters (`▓░`) for clean rendering in any terminal.

**Sub-agent accounting.** Sub-agents invoke `subagentStatusLine`, not `statusLine`, so they don't write to this ledger by default. If a user wants sub-agent cost rolled up, they can point their `subagentStatusLine.command` at this package too — the upsert is session-keyed, so different sub-agent IDs get separate rows, all summed by the daily query.

## Phase 2 — Portkey integration (deferred)

Enterprise users running Claude Code behind a [Portkey](https://portkey.ai) AI gateway want their statusline to reflect the **authoritative** server-side quota tracked by Portkey, not a locally-computed approximation. This is Phase 2.

**Integration design (to implement):**

- Config schema:
  ```json
  "limits": {
    "portkey": {
      "enabled": true,
      "virtual_key": "<Portkey virtual key>",
      "api_key_env": "PORTKEY_API_KEY",
      "budget_name": "claude-code-daily",
      "ttl_seconds": 300
    }
  }
  ```
- New `lib/portkey.sh`: wraps `GET https://api.portkey.ai/v1/analytics/usage?virtual_key=<vk>&window=day` with a 5-minute cache in `data/portkey-cache.json`.
- Statusline rendering precedence: if Portkey is enabled AND cache is fresh, show `PKY ▓▓▓░░ 62%` (with a dedicated prefix so the user knows it's authoritative). Fall back to local ledger on Portkey network failure.
- Secrets handling: API key read from env var at render time (never written to disk); the virtual key is public-ish metadata.
- Caveats documented: Portkey aggregates per Virtual Key, not per session, so session-level caps stay local-computed.

Why Phase 2: we want the local-first pattern (Portkey-free) to be rock-solid before layering in an external-service dependency. The hooks are in place (`lib/limits.sh` exposes a clean interface); adding Portkey is a self-contained module plus a render-path branch.

## Limitations (honest list)

1. **ARS (Argentine peso) not covered.** The ECB reference set doesn't include ARS. The only free no-key API that does (open.er-api.com) forbids redistribution in its ToS. To support ARS, a contributor would need to add a `lib/bcra.sh` that scrapes the Banco Central de la República Argentina public endpoint — doable, opt-in, documented as Phase 2.
2. **Gold is not LBMA-authoritative.** The London Bullion Market Association fix is ICE-licensed and not redistributable. gold-api.com aggregates spot from multiple sources; accurate to a few basis points but not the official daily fix.
3. **Pricing drift lag.** The weekly Action picks up Anthropic pricing changes within 7 days. Faster lag would require either a webhook from Anthropic (doesn't exist) or scraping the pricing marketing page (fragile).
4. **Effort level is global, not per-session.** `~/.claude/settings.json` `effortLevel` is the only persisted form. If a user changes effort mid-session via `/effort` (if that command exists/is added), the statusline would only notice after the global setting changes.
5. **Ledger grows unbounded within a month.** Every unique session_id creates a row. A heavy user with dozens of Claude Code sessions per day will see `data/spending-YYYY-MM.json` reach a few KB; not a concern, but an archive script is a tracked Phase 2 item.
6. **Local ledger vs. truth.** When a Portkey (or other gateway) quota is the source of truth, the local ledger can drift if sub-agents or alternate clients consume tokens outside Claude Code. Phase 2 Portkey integration resolves this by reading authoritative server-side numbers.

## Upstream pitch

If Anthropic adopts this:
- Bundle as an opt-in statusline template users can select via `claude config statusline --template observability`.
- Ship pricing updates in the CLI release itself, eliminating the drift Action.
- Replace gold-api.com with LBMA data if Anthropic has an LBMA license.
- Expose effort level + rate in the statusline JSON payload natively.

### Native `/statusline-config` panel — the ideal UX

**The observation.** During the development of this package, a real user reaction surfaced a gap in Claude Code's extension surface: user-defined slash commands are *prompts to the model*, not native UI panels. When a user types `/statusline-config` expecting the same interaction pattern as `/plugin` — a filterable list, arrow-key navigation, enter-to-select — what they get instead is a conversation with the assistant. That conversation works but is the wrong shape: it burns LLM tokens on every config change, pollutes the conversation context with config-flow chatter, and doesn't feel like the CLI itself.

**The gap.** Claude Code today has one native, model-less configuration surface users love: the plugin browser (`/plugin`). Users see a scrollable list of plugins with current-state annotations, type to filter, enter to toggle, no prompt sent to the model. This pattern exists for plugins. It doesn't exist for any other kind of user-extensible configuration.

**The proposal.** Extend the same pattern to user-defined config surfaces. Specifically: a **Native User Panel API** that lets a package author declare a structured schema and register a `/<name>` entry point that renders as a TUI panel, not a prompt.

Concretely, the package could ship a manifest like:

```yaml
# ~/.claude/statusline/claude-panel.yml
name: statusline-config
description: Configure the claude-code-statusline package
schema:
  - key: mode
    type: enum
    values: [minimal, compact, wide]
    current: .statusline.mode
    target:  .statusline.mode
  - key: currencies
    type: ordered-multiselect
    values: $(jq -r '.currencies | keys[]' ~/.claude/statusline/data/currencies.json)
    current: .statusline.currencies
    target:  .statusline.currencies
  - key: limits.daily.usd
    type: number-or-null
    current: .statusline.limits.daily.usd
    target:  .statusline.limits.daily.usd
  - key: limits.warn_at_pct
    type: percentage
    range: [0, 100]
    current: .statusline.limits.warn_at_pct
    target:  .statusline.limits.warn_at_pct
preview:
  type: shell
  command: bash ~/.claude/statusline/statusline.sh
  stdin_template: |
    {"session_id":"preview","model":{"display_name":"Opus 4.7"},"cost":{"total_duration_ms":3725000,"total_cost_usd":0.5123},...}
```

Claude Code, given that manifest, would render a panel just like `/plugin`:

```
┌─ statusline-config ────────────────────────────────── filter: ___ ─┐
│ > mode ............................. wide                          │
│   currencies ....................... [USD, JPY, EUR, XAU]          │
│   plan ............................. auto                          │
│   show_effort ...................... true                          │
│   limits.daily.usd ................. 50.00                         │
│   limits.session.usd ............... (not set)                     │
│   limits.warn_at_pct ............... 80                            │
│                                                                    │
│ [preview]                                                          │
│   [Opus 4.7 • high] ⏱ 1h02m  $0.51 • ¥82 • €0.43 • 0.0001 oz …    │
│                                                                    │
│   ↑↓ navigate   ↵ edit   / filter   q quit                         │
└────────────────────────────────────────────────────────────────────┘
```

On enter: a second-level panel shows valid values (enum) or an inline numeric editor. The preview pane auto-refreshes as values change. Writes go back to `~/.claude/settings.json` through the CLI's own config writer.

**Why Anthropic should want this.** The `/plugin` panel is already a compelling pattern that turns a dozen CLI flags into a single discoverable surface. Extending it to *any* well-typed user config would:

1. Let third-party Claude Code packages ship first-class config UX without reinventing TUI primitives (fzf / dialog / whiptail / custom).
2. Kill an entire class of LLM-token-waste: "please set my currency to JPY" → today, 1-3k tokens. With the panel: 0 tokens.
3. Solidify Claude Code's position as a *platform* for developer tools, not just a CLI. The MCP server + plugins + now native config panels together form a coherent extension story.
4. Give first-time users a discoverable path into deep configuration — the same reason VS Code's Settings UI exists alongside its `settings.json`.

**Minimal viable surface.** Claude Code only needs to implement:
- A manifest spec (enum / ordered-multiselect / number / boolean / free-text, plus a `target` jq-path)
- A TUI renderer (the same library backing `/plugin`)
- A preview hook (shell command with stdin template substitution)
- Config writer that respects `~/.claude/settings.json` merge semantics

Everything else — what keys exist, what values are valid, what the preview looks like — is owned by the package author's manifest. Zero schema maintenance burden on Anthropic.

**Fallback — what this package does today.** Until such an API exists, `claude-code-statusline` ships three config paths (in preference order): (1) `bin/config-tui.sh` — an `fzf`-based TUI that approximates the panel experience with zero model involvement; (2) per-key quick commands (`/statusline-mode`, `/statusline-add-currency`) using `$ARGUMENTS` for muscle-memory workflows; (3) `/statusline-config` as a model-mediated dialog for discovery. All three reduce to the same `jq` edits against `~/.claude/settings.json`. The native panel would collapse all three into one consistent surface.

## Attribution

- European Central Bank reference rates — public domain / ESCB reuse policy. Attribution string included in `LICENSE`.
- Frankfurter — MIT, Lineofflight. https://github.com/lineofflight/frankfurter
- Anthropic Claude Code source — pricing table extracted under fair-use reference; no source code redistributed.
