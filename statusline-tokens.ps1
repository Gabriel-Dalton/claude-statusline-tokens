#Requires -Version 5.1
# Custom status line: 5h + 7d windows with native percentages AND token totals.
# Percentages come from rate_limits.{five_hour,seven_day}.used_percentage injected
# by Claude Code on stdin. Tokens are summed from ~/.claude/projects/**/*.jsonl
# entries whose timestamps fall inside the rolling 5h / 7d window.

[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

# Stub: M2-05 will route to a rotating log at ~/.claude/statusline-tokens.log
# when $env:STATUSLINE_DEBUG is set. For now this swallows quietly.
function Write-DebugLog {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true, Position=0)]
        [object]$Message,
        [string]$Scope = ''
    )
    # Intentional no-op until M2-05.
}

# Without this, non-ASCII glyphs like ⎇ ✱ get downgraded to '?' by the
# system code page on Windows when PowerShell flushes stdout.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# Bounded stdin read: Claude Code pipes JSON, but if the script is launched
# from a TTY (manual invocation, debug) or the spawn forgot to attach stdin,
# a blocking ReadToEnd() would hang the statusline forever. The contract
# is "always print something fast"; bail with a fallback line if no input
# arrives within 200 ms.
#
# Implementation note: [Console]::In.ReadToEndAsync() looks tempting but
# isn't truly async on PS 5.1's StreamReader-wrapped console stream — the
# task only completes when the underlying blocking read returns, so
# Wait(200) routinely waits seconds instead of milliseconds. Going one
# layer lower to the raw byte stream via OpenStandardInput + BeginRead
# uses Win32 async pipe I/O, which does honor the timeout.
if (-not [Console]::IsInputRedirected) {
    [Console]::Out.Write("statusline-tokens: no hook input")
    exit 0
}
$stdin = ''
try {
    $stdinStream = [Console]::OpenStandardInput()
    $stdinBuf    = New-Object byte[] 4096
    $stdinMem    = New-Object System.IO.MemoryStream
    $stdinEnd    = [DateTime]::UtcNow.AddMilliseconds(200)
    while ($true) {
        $remaining = [int]([math]::Max(0, ($stdinEnd - [DateTime]::UtcNow).TotalMilliseconds))
        if ($remaining -le 0) { break }
        $iar = $stdinStream.BeginRead($stdinBuf, 0, $stdinBuf.Length, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($remaining)) { break }
        $n = $stdinStream.EndRead($iar)
        if ($n -le 0) { break }
        $stdinMem.Write($stdinBuf, 0, $n)
    }
    $stdinBytes = $stdinMem.ToArray()
    # Strip a leading UTF-8 BOM if present — Encoding.UTF8.GetString does
    # not auto-strip it the way StreamReader does, and PS 5.1's
    # ConvertFrom-Json rejects a leading U+FEFF with "Invalid JSON
    # primitive: ." Powershell's piping layer prepends a BOM in 5.1.
    if ($stdinBytes.Length -ge 3 -and $stdinBytes[0] -eq 0xEF -and $stdinBytes[1] -eq 0xBB -and $stdinBytes[2] -eq 0xBF) {
        $stdin = [System.Text.Encoding]::UTF8.GetString($stdinBytes, 3, $stdinBytes.Length - 3)
    } else {
        $stdin = [System.Text.Encoding]::UTF8.GetString($stdinBytes)
    }
} catch {
    Write-DebugLog $_ -Scope 'stdin-read'
    $stdin = ''
}
if ([string]::IsNullOrWhiteSpace($stdin)) {
    [Console]::Out.Write("statusline-tokens: no hook input")
    exit 0
}
try { $hook = $stdin | ConvertFrom-Json -ErrorAction Stop } catch {
    Write-DebugLog $_ -Scope 'hook-parse'
    $hook = $null
}

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
#
# Implementation note: we navigate by [string]::IndexOf / IndexOfAny rather
# than iterating $content[$i] one [char] at a time. The earlier per-char
# walk worked on ASCII names but read each UTF-16 code unit independently,
# which means a non-BMP codepoint (e.g. emoji 🚀 in organizationName) is
# decomposed into two lone surrogates during iteration. The brace counter
# itself is fine (braces are ASCII), but per-char state-machine logic on
# lone surrogates is fragile under PS 5.1's [char]/[string] coercion rules.
# Seeking the next interesting ASCII byte sidesteps that class of bug
# entirely and is faster on the multi-KB ~/.claude.json file.
function Get-JsonObject([string]$content, [string]$keyName) {
    $needle = '"' + $keyName + '"'
    $start = $content.IndexOf($needle)
    if ($start -lt 0) { return $null }
    $braceStart = $content.IndexOf('{', $start)
    if ($braceStart -lt 0) { return $null }
    # Significant characters: opening/closing brace, string delimiter,
    # backslash (escape inside string). Everything else — including any
    # high/low surrogate halves of an astral codepoint — is skipped.
    $interesting = [char[]]@('{','}','"','\')
    $i = $braceStart
    $depth = 0
    $inStr = $false
    while ($i -lt $content.Length) {
        if ($inStr) {
            # Inside a string: only " (terminator) and \ (next char is escaped)
            # matter. IndexOfAny jumps directly to the next one.
            $j = $content.IndexOfAny($interesting, $i)
            if ($j -lt 0) { return $null }
            $c = $content[$j]
            if ($c -eq '\') {
                # Skip the escaped character. \uXXXX is fine: we resume two
                # positions later and IndexOfAny will find the next " anyway,
                # whatever the four hex digits are.
                $i = $j + 2
                continue
            }
            if ($c -eq '"') {
                $inStr = $false
                $i = $j + 1
                continue
            }
            # Stray { or } inside a string — not interesting, advance past it.
            $i = $j + 1
            continue
        }
        # Outside any string: braces change depth, " opens a string. \ is not
        # meaningful here (JSON doesn't allow bare backslashes outside strings).
        $j = $content.IndexOfAny($interesting, $i)
        if ($j -lt 0) { return $null }
        $c = $content[$j]
        if ($c -eq '"') {
            $inStr = $true
            $i = $j + 1
            continue
        }
        if ($c -eq '{') {
            $depth++
            $i = $j + 1
            continue
        }
        if ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                # Both endpoints are ASCII braces, so this substring slice
                # cannot bisect a surrogate pair; the returned block is
                # well-formed UTF-16 even when organizationName contains
                # astral-plane characters.
                return $content.Substring($braceStart, $j - $braceStart + 1)
            }
            $i = $j + 1
            continue
        }
        # Backslash outside a string — shouldn't happen in valid JSON, but
        # don't loop forever on it.
        $i = $j + 1
    }
    return $null
}

$currentAccount = $null
if (Test-Path $globalConfigPath) {
    try {
        # -Encoding UTF8 because Claude Code writes ~/.claude.json without a
        # BOM; PS 5.1's default reader assumes the system code page and
        # mangles non-ASCII org names (accented characters, CJK, etc).
        $raw = Get-Content -Raw -Encoding UTF8 $globalConfigPath -ErrorAction Stop
        $block = Get-JsonObject $raw 'oauthAccount'
        if ($block) {
            $oa = $block | ConvertFrom-Json -ErrorAction Stop
            if ($oa.organizationUuid) {
                $currentAccount = @{
                    org   = [string]$oa.organizationUuid
                    email = [string]$oa.emailAddress
                    name  = [string]$oa.organizationName
                }
            }
        }
    } catch { Write-DebugLog $_ -Scope 'oauth-parse' }
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
        $loaded = [System.IO.File]::ReadAllText($accountsPath) | ConvertFrom-Json -ErrorAction Stop
        if ($loaded.checkpoints) { $checkpoints = @($loaded.checkpoints) }
    } catch { Write-DebugLog $_ -Scope 'accounts-load' }
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
            $body = @{ checkpoints = $checkpoints } | ConvertTo-Json -Depth 4 -ErrorAction Stop
            [System.IO.File]::WriteAllText($accountsPath, $body, [System.Text.UTF8Encoding]::new($false))
        } catch { Write-DebugLog $_ -Scope 'accounts-write' }
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
        try { $cpTime = [DateTime]::Parse($cp.from).ToUniversalTime() } catch {
            Write-DebugLog $_ -Scope 'checkpoint-parse'
            continue
        }
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
$cacheSchemaVersion = 2   # bump when on-disk shape changes; older caches discarded
$useCache = $false
$currentOrgKey = ''
if ($currentAccount) { $currentOrgKey = $currentAccount.org }
# Per-transcript tail cache (M1-04): keyed by absolute path, each entry
# carries `length`, `lastScanOffset`, `lastUsageLine`, and `turns` from
# the previous scan. Always loaded (even on top-level cache HIT) so the
# next MISS can resume cheaply.
$transcriptCache = @{}
if (Test-Path $cachePath) {
    try {
        $cache = [System.IO.File]::ReadAllText($cachePath) | ConvertFrom-Json -ErrorAction Stop
        $age = ($nowUtc - [DateTime]::Parse($cache.computedAtUtc).ToUniversalTime()).TotalSeconds
        # Invalidate if the active account changed since last scan — otherwise
        # the cached per-account numbers belong to the wrong org.
        $cachedOrg = ''
        if ($cache.PSObject.Properties.Match('orgKey').Count -gt 0) { $cachedOrg = [string]$cache.orgKey }
        $cachedVer = 0
        if ($cache.PSObject.Properties.Match('schemaVersion').Count -gt 0) { $cachedVer = [int]$cache.schemaVersion }
        if ($age -ge 0 -and $age -lt $cacheTtlSec -and $cachedOrg -eq $currentOrgKey) {
            $tok5h       = [long]$cache.tok5h
            $tok7d       = [long]$cache.tok7d
            $cost5h      = [double]$cache.cost5h
            $cost7d      = [double]$cache.cost7d
            $tokSession  = [long]$cache.tokSession
            $costSession = [double]$cache.costSession
            $useCache    = $true
        }
        # Per-transcript tail cache is only readable when the on-disk
        # shape matches what this script writes. An older cache from
        # v0.3 or earlier carries no `transcripts` dict; an even older
        # cache from a future incompatible bump would not be safe to
        # reuse. In either case, fall back to a full rescan — the
        # invalidation is automatic (we just don't populate
        # $transcriptCache here, so every file looks new).
        if ($cachedVer -eq $cacheSchemaVersion -and $cache.PSObject.Properties.Match('transcripts').Count -gt 0 -and $cache.transcripts) {
            foreach ($prop in $cache.transcripts.PSObject.Properties) {
                $transcriptCache[$prop.Name] = $prop.Value
            }
        }
    } catch { Write-DebugLog $_ -Scope 'cache-read' }
}

# Extract a turn from a single line. Returns a hashtable with ticks,
# sum, cost, msgId on success, or $null when the line isn't an
# assistant usage row (or carries no positive token count). The
# two-anchor probe is the M1-03 false-positive guard. Returning a
# hashtable lets the caller append to $turns and to the per-file
# cache without re-parsing.
function Parse-UsageLine([string]$line, [DateTime]$cut7dRef) {
    if (-not $line) { return $null }
    if ($line.IndexOf('"role":"assistant"') -lt 0) { return $null }
    if ($line.IndexOf('"usage":{') -lt 0) { return $null }

    $mTs = $rxTs.Match($line)
    if (-not $mTs.Success) { return $null }
    $t = $null
    try { $t = [DateTime]::Parse($mTs.Groups[1].Value).ToUniversalTime() }
    catch {
        Write-DebugLog $_ -Scope 'turn-timestamp-parse'
        return $null
    }
    if ($t -lt $cut7dRef) { return $null }

    $msgId = $null
    $mId = $rxMsgId.Match($line)
    if ($mId.Success) { $msgId = $mId.Groups[1].Value }

    $tIn = 0L; $tOut = 0L; $tCacheC = 0L; $tCacheR = 0L; $t5m = 0L; $t1h = 0L
    $m = $rxInput.Match($line)   ; if ($m.Success) { $tIn     = [long]$m.Groups[1].Value }
    $m = $rxOutput.Match($line)  ; if ($m.Success) { $tOut    = [long]$m.Groups[1].Value }
    $m = $rxCacheC.Match($line)  ; if ($m.Success) { $tCacheC = [long]$m.Groups[1].Value }
    $m = $rxCacheR.Match($line)  ; if ($m.Success) { $tCacheR = [long]$m.Groups[1].Value }
    $m = $rxCache5m.Match($line) ; if ($m.Success) { $t5m     = [long]$m.Groups[1].Value }
    $m = $rxCache1h.Match($line) ; if ($m.Success) { $t1h     = [long]$m.Groups[1].Value }

    $sum = $tIn + $tOut + $tCacheC + $tCacheR
    if ($sum -le 0) { return $null }

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

    return @{ ticks = $t.Ticks; sum = $sum; cost = $cost; msgId = $msgId }
}

# Apply a parsed turn to the rolling aggregates and the session-turn
# list. Dedupes by msgId (assistant turns get re-logged once per
# content block; counting all of them would triple-count tokens).
# Mutates the script-scope aggregates directly because PowerShell
# functions can't return-by-ref in PS 5.1.
function Apply-Turn($turn) {
    if (-not $turn) { return }
    if ($turn.msgId) {
        if ($script:seen.ContainsKey($turn.msgId)) { return }
        $script:seen[$turn.msgId] = $true
    }
    $t = [DateTime]::new([long]$turn.ticks, [DateTimeKind]::Utc)

    # Attribute the turn to the account that was active at
    # its timestamp. If no checkpoints exist yet (first run, no
    # ~/.claude.json), $turnAcct is $null and we fall back to
    # treating every turn as "current" — preserves the old
    # single-account behavior.
    $turnAcct = Account-At $t
    $isCurrent = $true
    if ($script:currentAccount) {
        $isCurrent = ($turnAcct -and [string]$turnAcct.org -eq $script:currentAccount.org)
    }

    if ($isCurrent) {
        $script:tok7d  += [long]$turn.sum
        $script:cost7d += [double]$turn.cost
        if ($t -gt $script:cut5h) {
            $script:tok5h  += [long]$turn.sum
            $script:cost5h += [double]$turn.cost
        }
    }
    # Capture every turn (any account) for session detection
    # below — session is account-independent.
    [void]$script:turns.Add(@{ ticks = $turn.ticks; sum = $turn.sum; cost = $turn.cost })
}

if (-not $useCache -and (Test-Path $projectsDir)) {
    $seen = @{}
    # All scanned turns, regardless of account, used after the scan to
    # detect the session boundary by walking backward through time.
    $turns = New-Object System.Collections.ArrayList
    # Updated per-transcript state written back to the cache file at the
    # end of this block. Built from $transcriptCache, mutated in-place
    # as we scan / resume each file.
    $transcriptStateOut = @{}
    $files = Get-ChildItem -Path $projectsDir -Filter *.jsonl -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -gt $cut7d }

    foreach ($f in $files) {
        $key = $f.FullName
        $currentLen = $f.Length
        $cached = $null
        if ($transcriptCache.ContainsKey($key)) { $cached = $transcriptCache[$key] }
        # Per-file scan plan:
        #  - resumeOffset = bytes to skip at file open. 0 means full scan.
        #  - kept[]       = previously-parsed turns we still trust (only
        #                   the cache-resume path populates this).
        # Reasons to *not* resume:
        #   1. No cached entry — first time we've seen this file.
        #   2. Cached length > current length — file rotated or truncated.
        #   3. The cached schemaVersion didn't match (handled above by
        #      $transcriptCache being empty).
        $resumeOffset = 0L
        $kept = @()
        if ($cached) {
            $cachedLen = [long]$cached.length
            if ($currentLen -lt $cachedLen) {
                # Rotated / truncated. Discard the cache entry and full-scan.
                $resumeOffset = 0L
            } else {
                $resumeOffset = [long]$cached.lastScanOffset
                if ($cached.PSObject.Properties.Match('turns').Count -gt 0 -and $cached.turns) {
                    foreach ($prev in $cached.turns) {
                        # Drop cached turns that have aged out of the 7d
                        # window since the last scan. Keeping them would
                        # over-count the 7d total.
                        if ([long]$prev.ticks -lt $cut7d.Ticks) { continue }
                        $kept += ,(@{ ticks = [long]$prev.ticks; sum = [long]$prev.sum; cost = [double]$prev.cost; msgId = [string]$prev.msgId })
                    }
                }
            }
        }

        # Replay cached turns first so $seen captures their msgIds before
        # any new-byte scan runs. This makes the dedup symmetric: an
        # assistant turn that was already in the cache won't be re-counted
        # if for some reason the resume seek lands mid-turn.
        foreach ($k in $kept) { Apply-Turn $k }

        $reader = $null
        $stream = $null
        $endOffset = $resumeOffset
        $lastUsageLineThisFile = $null
        if ($cached -and $cached.PSObject.Properties.Match('lastUsageLine').Count -gt 0) {
            $lastUsageLineThisFile = [string]$cached.lastUsageLine
        }
        $newTurnsForCache = New-Object System.Collections.ArrayList
        try {
            $stream = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($resumeOffset -gt 0 -and $resumeOffset -lt $stream.Length) {
                [void]$stream.Seek($resumeOffset, [System.IO.SeekOrigin]::Begin)
            }
            # BOM detection disabled: when resumeOffset > 0 we've seeked
            # past the start, so any "BOM-shaped" bytes there would just
            # be random JSON content. Claude Code's transcripts are
            # plain UTF-8 without a BOM anyway.
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 4096, $false)
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not $line) { continue }
                $turn = Parse-UsageLine $line $cut7d
                if (-not $turn) { continue }
                # Track the latest assistant usage line in this file so
                # the per-file cache can record it (used by context-token
                # readouts and future consumers).
                $lastUsageLineThisFile = $line
                Apply-Turn $turn
                [void]$newTurnsForCache.Add($turn)
            }
            # Position after the read is the resume point for the next
            # render. BaseStream.Position is the byte offset; even though
            # StreamReader buffers, .Position reflects the stream's actual
            # read head, which is what we want.
            $endOffset = $reader.BaseStream.Position
            $reader.Close()
            $stream = $null
        } catch {
            Write-DebugLog $_ -Scope 'transcript-scan'
            if ($reader) { try { $reader.Close() } catch { Write-DebugLog $_ -Scope 'transcript-reader-close' } }
            if ($stream) { try { $stream.Close() } catch { Write-DebugLog $_ -Scope 'transcript-reader-close' } }
        }

        # Combine kept (cache) + new turns for the next run's cache entry.
        $turnsForCache = @()
        foreach ($k in $kept)         { $turnsForCache += ,$k }
        foreach ($n in $newTurnsForCache) { $turnsForCache += ,$n }
        $transcriptStateOut[$key] = @{
            length         = $currentLen
            lastScanOffset = $endOffset
            lastUsageLine  = $lastUsageLineThisFile
            turns          = $turnsForCache
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
        schemaVersion = $cacheSchemaVersion
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
    # Persist the per-transcript tail cache (M1-04). On a top-level
    # cache HIT (or when no projects dir exists) we didn't scan, so
    # carry forward whatever we loaded from the previous cache file
    # so the next MISS still has resume offsets to seek to.
    if ($useCache -or -not (Test-Path $projectsDir)) {
        if ($transcriptCache.Count -gt 0) { $payload.transcripts = $transcriptCache }
    } else {
        $payload.transcripts = $transcriptStateOut
    }
    # Depth 6 covers transcripts -> <path> -> turns -> <turn-hashtable>
    # without flattening the per-turn fields into strings.
    $body = $payload | ConvertTo-Json -Compress -Depth 6 -ErrorAction Stop
    [System.IO.File]::WriteAllText($cachePath, $body, [System.Text.UTF8Encoding]::new($false))
} catch { Write-DebugLog $_ -Scope 'cache-write' }

# --- context tokens: last usage block in the current session transcript --
# Fast path (M1-04): the projects-dir scan already captured the last
# assistant usage line for every transcript it processed. Reuse it
# instead of re-walking the file from byte 0. Falls through to the
# full walk if the active transcript isn't in our per-file cache
# (e.g. brand-new session whose file post-dates the last scan).
$ctxTokens = [long]0
if ($hook -and $hook.transcript_path -and (Test-Path $hook.transcript_path)) {
    $lastUsageLine = $null
    $tpath = [string]$hook.transcript_path
    # Look up by exact path first, then by FullName-normalised form —
    # transcript_path arrives from the hook as the same string Claude
    # Code uses, but our scan keyed by FileInfo.FullName which
    # canonicalises separators. Try the path verbatim first, then a
    # normalised lookup.
    $hit = $null
    if ($transcriptStateOut -and $transcriptStateOut.ContainsKey($tpath)) {
        $hit = $transcriptStateOut[$tpath]
    } elseif ($transcriptCache -and $transcriptCache.ContainsKey($tpath)) {
        $hit = $transcriptCache[$tpath]
    } else {
        try {
            $normalized = (Get-Item -LiteralPath $tpath -ErrorAction Stop).FullName
            if ($transcriptStateOut -and $transcriptStateOut.ContainsKey($normalized)) {
                $hit = $transcriptStateOut[$normalized]
            } elseif ($transcriptCache -and $transcriptCache.ContainsKey($normalized)) {
                $hit = $transcriptCache[$normalized]
            }
        } catch { Write-DebugLog $_ -Scope 'ctx-path-normalize' }
    }
    if ($hit -and $hit.lastUsageLine) {
        $lastUsageLine = [string]$hit.lastUsageLine
    } else {
        foreach ($line in [System.IO.File]::ReadLines($tpath)) {
            # Anchor on JSON shape: require both `"role":"assistant"` and
            # `"usage":{` on the same line. A bare `"usage"` substring match
            # used to false-positive on user messages quoting the word
            # `usage`, clobbering $lastUsageLine and producing a 0-token
            # context readout. Claude Code writes one turn per line, so
            # both anchors will appear together iff this is a real
            # assistant turn with a usage block.
            if ($line.IndexOf('"role":"assistant"') -lt 0) { continue }
            if ($line.IndexOf('"usage":{') -lt 0) { continue }
            $lastUsageLine = $line
        }
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
    } catch { Write-DebugLog $_ -Scope 'git-head' }
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
