#Requires -Version 5.1
# Live-updating Claude Code usage dashboard for the Windows terminal.
#
# Run this in its own PowerShell window. It re-scans ~/.claude/projects/**/*.jsonl
# on an interval and renders a full-screen view of the 5-hour and 7-day rate-limit
# windows, the current session, a per-model and per-project breakdown for the
# last 7 days, and an hourly activity sparkline.
#
# Unlike statusline-tokens.ps1 this is standalone — it reads ~/.claude.json and
# the transcript files directly. There is no Claude Code hook involved.

[CmdletBinding()]
param(
    # Seconds between re-scans. Matches the statusline's cache TTL so successive
    # passes don't fight each other.
    [int]$RefreshSeconds = 20,

    # When set, render once and exit. Useful for piping into other tools or for
    # one-off inspection without committing a terminal pane.
    [switch]$Once,

    # Width of the activity sparkline, in hourly buckets going backward from now.
    # 24 = last day; bump higher for a wider trail.
    [int]$SparklineHours = 24
)

$ErrorActionPreference = 'SilentlyContinue'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

# Force UTF-8 output so the sparkline blocks and progress-bar shading render
# correctly regardless of the active Windows code page.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# ---------------------------------------------------------------------------
# Pricing — kept in sync with statusline-tokens.ps1. Update when Anthropic
# changes published rates.
# ---------------------------------------------------------------------------
$prices = @{
    fable      = @{ input = 10.00; output = 50.00; cacheRead = 1.00; cacheW5m = 12.50; cacheW1h = 20.00 }
    opus       = @{ input =  5.00; output = 25.00; cacheRead = 0.50; cacheW5m =  6.25; cacheW1h = 10.00 }
    opusLegacy = @{ input = 15.00; output = 75.00; cacheRead = 1.50; cacheW5m = 18.75; cacheW1h = 30.00 }
    sonnet     = @{ input =  3.00; output = 15.00; cacheRead = 0.30; cacheW5m =  3.75; cacheW1h =  6.00 }
    haiku      = @{ input =  1.00; output =  5.00; cacheRead = 0.10; cacheW5m =  1.25; cacheW1h =  2.00 }
}
function Get-ModelFamily([string]$id) {
    if ($id -match 'fable|mythos') { return 'fable' }
    # Opus 4.1 / 4.0 / 3 predate the price drop to $5/$25.
    if ($id -match 'opus-4-1|opus-4-0|opus-4-2025|3-opus') { return 'opusLegacy' }
    if ($id -match 'opus')   { return 'opus' }
    if ($id -match 'sonnet') { return 'sonnet' }
    if ($id -match 'haiku')  { return 'haiku' }
    return 'opus'
}
# ---------------------------------------------------------------------------
# Loop watch thresholds (#41). Override with
#   STATUSLINE_LOOP_WATCH=window,maxDistinct,tokenFloor
# e.g. "20,4,2000000" to require a longer, more varied, more expensive stretch
# before it counts. Defaults are calibrated against 18 real sessions in which
# healthy work never dropped below 8 distinct calls per 10-call window.
# ---------------------------------------------------------------------------
$script:loopWindow      = 10
$script:loopMaxDistinct = 3
$script:loopTokenFloor  = 1000000
if ($env:STATUSLINE_LOOP_WATCH -match '^\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*$') {
    $script:loopWindow      = [int]$Matches[1]
    $script:loopMaxDistinct = [int]$Matches[2]
    $script:loopTokenFloor  = [long]$Matches[3]
}

# Pricing family vs display family: legacy Opus is billed at its own rate but
# shown on the 'opus' row, so the breakdown stays one line per model name.
function Get-DisplayFamily([string]$family) {
    if ($family -eq 'opusLegacy') { return 'opus' }
    return $family
}

# Timestamp normalizer, mirroring statusline-tokens.ps1. Every stamp this
# script reads is UTC-with-Z today, but parsing defensively means a stamp
# that ever arrives naive is read as UTC rather than as host-local time —
# otherwise the same data would produce different windows in different
# timezones. See the fuller comment in statusline-tokens.ps1.
$script:utcParseStyles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                         [Globalization.DateTimeStyles]::AssumeUniversal
function ConvertTo-Utc($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [DateTime]) {
        if ($value.Kind -eq [DateTimeKind]::Utc)   { return $value }
        if ($value.Kind -eq [DateTimeKind]::Local) { return $value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($value, [DateTimeKind]::Utc)
    }
    $text = ([string]$value).Trim()
    if ([string]::IsNullOrEmpty($text)) { return $null }
    if ($text -match '^\d+$') {
        $n = 0L
        if (-not [long]::TryParse($text, [ref]$n)) { return $null }
        if ($n -le 0) { return $null }
        $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        if ($n -gt 100000000000) { return $epoch.AddMilliseconds($n) }
        return $epoch.AddSeconds($n)
    }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
                             $script:utcParseStyles, [ref]$parsed)) {
        return [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }
    return $null
}

# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------
function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000) { '{0:0.0}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000.0) }
    else { "$n" }
}
function Fmt-Cost([double]$d) {
    if ($d -ge 1000) { return '${0:0.0}k' -f ($d / 1000.0) }
    if ($d -ge 100)  { return '${0:0}'   -f $d }
    if ($d -ge 1)    { return '${0:0.00}' -f $d }
    return '${0:0.00}' -f $d
}
function Fmt-Duration([TimeSpan]$ts) {
    if ($ts.TotalDays -ge 1)   { return ('{0}d {1}h' -f [int]$ts.TotalDays, $ts.Hours) }
    if ($ts.TotalHours -ge 1)  { return ('{0}h {1:00}m' -f [int]$ts.TotalHours, $ts.Minutes) }
    if ($ts.TotalMinutes -ge 1){ return ('{0}m {1:00}s' -f [int]$ts.TotalMinutes, $ts.Seconds) }
    return ('{0}s' -f [int]$ts.TotalSeconds)
}

# Non-ASCII glyphs constructed at runtime so the source file stays in the
# ASCII subset. PS 5.1 reads .ps1 files using the system code page unless a
# UTF-8 BOM is present; embedding raw U+2581…U+2588 here would mojibake under
# Windows-1252 and the parser would barf. Constructing via [char] sidesteps
# the whole source-encoding question.
$blockFull   = [char]0x2588     # █
$blockShade  = [char]0x2591     # ░
$emDash      = [char]0x2014     # —
$ellipsisCh  = [char]0x2026     # …
$sparkChars  = @(
    ' ',
    [char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584,
    [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588
)

# Progress bar of a fixed width. Returns a colored string already wrapped in
# SGR codes.
function Make-Bar([double]$pct, [int]$width, [string]$colorFull, [string]$colorDim) {
    if ($pct -lt 0)   { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $filled = [int][math]::Floor(($pct / 100.0) * $width)
    $empty  = $width - $filled
    $full  = [string]::new([char]$blockFull,  $filled)
    $rest  = [string]::new([char]$blockShade, $empty)
    "$colorFull$full$colorDim$rest$reset"
}

# Map an array of bucket values to a sparkline string using eight block heights.
# Empty input still emits a row of single-pixel marks so the chart slot stays
# visually anchored instead of collapsing to whitespace.
function Make-Sparkline([long[]]$values) {
    if (-not $values -or $values.Count -eq 0) { return '' }
    $max = 0L
    foreach ($v in $values) { if ($v -gt $max) { $max = $v } }
    if ($max -le 0) {
        return [string]::new([char]$sparkChars[1], $values.Count)
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($v in $values) {
        $idx = [int][math]::Round(($v / [double]$max) * 8)
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -gt 8) { $idx = 8 }
        [void]$sb.Append($sparkChars[$idx])
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# ANSI palette — mirrors the statusline so colors feel consistent.
# ---------------------------------------------------------------------------
$esc      = [char]27
$reset    = "$esc[0m"
$bold     = "$esc[1m"
$fgDim    = "$esc[38;5;245m"
$fgLabel  = "$esc[38;5;253m"
$fgHeader = "$esc[38;5;231m"
$fg5h     = "$esc[38;5;81m"
$fg7d     = "$esc[38;5;108m"
$fgSess   = "$esc[38;5;178m"
$fgCtx    = "$esc[38;5;110m"
$fgFable  = "$esc[38;5;209m"
$fgOpus   = "$esc[38;5;141m"
$fgSon    = "$esc[38;5;81m"
$fgHaiku  = "$esc[38;5;108m"
$fgProj   = "$esc[38;5;215m"
$fgBarDim = "$esc[38;5;238m"

# Headroom palette — same thresholds as the statusline so the bars and the
# 5h / 7d % readouts agree. Override with STATUSLINE_PCT_THRESHOLDS="warn,crit".
$fgPctGreen  = "$esc[38;5;77m"
$fgPctYellow = "$esc[38;5;221m"
$fgPctRed    = "$esc[38;5;203m"

$pctWarn = 50.0
$pctCrit = 80.0
if ($env:STATUSLINE_PCT_THRESHOLDS -match '^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$') {
    $pctWarn = [double]$Matches[1]
    $pctCrit = [double]$Matches[2]
}

function Get-PctColor([double]$pct) {
    if ($pct -lt 0) { return $fgDim }
    if ($pct -ge $pctCrit) { return $fgPctRed }
    if ($pct -ge $pctWarn) { return $fgPctYellow }
    return $fgPctGreen
}

function Color([string]$fg, [string]$text) { "$fg$text$reset" }

# ---------------------------------------------------------------------------
# Brace-walking JSON extractor — same approach as the statusline. Needed
# because ~/.claude.json contains a projects map keyed by absolute path; on
# case-insensitive Windows filesystems that map ends up with duplicate keys
# that PS 5.1's ConvertFrom-Json rejects. We only want oauthAccount, so we
# slice the surrounding braces out and parse the slice.
# ---------------------------------------------------------------------------
function Get-JsonObject([string]$content, [string]$keyName) {
    $needle = '"' + $keyName + '"'
    $start = $content.IndexOf($needle)
    if ($start -lt 0) { return $null }
    $braceStart = $content.IndexOf('{', $start)
    if ($braceStart -lt 0) { return $null }
    $depth = 0; $inStr = $false; $esc2 = $false
    for ($i = $braceStart; $i -lt $content.Length; $i++) {
        $c = $content[$i]
        if ($esc2) { $esc2 = $false; continue }
        if ($inStr) {
            if ($c -eq '\') { $esc2 = $true; continue }
            if ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) { return $content.Substring($braceStart, $i - $braceStart + 1) }
        }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Account detection + checkpoint history. Identical semantics to the
# statusline so the two views agree on "which org owns this turn."
# ---------------------------------------------------------------------------
# Cross-platform user-profile resolution. [Environment]::GetFolderPath
# returns "" rather than $null on non-Windows when the folder is unknown,
# so we fall through to $HOME (PowerShell-provided on all platforms) and
# finally to the Windows-only $env:USERPROFILE as a last resort.
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $HOME }
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $env:USERPROFILE }

# [IO.Path]::Combine handles per-OS separators and accepts any number of
# parts, so the same call works on PS 5.1 (whose Join-Path is two-arg only)
# and on pwsh 7+.
$projectsDir      = [System.IO.Path]::Combine($userProfile, '.claude', 'projects')
$globalConfigPath = [System.IO.Path]::Combine($userProfile, '.claude.json')
$accountsPath     = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-accounts.json')
$statuslineCache  = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-tokens.cache.json')

# The statusline persists the most recent rate_limits.{five_hour,seven_day}
# percentages it sees from the hook stdin. We read them here so the dashboard
# can show the same authoritative numbers Claude Code uses to throttle. If
# the cache is missing, stale (older than ~10 min), or belongs to a different
# org, we return -1 to signal "no data" and the bar renders as "--%".
function Read-RateLimitPcts([string]$expectedOrg, [DateTime]$nowUtc) {
    $out = @{ pct5h = -1.0; pct7d = -1.0 }
    if (-not (Test-Path $statuslineCache)) { return $out }
    try {
        $cache = Get-Content -Raw -Encoding UTF8 $statuslineCache | ConvertFrom-Json
        $cachedOrg = ''
        if ($cache.PSObject.Properties.Match('orgKey').Count -gt 0) { $cachedOrg = [string]$cache.orgKey }
        if ($expectedOrg -and $cachedOrg -and $cachedOrg -ne $expectedOrg) { return $out }
        # Percentages persisted by the statusline. Older statusline versions
        # don't write these fields; absence is treated as "no data".
        if ($cache.PSObject.Properties.Match('pct5h').Count -gt 0 -and $cache.pct5h -ne $null) {
            $out.pct5h = [double]$cache.pct5h
        }
        if ($cache.PSObject.Properties.Match('pct7d').Count -gt 0 -and $cache.pct7d -ne $null) {
            $out.pct7d = [double]$cache.pct7d
        }
        # Staleness gate — if Claude Code hasn't fired the hook in a while
        # the numbers are old; better to show "--%" than mislead.
        if ($cache.PSObject.Properties.Match('pctSavedAtUtc').Count -gt 0 -and $cache.pctSavedAtUtc) {
            $savedAt = ConvertTo-Utc $cache.pctSavedAtUtc
            # An unreadable stamp is treated as stale rather than as fresh —
            # showing '--%' is honest, showing an unknown-age number is not.
            if ($null -eq $savedAt -or ($nowUtc - $savedAt).TotalMinutes -gt 10) {
                $out.pct5h = -1.0
                $out.pct7d = -1.0
            }
        }
    } catch {}
    return $out
}

function Read-CurrentAccount {
    if (-not (Test-Path $globalConfigPath)) { return $null }
    try {
        $raw = Get-Content -Raw -Encoding UTF8 $globalConfigPath
        $block = Get-JsonObject $raw 'oauthAccount'
        if (-not $block) { return $null }
        $oa = $block | ConvertFrom-Json
        if (-not $oa.organizationUuid) { return $null }
        return @{
            org   = [string]$oa.organizationUuid
            email = [string]$oa.emailAddress
            name  = [string]$oa.organizationName
        }
    } catch { return $null }
}

function Read-Checkpoints {
    # Comma operator forces the function to emit a single object (the array)
    # rather than enumerating it — without this, a one-item array decays to
    # the bare item at the call site and `$checkpoints += @{...}` ends up
    # invoking PSObject + Hashtable, which throws op_Addition.
    if (-not (Test-Path $accountsPath)) { return ,@() }
    try {
        $loaded = Get-Content -Raw -Encoding UTF8 $accountsPath | ConvertFrom-Json
        if ($loaded.checkpoints) { return ,@($loaded.checkpoints) }
    } catch {}
    return ,@()
}

# Returns the checkpoint that owned the given UTC instant. Pre-first-checkpoint
# history is attributed to the earliest checkpoint, matching statusline behavior.
function Account-At([DateTime]$t, $checkpoints) {
    if (-not $checkpoints -or $checkpoints.Count -eq 0) { return $null }
    $acct = $checkpoints[0]
    foreach ($cp in $checkpoints) {
        $cpTime = ConvertTo-Utc $cp.from
        if ($null -eq $cpTime) { continue }
        if ($t -ge $cpTime) { $acct = $cp } else { break }
    }
    return $acct
}

# ---------------------------------------------------------------------------
# Regex extractors. ConvertFrom-Json per line is far too slow on 20MB+
# transcripts; line-level regex is ~10x faster and only reads fields we use.
# ---------------------------------------------------------------------------
$rxTs      = [regex]'"timestamp":"([^"]+)"'
$rxMsgId   = [regex]'"id":"(msg_[A-Za-z0-9]+)"'
$rxModel   = [regex]'"model":"(claude-[^"]+)"'
$rxInput   = [regex]'"input_tokens":(\d+)'
$rxOutput  = [regex]'"output_tokens":(\d+)'
$rxCacheC  = [regex]'"cache_creation_input_tokens":(\d+)'
$rxCacheR  = [regex]'"cache_read_input_tokens":(\d+)'
$rxCache5m = [regex]'"ephemeral_5m_input_tokens":(\d+)'
$rxCache1h = [regex]'"ephemeral_1h_input_tokens":(\d+)'
$rxCwd     = [regex]'"cwd":"([^"]+)"'

# ---------------------------------------------------------------------------
# Core scan. Walks every .jsonl under ~/.claude/projects that has been
# touched in the last 7 days and folds each usage record into aggregates
# scoped by the active account.
# ---------------------------------------------------------------------------
function Invoke-Scan {
    param(
        [DateTime]$NowUtc,
        $CurrentAccount,
        $Checkpoints,
        [int]$SparklineHours,
        [int]$SessionGapMinutes = 30
    )

    $cut5h = $NowUtc.AddHours(-5)
    $cut7d = $NowUtc.AddDays(-7)
    $cutSpark = $NowUtc.AddHours(-$SparklineHours)

    # Output accumulators
    $tok5h  = [long]0; $cost5h  = 0.0
    $tok7d  = [long]0; $cost7d  = 0.0
    $oldest5h = $null
    $oldest7d = $null
    # Keyed by *display* family (legacy Opus folds into 'opus'), so a Fable
    # turn lands in its own bucket instead of silently missing from the split.
    $modelTokens = @{ fable = [long]0; opus = [long]0; sonnet = [long]0; haiku = [long]0 }
    $modelCost   = @{ fable = 0.0;     opus = 0.0;     sonnet = 0.0;     haiku = 0.0     }
    $projectTokens = @{}
    $projectCost   = @{}
    $sparkBuckets = New-Object 'long[]' $SparklineHours
    $turns = New-Object System.Collections.ArrayList
    $sessionsCounted = 0
    $latestContext = [long]0
    $latestContextTime = [DateTime]::MinValue
    $totalTurns = 0
    $seen = @{}
    # Loop watch (#41): message id -> the tool calls that turn issued, and
    # message id -> that turn's ticks/tokens/cost. Both scoped to the 5h window.
    $toolCallsByTurn = @{}
    $turnCostByTurn  = @{}

    if (-not (Test-Path $projectsDir)) {
        return [pscustomobject]@{
            tok5h = 0; cost5h = 0; tok7d = 0; cost7d = 0
            oldest5h = $null; oldest7d = $null
            modelTokens = $modelTokens; modelCost = $modelCost
            loop = $null
            projectTokens = $projectTokens; projectCost = $projectCost
            sparkBuckets = $sparkBuckets
            tokSession = 0; costSession = 0; sessionStart = $null; sessionTurns = 0
            ctxTokens = 0; ctxModel = ''
            totalTurns = 0; sessionsLastWeek = 0
        }
    }

    $files = Get-ChildItem -Path $projectsDir -Filter *.jsonl -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -gt $cut7d }

    foreach ($f in $files) {
        # Project label: try cwd from the file's first cwd-bearing line so
        # paths with embedded dashes ("Gabriel-Dalton") survive intact. The
        # parent folder name in .claude/projects has all separators replaced
        # with dashes, which loses information.
        $projLabel = $f.Directory.Name
        $modelForContext = ''

        $reader = $null
        try {
            $reader = [System.IO.File]::OpenText($f.FullName)
            $cwdResolved = $false
            $fileTurns = New-Object System.Collections.ArrayList

            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not $line) { continue }

                if (-not $cwdResolved) {
                    $mCwd = $rxCwd.Match($line)
                    if ($mCwd.Success) {
                        $rawCwd = $mCwd.Groups[1].Value -replace '\\\\','\'
                        $leaf = Split-Path -Leaf $rawCwd
                        if ($leaf) { $projLabel = $leaf }
                        $cwdResolved = $true
                    }
                }

                if ($line.IndexOf('"usage"') -lt 0) { continue }

                $mTs = $rxTs.Match($line)
                if (-not $mTs.Success) { continue }
                # AssumeUniversal: a stamp without an offset is UTC, not local.
                $t = [DateTime]::MinValue
                if (-not [DateTime]::TryParse($mTs.Groups[1].Value,
                        [Globalization.CultureInfo]::InvariantCulture,
                        $script:utcParseStyles, [ref]$t)) { continue }
                if ($t -lt $cut7d) { continue }

                # Same-message dedup: a single assistant turn is logged once
                # per content block, and every block carries the same usage.
                $mId = $rxMsgId.Match($line)

                # --- loop watch: harvest tool calls (#41) --------------------
                # This MUST run before the dedupe below. Dedupe keeps only the
                # first logged block of a turn, which is frequently a thinking
                # block - by the time it has run, the tool_use lines for that
                # turn are already discarded.
                #
                # Only lines containing "tool_use" get a real JSON parse: about
                # a hundred lines out of many thousands, so the cost is bounded
                # and the dashboard refreshes on a timer rather than per
                # keystroke. Regex is not an option here - the input object
                # needs balanced-brace matching, and hashing a fixed-length
                # slice instead produces false matches between distinct calls
                # that happen to share a prefix.
                if ($mId.Success -and $t -gt $cut5h -and $line.IndexOf('"tool_use"') -ge 0) {
                    try {
                        $parsed = $line | ConvertFrom-Json -ErrorAction Stop
                        $blocks = $parsed.message.content
                        if ($blocks -is [System.Array]) {
                            $msgKey = $mId.Groups[1].Value
                            foreach ($b in $blocks) {
                                if ($b.type -ne 'tool_use') { continue }
                                $inputJson = ''
                                if ($null -ne $b.input) {
                                    $inputJson = $b.input | ConvertTo-Json -Compress -Depth 8
                                }
                                if (-not $toolCallsByTurn.ContainsKey($msgKey)) {
                                    $toolCallsByTurn[$msgKey] =
                                        New-Object System.Collections.ArrayList
                                }
                                [void]$toolCallsByTurn[$msgKey].Add(
                                    ('{0}({1})' -f $b.name, $inputJson))
                            }
                        }
                    } catch {
                        # A malformed line costs us one turn's tool detail, not
                        # the scan. Token accounting below is unaffected.
                        Write-Verbose "loop watch: unparseable tool_use line skipped: $_"
                    }
                }

                if ($mId.Success) {
                    $key = $mId.Groups[1].Value
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                }

                $tIn = 0L; $tOut = 0L; $tCacheC = 0L; $tCacheR = 0L; $t5m = 0L; $t1h = 0L
                $m = $rxInput.Match($line);   if ($m.Success) { $tIn     = [long]$m.Groups[1].Value }
                $m = $rxOutput.Match($line);  if ($m.Success) { $tOut    = [long]$m.Groups[1].Value }
                $m = $rxCacheC.Match($line);  if ($m.Success) { $tCacheC = [long]$m.Groups[1].Value }
                $m = $rxCacheR.Match($line);  if ($m.Success) { $tCacheR = [long]$m.Groups[1].Value }
                $m = $rxCache5m.Match($line); if ($m.Success) { $t5m     = [long]$m.Groups[1].Value }
                $m = $rxCache1h.Match($line); if ($m.Success) { $t1h     = [long]$m.Groups[1].Value }

                $sum = $tIn + $tOut + $tCacheC + $tCacheR
                if ($sum -le 0) { continue }

                $modelId = ''
                $mm = $rxModel.Match($line); if ($mm.Success) { $modelId = $mm.Groups[1].Value }
                $family = Get-ModelFamily $modelId
                $p = $prices[$family]
                if (($t5m + $t1h) -le 0) { $t5m = $tCacheC; $t1h = 0L }
                $cost = (
                    $tIn     * $p.input     +
                    $tOut    * $p.output    +
                    $tCacheR * $p.cacheRead +
                    $t5m     * $p.cacheW5m  +
                    $t1h     * $p.cacheW1h
                ) / 1000000.0

                # Loop watch needs cost at TURN granularity, keyed the same way
                # the harvest above is, so a repetitive stretch can be priced.
                if ($mId.Success -and $t -gt $cut5h) {
                    $turnCostByTurn[$mId.Groups[1].Value] = @{
                        ticks = $t.Ticks; sum = $sum; cost = $cost
                    }
                }

                $turnAcct = Account-At $t $Checkpoints
                $isCurrent = $true
                if ($CurrentAccount) {
                    $isCurrent = ($turnAcct -and [string]$turnAcct.org -eq $CurrentAccount.org)
                }

                if ($isCurrent) {
                    $tok7d  += $sum;  $cost7d += $cost
                    if (-not $oldest7d -or $t -lt $oldest7d) { $oldest7d = $t }
                    # Cost was already computed at $family's own rate above;
                    # only the bucket label collapses legacy Opus into 'opus'.
                    $displayFamily = Get-DisplayFamily $family
                    $modelTokens[$displayFamily] += $sum
                    $modelCost[$displayFamily]   += $cost
                    if (-not $projectTokens.ContainsKey($projLabel)) {
                        $projectTokens[$projLabel] = [long]0
                        $projectCost[$projLabel]   = 0.0
                    }
                    $projectTokens[$projLabel] = [long]$projectTokens[$projLabel] + $sum
                    $projectCost[$projLabel]   = [double]$projectCost[$projLabel] + $cost
                    if ($t -gt $cut5h) {
                        $tok5h  += $sum;  $cost5h += $cost
                        if (-not $oldest5h -or $t -lt $oldest5h) { $oldest5h = $t }
                    }
                    if ($t -gt $cutSpark) {
                        $bucket = [int][math]::Floor(($NowUtc - $t).TotalHours)
                        $bucketIdx = $SparklineHours - 1 - $bucket
                        if ($bucketIdx -ge 0 -and $bucketIdx -lt $SparklineHours) {
                            $sparkBuckets[$bucketIdx] += $sum
                        }
                    }
                    $totalTurns++
                }

                # Capture every turn (any account) for session detection.
                [void]$turns.Add(@{
                    ticks = $t.Ticks; sum = $sum; cost = $cost
                    family = $family; ctxLine = $line
                })
                [void]$fileTurns.Add(@{ ticks = $t.Ticks; line = $line; model = $modelId })
            }
            $reader.Close()

            # Track the most recent usage line across all files to surface
            # "context tokens loaded right now" — the standalone dashboard
            # has no Claude Code hook so we can't know which transcript is
            # active; the latest one is the best proxy.
            if ($fileTurns.Count -gt 0) {
                $latest = $fileTurns | Sort-Object -Property { $_.ticks } -Descending | Select-Object -First 1
                $latestT = [DateTime]::new($latest.ticks, [DateTimeKind]::Utc)
                if ($latestT -gt $latestContextTime) {
                    $sumCtx = 0L
                    $m = $rxInput.Match($latest.line);  if ($m.Success) { $sumCtx += [long]$m.Groups[1].Value }
                    $m = $rxCacheC.Match($latest.line); if ($m.Success) { $sumCtx += [long]$m.Groups[1].Value }
                    $m = $rxCacheR.Match($latest.line); if ($m.Success) { $sumCtx += [long]$m.Groups[1].Value }
                    $latestContext = $sumCtx
                    $latestContextTime = $latestT
                    $modelForContext = $latest.model
                }
            }
        } catch {
            if ($reader) { try { $reader.Close() } catch {} }
        }
    }

    # ----- Session detection -------------------------------------------------
    # A session is the trailing run of turns where no consecutive gap exceeds
    # $SessionGapMinutes — and the most recent turn is itself within that gap
    # of "now". If the latest turn is older than the gap we report zero
    # rather than freezing on a stale total.
    $tokSession  = [long]0
    $costSession = 0.0
    $sessionStart = $null
    $sessionTurns = 0
    if ($turns.Count -gt 0) {
        $gapTicks = [long]$SessionGapMinutes * [TimeSpan]::TicksPerMinute
        $sorted = @($turns | Sort-Object -Property { $_.ticks } -Descending)
        $latestTicks = $sorted[0].ticks
        if (($NowUtc.Ticks - $latestTicks) -le $gapTicks) {
            $prev = $latestTicks
            $earliest = $latestTicks
            foreach ($e in $sorted) {
                if (($prev - $e.ticks) -gt $gapTicks) { break }
                $tokSession  += [long]$e.sum
                $costSession += [double]$e.cost
                $earliest = $e.ticks
                $sessionTurns++
                $prev = $e.ticks
            }
            $sessionStart = [DateTime]::new($earliest, [DateTimeKind]::Utc)
        }
    }

    # ----- Sessions-this-week count -----------------------------------------
    # Walk turns chronologically, start a new session whenever the gap to the
    # prior turn exceeds the threshold. Counts every account, mirroring the
    # session segment's account-agnostic behavior.
    $sessionsLastWeek = 0
    if ($turns.Count -gt 0) {
        $gapTicks = [long]$SessionGapMinutes * [TimeSpan]::TicksPerMinute
        $asc = @($turns | Sort-Object -Property { $_.ticks })
        $sessionsLastWeek = 1
        for ($i = 1; $i -lt $asc.Count; $i++) {
            if (($asc[$i].ticks - $asc[$i-1].ticks) -gt $gapTicks) { $sessionsLastWeek++ }
        }
    }

    $loopWatch = Get-LoopWatch -ToolCallsByTurn $toolCallsByTurn `
                               -TurnCostByTurn $turnCostByTurn `
                               -Window $script:loopWindow `
                               -MaxDistinct $script:loopMaxDistinct `
                               -TokenFloor $script:loopTokenFloor

    [pscustomobject]@{
        tok5h = $tok5h; cost5h = $cost5h
        tok7d = $tok7d; cost7d = $cost7d
        oldest5h = $oldest5h; oldest7d = $oldest7d
        modelTokens = $modelTokens; modelCost = $modelCost
        loop = $loopWatch
        projectTokens = $projectTokens; projectCost = $projectCost
        sparkBuckets = $sparkBuckets
        tokSession = $tokSession; costSession = $costSession
        sessionStart = $sessionStart; sessionTurns = $sessionTurns
        ctxTokens = $latestContext; ctxModel = $modelForContext
        totalTurns = $totalTurns; sessionsLastWeek = $sessionsLastWeek
        pct5h = -1.0; pct7d = -1.0   # filled by the caller from the statusline cache
    }
}

# ---------------------------------------------------------------------------
# Loop watch (#41) - detect a repeating tool pattern that is burning tokens.
#
# Why not a cost-anomaly test: #30 proposed flagging turns more than 3 sigma
# above the session mean. That measures "unusual" against a yardstick the
# problem itself bends. A loop of identical cheap turns drags the mean toward
# itself and collapses the variance, so it scores LOWER the longer it runs
# (0.17 sigma at 5 turns, 0.07 at 80 in simulation) - and worse, it inverts:
# past ~40 loop turns an ordinary turn scores 4.4 sigma and gets flagged as
# the anomaly instead. Classic masking and swamping.
#
# Repetition has no such weakness. It is a structural property of the call
# sequence, so there is no estimator to contaminate. Measured across 18 real
# sessions / 1000 tool calls: healthy work never dropped below 8 distinct
# calls in any 10-call window, and exact identical consecutive calls never
# occurred at all. A threshold of 3 sits well clear of that.
#
# Repetition alone is not the alarm, though. A deliberate poll-until-ready
# loop repeats too. The alarm is repetition PLUS accumulating spend: polling
# stays cheap, while a runaway loop re-reads the whole context every turn and
# crosses a token floor quickly. That is the synthesis of the two failure
# shapes in the design critique on #30.
# ---------------------------------------------------------------------------
function Get-LoopWatch {
    param(
        [hashtable]$ToolCallsByTurn,
        [hashtable]$TurnCostByTurn,
        [int]$Window       = 10,
        [int]$MaxDistinct  = 3,
        [long]$TokenFloor  = 1000000
    )

    $quiet = [pscustomobject]@{
        tripped = $false; distinct = $null; window = $Window
        turns = 0; tokens = [long]0; cost = 0.0; span = [TimeSpan]::Zero
        calls = @()
    }

    # One entry per turn that issued tool calls, in time order. The signature
    # is the turn's whole fan-out, sorted: a turn that issues Read(a)+Read(b)
    # repeatedly is as much a loop as one that issues Read(a) repeatedly.
    $seq = New-Object System.Collections.ArrayList
    foreach ($msgId in $ToolCallsByTurn.Keys) {
        if (-not $TurnCostByTurn.ContainsKey($msgId)) { continue }
        $meta = $TurnCostByTurn[$msgId]
        $names = @($ToolCallsByTurn[$msgId]) | Sort-Object
        [void]$seq.Add([pscustomobject]@{
            ticks = [long]$meta.ticks
            sum   = [long]$meta.sum
            cost  = [double]$meta.cost
            sig   = ($names -join '+')
            calls = $names
        })
    }
    if ($seq.Count -lt $Window) { return $quiet }
    $ordered = @($seq | Sort-Object -Property ticks)

    # Worst (least varied) window.
    $bestStart = -1
    $bestDistinct = [int]::MaxValue
    for ($i = 0; $i -le $ordered.Count - $Window; $i++) {
        $d = (@($ordered[$i..($i + $Window - 1)] | ForEach-Object { $_.sig } |
                Sort-Object -Unique)).Count
        if ($d -lt $bestDistinct) { $bestDistinct = $d; $bestStart = $i }
    }
    if ($bestStart -lt 0) { return $quiet }
    $quiet.distinct = $bestDistinct
    if ($bestDistinct -gt $MaxDistinct) { return $quiet }

    # Grow the stretch outward while it stays repetitive, so the span reported
    # is the actual loop rather than an arbitrary $Window-sized slice of it.
    $lo = $bestStart
    $hi = $bestStart + $Window - 1
    $distinctOf = {
        param($a, $b)
        (@($ordered[$a..$b] | ForEach-Object { $_.sig } | Sort-Object -Unique)).Count
    }
    $grew = $true
    while ($grew) {
        $grew = $false
        if ($lo -gt 0 -and (& $distinctOf ($lo - 1) $hi) -le $MaxDistinct) {
            $lo--; $grew = $true
        }
        if ($hi -lt ($ordered.Count - 1) -and (& $distinctOf $lo ($hi + 1)) -le $MaxDistinct) {
            $hi++; $grew = $true
        }
    }

    $stretch = $ordered[$lo..$hi]
    $tokens = [long]0; $cost = 0.0
    foreach ($e in $stretch) { $tokens += $e.sum; $cost += $e.cost }
    $span = [TimeSpan]::FromTicks([long]($stretch[-1].ticks - $stretch[0].ticks))

    # Which calls, and how often. Truncated for display - the input is in the
    # signature to make the match exact, not to be read on screen.
    $counts = @{}
    foreach ($e in $stretch) {
        foreach ($c in $e.calls) {
            $short = $c
            $paren = $short.IndexOf('(')
            if ($paren -gt 0) {
                $name = $short.Substring(0, $paren)
                $arg  = $short.Substring($paren + 1).TrimEnd(')')
                # The full input JSON is in the signature so the match is
                # exact; for display, unwrap the commonest shape - a
                # single-key object - so the line reads Bash(npm test)
                # rather than Bash({"command":"npm test"}).
                $m = [regex]::Match($arg, '^\{\s*"[^"]+"\s*:\s*"?(.*?)"?\s*\}$')
                if ($m.Success) { $arg = $m.Groups[1].Value }
                $arg = $arg -replace '\\"', '"' -replace '\\\\', '\' -replace '\s+', ' '
                if ($arg.Length -gt 40) {
                    $arg = $arg.Substring(0, 39) + [string][char]0x2026
                }
                $short = '{0}({1})' -f $name, $arg
            }
            if (-not $counts.ContainsKey($short)) { $counts[$short] = 0 }
            $counts[$short]++
        }
    }
    $callList = @($counts.GetEnumerator() | Sort-Object -Property Value -Descending |
        ForEach-Object { '{0} x{1}' -f $_.Key, $_.Value })

    [pscustomobject]@{
        # Repetitive but cheap is information, not an alarm: that is what a
        # legitimate polling loop looks like.
        tripped  = ($tokens -ge $TokenFloor)
        distinct = $bestDistinct
        window   = $Window
        turns    = $stretch.Count
        tokens   = $tokens
        cost     = $cost
        span     = $span
        calls    = $callList
    }
}

# ---------------------------------------------------------------------------
# Frame rendering. Returns an array of lines; the main loop positions the
# cursor at (0,0) and overwrites each line, padding to the console width so
# leftovers from a prior, taller frame don't bleed through.
# ---------------------------------------------------------------------------
function Build-Frame {
    param($Scan, $CurrentAccount, [DateTime]$NowUtc, [int]$RefreshSeconds, [int]$Width)

    $lines = New-Object System.Collections.ArrayList

    # Header --------------------------------------------------------------
    $title = "CLAUDE USAGE DASHBOARD"
    $who = ''
    if ($CurrentAccount) {
        $who = $CurrentAccount.email
        if (-not $who) { $who = $CurrentAccount.name }
        if (-not $who) { $who = $CurrentAccount.org }
    }
    $gap = $Width - $title.Length - $who.Length - 2
    if ($gap -lt 1) { $gap = 1 }
    [void]$lines.Add("$bold$fgHeader$title$reset" + (' ' * $gap) + (Color $fgDim $who))
    [void]$lines.Add((Color $fgDim ('-' * ($Width - 1))))
    [void]$lines.Add('')

    # 5-hour window --------------------------------------------------------
    # pct5h / pct7d come from the statusline cache, which captures the
    # authoritative numbers Anthropic ships in the hook payload. If the
    # statusline hasn't run recently (no Claude Code activity since launch),
    # the values are -1 and the bar renders empty with a "--%" label.
    # Bar fill and % text both color-shift green -> yellow -> red as headroom
    # disappears, so a glance at the dashboard tells you where you stand.
    $pctColor5 = Get-PctColor $Scan.pct5h
    $bar5 = Make-Bar $Scan.pct5h 30 $pctColor5 $fgBarDim
    $countdown5 = [string]$emDash
    if ($Scan.oldest5h) {
        $rollOut = $Scan.oldest5h.AddHours(5) - $NowUtc
        if ($rollOut.TotalSeconds -gt 0) { $countdown5 = Fmt-Duration $rollOut }
    }
    $pctText5 = if ($Scan.pct5h -ge 0) { (Color $pctColor5 ('{0,3:0}%' -f $Scan.pct5h)) } else { (Color $fgDim ' --%') }
    # Fable joins the inline split only when it has usage, so the line keeps
    # its existing width for anyone who never runs it.
    $splitParts = @()
    if ($Scan.modelTokens.fable -gt 0) {
        $splitParts += ('fable {0}' -f (Fmt-Tokens $Scan.modelTokens.fable))
    }
    $splitParts += ('opus {0}'   -f (Fmt-Tokens $Scan.modelTokens.opus))
    $splitParts += ('sonnet {0}' -f (Fmt-Tokens $Scan.modelTokens.sonnet))
    $splitParts += ('haiku {0}'  -f (Fmt-Tokens $Scan.modelTokens.haiku))
    $inlineSplit = $splitParts -join '  |  '
    [void]$lines.Add((Color $fg5h "5-HOUR WINDOW") + (' ' * 6) +
        ("{0} {1}  {2} tok   {3}" -f $bar5, $pctText5, (Fmt-Tokens $Scan.tok5h), (Fmt-Cost $Scan.cost5h)))
    [void]$lines.Add((Color $fgDim "     oldest turn rolls out in $countdown5") + '   ' +
        (Color $fgDim $inlineSplit))
    [void]$lines.Add('')

    # 7-day window ---------------------------------------------------------
    $pctColor7 = Get-PctColor $Scan.pct7d
    $bar7 = Make-Bar $Scan.pct7d 30 $pctColor7 $fgBarDim
    $countdown7 = [string]$emDash
    if ($Scan.oldest7d) {
        $rollOut = $Scan.oldest7d.AddDays(7) - $NowUtc
        if ($rollOut.TotalSeconds -gt 0) { $countdown7 = Fmt-Duration $rollOut }
    }
    $pctText7 = if ($Scan.pct7d -ge 0) { (Color $pctColor7 ('{0,3:0}%' -f $Scan.pct7d)) } else { (Color $fgDim ' --%') }
    $projCount = ($Scan.projectTokens.Keys).Count
    [void]$lines.Add((Color $fg7d "7-DAY WINDOW ") + (' ' * 6) +
        ("{0} {1}  {2} tok   {3}" -f $bar7, $pctText7, (Fmt-Tokens $Scan.tok7d), (Fmt-Cost $Scan.cost7d)))
    [void]$lines.Add((Color $fgDim "     oldest turn rolls out in $countdown7") + '   ' +
        (Color $fgDim ("{0} sessions, {1} projects touched" -f $Scan.sessionsLastWeek, $projCount)))
    [void]$lines.Add('')

    # Current session ------------------------------------------------------
    $sessDur = ''
    if ($Scan.sessionStart) { $sessDur = Fmt-Duration ($NowUtc - $Scan.sessionStart) }
    else { $sessDur = 'idle' }
    $sessText = "{0}, {1} turns" -f $sessDur, $Scan.sessionTurns
    [void]$lines.Add((Color $fgSess "CURRENT SESSION") + '    ' + (Color $fgDim $sessText.PadRight(30)) +
        ("{0} tok   {1}" -f (Fmt-Tokens $Scan.tokSession), (Fmt-Cost $Scan.costSession)))

    # Context tokens — assume a 200k window unless the latest turn used Opus
    # 4.7 1M, which we don't reliably distinguish from its 200k sibling here.
    $ctxLimit = 200000
    $ctxPct = 0.0
    if ($ctxLimit -gt 0) { $ctxPct = [math]::Min(100, ($Scan.ctxTokens / [double]$ctxLimit) * 100) }
    [void]$lines.Add((Color $fgCtx "CONTEXT        ") + '    ' +
        (Color $fgDim ("{0} / 200k  ({1:0}%)" -f (Fmt-Tokens $Scan.ctxTokens), $ctxPct)))

    # Loop watch (#41) ------------------------------------------------------
    # Three states, and the quiet one is stated explicitly rather than omitted:
    # a blank line can't distinguish "checked, found nothing" from "didn't run".
    $lw = $Scan.loop
    if ($null -ne $lw) {
        if ($lw.tripped) {
            [void]$lines.Add((Color $fgPctRed "LOOP WATCH     ") + '    ' +
                ("{0} turns cycling {1} distinct call(s)   {2} tok   {3}   {4}" -f
                    $lw.turns, $lw.distinct, (Fmt-Tokens $lw.tokens),
                    (Fmt-Cost $lw.cost), (Fmt-Duration $lw.span)))
            foreach ($c in ($lw.calls | Select-Object -First 2)) {
                [void]$lines.Add((Color $fgDim ('                   ' + $c)))
            }
        } elseif ($null -ne $lw.distinct -and $lw.distinct -le $script:loopMaxDistinct) {
            # Repetitive but under the token floor. This is what a deliberate
            # polling loop looks like, so it is reported, not alarmed about.
            [void]$lines.Add((Color $fgPctYellow "LOOP WATCH     ") + '    ' +
                (Color $fgDim ("repeating but cheap - {0} turns, {1} tok (floor {2})" -f
                    $lw.turns, (Fmt-Tokens $lw.tokens), (Fmt-Tokens $script:loopTokenFloor))))
        } elseif ($null -ne $lw.distinct) {
            [void]$lines.Add((Color $fgCtx "LOOP WATCH     ") + '    ' +
                (Color $fgDim ("quiet - {0} of last {1} tool turns distinct" -f
                    $lw.distinct, $lw.window)))
        } else {
            [void]$lines.Add((Color $fgCtx "LOOP WATCH     ") + '    ' +
                (Color $fgDim ("quiet - fewer than {0} tool turns to compare" -f $lw.window)))
        }
    }
    [void]$lines.Add('')

    # Top projects + top models --------------------------------------------
    [void]$lines.Add((Color $fgLabel "TOP PROJECTS (7d)") + '                    ' +
        (Color $fgLabel "TOP MODELS (7d)"))
    $topProjects = @($Scan.projectTokens.GetEnumerator() |
        Sort-Object -Property Value -Descending | Select-Object -First 5)
    $modelRows = @()
    # Same rule as the inline split: Fable earns a row once it has usage.
    if ($Scan.modelTokens.fable -gt 0) {
        $modelRows += @{ name = 'fable'; tok = $Scan.modelTokens.fable; cost = $Scan.modelCost.fable; color = $fgFable }
    }
    $modelRows += @{ name = 'opus';   tok = $Scan.modelTokens.opus;   cost = $Scan.modelCost.opus;   color = $fgOpus  }
    $modelRows += @{ name = 'sonnet'; tok = $Scan.modelTokens.sonnet; cost = $Scan.modelCost.sonnet; color = $fgSon   }
    $modelRows += @{ name = 'haiku';  tok = $Scan.modelTokens.haiku;  cost = $Scan.modelCost.haiku;  color = $fgHaiku }
    $rowsNeeded = [math]::Max($topProjects.Count, $modelRows.Count)
    if ($rowsNeeded -lt 3) { $rowsNeeded = 3 }
    for ($i = 0; $i -lt $rowsNeeded; $i++) {
        $left = ''
        if ($i -lt $topProjects.Count) {
            $name = $topProjects[$i].Key
            if ($name.Length -gt 24) { $name = $name.Substring(0, 23) + [string]$ellipsisCh }
            $left = (Color $fgProj $name.PadRight(26)) +
                (Color $fgDim (Fmt-Tokens ([long]$topProjects[$i].Value)).PadLeft(8))
        }
        $right = ''
        if ($i -lt $modelRows.Count) {
            $r = $modelRows[$i]
            $right = (Color $r.color $r.name.PadRight(8)) +
                (Color $fgDim (Fmt-Tokens ([long]$r.tok)).PadLeft(8)) + '  ' +
                (Color $fgDim (Fmt-Cost ([double]$r.cost)).PadLeft(8))
        }
        $leftPlain = $left -replace "$esc\[[0-9;]*m",''
        $padLen = 44 - $leftPlain.Length
        if ($padLen -lt 2) { $padLen = 2 }
        [void]$lines.Add($left + (' ' * $padLen) + $right)
    }
    [void]$lines.Add('')

    # Activity sparkline ---------------------------------------------------
    $spark = Make-Sparkline $Scan.sparkBuckets
    [void]$lines.Add((Color $fgLabel "RECENT ACTIVITY (last ${SparklineHours}h, per hour)"))
    [void]$lines.Add((Color $fg5h $spark))
    $oldestLabel = ('{0}h ago' -f $SparklineHours)
    $axis = (Color $fgDim $oldestLabel) + (' ' * ([math]::Max(1, $SparklineHours - $oldestLabel.Length - 3))) + (Color $fgDim 'now')
    [void]$lines.Add($axis)
    [void]$lines.Add('')

    # Footer ---------------------------------------------------------------
    # Plain ASCII separators in the footer — the U+00B7 middle dot used to
    # be here but it survives the script as raw UTF-8 bytes that downstream
    # consumers (capturing terminals, pipes) sometimes decode as Windows-1252
    # and render as `Â·`. Same failure mode the statusline em-dash hit.
    $footer = if ($Once) { 'one-shot' } else { "refresh every ${RefreshSeconds}s | Ctrl+C to exit" }
    $stamp = $NowUtc.ToLocalTime().ToString('HH:mm:ss')
    $rgap = $Width - $footer.Length - $stamp.Length - 16
    if ($rgap -lt 1) { $rgap = 1 }
    [void]$lines.Add((Color $fgDim $footer) + (' ' * $rgap) + (Color $fgDim "last update $stamp"))

    return ,$lines
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
$cursorWasVisible = $true
try { $cursorWasVisible = [Console]::CursorVisible } catch {}
try { [Console]::CursorVisible = $false } catch {}
Clear-Host

$previousHeight = 0
try {
    while ($true) {
        $nowUtc = [DateTime]::UtcNow
        $currentAccount = Read-CurrentAccount
        $checkpoints = Read-Checkpoints

        # Persist a checkpoint on org change so the dashboard contributes to
        # the same history file the statusline reads/writes. This keeps the
        # two tools in lockstep about account boundaries.
        if ($currentAccount) {
            $last = $null
            if ($checkpoints.Count -gt 0) { $last = $checkpoints[-1] }
            if (-not $last -or [string]$last.org -ne $currentAccount.org) {
                $checkpoints += @{
                    from  = $nowUtc.ToString('o')
                    org   = $currentAccount.org
                    email = $currentAccount.email
                    name  = $currentAccount.name
                }
                try {
                    @{ checkpoints = $checkpoints } |
                        ConvertTo-Json -Depth 4 |
                        Set-Content -Path $accountsPath -Encoding utf8
                } catch {}
            }
        }

        $scan = Invoke-Scan -NowUtc $nowUtc -CurrentAccount $currentAccount `
            -Checkpoints $checkpoints -SparklineHours $SparklineHours

        $expectedOrg = ''
        if ($currentAccount) { $expectedOrg = $currentAccount.org }
        $pcts = Read-RateLimitPcts $expectedOrg $nowUtc
        $scan.pct5h = $pcts.pct5h
        $scan.pct7d = $pcts.pct7d

        $width = 100
        try { $width = [Console]::WindowWidth } catch {}
        if ($width -lt 80) { $width = 80 }

        $frame = Build-Frame -Scan $scan -CurrentAccount $currentAccount `
            -NowUtc $nowUtc -RefreshSeconds $RefreshSeconds -Width $width

        try { [Console]::SetCursorPosition(0, 0) } catch {}
        foreach ($line in $frame) {
            # Pad the visible (non-ANSI) length out to width so the previous
            # frame's longer line tails don't survive into the new frame.
            $plain = $line -replace "$esc\[[0-9;]*m",''
            $padNeeded = $width - 1 - $plain.Length
            if ($padNeeded -lt 0) { $padNeeded = 0 }
            [Console]::Out.WriteLine($line + (' ' * $padNeeded))
        }
        # Clear any rows left behind by a previously-taller frame.
        for ($i = $frame.Count; $i -lt $previousHeight; $i++) {
            [Console]::Out.WriteLine(' ' * ($width - 1))
        }
        $previousHeight = $frame.Count

        if ($Once) { break }
        Start-Sleep -Seconds $RefreshSeconds
    }
} finally {
    try { [Console]::CursorVisible = $cursorWasVisible } catch {}
    Write-Host ''
}
