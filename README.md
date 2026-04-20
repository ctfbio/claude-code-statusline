# claude-code-statusline

A professional-grade statusline for [Claude Code](https://claude.com/claude-code) that surfaces the information a power user actually wants — elapsed session time, effort level, real-time cost in your preferred currency, and the per-token rate Claude Code is billing you. Cross-platform (macOS / Linux / Git Bash on Windows), zero runtime network calls, and colored to match `/color` automatically.

```
[Opus 4.7 • high] ⏱ 1h02m  $1.46 (¥10.62 • €1.34) | 💰 $15/$75 MTok | 📁 my-project
```

## Features

- **Session duration** — wall-clock since session start, ticks live through `/loop` and autonomous iterations.
- **Effort level** — reads `effortLevel` from `~/.claude/settings.json`, shown next to the model name.
- **Live cost** — the same `cost.total_cost_usd` Claude Code bills you, displayed in any number of currencies.
- **Per-token rate** — the `$in/$out per million tokens` rate for the active model, sourced from the Claude Code CLI's own pricing table.
- **Currency conversion** — USD base with live daily refresh from the European Central Bank via [Frankfurter](https://frankfurter.dev) (MIT, bank-grade). Supports 30+ fiat currencies plus gold (XAU). Fully offline-capable via 24h cache.
- **Session color** — automatically matches whatever color you've set with `/color`. Reads the transcript JSONL directly — no polling, no extra state.
- **Cross-machine** — single package synced via your existing dotfiles setup.

## Installation

```bash
git clone https://github.com/<you>/claude-code-statusline ~/.claude/statusline
~/.claude/statusline/install.sh
```

That's it. The installer:
1. Checks for `jq` and `curl` (prompts to install if missing).
2. Merges a `statusLine` block into `~/.claude/settings.json`.
3. Adds a default `statusline` config key with `currencies: ["USD"]`.
4. Seeds the FX cache with a first fetch.

Open a new Claude Code session and you'll see the new line at the bottom.

## Configuration (`~/.claude/settings.json`)

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline/statusline.sh",
    "refreshInterval": 5
  },
  "statusline": {
    "mode": "compact",
    "currencies": ["USD", "JPY", "EUR"],
    "plan": "auto",
    "show_effort": true,
    "show_rate": true,
    "show_cwd": true,
    "show_tokens": true,
    "show_cache_split": true,
    "limits": {
      "session": { "usd": 5.00, "tokens": null },
      "daily":   { "usd": 50.00, "tokens": null },
      "warn_at_pct": 80
    }
  }
}
```

| Key | Values | Default |
|---|---|---|
| `mode` | `minimal`, `compact`, `wide` | `compact` |
| `currencies` | Array of ISO 4217 codes (plus `XAU` for gold). Order preserved. | `["USD"]` |
| `plan` | `api`, `pro`, `max`, `auto` — controls the `API≡` label on cost | `auto` |
| `show_effort` | Show effort level next to model | `true` |
| `show_rate` | Show `$in/$out MTok` | `true` in `wide`, `false` elsewhere |
| `show_cwd` | Show current directory basename | `true` |
| `show_tokens` | Show `📊 X in + Y cache` segment | `true` in `wide`, `false` elsewhere |
| `show_cache_split` | Show `($X + $Y cache)` breakdown of cost | `true` in `compact`/`wide` |
| `limits.session.usd` | Hard cap for this session (number or `null`) | `null` |
| `limits.session.tokens` | Token cap for this session | `null` |
| `limits.daily.usd` | Hard cap summed across today's sessions | `null` |
| `limits.daily.tokens` | Token cap summed across today's sessions | `null` |
| `limits.warn_at_pct` | % at which progress bar turns yellow (red at 100%) | `80` |

**Interactive config:** run `/statusline-config` to walk through changes without editing JSON by hand.

### Spending limits

When any `limits.*` cap is set, a progress bar segment appears:

```
… | ▓▓▓░░ 73%s$ ▓▓▓▓░ 91%d$ | …
```

Suffixes: `s$` = session USD, `d$` = daily USD, `s⭾` = session tokens, `d⭾` = daily tokens.
Colors: **green** below `warn_at_pct`, **yellow** at/above it, **red** at 100%+.

Daily totals aggregate across all sessions that rendered today — they persist in `data/spending-YYYY-MM.json` and survive CLI restarts. The ledger is upserted on every render; no hooks required.

### Supported currencies

30 fiat currencies from the ECB reference set: **USD, EUR, CNY, JPY, GBP, CHF, CAD, AUD, NZD, KRW, HKD, SGD, INR, BRL, MXN, ZAR, SEK, NOK, DKK, PLN, CZK, HUF, TRY, THB, PHP, MYR, IDR, ILS, RON, BGN, ISK** — plus **XAU** (gold, troy ounce, non-LBMA).

ARS (Argentine peso) is not in the ECB set. See `DESIGN.md` § Limitations.

## Architecture

```
statusline.sh          # entry point — reads stdin, sources lib/*, emits line
lib/
  fx.sh                # Frankfurter → ECB XML fallback, 24h cache
  gold.sh              # gold-api.com for XAU
  pricing.sh           # model → $/MTok lookup, effort reader
  format.sh            # ANSI colors, layout modes, duration formatter
data/
  anthropic-pricing.json   # extracted from Claude Code source; drift-checked weekly
  currencies.json          # names, symbols, decimal places
  fx-cache.json            # auto-written, gitignored
bin/
  refresh-pricing.sh   # diffs upstream Claude Code pricing; used by Action
.github/workflows/
  refresh-fx.yml       # daily cron, commits data/fx-cache.json
  drift-check-pricing.yml   # weekly, opens PR on pricing drift
  ci.yml               # shellcheck + bats on every PR
tests/                 # bats unit tests
install.sh             # idempotent installer
LICENSE                # MIT
DESIGN.md              # architecture, rationale, pitch notes
```

## Data sources

| Source | Use | License |
|---|---|---|
| [European Central Bank](https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml) | FX primary via Frankfurter | ESCB reuse (attribution required — included in LICENSE) |
| [Frankfurter](https://frankfurter.dev) | ECB proxy, JSON, no key | MIT |
| [gold-api.com](https://gold-api.com) | XAU spot | No key, unrestricted |
| [@anthropic-ai/claude-code](https://www.npmjs.com/package/@anthropic-ai/claude-code) | Source of truth for pricing | Anthropic |

Zero API keys. Zero secrets in git. Zero runtime network calls on the render path (background refresh only).

## Development

```bash
cd ~/.claude/statusline
shellcheck **/*.sh                  # lint
bats tests/                         # unit tests
./install.sh --dev                  # install with symlinks instead of copies
```

## Contributing / pitching to Anthropic

This package is MIT-licensed and designed as a reference implementation of the statusline feature Claude Code ships. The `DESIGN.md` file is the pitch doc — it frames the rationale behind each decision and the extensibility model.

Contributions welcome. See `DESIGN.md` § Extensibility for how to add currencies, model providers, or display modes.
