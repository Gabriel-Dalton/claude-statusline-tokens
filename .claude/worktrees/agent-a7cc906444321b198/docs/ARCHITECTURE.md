# Architecture — how the script works internally

A compact explainer for contributors and anyone curious about the implementation choices. The script is ~240 lines of PowerShell; this doc maps the moving parts.

## The big picture

```
┌──────────────────────────────────────────────────────────────────────┐
│                          Claude Code                                  │
│  (re-renders the status line on every prompt cycle)                  │
└─────────────────────────────┬────────────────────────────────────────┘
                              │
                              │  stdin JSON:
                              │    workspace, model, transcript_path,
                              │    rate_limits.five_hour.used_percentage,
                              │    rate_limits.seven_day.used_percentage
                              ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    statusline-tokens.ps1                              │
│                                                                       │
│   1. Read stdin JSON  ───►  $hook                                     │
│                                                                       │
│   2. Check cache  ──────────────────────────────────┐                 │
│      ~/.claude/statusline-tokens.cache.json         │                 │
│      Computed within last 20s?                      │                 │
│                                                     ▼                 │
│                                          ┌───────────────────┐        │
│   3a. yes ───────────────────────────────► use cached numbers│        │
│                                          └───────┬───────────┘        │
│                                                  │                    │
│   3b. no  ──► detect current account from        │                    │
│         ~/.claude.json oauthAccount.org;         │                    │
│         append checkpoint if changed.            │                    │
│         Scan transcripts:                        │                    │
│         Get-ChildItem ~/.claude/projects/        │                    │
│           **/*.jsonl mtime > 7d ago              │                    │
│         For each line containing "usage":        │                    │
│           regex-extract timestamp, msg.id,       │                    │
│              model, 4 token fields, 5m/1h split  │                    │
│           dedupe by msg.id                       │                    │
│           attribute timestamp → account          │                    │
│           cost = perTurn(model, tokens)          │                    │
│           accumulate per-account 5h/7d           │                    │
│           collect every turn into $turns[]       │                    │
│         Sort $turns desc, walk back until gap >  │                    │
│           sessionGapMinutes → session totals     │                    │
│         Write cache JSON keyed by current org    │                    │
│                                                  ▼                    │
│   4. Render colored line to stdout                                    │
│      [Console]::Out.Write(...) with UTF-8 OutputEncoding              │
└──────────────────────────────────────────────────────────────────────┘
```

## Files touched

| Path | Read | Written |
|---|---|---|
| `stdin` | ✓ | — |
| `~/.claude.json` | ✓ (only the `oauthAccount` sub-object via brace-walk) | — |
| `~/.claude/projects/**/*.jsonl` | ✓ (filtered to mtime > 7d ago) | — |
| `~/.claude/statusline-accounts.json` | ✓ | ✓ (append-only on account switch) |
| `~/.claude/statusline-tokens.cache.json` | ✓ | ✓ |
| `stdout` | — | ✓ (final colored line) |
| `$cwd/.git` | ✓ (via `git rev-parse`) | — |

Nothing else is touched — no network calls, no temp files, no environment mutations.

## The hook stdin JSON

Claude Code pipes a single JSON object to the configured status-line command. The fields we care about:

```jsonc
{
  "session_id": "...",
  "model": {
    "id": "claude-opus-4-7",
    "display_name": "Opus 4.7"
  },
  "workspace": {
    "current_dir": "C:\\Users\\you\\code\\my-repo",
    "project_dir": "C:\\Users\\you\\code\\my-repo"
  },
  "transcript_path": "C:\\Users\\you\\.claude\\projects\\C--Users-you-code-my-repo\\<uuid>.jsonl",
  "cwd": "C:\\Users\\you\\code\\my-repo",
  "rate_limits": {
    "five_hour": { "used_percentage": 42, "resets_at": "2026-05-17T20:00:00Z" },
    "seven_day": { "used_percentage": 17, "resets_at": "2026-05-22T10:00:00Z" }
  }
}
```

The `rate_limits` field is present in Claude Code 2.x+. Older versions omit it, in which case the percentages render as `—`.

## The transcript JSONL format

Every assistant turn appears in `~/.claude/projects/<slug>/<session-uuid>.jsonl` as one line per content block (`thinking`, `tool_use`, `text`, ...). Each line carries the **same** `usage` block — so a turn with 3 content blocks produces 3 lines with identical token counts. **This is the source of the de-dup-by-`message.id` rule:** counting all lines triples the real total.

Relevant fields in a typical assistant line:

```jsonc
{
  "timestamp": "2026-05-18T05:55:40.195Z",
  "type": "assistant",
  "sessionId": "<uuid>",
  "message": {
    "id": "msg_011cYfLg7u1svRVTnzarW1ft",  // dedup key
    "model": "claude-opus-4-7",            // pricing lookup key
    "usage": {
      "input_tokens": 6,
      "cache_creation_input_tokens": 12509,
      "cache_read_input_tokens": 22903,
      "output_tokens": 277,
      "cache_creation": {
        "ephemeral_1h_input_tokens": 12509,
        "ephemeral_5m_input_tokens": 0
      }
    }
  }
}
```

Non-assistant lines (user turns, file-history snapshots, system events) don't have `usage` and are filtered out by a cheap `$line.IndexOf('"usage"') -lt 0` check before any expensive parsing.

## Regex over JSON

```powershell
$rxTs       = [regex]'"timestamp":"([^"]+)"'
$rxMsgId    = [regex]'"id":"(msg_[A-Za-z0-9]+)"'
$rxModel    = [regex]'"model":"(claude-[^"]+)"'
$rxInput    = [regex]'"input_tokens":(\d+)'
# ... etc.
```

Why not `ConvertFrom-Json` per line? Throughput. On a 20MB pile of transcripts:

| Approach | Time |
|---|---|
| `ConvertFrom-Json` per line | ~6,000 ms |
| Regex extraction per line | ~700 ms |

PowerShell's JSON parser allocates a full object graph per line. Regex extraction stays in string-scanning territory, which is what we actually need for ~10 named fields.

The trade-off: regex doesn't validate JSON. If a transcript line is malformed (rare — Claude Code writes well-formed JSON), the regexes silently skip the missing field. Worst case is an under-count, which we'd rather have than a crashed status line.

## Dedup logic

```powershell
$mId = $rxMsgId.Match($line)
if ($mId.Success) {
    $key = $mId.Groups[1].Value
    if ($seen.ContainsKey($key)) { continue }
    $seen[$key] = $true
}
```

The `seen` hashtable is per-scan, not persisted. Memory cost is roughly 100 bytes × number of unique turns in the last 7 days — typically under 1MB even for heavy users.

## Window math

Two flavors:

**Fixed-rolling windows (5h, 7d)** — straightforward UTC arithmetic:

```powershell
$nowUtc = [DateTime]::UtcNow
$cut5h  = $nowUtc.AddHours(-5)
$cut7d  = $nowUtc.AddDays(-7)
```

Per-turn accumulation, with current-account filtering for the rate-limit windows:

```powershell
if ($isCurrent) {                  # turn belongs to current account
    if ($t -gt $cut7d) { $tok7d += $sum; $cost7d += $cost }
    if ($t -gt $cut5h) { $tok5h += $sum; $cost5h += $cost }
}
[void]$turns.Add(@{ ticks = $t.Ticks; sum = $sum; cost = $cost })
```

`$isCurrent` is `true` whenever no checkpoints exist yet (graceful degradation to single-account behavior on fresh installs).

**Activity-driven session window** — derived after the scan completes. See [`SESSION.md`](SESSION.md) for the full model. The algorithm:

```powershell
# Sort every collected turn newest → oldest, then walk back
# stopping at the first inter-turn gap larger than the threshold.
$sorted = @($turns | Sort-Object -Property { $_.ticks } -Descending)
if (($nowUtc.Ticks - $sorted[0].ticks) -le $gapTicks) {
    $prev = $sorted[0].ticks
    foreach ($e in $sorted) {
        if (($prev - $e.ticks) -gt $gapTicks) { break }
        $tokSession  += $e.sum
        $costSession += $e.cost
        $prev = $e.ticks
    }
}
```

The "latest turn within `$sessionGapMinutes` of now" gate is what makes the session segment go to `0` after a long break, instead of forever displaying the last burst's frozen total.

`Get-ChildItem -Recurse` is filtered by `LastWriteTimeUtc > cut7d` before iteration, skipping ancient session files that can't contribute to either window.

## The 20-second cache

```powershell
@{
  computedAtUtc = $nowUtc.ToString('o')
  tok5h         = $tok5h
  tok7d         = $tok7d
  cost5h        = $cost5h
  cost7d        = $cost7d
} | ConvertTo-Json -Compress | Set-Content -Path $cachePath -Encoding utf8
```

Why 20 seconds? Two competing concerns:

- **Snappy renders.** The status line re-draws on every prompt submit. A 600–800ms scan on every render feels laggy.
- **Fresh numbers.** When you're watching your own usage tick up, you want to see it move within a turn or two.

20s is short enough that the numbers feel live during interactive use, and long enough that bursts of activity (rapid `Esc` presses, tool-call rounds) reuse the same cache entry.

Tune `$cacheTtlSec` to taste. Setting it to `0` disables the cache entirely.

## Encoding

Two different concerns, both of which had to be solved before non-ASCII characters in the output rendered correctly on Windows PowerShell 5.1:

**1. Output encoding** — what PowerShell sends to stdout. The script forces UTF-8:

```powershell
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
```

Without this, PowerShell defaults to the system code page (often Windows-1252) and silently downgrades any non-ASCII character to `?` when flushed.

**2. Source encoding** — how PowerShell reads the `.ps1` file itself. Windows PowerShell 5.1 reads `.ps1` files using the system code page **unless the file has a UTF-8 BOM (`EF BB BF`)** or is UTF-16 with a BOM. If the file is UTF-8 without a BOM, a literal like `'—'` in the source is decoded as three Windows-1252 characters (`â€"`) — classic mojibake — before the output encoding above can do anything about it. The script is therefore committed with a UTF-8 BOM, and the one runtime em-dash is also constructed via `[char]0x2014` as belt-and-suspenders against re-save mishaps.

The combination of `Console::OutputEncoding = UTF8` + a UTF-8 BOM on the source + runtime-constructed Unicode for output strings is what lets `5h —` render correctly when the rate-limit data hasn't arrived yet.

A third subtlety: file *reads* of `~/.claude.json` and the sidecar JSON files use `Get-Content -Raw -Encoding UTF8` explicitly, because Claude Code writes those files without a BOM and PS 5.1's default `Get-Content` would otherwise mangle non-ASCII organization names.

## Performance budget

Approximate cold render (no cache, 20MB transcript pile):

| Phase | Time |
|---|---|
| PowerShell startup + script load | ~500 ms |
| Parse stdin JSON | <5 ms |
| Enumerate `.jsonl` files | ~50 ms |
| Scan + regex-extract + accumulate | ~600 ms |
| Compose + write output | ~10 ms |
| **Total** | **~1.2 s** |

Warm render (cache hit):

| Phase | Time |
|---|---|
| PowerShell startup + script load | ~500 ms |
| Parse stdin JSON | <5 ms |
| Read + parse cache JSON | ~10 ms |
| Compose + write output | ~10 ms |
| **Total** | **~0.9 s** |

The dominant cost on warm renders is PowerShell's own startup, not anything the script does. A native binary or `pwsh -nop` (PowerShell 7) would shave ~200-300 ms off, but we stick to Windows PowerShell 5.1 to avoid an install dependency.

## Why a `.cmd` wrapper isn't needed

The `settings.json` entry calls `powershell -File "..."` directly. Claude Code spawns commands via the system shell (`cmd.exe /c <command>` on Windows), which treats the rest of the line as literal text and hands it to PowerShell. No nested-quote escapes, no inline `$env:Path` games — the previous iteration of this setup used `powershell -Command "$env:Path = ...; npx ..."` and ran into shell-expansion bugs depending on who re-quoted the command. `-File` sidesteps all of that.
