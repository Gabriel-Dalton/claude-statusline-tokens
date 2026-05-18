# Customize

Common recipes for tweaking `statusline-tokens.ps1`. All edits live in that one file.

## Colors

Each segment uses a 256-color ANSI foreground:

```powershell
$fgDim     = "$esc[38;5;245m"   # the dim '|' separator
$fgDir     = "$esc[38;5;215m"   # working dir
$fgGit     = "$esc[38;5;180m"   # git branch
$fgMod     = "$esc[38;5;141m"   # model
$fg5h      = "$esc[38;5;81m"    # 5h window (current account)
$fg7d      = "$esc[38;5;108m"   # 7d window (current account)
$fgSession = "$esc[38;5;178m"   # current burst, every account in burst (gold)
$fgCtx     = "$esc[38;5;110m"   # context tokens
```

Swap the numbers for any code from the 256-color [palette](https://www.ditig.com/256-colors-cheat-sheet). Examples:

```powershell
$fgGit = "$esc[38;5;39m"    # bright cyan
$fgGit = "$esc[38;5;208m"   # orange
$fgGit = "$esc[38;5;255m"   # near-white
```

For truecolor (24-bit RGB) instead, use `[38;2;R;G;Bm`:

```powershell
$fgGit = "$esc[38;2;0;200;255m"   # cyan
```

## Separator

The `|` between segments lives in:

```powershell
$sep = " $fgDim|$reset "
```

Some alternatives:

```powershell
$sep = "  "                          # whitespace only
$sep = " $fgDim・$reset "             # dot operator
$sep = " $fgDim▍$reset "             # left half-block
$sep = " $fgDim│$reset "             # box-drawing pipe (cleaner than ASCII |)
```

## Session gap threshold

```powershell
$sessionGapMinutes = 30
```

Controls how long an inactivity gap has to be before it ends the current session. Lower = more granular bursts; higher = lumps related work into one session. Default 30 minutes matches the industry-standard "active session" definition. See [`docs/SESSION.md`](SESSION.md#tuning-the-gap-threshold) for a comparison table.

## Cache TTL

```powershell
$cacheTtlSec = 20
```

Lower = fresher numbers, slower renders during bursts. Higher = snappier, staler. Set to `0` to disable caching entirely. The cache file is at `~/.claude/statusline-tokens.cache.json`; delete it to force a fresh scan once.

## Token format

```powershell
function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000) { '{0:0.0}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000.0) }
    else { "$n" }
}
```

Want plain numbers with commas?

```powershell
function Fmt-Tokens([long]$n) { '{0:N0}' -f $n }   # → 1,234,567
```

Want B for billions too?

```powershell
function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000000) { '{0:0.00}B' -f ($n / 1000000000.0) }
    elseif ($n -ge 1000000) { '{0:0.0}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000.0) }
    else { "$n" }
}
```

## Cost format

```powershell
function Fmt-Cost([double]$d) {
    if ($d -ge 1000) { return '${0:0.0}k' -f ($d / 1000.0) }
    if ($d -ge 100)  { return '${0:0}'   -f $d }
    if ($d -ge 1)    { return '${0:0.00}' -f $d }
    if ($d -gt 0)    { return '${0:0.00}' -f $d }
    return '$0.00'
}
```

Prefer always two decimals?

```powershell
function Fmt-Cost([double]$d) { '${0:0.00}' -f $d }
```

Prefer a currency other than USD? Add a symbol prefix to the format string and apply your own exchange rate. (The script has no concept of currency — `$` is just a literal in the format strings.)

## Adding or removing segments

The `$parts` array near the bottom is the order of segments. Comment out anything you don't want.

To **drop** the git segment entirely:

```powershell
# if ($gitBranch) { $parts += (Color $fgGit $gitBranch.Trim()) }
```

To **add** a session-id segment for debugging:

```powershell
if ($hook.session_id) {
    $parts += (Color "$esc[38;5;240m" "session $($hook.session_id.Substring(0,8))")
}
```

To **reorder** segments, just move the `$parts +=` lines.

## Adding a new model family

In the `$prices` hashtable near the top:

```powershell
$prices = @{
    opus       = @{ input = 15.00; output = 75.00; cacheRead = 1.50; cacheW5m = 18.75; cacheW1h = 30.00 }
    sonnet     = @{ input =  3.00; output = 15.00; cacheRead = 0.30; cacheW5m =  3.75; cacheW1h =  6.00 }
    haiku      = @{ input =  1.00; output =  5.00; cacheRead = 0.10; cacheW5m =  1.25; cacheW1h =  2.00 }
    # Add your model here:
    gpt5       = @{ input =  X.XX; output = X.XX; cacheRead = X.XX; cacheW5m = X.XX; cacheW1h = X.XX }
}
```

Then add a match arm to `Get-ModelFamily`:

```powershell
function Get-ModelFamily([string]$id) {
    if ($id -match 'opus')   { return 'opus' }
    if ($id -match 'sonnet') { return 'sonnet' }
    if ($id -match 'haiku')  { return 'haiku' }
    if ($id -match 'gpt-5')  { return 'gpt5' }
    return 'opus'
}
```

The transcript's `message.model` is what gets matched — whatever string ends up in `"model":"<value>"` in your JSONL. Run `Get-Content <session>.jsonl | Select-String '"model":"' -SimpleMatch | Select-Object -First 1` to see the exact strings to match against.

## Changing the windows

The 5h and 7d cutoffs are computed as:

```powershell
$cut5h = $nowUtc.AddHours(-5)
$cut7d = $nowUtc.AddDays(-7)
```

Swap the offsets to render different windows (e.g. last hour and last 30 days). You'll also want to relabel the segments — search for `"5h"` and `"7d"` in the render section.

Note that the *percentages* still come from the native `rate_limits.{five_hour,seven_day}` fields injected by Claude Code — those are tied to Anthropic's actual rate-limit windows. If you change the local window, the % no longer matches the tokens beside it. Either rename to make the meaning clear (e.g. `"24h N/A (4.2M tok, $12.40)"`) or drop the percentage for custom windows entirely.

## Disabling the cache

Set `$cacheTtlSec = 0` to never reuse cached numbers (every render does a fresh scan).

Or delete the cache-write block at the bottom of the scan branch to prevent the file from being created at all:

```powershell
# try {
#     @{
#         computedAtUtc = $nowUtc.ToString('o')
#         tok5h         = $tok5h
#         tok7d         = $tok7d
#         cost5h        = $cost5h
#         cost7d        = $cost7d
#     } | ConvertTo-Json -Compress | Set-Content -Path $cachePath -Encoding utf8
# } catch {}
```

## Debugging

To see exactly what stdin Claude Code is sending you, temporarily add at the top:

```powershell
$stdin | Out-File "$env:USERPROFILE\statusline-debug.json" -Encoding utf8
```

Run a turn, then inspect `~/statusline-debug.json` to see the full hook payload. Remove the line before you commit.
