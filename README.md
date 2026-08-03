<div align="center">

# claude-statusline-tokens

**A Claude Code status line for Windows that shows real numbers — percentage used, token count, dollar cost, and time until reset — for your 5-hour and 7-day rate-limit windows, your Fable 5 weekly limit, AND your current work session, with multi-account awareness.**

```
my-project | main | Opus 5 | 5h 42% (1.2M tok, $4.50, resets 2h14m @ 12:38pm PDT) | 7d 17% (4.8M tok, $18.20, resets 4d6h @ Sun 6am PDT) | fable 61% (resets 4d6h @ Sun 6am PDT) | session 850k ($3.40) | ctx 23k (2%)
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

- **Color-coded headroom** — the 5h and 7d percentages tint **green** (< 50%), **yellow** (50–79%), **red** (≥ 80%) so a glance tells you where you stand. Tweak the bands with `STATUSLINE_PCT_THRESHOLDS=warn,crit` (e.g. `STATUSLINE_PCT_THRESHOLDS=65,85`)
- **Percentage + tokens + $ in one line** for both the 5h block and the 7d weekly limit
- **Fable 5 weekly limit** — the separate weekly quota Claude Code meters premium models on, which it tracks internally but **does not send to the status line hook**. This is the only status line that shows it. See [Fable 5 weekly limit](#fable-5-weekly-limit)
- **Reset countdown** on both windows — `resets 2h14m @ 12:38pm PDT` — so you know whether to push on or take a break. The zone is resolved for the instant being printed, so a reset on the far side of a DST cutover reads correctly; drop the suffix with `STATUSLINE_TZ_LABEL=0`. Immune to DST, and it survives renders where Claude Code omits the field
- **Context fill %** from `context_window.used_percentage` — a raw `ctx 63.0k` reads like a third of a 200k window but is 6% of a 1M one, so the percentage is the only signal that means the same thing on every model
- **Verify the numbers yourself** with [`scripts/verify-tokens.ps1`](scripts/verify-tokens.ps1) — an independent re-derivation that cross-checks the status line's own arithmetic
- **Session-based "current burst" indicator** that captures continuous activity regardless of clock-midnight or account switches — see [`docs/SESSION.md`](docs/SESSION.md)
- **Multi-account aware** — the 5h / 7d numbers track the account you're currently signed into; the session segment is account-independent. Account switches are detected automatically via `~/.claude.json`'s `oauthAccount.organizationUuid`. See [`docs/MULTI-ACCOUNT.md`](docs/MULTI-ACCOUNT.md)
- **Per-turn pricing** that respects whichever model that turn used — mixing Opus and Haiku in a session yields a correctly blended cost, not an Opus-rated overcharge
- **5m vs 1h ephemeral cache-write rates applied separately** when the transcript carries the breakdown (Claude Code 2.1+ does)
- **Regex-based scan** of `.jsonl` transcripts — ~10× faster than `ConvertFrom-Json` per line on a 20MB+ pile
- **20-second on-disk result cache** keyed by current account so switches auto-invalidate
- **Zero dependencies** beyond PowerShell 5.1 (ships with Windows 10/11) and `git` (for the branch name)
- **No telemetry, no third parties.** Every segment but one reads only your local `~/.claude` directory. The exception is the Fable 5 limit, which is not in any local file — that polls Anthropic's own usage endpoint every 15 minutes, off the render path, and switches off with `STATUSLINE_SCOPED_LIMITS=0`
- **Loop watch** in the dashboard — flags an agent stuck repeating the same tool calls while burning tokens, using repetition rather than cost-anomaly detection. See [Loop watch](#loop-watch)
- **Live dashboard companion** — `claude-dashboard.ps1` opens a full-screen, re-rendering view of the same numbers plus a per-project table, opus/sonnet/haiku split, and a 24-hour activity sparkline. See [Dashboard](#dashboard) below.

## Dashboard

Run the dashboard in its own PowerShell window:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File "$env:USERPROFILE\.claude\claude-dashboard.ps1"
```

```
CLAUDE USAGE DASHBOARD                                        you@example.com

5-HOUR WINDOW       ████████████░░░░░░░░░░░░░░░░░░  43%  28.2M tok   $117
     oldest turn rolls out in 4h 26m    opus 322.1M  |  sonnet 0  |  haiku 541.9k

7-DAY WINDOW        █████░░░░░░░░░░░░░░░░░░░░░░░░░  17%  322.7M tok  $932
     oldest turn rolls out in 4d 11h    4 sessions, 7 projects touched

CURRENT SESSION     34m 46s, 284 turns         28.2M tok  $117
CONTEXT             94.8k / 200k  (47%)
LOOP WATCH          quiet - 9 of last 10 tool turns distinct
PRICIEST TURN       $0.42 (612.4k tok) at 12:19

TOP PROJECTS (7d)                    TOP MODELS (7d)
my-app                      137.8M   opus       322.1M       $928
docs-site                    68.7M   sonnet          0      $0.00
api-service                  43.8M   haiku       541.9k     $0.14

RECENT ACTIVITY (last 24h, per hour)
        ▁▅▆▇█          ▃
24h ago              now

refresh every 20s | Ctrl+C to exit                       last update 12:47:39
```

Flags:

- `-RefreshSeconds <int>` — how often to re-scan and re-render (default `20`, matches the statusline cache TTL so the two stay in sync).
- `-SparklineHours <int>` — width of the activity chart in hourly buckets (default `24`).
- `-Once` — render a single frame and exit, useful for scripting or one-off inspection.

### Loop watch

The dashboard flags a repeating tool pattern that is burning tokens — an agent
stuck re-running the same command, or cycling between two files, without making
progress.

```
LOOP WATCH          18 turns cycling 1 distinct call(s)   3.6M tok   $2.71   4m 12s
                    Bash(pytest tests/) x18
```

It watches for **repetition, not cost anomaly**. A threshold based on "this turn
costs more than 3 standard deviations above the session mean" fails on exactly
the case you most want caught: a loop of individually cheap turns drags the mean
toward itself and shrinks the variance, so it scores *lower* the longer it runs —
and past roughly 40 turns it inverts, flagging your legitimate work as the
anomaly instead. Repetition is a structural property of the call sequence, so
there is no statistic for the loop to contaminate.

Repetition alone isn't the alarm, though — a deliberate poll-until-ready loop
repeats too. The alarm is repetition **plus** accumulating tokens: polling stays
cheap and reports as `repeating but cheap`, while a runaway loop re-reads your
whole context every turn and crosses the floor quickly.

Calibrated against 18 real sessions in which healthy work never dropped below 8
distinct calls per 10-turn window. Override the thresholds with
`STATUSLINE_LOOP_WATCH=window,maxDistinct,tokenFloor` (default `10,3,1000000`).

Design credit: [@Keesan12](https://github.com/Gabriel-Dalton/claude-statusline-tokens/issues/30#issuecomment-4624506065).

### Priciest turn

The companion signal to the loop watch, and the other failure shape in that same
critique: not a loop, but **one turn that costs a fortune on its own**.

```
PRICIEST TURN       $7.47 (768.2k tok) at 14:14
```

Reported, but deliberately **not alarmed on by default** — because the shape
turns out not to be reachable. A single turn is capped by the context window plus
max output, which fixes its worst case:

| model | worst possible single turn |
|---|---|
| Sonnet 5 | $7.92 |
| Opus 5 / 4.8 / 4.7 | $13.20 |
| Fable 5 / Mythos 5 | $26.40 |
| Opus 4.1 (legacy) | $39.60 |

Against a heavy 5-hour window of ~$187, the worst an Opus 5 turn can do is
**7.1%** of it. One turn cannot blow a 5-hour budget; an accumulating loop can,
which is why that shape gets the alarm and this one gets a readout.

A naive absolute threshold also misfires. The priciest turn in a real session
was $7.47 — inspection showed 740k tokens of *cache creation* against 1,968
tokens of output: a one-off cache priming that makes every later turn cheap.
Expensive, entirely healthy, and exactly what a $2 floor would have flagged red.

Set `STATUSLINE_SPIKE_FLOOR` to a dollar figure to opt into an alarm anyway —
worth it on legacy Opus, where the ceiling is $39.60.

The percentage bars need the statusline to have run at least once in the last 10 minutes — that's how the dashboard learns the authoritative `rate_limits.used_percentage` numbers from Claude Code's hook payload. Until then, the bars show `--%` and you still get tokens, cost, model split, projects, and the sparkline from a direct JSONL scan.

## Install

**Requirements:** Windows 10 or 11 (macOS/Linux supported with `pwsh`), PowerShell 7+ recommended (`winget install Microsoft.PowerShell`) but Windows PowerShell 5.1 also works. Claude Code already set up. No npm, no pip, no extra modules.

### Recommended: clone and run setup (30 seconds)

```powershell
git clone https://github.com/Gabriel-Dalton/claude-statusline-tokens
cd claude-statusline-tokens
.\setup.ps1
```

`setup.ps1` does three things:

1. Copies `statusline-tokens.ps1` and `claude-dashboard.ps1` into `~/.claude/`.
2. Shows the exact JSON block it wants to add to `~/.claude/settings.json` and asks `Y/n` before writing. A backup is saved to `settings.json.bak` first.
3. Smoke-tests the statusline and offers to launch the dashboard once so you can see what you got.

That's it — open a new Claude Code conversation to see the statusline; run `.\dashboard.ps1` any time for the full dashboard view.

> **Want to see what setup will do without committing?** Run `.\setup.ps1 -DryRun` first. Nothing is written. To uninstall later: `.\setup.ps1 -Uninstall` (restores the `settings.json.bak` backup).

> **Just want to try the dashboard first?** After cloning, run `.\dashboard.ps1 -Once`. No install, no settings.json change — it reads your existing `~/.claude/projects/**` transcripts and renders a single frame. (The progress-bar percentages will show `--%` until you also install the statusline, since they come from Claude Code's hook payload.)

### Manual install (no setup.ps1)

If you'd rather wire it up by hand, expand the details below. The setup script just automates these same steps.

<details>
<summary><strong>Fast path — copy two files + merge one JSON block</strong></summary>

From a PowerShell prompt:

```powershell
# 1. Download both scripts into Claude Code's config dir
foreach ($f in 'statusline-tokens.ps1','claude-dashboard.ps1') {
  Invoke-WebRequest `
    -Uri "https://raw.githubusercontent.com/Gabriel-Dalton/claude-statusline-tokens/main/$f" `
    -OutFile "$env:USERPROFILE\.claude\$f"
}

# 2. Open settings.json and add the statusLine block shown below
notepad "$env:USERPROFILE\.claude\settings.json"
```

The block to **merge** into `settings.json` (if the file already has other keys, add this alongside them — don't replace the whole file):

```json
{
  "statusLine": {
    "type": "command",
    "command": "pwsh -NoProfile -ExecutionPolicy Bypass -File \"%USERPROFILE%\\.claude\\statusline-tokens.ps1\"",
    "padding": 0,
    "refreshInterval": 10
  }
}
```

> If you don't have `pwsh` installed, replace `pwsh` with `powershell` in the command above.

`refreshInterval` re-runs the command every N seconds on top of Claude Code's
own event-driven updates. Without it, a window that is sitting idle stops
re-rendering, so it keeps showing whatever it last drew — which matters here
because the numbers are shared between windows and an idle one would never
pick up what the others have learned. It also keeps the reset countdowns
ticking. Ten seconds costs about half a second of work per idle window;
lower it if you want it snappier, drop it if you only ever run one window.
Requires Claude Code 2.1.216 or newer.

Save, start a new Claude Code conversation, done. Run the dashboard with:

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\claude-dashboard.ps1"
```

The repo ships a ready-to-copy version at [`examples/settings.json`](examples/settings.json).
</details>

<details>
<summary><strong>Guided path — eight verifiable steps</strong></summary>

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
</details>

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

If you installed via `setup.ps1`:

```powershell
.\setup.ps1 -Uninstall
```

This removes the copied scripts, restores `settings.json` from the backup, and leaves your cache/accounts history in place (delete those by hand for a clean slate).

Manual uninstall:

```powershell
Remove-Item "$env:USERPROFILE\.claude\statusline-tokens.ps1"
Remove-Item "$env:USERPROFILE\.claude\claude-dashboard.ps1"         -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.claude\statusline-tokens.cache.json" -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\.claude\statusline-accounts.json"     -ErrorAction SilentlyContinue
```

Then remove the `statusLine` block from `~/.claude/settings.json` by hand.

Then edit `~/.claude/settings.json` and remove the `statusLine` block.
</details>

## What you see

| Segment | Source | Color | Scope |
|---|---|---|---|
| working dir | `workspace.current_dir` from the hook JSON | orange | — |
| git branch | `git rev-parse --abbrev-ref HEAD` in that dir | tan | — |
| model | `model.display_name` from the hook JSON | purple | — |
| **5h % + tokens + $ + reset** | native `rate_limits.five_hour` for the % and reset time; transcript scan for tokens and cost | cyan, % shifts green/yellow/red | **current account** |
| **7d % + tokens + $ + reset** | native `rate_limits.seven_day` for the % and reset time; transcript scan for tokens and cost | green, % shifts green/yellow/red | **current account** |
| **fable % + reset** | `GET /api/oauth/usage`, refreshed every 15 min off the render path — the hook does not carry this window | orchid, % shifts green/yellow/red | **current account** |
| **session tokens + $** | contiguous activity, walking back until a 30-minute gap | gold | **every account in the burst** |
| ctx | tokens in the live context, plus fill % from `context_window.used_percentage` when the hook supplies it | blue | — |

If `rate_limits` is missing for a given turn (typical at session start, before Claude Code has issued its first response), the percentage renders as `--%`. Token totals and costs always render.

### Reset countdown

Each window segment ends with how long is left before that quota frees up:

```
5h 42% (15.3M tok, $25.07, resets 2h14m @ 12:38pm PDT)
7d 18% (15.3M tok, $25.07, resets 6d18h @ Wed 5:34am PDT)
```

The countdown reads `<1m` / `45m` / `2h14m` / `6d18h`, followed by the wall-clock time it lands on and the zone that time is in — day-of-week included for the 7-day window.

Four details worth knowing:

- **Shape-agnostic parsing.** `resets_at` arrives from Claude Code as a Unix epoch, but this script's own cache round-trips ISO-8601 and `ConvertFrom-Json` sometimes yields a `[DateTime]`. All three are accepted. (Parsing only the ISO form is a silent failure: the parse throws, the countdown disappears, and it looks exactly like Claude Code never sent the field.)
- **Survives a missing payload.** The last-seen reset time is cached, so the countdown keeps running on renders where the hook sends no `rate_limits` at all. It's scoped to the signed-in account — after an account switch the previous org's reset time is discarded rather than replayed — and anything already elapsed is dropped rather than shown as a stale or negative value.
- **Timezone-independent.** Every instant is held as UTC internally and converted to local time only at render, using the OS timezone database. The "time left" figure is a UTC-to-UTC delta, so a DST change can't skew it, and the wall-clock time resolves the offset for that specific instant — a reset landing on the far side of a DST boundary prints correctly rather than an hour off.
- **The zone is named, per instant.** `12:38pm` alone is only meaningful if you already know which clock it's on, so the abbreviation follows it: `12:38pm PDT`. It's chosen for the instant being printed rather than for today, so a reset that lands after November's cutover reads `PST` while the current time is still `PDT`. Zones outside the mapped set — and any non-English Windows, where these names are localized — fall back to a numeric offset, `12:38pm UTC+5:45`, rather than a guessed abbreviation: initialising Windows' own name for London ("GMT Standard Time") would produce `GST`, a real zone four hours east. Set `STATUSLINE_TZ_LABEL=0` (or `off` / `false` / `no`) to drop the suffix and get the bare clock time back.

> The `5h` and `7d` numbers are scoped to your **current Claude account**, so they always match the percentage Claude Code itself is showing you. The `session` number tracks your **current burst of work** independent of which account is signed in — so a mid-day account switch (or the clock crossing midnight in the middle of a coding session) doesn't fragment it. Read [`docs/SESSION.md`](docs/SESSION.md) and [`docs/MULTI-ACCOUNT.md`](docs/MULTI-ACCOUNT.md) for the full models.

### Fable 5 weekly limit

Claude Code meters its premium models on a **separate weekly window** from your plan-wide weekly limit. Run `/usage` and you'll see it as its own bar; internally Claude Code calls that bucket `seven_day_overage_included` and labels it "Fable 5 limit". Burn through it and Fable stops being available for the rest of the week while your ordinary weekly limit still has room — which is exactly the situation you want warning of in advance.

```
7d 17% (4.8M tok, $18.20, resets 4d6h @ Sun 6am PDT) | fable 61% (resets 4d6h @ Sun 6am PDT)
```

**The status line hook cannot see this number.** Claude Code assembles the hook payload from two buckets only:

```js
rate_limits = { ...five_hour && {five_hour}, ...seven_day && {seven_day} }
```

`seven_day_opus`, `seven_day_sonnet` and the Fable bucket are all tracked in the same process — parsed straight off the `anthropic-ratelimit-unified-*` response headers — and none of them are forwarded. No amount of parsing the hook JSON will surface it, which is why no other status line shows it.

So this one fetches it, the same way `/usage` does:

- **`GET /api/oauth/usage`**, where the window arrives as a `limits[]` entry with `kind: "weekly_scoped"` and `scope.model.display_name`. Any scoped weekly window your account has gets its own segment, so if Anthropic adds a second one it appears without a code change.
- **Never on the render path.** The render reads a small cache file and nothing else. When that cache passes its TTL, the render spawns a *detached* copy of the script to do the fetch, and the result lands on the next render. A status line that blocked on HTTP would stall your prompt.
- **One fetch across every open window.** The spawn is guarded by an atomically-created lock file, so ten Claude Code windows re-rendering independently still produce one request per interval. A lock orphaned by a killed process is cleared after 120 seconds.
- **Backs off when the endpoint says no.** The usage endpoint rate-limits, and Claude Code polls it too. Consecutive failed requests double the interval up to an hour, so a 429 or an outage isn't answered by knocking every fifteen minutes indefinitely. A success resets the counter; the short-circuit paths that never reach the network (expired token, no credentials file) don't count against it.
- **Stale data degrades honestly.** A percentage that hasn't refreshed in three hours renders `--%` rather than presenting an old number as current — three rather than one, so a value that's merely waiting on the backoff isn't blanked as though it were wrong. The reset countdown survives that gate, because a weekly reset timestamp stays true for days.
- **Account-scoped like every other window.** The cache records the org it belongs to; switching accounts discards it and refetches rather than replaying the previous account's percentage.

#### What it touches, and how to turn it off

The OAuth access token is read from `~/.claude/.credentials.json` (the file Claude Code already keeps there), held in memory for the duration of the request, and **never logged, printed, or written to the cache** — `~/.claude/statusline-scoped-limits.cache.json` holds percentages and timestamps only. An expired token short-circuits before any request is made; refreshing it is Claude Code's job, and racing it there could invalidate your live session. Where Claude Code stores credentials in an OS keychain instead of that file, the segment simply stays hidden — no prompt, no keychain access.

| Variable | Effect |
|---|---|
| `STATUSLINE_SCOPED_LIMITS=0` | Disables the segment, the cache read, and the network call entirely (`off` / `false` / `no` also work) |
| `STATUSLINE_SCOPED_TTL=1800` | Seconds between refreshes while the model is idle; default `900` |
| `STATUSLINE_SCOPED_ACTIVE_TTL=45` | Seconds between refreshes once that model has actually run; default `90` |

Two intervals, because a per-model bar is the one figure Claude Code never
sends on the hook — the endpoint is its only source, and polling it on a flat
fifteen-minute timer means a Fable turn lands and the segment sits on a stale
number long enough to look broken. So the script watches your transcripts for
turns on a model that has a bar, and when one has run since the last
successful fetch it refreshes on the shorter interval instead. No usage on
that model, no extra requests. The failure backoff still overrides both:
being mid-burst is not a reason to keep knocking on an endpoint that just
refused you.

With `STATUSLINE_SCOPED_LIMITS=0` the script makes no network calls at all, which is where it stood before this feature.

## Pricing at a glance

Pricing uses Anthropic's published per-million-token rates, embedded in the script's `$prices` hashtable:

| Family | input | output | cache read | cache write 5m | cache write 1h |
|---|---|---|---|---|---|
| Fable 5 / Mythos 5 | $10.00 | $50.00 | $1.00 | $12.50 | $20.00 |
| Opus 5 / 4.8 / 4.7 / 4.6 / 4.5 |  $5.00 | $25.00 | $0.50 |  $6.25 | $10.00 |
| Opus 4.1 / 4.0 / Opus 3 | $15.00 | $75.00 | $1.50 | $18.75 | $30.00 |
| Sonnet 5 / 4.x |  $3.00 | $15.00 | $0.30 |  $3.75 |  $6.00 |
| Haiku 4.x  |  $1.00 |  $5.00 | $0.10 |  $1.25 |  $2.00 |

> ⚠️ **This is API-equivalent cost, not your bill.** If you're on Claude Pro / Max / Team / Enterprise, you pay a flat monthly fee regardless of what the status line says. The dollar amount is "what an API customer would have paid to do the same work" — a useful intensity signal, not an invoice.
>
> Heavy Claude Code sessions look expensive because **~97% of your tokens are cache reads** — at current Opus rates, $0.50/M. Anthropic re-bills the same conversation context on every turn, so your dollar figure is mostly those replays, not new work.

### "It says I used 168 million tokens today." Is that real?

Yes — and it's the first thing everyone asks, so here is a real measurement rather than a hand-wave. One 5-hour session, broken down by billing category:

| Category | Tokens | Share |
|---|---:|---:|
| cache read — the conversation replayed each turn | 164.4M | 97.7% |
| cache write | 3.0M | 1.8% |
| output — words the model actually generated | 778.0k | 0.5% |
| input — fresh text sent | 1.8k | 0.0% |
| **total** | **168.2M** | **100%** |

Genuinely new work was **3.8M tokens (2.3%)**. The rest is the same conversation being re-read. The arithmetic that confirms it:

```
827 assistant turns × 198.8k average context re-read = 164.4M
measured cache read                                  = 164.4M
```

**Verify it on your own machine:**

```powershell
.\scripts\verify-tokens.ps1           # last 5 hours
.\scripts\verify-tokens.ps1 -Today    # since local midnight
.\scripts\verify-tokens.ps1 -Hours 24
```

That script deliberately does **not** share code with the status line. The status line extracts fields with regex for speed; the verifier does a full `ConvertFrom-Json` parse of every line. Two independent implementations landing on the same total means the number isn't an artifact of how it was parsed — on the run above they agreed to **0.00%**. The script also prints the pre-dedupe line count (raw log lines are ~2.3× the turn count, because one turn is logged once per content block and each copy repeats the same `usage` object), so you can see the de-duplication is doing its job rather than trusting it.

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
