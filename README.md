<div align="center">

# claude-statusline-tokens

**A Claude Code status line for Windows that shows real numbers — percentage used, token count, and dollar cost — for your 5-hour and 7-day rate-limit windows AND your current work session, with multi-account awareness.**

```
redesign-2026 | main | Opus 4.7 | 5h 42% (1.2M, $4.50) | 7d 17% (4.8M, $18.20) | session 850k ($3.40) | ctx 23k
```

[Install](#install) · [How it works](docs/ARCHITECTURE.md) · [Pricing math](docs/PRICING.md) · [Multi-account](docs/MULTI-ACCOUNT.md) · [Customize](docs/CUSTOMIZE.md) · [Contributing](CONTRIBUTING.md)

</div>

---

## Why this exists

Claude Code can render a custom status line via a configured command, and Anthropic injects rate-limit data into the status-line hook. But that data only carries `used_percentage` and `resets_at` — **no raw token counts, and no cost**. The popular [`@owloops/claude-powerline`](https://github.com/Owloops/claude-powerline) package renders those windows as percentages only because that's all the hook gives you.

This script fills the gap by combining two data sources:

1. **Percentages** — straight from `rate_limits.five_hour.used_percentage` and `rate_limits.seven_day.used_percentage` injected into stdin. These are the same authoritative numbers Claude Code uses to throttle you.
2. **Tokens + cost** — summed locally from `~/.claude/projects/**/*.jsonl` (the transcript files Claude Code already writes to disk). Each turn carries its own `usage` block, so we re-derive activity per the rolling 5h / 7d window.

A 20-second on-disk cache keeps the render snappy without burning CPU on every keystroke.

## Features

- **Percentage + tokens + $ in one line** for both the 5h block and the 7d weekly limit
- **Session-based "current burst" indicator** that captures continuous activity regardless of clock-midnight or account switches — see [`docs/SESSION.md`](docs/SESSION.md)
- **Multi-account aware** — the 5h / 7d numbers track the account you're currently signed into; the session segment is account-independent. Account switches are detected automatically via `~/.claude.json`'s `oauthAccount.organizationUuid`. See [`docs/MULTI-ACCOUNT.md`](docs/MULTI-ACCOUNT.md)
- **Per-turn pricing** that respects whichever model that turn used — mixing Opus and Haiku in a session yields a correctly blended cost, not an Opus-rated overcharge
- **5m vs 1h ephemeral cache-write rates applied separately** when the transcript carries the breakdown (Claude Code 2.1+ does)
- **Regex-based scan** of `.jsonl` transcripts — ~10× faster than `ConvertFrom-Json` per line on a 20MB+ pile
- **20-second on-disk result cache** keyed by current account so switches auto-invalidate
- **Zero dependencies** beyond PowerShell 5.1 (ships with Windows 10/11) and `git` (for the branch name)
- **No network calls, no telemetry** — everything reads from your local `~/.claude` directory

## Install

1. Save `statusline-tokens.ps1` to `%USERPROFILE%\.claude\statusline-tokens.ps1`.
2. Add this `statusLine` block to `%USERPROFILE%\.claude\settings.json` (also at [`examples/settings.json`](examples/settings.json)):

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline-tokens.ps1\"",
       "padding": 0
     }
   }
   ```

3. Restart Claude Code (or just start a new conversation). The status line refreshes on the next prompt cycle.

> **Tip:** if `%USERPROFILE%` doesn't get expanded in your harness, use the absolute path — e.g. `C:\\Users\\you\\.claude\\statusline-tokens.ps1`.

## What you see

| Segment | Source | Color | Scope |
|---|---|---|---|
| working dir | `workspace.current_dir` from the hook JSON | orange | — |
| git branch | `git rev-parse --abbrev-ref HEAD` in that dir | tan | — |
| model | `model.display_name` from the hook JSON | purple | — |
| **5h % + tokens + $** | native `rate_limits.five_hour` for the %; transcript scan for tokens and cost | cyan | **current account** |
| **7d % + tokens + $** | native `rate_limits.seven_day` for the %; transcript scan for tokens and cost | green | **current account** |
| **session tokens + $** | contiguous activity, walking back until a 30-minute gap | gold | **every account in the burst** |
| ctx | sum of `input + cache` tokens from the last assistant turn of the current session | blue | — |

If `rate_limits` is missing for a given turn (rare; only at session start), the percentage renders as `—`. Token totals and costs always render.

> The `5h` and `7d` numbers are scoped to your **current Claude account**, so they always match the percentage Claude Code itself is showing you. The `session` number tracks your **current burst of work** independent of which account is signed in — so a mid-day account switch (or the clock crossing midnight in the middle of a coding session) doesn't fragment it. Read [`docs/SESSION.md`](docs/SESSION.md) and [`docs/MULTI-ACCOUNT.md`](docs/MULTI-ACCOUNT.md) for the full models.

## Pricing at a glance

Pricing uses Anthropic's published per-million-token rates, embedded in the script's `$prices` hashtable:

| Family | input | output | cache read | cache write 5m | cache write 1h |
|---|---|---|---|---|---|
| Opus 4.x   | $15.00 | $75.00 | $1.50 | $18.75 | $30.00 |
| Sonnet 4.x |  $3.00 | $15.00 | $0.30 |  $3.75 |  $6.00 |
| Haiku 4.x  |  $1.00 |  $5.00 | $0.10 |  $1.25 |  $2.00 |

> ⚠️ **This is API-equivalent cost, not your bill.** If you're on Claude Pro / Max / Team / Enterprise, you pay a flat monthly fee regardless of what the status line says. The dollar amount is "what an API customer would have paid to do the same work" — a useful intensity signal, not an invoice.
>
> Heavy Claude Code sessions look expensive because **96%+ of your tokens are usually cache reads** at $1.50/M — Anthropic re-bills the same conversation context on every turn, and your dollar figure is mostly those replays, not new work. The actual *fresh* tokens (input + output + cache writes) are a fraction of the total; a $400 5h window is typically ~5M new tokens and 140M cache replay.

Full pricing logic, model-family mapping, and FAQs live in **[`docs/PRICING.md`](docs/PRICING.md)**.

## How it works (in 30 seconds)

```
┌────────────┐    stdin JSON     ┌──────────────────────┐    20s cache?    ┌─────────────────┐
│ Claude Code├──────────────────▶│ statusline-tokens.ps1│─────────yes─────▶│ render from     │
└────────────┘   hook payload    │                      │                  │ cached numbers  │
                                 │                      │                  └─────────────────┘
                                 │                      │    no
                                 │                      ▼
                                 │      ┌──────────────────────────┐
                                 │      │ scan ~/.claude/projects  │
                                 │      │ **/*.jsonl (mtime < 7d)  │
                                 │      │  • dedupe by message.id  │
                                 │      │  • cost per turn's model │
                                 │      └─────────┬────────────────┘
                                 │                ▼
                                 │      ┌──────────────────────────┐
                                 │      │ render colored line,     │
                                 └──────│ persist cache JSON       │
                                        └──────────────────────────┘
```

Full walkthrough: **[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)**.

## Customize

Colors, separators, segment order, cache TTL, price overrides — all editable near the top of the script. See **[`docs/CUSTOMIZE.md`](docs/CUSTOMIZE.md)** for recipes.

## Roadmap

- [ ] **bash / zsh port** for macOS + Linux (the transcript layout is identical there)
- [ ] **`--once` mode** for sanity-checking output without piping a hook JSON
- [ ] **Today / this-month windows** with separate cost totals
- [ ] **Optional refresh-prices command** to pull from a hosted JSON instead of editing the script
- [ ] **Per-project cost breakdown** when invoked from inside a workspace

PRs welcome — see **[`CONTRIBUTING.md`](CONTRIBUTING.md)**.

## License

MIT. See [`LICENSE`](LICENSE).

## Credits

Inspired by [`@owloops/claude-powerline`](https://github.com/Owloops/claude-powerline) and [`ccusage`](https://github.com/ryoppippi/ccusage). The pricing approach (per-turn, per-model, with 5m/1h cache-write split) borrows directly from `ccusage`'s analysis of Anthropic's billing model.
