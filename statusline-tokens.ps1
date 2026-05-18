#Requires -Version 5.1
# Custom status line: 5h + 7d windows with native percentages AND token totals.
# Percentages come from rate_limits.{five_hour,seven_day}.used_percentage injected
# by Claude Code on stdin. Tokens are summed from ~/.claude/projects/**/*.jsonl
# entries whose timestamps fall inside the rolling 5h / 7d window.

$ErrorActionPreference = 'SilentlyContinue'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

# Without this, non-ASCII glyphs like ⎇ ✱ get downgraded to '?' by the
# system code page on Windows when PowerShell flushes stdout.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

$stdin = [Console]::In.ReadToEnd()
try { $hook = $stdin | ConvertFrom-Json -ErrorAction Stop } catch { $hook = $null }

function Fmt-Tokens([long]$n) {
    if ($n -ge 1000000) { '{0:0.0}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000.0) }
    else { "$n" }
}

# --- pricing (USD per 1M tokens) ------------------------------------------
# Source: Anthropic's published API rates. Update when they change.
# Cache write rates: 5m ephemeral = 1.25x input, 1h ephemeral = 2x input.
$prices = @{
    opus   = @{ input = 15.00; output = 75.00; cacheRead = 1.50; cacheW5m = 18.75; cacheW1h = 30.00 }
    sonnet = @{ input =  3.00; output = 15.00; cacheRead = 0.30; cacheW5m =  3.75; cacheW1h =  6.00 }
    haiku  = @{ input =  1.00; output =  5.00; cacheRead = 0.10; cacheW5m =  1.25; cacheW1h =  2.00 }
}
function Get-ModelFamily([string]$id) {
    if ($id -match 'opus')   { return 'opus' }
    if ($id -match 'sonnet') { return 'sonnet' }
    if ($id -match 'haiku')  { return 'haiku' }
    return 'opus'  # conservative fallback: over-estimate rather than under
}
function Fmt-Cost([double]$d) {
    if ($d -ge 1000) { return '${0:0.0}k' -f ($d / 1000.0) }
    if ($d -ge 100)  { return '${0:0}'   -f $d }
    if ($d -ge 1)    { return '${0:0.00}' -f $d }
    if ($d -gt 0)    { return '${0:0.00}' -f $d }   # e.g. $0.04
    return '$0.00'
}

# --- token sums across the rolling windows ---------------------------------
$nowUtc = [DateTime]::UtcNow
$cut5h  = $nowUtc.AddHours(-5)
$cut7d  = $nowUtc.AddDays(-7)

# "Session" = the most recent contiguous burst of activity, walking backward
# until we hit a gap larger than this many minutes between consecutive turns.
# This survives clock-midnight, Claude Code restarts, and account switches —
# it's about *your* continuous work, not the calendar or the active account.
$sessionGapMinutes = 30

$tok5h      = [long]0; $cost5h      = 0.0
$tok7d      = [long]0; $cost7d      = 0.0
$tokSession = [long]0; $costSession = 0.0   # all accounts contributing to the current burst

# Cross-platform user profile resolution. [Environment]::GetFolderPath
# returns "" rather than $null on non-Windows when the folder is unknown,
# so we explicitly fall through. $HOME is set by PowerShell on all
# platforms; $env:USERPROFILE is Windows-only and kept as a last resort.
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $HOME }
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $env:USERPROFILE }

# [IO.Path]::Combine handles per-OS separators and works in PS 5.1
# (whose Join-Path is two-arg only) as well as pwsh 7.
$projectsDir       = [System.IO.Path]::Combine($userProfile, '.claude', 'projects')
$cachePath         = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-tokens.cache.json')
$globalConfigPath  = [System.IO.Path]::Combine($userProfile, '.claude.json')
$accountsPath      = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-accounts.json')

# --- detect current account ----------------------------------------------
# ~/.claude.json carries oauthAccount.{organizationUuid, emailAddress, ...}
# We use organizationUuid as the stable identifier — it survives token
# refreshes and only changes when you actually sign into a different
# account/org.
#
# We can't ConvertFrom-Json the whole file: ~/.claude.json contains a
# projects map keyed by absolute path, and Windows-case-insensitive
# filesystems produce duplicate keys (e.g. "...\GitHub\VCASSE" and
# "...\github\vcasse") that PS 5.1's parser rejects. Instead, walk the
# JSON to extract just the oauthAccount object and parse that.
function Get-JsonObject([string]$content, [string]$keyName) {
    $needle = '"' + $keyName + '"'
    $start = $content.IndexOf($needle)
    if ($start -lt 0) { return $null }
    $braceStart = $content.IndexOf('{', $start)
    if ($braceStart -lt 0) { return $null }
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $braceStart; $i -lt $content.Length; $i++) {
        $c = $content[$i]
        if ($esc) { $esc = $false; continue }
        if ($inStr) {
            if ($c -eq '\') { $esc = $true; continue }
            if ($c -eq '"') { $inStr = $false }
            continue
        }
        if ($c -eq '"') { $inStr = $true; continue }
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                return $content.Substring($braceStart, $i - $braceStart + 1)
            }
        }
    }
    return $null
}

$currentAccount = $null
if (Test-Path $globalConfigPath) {
    try {
        # -Encoding UTF8 because Claude Code writes ~/.claude.json without a
        # BOM; PS 5.1's default reader assumes the system code page and
        # mangles non-ASCII org names (accented characters, CJK, etc).
        $raw = Get-Content -Raw -Encoding UTF8 $globalConfigPath
        $block = Get-JsonObject $raw 'oauthAccount'
        if ($block) {
            $oa = $block | ConvertFrom-Json
            if ($oa.organizationUuid) {
                $currentAccount = @{
                    org   = [string]$oa.organizationUuid
                    email = [string]$oa.emailAddress
                    name  = [string]$oa.organizationName
                }
            }
        }
    } catch {}
}

# --- load and update account checkpoints ---------------------------------
# Append a new checkpoint whenever the current organizationUuid differs
# from the last recorded one. Each checkpoint owns the time-range from
# its 'from' value to the next checkpoint's 'from' (or now).
$checkpoints = @()
if (Test-Path $accountsPath) {
    try {
        # ReadAllText is BOM-tolerant by default (auto-detects UTF-8/16
        # BOMs, falls back to UTF-8) and behaves identically on PS 5.1 and
        # pwsh 7 — unlike Get-Content -Encoding UTF8, which writes the
        # BOM in PS 5.1 but not in pwsh 7.
        $loaded = [System.IO.File]::ReadAllText($accountsPath) | ConvertFrom-Json
        if ($loaded.checkpoints) { $checkpoints = @($loaded.checkpoints) }
    } catch {}
}
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
            # WriteAllText with UTF8Encoding($false) is the only way to
            # produce a no-BOM file that's byte-identical across PS 5.1
            # and pwsh 7. Set-Content -Encoding utf8 emits a BOM on PS
            # 5.1 and no BOM on pwsh 7.
            $body = @{ checkpoints = $checkpoints } | ConvertTo-Json -Depth 4
            [System.IO.File]::WriteAllText($accountsPath, $body, [System.Text.UTF8Encoding]::new($false))
        } catch {}
    }
}

# Map a UTC timestamp to the account that owned it at that moment.
# Pre-first-checkpoint history is attributed to the earliest checkpoint —
# i.e., "if you install this script while signed into account A, all your
# past usage shows as A; future switches are tracked correctly from
# install onward."
function Account-At([DateTime]$t) {
    if (-not $script:checkpoints -or $script:checkpoints.Count -eq 0) { return $null }
    $acct = $script:checkpoints[0]
    foreach ($cp in $script:checkpoints) {
        try { $cpTime = [DateTime]::Parse($cp.from).ToUniversalTime() } catch { continue }
        if ($t -ge $cpTime) { $acct = $cp } else { break }
    }
    return $acct
}

# Field-level regex extraction — ConvertFrom-Json per line is too slow on 19MB+.
$rxTs       = [regex]'"timestamp":"([^"]+)"'
$rxMsgId    = [regex]'"id":"(msg_[A-Za-z0-9]+)"'
$rxModel    = [regex]'"model":"(claude-[^"]+)"'
$rxInput    = [regex]'"input_tokens":(\d+)'
$rxOutput   = [regex]'"output_tokens":(\d+)'
$rxCacheC   = [regex]'"cache_creation_input_tokens":(\d+)'
$rxCacheR   = [regex]'"cache_read_input_tokens":(\d+)'
$rxCache5m  = [regex]'"ephemeral_5m_input_tokens":(\d+)'
$rxCache1h  = [regex]'"ephemeral_1h_input_tokens":(\d+)'

# Cache: full scan takes ~600-800ms over 19MB+, but the statusline re-renders
# on every turn. Reuse the cached numbers if computed within the last 20s.
$cacheTtlSec = 20
$useCache = $false
$currentOrgKey = ''
if ($currentAccount) { $currentOrgKey = $currentAccount.org }
if (Test-Path $cachePath) {
    try {
        $cache = [System.IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
        $age = ($nowUtc - [DateTime]::Parse($cache.computedAtUtc).ToUniversalTime()).TotalSeconds
        # Invalidate if the active account changed since last scan — otherwise
        # the cached per-account numbers belong to the wrong org.
        $cachedOrg = ''
        if ($cache.PSObject.Properties.Match('orgKey').Count -gt 0) { $cachedOrg = [string]$cache.orgKey }
        if ($age -ge 0 -and $age -lt $cacheTtlSec -and $cachedOrg -eq $currentOrgKey) {
            $tok5h       = [long]$cache.tok5h
            $tok7d       = [long]$cache.tok7d
            $cost5h      = [double]$cache.cost5h
            $cost7d      = [double]$cache.cost7d
            $tokSession  = [long]$cache.tokSession
            $costSession = [double]$cache.costSession
            $useCache    = $true
        }
    } catch {}
}

if (-not $useCache -and (Test-Path $projectsDir)) {
    $seen = @{}
    # All scanned turns, regardless of account, used after the scan to
    # detect the session boundary by walking backward through time.
    $turns = New-Object System.Collections.ArrayList
    $files = Get-ChildItem -Path $projectsDir -Filter *.jsonl -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -gt $cut7d }

    foreach ($f in $files) {
        $reader = $null
        try {
            $reader = [System.IO.File]::OpenText($f.FullName)
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not $line) { continue }
                # Cheap filter — only lines with a usage block carry tokens.
                if ($line.IndexOf('"usage"') -lt 0) { continue }

                $mTs = $rxTs.Match($line)
                if (-not $mTs.Success) { continue }
                $t = $null
                try { $t = [DateTime]::Parse($mTs.Groups[1].Value).ToUniversalTime() }
                catch { continue }
                if ($t -lt $cut7d) { continue }

                # Dedupe by message id — the same assistant turn is logged
                # once per content block (thinking, tool_use, ...) and each
                # log carries the same usage. Counting them all triples the
                # number.
                $mId = $rxMsgId.Match($line)
                if ($mId.Success) {
                    $key = $mId.Groups[1].Value
                    if ($seen.ContainsKey($key)) { continue }
                    $seen[$key] = $true
                }

                $tIn = 0L; $tOut = 0L; $tCacheC = 0L; $tCacheR = 0L; $t5m = 0L; $t1h = 0L
                $m = $rxInput.Match($line)   ; if ($m.Success) { $tIn     = [long]$m.Groups[1].Value }
                $m = $rxOutput.Match($line)  ; if ($m.Success) { $tOut    = [long]$m.Groups[1].Value }
                $m = $rxCacheC.Match($line)  ; if ($m.Success) { $tCacheC = [long]$m.Groups[1].Value }
                $m = $rxCacheR.Match($line)  ; if ($m.Success) { $tCacheR = [long]$m.Groups[1].Value }
                $m = $rxCache5m.Match($line) ; if ($m.Success) { $t5m     = [long]$m.Groups[1].Value }
                $m = $rxCache1h.Match($line) ; if ($m.Success) { $t1h     = [long]$m.Groups[1].Value }

                $sum = $tIn + $tOut + $tCacheC + $tCacheR
                if ($sum -le 0) { continue }

                # Per-turn cost using this turn's model
                $modelId = ''
                $mm = $rxModel.Match($line); if ($mm.Success) { $modelId = $mm.Groups[1].Value }
                $p = $prices[(Get-ModelFamily $modelId)]
                # If the 5m/1h breakdown isn't present (older transcripts),
                # fall back to charging all cache creation at the 5m rate
                # (the API default and the cheaper of the two).
                if (($t5m + $t1h) -le 0) { $t5m = $tCacheC; $t1h = 0L }
                $cost = (
                    $tIn     * $p.input     +
                    $tOut    * $p.output    +
                    $tCacheR * $p.cacheRead +
                    $t5m     * $p.cacheW5m  +
                    $t1h     * $p.cacheW1h
                ) / 1000000.0

                # Attribute the turn to the account that was active at
                # its timestamp. If no checkpoints exist yet (first run, no
                # ~/.claude.json), $turnAcct is $null and we fall back to
                # treating every turn as "current" — preserves the old
                # single-account behavior.
                $turnAcct = Account-At $t
                $isCurrent = $true
                if ($currentAccount) {
                    $isCurrent = ($turnAcct -and [string]$turnAcct.org -eq $currentAccount.org)
                }

                if ($isCurrent) {
                    $tok7d  += $sum
                    $cost7d += $cost
                    if ($t -gt $cut5h) {
                        $tok5h  += $sum
                        $cost5h += $cost
                    }
                }
                # Capture every turn (any account) for session detection
                # below — session is account-independent.
                [void]$turns.Add(@{ ticks = $t.Ticks; sum = $sum; cost = $cost })
            }
            $reader.Close()
        } catch {
            if ($reader) { try { $reader.Close() } catch {} }
        }
    }

    # --- session boundary ----------------------------------------------------
    # A session is the current burst of contiguous activity, defined as
    # "the chain of turns ending at the most recent one, where no gap
    # between consecutive turns exceeds $sessionGapMinutes — AND the
    # most recent turn itself is within $sessionGapMinutes of now."
    #
    # If the latest turn is older than that, no session is "active" right
    # now and we report 0. The next new turn seeds a fresh session.
    if ($turns.Count -gt 0) {
        $gapTicks = [long]$sessionGapMinutes * [TimeSpan]::TicksPerMinute
        $sorted = @($turns | Sort-Object -Property { $_.ticks } -Descending)
        $latestTicks = $sorted[0].ticks
        if (($nowUtc.Ticks - $latestTicks) -le $gapTicks) {
            $prev = $latestTicks
            foreach ($e in $sorted) {
                if (($prev - $e.ticks) -gt $gapTicks) { break }
                $tokSession  += [long]$e.sum
                $costSession += [double]$e.cost
                $prev = $e.ticks
            }
        }
    }

}

# --- native percentages from hook stdin -----------------------------------
$pct5h = $null
$pct7d = $null
if ($hook -and $hook.rate_limits) {
    if ($hook.rate_limits.five_hour) { $pct5h = $hook.rate_limits.five_hour.used_percentage }
    if ($hook.rate_limits.seven_day) { $pct7d = $hook.rate_limits.seven_day.used_percentage }
}

# Always rewrite the cache so claude-dashboard.ps1 (which reads this same
# file) picks up fresh percentages on every Claude Code turn, even on cache
# HIT paths where we skipped re-scanning tokens. The pcts come from the hook
# stdin which is provided on every invocation; tokens come from either the
# fresh scan above or the prior cache values loaded earlier in the script.
try {
    $payload = @{
        computedAtUtc = $nowUtc.ToString('o')
        orgKey        = $currentOrgKey
        tok5h         = $tok5h
        tok7d         = $tok7d
        cost5h        = $cost5h
        cost7d        = $cost7d
        tokSession    = $tokSession
        costSession   = $costSession
    }
    if ($null -ne $pct5h) { $payload.pct5h = [double]$pct5h }
    if ($null -ne $pct7d) { $payload.pct7d = [double]$pct7d }
    if ($null -ne $pct5h -or $null -ne $pct7d) {
        $payload.pctSavedAtUtc = $nowUtc.ToString('o')
    }
    $body = $payload | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($cachePath, $body, [System.Text.UTF8Encoding]::new($false))
} catch {}

# --- context tokens: last usage block in the current session transcript --
$ctxTokens = [long]0
if ($hook -and $hook.transcript_path -and (Test-Path $hook.transcript_path)) {
    $lastUsageLine = $null
    foreach ($line in [System.IO.File]::ReadLines($hook.transcript_path)) {
        if ($line.IndexOf('"usage"') -ge 0) { $lastUsageLine = $line }
    }
    if ($lastUsageLine) {
        $sum = [long]0
        $m = $rxInput.Match($lastUsageLine) ; if ($m.Success) { $sum += [long]$m.Groups[1].Value }
        $m = $rxCacheC.Match($lastUsageLine); if ($m.Success) { $sum += [long]$m.Groups[1].Value }
        $m = $rxCacheR.Match($lastUsageLine); if ($m.Success) { $sum += [long]$m.Groups[1].Value }
        $ctxTokens = $sum
    }
}

# --- working dir + git ----------------------------------------------------
$dir = ''
if ($hook -and $hook.workspace -and $hook.workspace.current_dir) {
    $dir = Split-Path -Leaf $hook.workspace.current_dir
} elseif ($hook -and $hook.cwd) {
    $dir = Split-Path -Leaf $hook.cwd
}

$gitBranch = ''
$cwd = $null
if ($hook) { $cwd = $hook.workspace.current_dir; if (-not $cwd) { $cwd = $hook.cwd } }
# Read .git/HEAD directly instead of shelling out to git. Shelling out
# costs ~30-80 ms per render, fragments the rendering budget, and leaks
# $LASTEXITCODE up to the caller. .git/HEAD is a one-line file:
#   "ref: refs/heads/<name>"  → branch <name>
#   "<40-char SHA>"           → detached HEAD, render first 7
# Worktrees use .git as a *file* pointing at the real gitdir; resolve
# that before reading HEAD.
if ($cwd -and (Test-Path $cwd)) {
    try {
        $gitPath = [System.IO.Path]::Combine($cwd, '.git')
        if (Test-Path $gitPath) {
            $gitDir = $gitPath
            $info = Get-Item $gitPath -Force -ErrorAction SilentlyContinue
            if ($info -and -not $info.PSIsContainer) {
                # .git is a file: "gitdir: <path>"
                $pointer = [System.IO.File]::ReadAllText($gitPath).Trim()
                if ($pointer.StartsWith('gitdir:')) {
                    $resolved = $pointer.Substring(7).Trim()
                    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                        $resolved = [System.IO.Path]::GetFullPath(
                            [System.IO.Path]::Combine($cwd, $resolved))
                    }
                    $gitDir = $resolved
                }
            }
            $headPath = [System.IO.Path]::Combine($gitDir, 'HEAD')
            if (Test-Path $headPath) {
                $head = [System.IO.File]::ReadAllText($headPath).Trim()
                if ($head.StartsWith('ref:')) {
                    $ref = $head.Substring(4).Trim()
                    if ($ref.StartsWith('refs/heads/')) {
                        $gitBranch = $ref.Substring(11)
                    } else {
                        $gitBranch = $ref
                    }
                } elseif ($head -match '^[0-9a-fA-F]{40}$') {
                    $gitBranch = $head.Substring(0, 7)
                }
            }
        }
    } catch {}
}

$model = ''
if ($hook -and $hook.model -and $hook.model.display_name) { $model = $hook.model.display_name }

# --- compose --------------------------------------------------------------
$esc = [char]27
$reset = "$esc[0m"
$fgDim = "$esc[38;5;245m"
$fgDir = "$esc[38;5;215m"
$fgGit = "$esc[38;5;180m"
$fgMod = "$esc[38;5;141m"
$fg5h      = "$esc[38;5;81m"
$fg7d      = "$esc[38;5;108m"
$fgSession = "$esc[38;5;178m"   # current work-burst, every account (gold)
$fgCtx     = "$esc[38;5;110m"

function Color($fg, $text) { "$fg$text$reset" }

$parts = @()
if ($dir)       { $parts += (Color $fgDir $dir) }
if ($gitBranch) { $parts += (Color $fgGit $gitBranch.Trim()) }
if ($model)     { $parts += (Color $fgMod $model) }

# Pure-ASCII placeholder for the loading state (percentages not yet supplied
# by the hook — typical at session start or right after an account switch).
# Earlier versions used a U+2014 em-dash, but even with the script saved as
# UTF-8-with-BOM and the glyph constructed via [char]0x2014, some consumers
# of the status-line output still decoded the bytes as Windows-1252 and
# rendered 'â€"'. ASCII removes that failure mode entirely.
$loading = '--%'
if ($null -ne $pct5h) { $p5 = '{0}%' -f [int][math]::Round([double]$pct5h) } else { $p5 = $loading }
if ($null -ne $pct7d) { $p7 = '{0}%' -f [int][math]::Round([double]$pct7d) } else { $p7 = $loading }
$parts += (Color $fg5h      ("5h {0} ({1} tok, {2})" -f $p5, (Fmt-Tokens $tok5h),      (Fmt-Cost $cost5h)))
$parts += (Color $fg7d      ("7d {0} ({1} tok, {2})" -f $p7, (Fmt-Tokens $tok7d),      (Fmt-Cost $cost7d)))
$parts += (Color $fgSession ("session {0} ({1})"     -f       (Fmt-Tokens $tokSession), (Fmt-Cost $costSession)))
$parts += (Color $fgCtx     ("ctx {0}"               -f       (Fmt-Tokens $ctxTokens)))

$sep = " $fgDim|$reset "
[Console]::Out.Write([string]::Join($sep, $parts))
