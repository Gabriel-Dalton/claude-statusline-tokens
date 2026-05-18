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

**Requirements:** Windows 10 or 11, Windows PowerShell 5.1 (preinstalled), Claude Code already set up. No npm, no pip, no extra modules.

Pick the path that fits you. The fast path is for people comfortable editing JSON; the guided path holds your hand and tells you exactly what to do if something goes wrong.

### Fast path (30 seconds, for AI/dev engineers)

From a PowerShell prompt:

```powershell
# 1. Download the script straight into Claude Code's config dir
Invoke-WebRequest `
  -Uri https://raw.githubusercontent.com/Gabriel-Dalton/claude-statusline-tokens/main/statusline-tokens.ps1 `
  -OutFile "$env:USERPROFILE\.claude\statusline-tokens.ps1"

# 2. Open settings.json and add the statusLine block shown below
notepad "$env:USERPROFILE\.claude\settings.json"
```

The block to **merge** into `settings.json` (if the file already has other keys, add this alongside them — don't replace the whole file):

```json
{
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline-tokens.ps1\"",
    "padding": 0
  }
}
```

Save, start a new Claude Code conversation, done. The script never touches the network and only reads files under `~/.claude`.

> The repo ships a ready-to-copy version at [`examples/settings.json`](examples/settings.json).

### Guided path (5 minutes, for first-time Claude Code users)

If you've never customized Claude Code before, follow these steps in order. Every step is verifiable so you'll know if it worked before moving on.

**Step 1 — Open PowerShell.**

Press `Win + R`, type `powershell`, hit Enter. A blue (or black) window appears with a prompt like `PS C:\Users\You>`.

**Step 2 — Confirm Claude Code is installed and has been used at least once.**

```powershell
Test-Path "$env:USERPROFILE\.claude"
```

This must print `True`. If it prints `False`, install Claude Code first and run one conversation — it creates the `.claude` folder on first launch.

**Step 3 — Download the script.**

```powershell
Invoke-WebRequest `
  -Uri https://raw.githubusercontent.com/Gabriel-Dalton/claude-statusline-tokens/main/statusline-tokens.ps1 `
  -OutFile "$env:USERPROFILE\.claude\statusline-tokens.ps1"
```

Verify it landed:

```powershell
Test-Path "$env:USERPROFILE\.claude\statusline-tokens.ps1"   # → True
```

> No internet, or behind a corporate proxy? Download the file from the [GitHub repo](https://github.com/Gabriel-Dalton/claude-statusline-tokens/blob/main/statusline-tokens.ps1) in your browser via the **"Download raw file"** button, then drag it into `C:\Users\<you>\.claude\`. Make sure the resulting file is named exactly `statusline-tokens.ps1` (no `.txt` suffix — Windows sometimes adds one).

**Step 4 — Open `settings.json` in Notepad.**

```powershell
notepad "$env:USERPROFILE\.claude\settings.json"
```

If the file doesn't exist yet, Notepad will offer to create it — click Yes and start with `{}` as the contents.

**Step 5 — Add the `statusLine` block.**

Inside the outermost `{ ... }` of `settings.json`, add this key (merging — don't delete what's already there):

```json
"statusLine": {
  "type": "command",
  "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline-tokens.ps1\"",
  "padding": 0
}
```

If `settings.json` was empty (`{}`), the whole file should now look like the [`examples/settings.json`](examples/settings.json) snippet in this repo. If it already had keys, the file should look like:

```json
{
  "theme": "dark",
  "statusLine": {
    "type": "command",
    "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline-tokens.ps1\"",
    "padding": 0
  }
}
```

(Note the comma after every key except the last one — that's JSON's only formatting rule.)

Save the file (`Ctrl + S`) and close Notepad.

**Step 6 — Sanity-check the JSON is valid.**

```powershell
Get-Content -Raw "$env:USERPROFILE\.claude\settings.json" | ConvertFrom-Json | Out-Null
```

No output = valid JSON. If you see a red `ConvertFrom-Json` error, you have a typo — a missing comma or a stray quote. Open the file in Notepad, compare it to the example above, fix, retry. Claude Code itself will refuse to load malformed JSON, so it's worth catching here.

**Step 7 — Smoke-test the script.**

Run it once with a fake hook payload to confirm PowerShell can execute it:

```powershell
$j = '{"workspace":{"current_dir":"."},"model":{"display_name":"Opus 4.7"},"rate_limits":{"five_hour":{"used_percentage":42},"seven_day":{"used_percentage":17}}}'
$j | powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\statusline-tokens.ps1"
```

You should see a colored status line print to your terminal. If you get a permission error, see *Troubleshooting* below.

**Step 8 — Launch Claude Code.**

Open Claude Code (close any existing window first). The status line appears below the prompt on the next turn. If it doesn't show up, see *Troubleshooting*.

### Troubleshooting

<details>
<summary><strong>"Running scripts is disabled on this system"</strong></summary>

PowerShell's execution policy is blocking the script. Two fixes:

- **Just for this script** — the `-ExecutionPolicy Bypass` flag in the `command` line already handles this when Claude Code launches it. If you saw this when running the smoke-test command in Step 7, you can ignore the warning — Claude Code will succeed because the flag is present in the configured command.
- **Permanently for your user** — `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`. This is the Microsoft-recommended setting and is safe.

Do **not** run `Set-ExecutionPolicy Unrestricted -Scope LocalMachine` — that's broader than necessary.
</details>

<details>
<summary><strong>Status line shows but the 5h / 7d sections render as <code>â€"</code> while loading</strong></summary>

Older versions used a U+2014 em-dash (`—`) as the placeholder shown when the hook hasn't supplied `rate_limits` yet (session start, account switch, etc.). Even after the source file was switched to UTF-8-with-BOM and the glyph was constructed at runtime via `[char]0x2014`, some terminals / status-line consumers still decoded the UTF-8 bytes as Windows-1252 and rendered `â€"`. The current script uses a plain ASCII placeholder (`--%`, e.g. `5h --% (103.8M tok, $300)`) for the loading state, which can't mojibake. Re-download `statusline-tokens.ps1` from the repo if you're still seeing the em-dash variant.
</details>

<details>
<summary><strong>Status line shows percentages but token counts are 0</strong></summary>

The script reads transcripts from `~/.claude/projects/**/*.jsonl`. If that directory is empty or doesn't exist, token totals will be 0 even though the percentages render. Use Claude Code for a few turns and the counts will populate (cache TTL is 20s).
</details>

<details>
<summary><strong>Status line doesn't appear at all in Claude Code</strong></summary>

Three things to check, in order:

1. **JSON validity** — run the check from Step 6 again. If `settings.json` is malformed, Claude Code silently falls back to no custom status line.
2. **The PowerShell command works standalone** — re-run the Step 7 smoke test. If it errors, the status-line command will too.
3. **`%USERPROFILE%` expanded correctly** — Claude Code launches the command via `cmd.exe /c …`, which expands `%USERPROFILE%`. If your harness doesn't, replace it with the absolute path: `C:\\Users\\<your-name>\\.claude\\statusline-tokens.ps1` (note the doubled backslashes, required for JSON strings).
</details>

<details>
<summary><strong>I'm on macOS or Linux</strong></summary>

This script is Windows-only at the moment — a bash/zsh port is on the roadmap (`CONTRIBUTING.md`). The transcript layout is identical on every platform, so the port is straightforward; PRs welcome.
</details>

<details>
<summary><strong>I want to uninstall</strong></summary>

```powershell
Remove-Item "$env:USERPROFILE\.claude\statusline-tokens.ps1"
Remove-Item "$env:USERPROFILE\.claude\statusline-tokens.cache.json" -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.claude\statusline-accounts.json"     -ErrorAction SilentlyContinue
```

Then edit `~/.claude/settings.json` and remove the `statusLine` block.
</details>

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
