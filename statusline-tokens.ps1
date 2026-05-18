#Requires -Version 5.1
# Custom status line: 5h + 7d windows with native percentages AND token totals.
# Percentages come from rate_limits.{five_hour,seven_day}.used_percentage injected
# by Claude Code on stdin. Tokens are summed from ~/.claude/projects/**/*.jsonl
# entries whose timestamps fall inside the rolling 5h / 7d window.

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
$nowUtc  = [DateTime]::UtcNow
$cut5h   = $nowUtc.AddHours(-5)
$cut7d   = $nowUtc.AddDays(-7)

$tok5h = [long]0
$tok7d = [long]0
$cost5h = 0.0
$cost7d = 0.0

$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
$cachePath   = Join-Path $env:USERPROFILE '.claude\statusline-tokens.cache.json'

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
if (Test-Path $cachePath) {
    try {
        $cache = Get-Content -Raw $cachePath | ConvertFrom-Json
        $age = ($nowUtc - [DateTime]::Parse($cache.computedAtUtc).ToUniversalTime()).TotalSeconds
        if ($age -ge 0 -and $age -lt $cacheTtlSec) {
            $tok5h    = [long]$cache.tok5h
            $tok7d    = [long]$cache.tok7d
            $cost5h   = [double]$cache.cost5h
            $cost7d   = [double]$cache.cost7d
            $useCache = $true
        }
    } catch {}
}

if (-not $useCache -and (Test-Path $projectsDir)) {
    $seen = @{}
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
                # number. Check the key now but only commit it after the
                # line is proven to have real usage data, so a malformed or
                # zero-usage line can't poison the dedupe set.
                $key = $null
                $mId = $rxMsgId.Match($line)
                if ($mId.Success) {
                    $key = $mId.Groups[1].Value
                    if ($seen.ContainsKey($key)) { continue }
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
                if ($key) { $seen[$key] = $true }

                # Per-turn cost using this turn's model
                $modelId = ''
                $mm = $rxModel.Match($line); if ($mm.Success) { $modelId = $mm.Groups[1].Value }
                $p = $prices[(Get-ModelFamily $modelId)]
                # If the 5m/1h breakdown isn't present (older transcripts),
                # charge all cache creation at the 5m rate — that's the default
                # TTL for unflagged cache_control blocks, and the cheaper of
                # the two ephemeral tiers.
                if (($t5m + $t1h) -le 0) { $t5m = $tCacheC; $t1h = 0L }
                $cost = (
                    $tIn     * $p.input     +
                    $tOut    * $p.output    +
                    $tCacheR * $p.cacheRead +
                    $t5m     * $p.cacheW5m  +
                    $t1h     * $p.cacheW1h
                ) / 1000000.0

                $tok7d  += $sum
                $cost7d += $cost
                if ($t -gt $cut5h) {
                    $tok5h  += $sum
                    $cost5h += $cost
                }
            }
            $reader.Close()
        } catch {
            if ($reader) { try { $reader.Close() } catch {} }
        }
    }

    # Write atomically — two concurrent statusline invocations would otherwise
    # race on Set-Content's truncate-then-write, and the slower one could
    # overwrite fresher numbers with stale ones. tmp + Move-Item -Force is
    # atomic on NTFS.
    try {
        $tmpCache = "$cachePath.tmp"
        @{
            computedAtUtc = $nowUtc.ToString('o')
            tok5h         = $tok5h
            tok7d         = $tok7d
            cost5h        = $cost5h
            cost7d        = $cost7d
        } | ConvertTo-Json -Compress | Set-Content -Path $tmpCache -Encoding utf8
        Move-Item -Path $tmpCache -Destination $cachePath -Force
    } catch {}
}

# --- native percentages from hook stdin -----------------------------------
$pct5h = $null
$pct7d = $null
if ($hook -and $hook.rate_limits) {
    if ($hook.rate_limits.five_hour) { $pct5h = $hook.rate_limits.five_hour.used_percentage }
    if ($hook.rate_limits.seven_day) { $pct7d = $hook.rate_limits.seven_day.used_percentage }
}

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
# Reject paths whose first char is '-' — git would parse them as a flag for -C
# (argument injection). Modern git mitigates running in untrusted directories
# via safe.directory (CVE-2022-24765), but this guard is essentially free.
if ($cwd -and ($cwd[0] -ne '-') -and (Test-Path -LiteralPath $cwd)) {
    try {
        $gitBranch = (& git -C $cwd rev-parse --abbrev-ref HEAD 2>$null)
        # Detached HEAD returns the literal string "HEAD"; show short SHA instead.
        if ($gitBranch -eq 'HEAD') {
            $gitBranch = (& git -C $cwd rev-parse --short HEAD 2>$null)
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
$fg5h  = "$esc[38;5;81m"
$fg7d  = "$esc[38;5;108m"
$fgCtx = "$esc[38;5;110m"

function Color($fg, $text) { "$fg$text$reset" }

$parts = @()
if ($dir)       { $parts += (Color $fgDir $dir) }
if ($gitBranch) { $parts += (Color $fgGit $gitBranch.Trim()) }
if ($model)     { $parts += (Color $fgMod $model) }

if ($null -ne $pct5h) { $p5 = '{0}%' -f [int][math]::Round([double]$pct5h) } else { $p5 = '—' }
if ($null -ne $pct7d) { $p7 = '{0}%' -f [int][math]::Round([double]$pct7d) } else { $p7 = '—' }
$parts += (Color $fg5h ("5h {0} ({1} tok, {2})" -f $p5, (Fmt-Tokens $tok5h), (Fmt-Cost $cost5h)))
$parts += (Color $fg7d ("7d {0} ({1} tok, {2})" -f $p7, (Fmt-Tokens $tok7d), (Fmt-Cost $cost7d)))
$parts += (Color $fgCtx ("ctx {0}" -f (Fmt-Tokens $ctxTokens)))

$sep = " $fgDim|$reset "
[Console]::Out.Write([string]::Join($sep, $parts))
