# Proposal: Native User Panel API for slash command config UIs

**Title for GitHub issue:**
`Proposal: Native user-panel API — let third-party slash commands render like /plugin instead of as model prompts`

**Body (copy-paste to issue):**

---

## Summary

User-defined slash commands in Claude Code are prompts to the model, not native TUI panels. When a user invokes a package's `/<name>-config` expecting the experience they get from `/plugin` — filter-as-you-type, arrow-key navigation, enter-to-toggle — they instead end up in a conversation with Claude that edits `settings.json` on their behalf.

That works, but it's the wrong shape: it burns LLM tokens on every config change, pollutes the working conversation context, and is discoverably *not* how the CLI itself feels. `/plugin` proves the right pattern already exists — this proposal is to expose that primitive to user packages.

## Background — the example that surfaced this

We built [`claude-code-statusline`](https://github.com/ctfbio/claude-code-statusline) — MIT, zero-key, production statusline with FX/gold conversion, per-MTok rate display, session + daily spending caps. 52 tests, shellchecked, cross-platform (macOS / Linux / Git Bash on Windows).

Config today: `/statusline-config` (model-mediated, ~2-5k tokens per change), optional `fzf`-based TUI, or direct `settings.json` editing. The model-mediated path was the first thing users reached for — and the first thing they complained about. Quote: *"I want this as a markdown menu like when I browse for plugins, not an interactive conversation with you."*

## Proposal

A package ships a manifest declaring its config schema. Claude Code renders that schema as a TUI panel identical in UX to `/plugin`.

```yaml
# ~/.claude/statusline/claude-panel.yml
name: statusline-config
description: Configure the claude-code-statusline package
schema:
  - key: mode
    type: enum
    values: [minimal, compact, wide]
    target: .statusline.mode
  - key: currencies
    type: ordered-multiselect
    values_from: jq -r '.currencies | keys[]' ~/.claude/statusline/data/currencies.json
    target: .statusline.currencies
  - key: limits.daily.usd
    type: number-or-null
    target: .statusline.limits.daily.usd
  - key: limits.warn_at_pct
    type: percentage
    target: .statusline.limits.warn_at_pct
preview:
  type: shell
  command: bash ~/.claude/statusline/statusline.sh
  stdin_template: |
    {"session_id":"preview","model":{"display_name":"Opus 4.7"},"cost":{...}}
```

Rendered panel:

```
┌─ statusline-config ────────────────────────── filter: ___ ─┐
│ > mode ............................. wide                  │
│   currencies ....................... [USD, JPY, EUR, XAU]  │
│   plan ............................. auto                  │
│   limits.daily.usd ................. 50.00                 │
│   limits.session.usd ............... (not set)             │
│   limits.warn_at_pct ............... 80                    │
│                                                            │
│ [preview]                                                  │
│   [Opus 4.7 • high] ⏱ 1h02m  $0.51 • ¥82 • €0.43 …        │
│                                                            │
│   ↑↓ navigate   ↵ edit   / filter   q quit                 │
└────────────────────────────────────────────────────────────┘
```

Enter on a row → second-level picker (enum values / numeric input / multiselect). Preview auto-refreshes. Writes go through the CLI's existing `settings.json` merge logic.

## Why this matters

1. **Token-waste elimination.** Config changes today cost 2-5k tokens each via model-mediated commands. Native panel = zero tokens.
2. **Platform parity.** `/plugin` has this UX. Nothing else does. Every third-party package has to pick between "reinvent TUI with fzf" or "live with the conversation-shaped config flow."
3. **Discoverability.** First-time users don't know what keys exist. A filter-as-you-type list solves that the way VS Code's Settings UI does.
4. **Ecosystem signal.** Claude Code is already a platform (plugins, MCP servers, hooks). A user-panel API turns config into one more first-class extension surface.

## Minimal viable implementation

Looking at what `/plugin` already does internally:

1. **Manifest spec** — YAML/JSON with types: `enum`, `number`, `number-or-null`, `boolean`, `string`, `ordered-multiselect`, `percentage`. Each row has a `target` jq-path into `settings.json`.
2. **TUI renderer** — reuse whatever backs `/plugin`. The layout is the same primitive.
3. **Preview hook** — shell command with stdin template. Re-runs on value change, output displayed in a pane below the list.
4. **Config writer** — already exists in the CLI.

The CLI owns rendering + writing. The package owns the schema + preview command. Clean separation.

## Fallback (what packages do today, for reference)

1. `fzf`-based TUI via `!` shell escape — closest to the target UX, but requires `fzf` installed.
2. Per-key quick commands with `$ARGUMENTS` — good for muscle memory, bad for discovery.
3. Model-mediated dialog — works everywhere, but wrong shape.

None of these compose into one consistent surface. The native panel would.

---

**Full rationale + worked-example package:** [claude-code-statusline/DESIGN.md § Native /statusline-config panel](https://github.com/ctfbio/claude-code-statusline/blob/main/DESIGN.md#native-statusline-config-panel--the-ideal-ux)

*Filed by a team who built a statusline package and watched the first user ask for exactly this UX.*
