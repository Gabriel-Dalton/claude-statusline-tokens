#Requires -Version 5.1

param(

    [switch]$RefreshScopedLimits,
    [string]$OrgKey = ''
)

[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$script:utcParseStyles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                         [Globalization.DateTimeStyles]::AssumeUniversal

function Write-DebugLog {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true, Position=0)]
        [object]$Message,
        [string]$Scope = ''
    )

}

function ConvertTo-ResetUtc($value) {
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
    Write-DebugLog "unparseable timestamp: $text" -Scope 'timestamp-parse'
    return $null
}

function Get-HookField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowNull()]$Hook,
        [Parameter(Mandatory=$true)][string]$DottedPath,
        [Parameter()]$Fallback = $null,
        [Parameter()][switch]$NoLog
    )
    $node = $Hook
    if ($null -eq $node) {
        if (-not $NoLog) {
            Write-DebugLog "missing hook.$DottedPath (no hook)" -Scope 'hook-field-missing'
        }
        return $Fallback
    }
    foreach ($seg in $DottedPath.Split('.')) {
        if ($null -eq $node) {
            if (-not $NoLog) {
                Write-DebugLog "missing hook.$DottedPath" -Scope 'hook-field-missing'
            }
            return $Fallback
        }

        $hasProp = $false
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            $hasProp = ($node.PSObject.Properties.Match($seg).Count -gt 0)
        } elseif ($node -is [System.Collections.IDictionary]) {
            $hasProp = $node.Contains($seg)
        } else {

            try { $hasProp = ($null -ne $node.$seg) } catch { $hasProp = $false }
        }
        if (-not $hasProp) {
            if (-not $NoLog) {
                Write-DebugLog "missing hook.$DottedPath" -Scope 'hook-field-missing'
            }
            return $Fallback
        }
        $node = $node.$seg
    }
    if ($null -eq $node) {

        if (-not $NoLog) {
            Write-DebugLog "missing hook.$DottedPath (null leaf)" -Scope 'hook-field-missing'
        }
        return $Fallback
    }
    return $node
}

$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $HOME }
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $env:USERPROFILE }
$claudeDir        = [System.IO.Path]::Combine($userProfile, '.claude')
$globalConfigPath = [System.IO.Path]::Combine($userProfile, '.claude.json')
$configDirOverride = ([string]$env:CLAUDE_CONFIG_DIR).Trim()
if (-not [string]::IsNullOrEmpty($configDirOverride)) {
    $claudeDir        = $configDirOverride
    $globalConfigPath = [System.IO.Path]::Combine($configDirOverride, '.claude.json')
}

$scopedCachePath = [System.IO.Path]::Combine($claudeDir, 'statusline-scoped-limits.cache.json')
$scopedLockPath  = [System.IO.Path]::Combine($claudeDir, 'statusline-scoped-limits.lock')

$limitsStorePath = [System.IO.Path]::Combine($claudeDir, 'statusline-limits.cache.json')

$limitsSchema    = 2

$limitsWindowTolSec = 120

$limitsKey5h = '5h'
$limitsKey7d = '7d'

function Read-LimitsStore([string]$Path, [string]$Org) {
    $buckets = @{}
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path $Path)) { return $buckets }
    $raw = $null

    foreach ($attempt in 1..2) {
        $fs = $null; $sr = $null
        try {
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            $sr = New-Object System.IO.StreamReader($fs)
            $raw = $sr.ReadToEnd()
            break
        } catch { Start-Sleep -Milliseconds 20 }
        finally {
            if ($sr) { try { $sr.Dispose() } catch {} }
            if ($fs) { try { $fs.Dispose() } catch {} }
        }
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $buckets }
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop

        if ([string]$doc.orgKey -ne $Org) { return $buckets }
        if ([int]$doc.schemaVersion -ne $script:limitsSchema) { return $buckets }
        foreach ($prop in $doc.buckets.PSObject.Properties) {
            $b = $prop.Value
            if ($null -eq $b) { continue }
            $entry = @{
                name          = [string]$b.name
                percent       = [double]$b.percent
                observedAtUtc = ConvertTo-ResetUtc $b.observedAtUtc
                resetsAtUtc   = ConvertTo-ResetUtc $b.resetsAtUtc
                knownAtUtc    = ConvertTo-ResetUtc $b.knownAtUtc
            }
            if ($null -eq $entry.observedAtUtc) { continue }
            if ($null -eq $entry.knownAtUtc) { $entry.knownAtUtc = [DateTime]::MinValue }
            $buckets[$prop.Name] = $entry
        }
    } catch { Write-DebugLog $_ -Scope 'limits-store-read' }
    return $buckets
}

function Merge-LimitObservation($Store, [string]$Key, [string]$Name, $Percent, $ResetsUtc, [DateTime]$ObservedUtc, $KnownAtUtc) {
    if ($null -eq $Store -or [string]::IsNullOrEmpty($Key) -or $null -eq $Percent) { return }
    $p = $null
    if ($Percent -is [double] -or $Percent -is [int] -or $Percent -is [long] -or
        $Percent -is [decimal] -or $Percent -is [single]) {
        $p = [double]$Percent
    } else {
        $parsed = 0.0
        if ([double]::TryParse([string]$Percent, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { $p = $parsed }
    }
    if ($null -eq $p) { return }

    if ($p -lt 0 -or $p -gt 100) {
        Write-DebugLog "out-of-range percent for $Key`: $p" -Scope 'limits-merge'
        return
    }

    $known = [DateTime]::MinValue
    if ($KnownAtUtc) { $known = [DateTime]$KnownAtUtc }

    $incoming = @{ name = $Name; percent = $p; observedAtUtc = $ObservedUtc
                   resetsAtUtc = $ResetsUtc; knownAtUtc = $known }
    $old = $Store[$Key]
    if ($null -eq $old) { $Store[$Key] = $incoming; return }

    if ($old.resetsAtUtc -and $ResetsUtc) {
        $delta = ($ResetsUtc - $old.resetsAtUtc).TotalSeconds
        if ($delta -gt $script:limitsWindowTolSec)  { $Store[$Key] = $incoming; return }
        if ($delta -lt -$script:limitsWindowTolSec) {
            $oldKnownAt = [DateTime]::MinValue
            if ($old.knownAtUtc) { $oldKnownAt = [DateTime]$old.knownAtUtc }
            if ($ResetsUtc -gt $ObservedUtc -and $known -gt $oldKnownAt) { $Store[$Key] = $incoming }
            return
        }
    }

    $oldKnown = [DateTime]::MinValue
    if ($old.knownAtUtc) { $oldKnown = [DateTime]$old.knownAtUtc }
    if (($known -gt $oldKnown) -or ($known -eq $oldKnown -and $p -gt [double]$old.percent)) {

        if (-not $incoming.resetsAtUtc) { $incoming.resetsAtUtc = $old.resetsAtUtc }

        if ($old.observedAtUtc -and ([DateTime]$old.observedAtUtc) -gt $ObservedUtc) {
            $incoming.observedAtUtc = $old.observedAtUtc
        }
        $Store[$Key] = $incoming
        return
    }

    if ((-not $old.observedAtUtc) -or ($ObservedUtc -gt [DateTime]$old.observedAtUtc)) {
        $old.observedAtUtc = $ObservedUtc
    }
    if (-not $old.resetsAtUtc -and $ResetsUtc) { $old.resetsAtUtc = $ResetsUtc }
    $Store[$Key] = $old
}

function Write-LimitsStore([string]$Path, [string]$Org, $Store) {
    if ([string]::IsNullOrEmpty($Path) -or $null -eq $Store) { return }
    $out = @{}
    foreach ($k in $Store.Keys) {
        $b = $Store[$k]
        $row = @{ name = [string]$b.name; percent = [double]$b.percent }

        if ($b.observedAtUtc) { $row.observedAtUtc = ([DateTime]$b.observedAtUtc).ToString('o') }
        if ($b.resetsAtUtc)   { $row.resetsAtUtc   = ([DateTime]$b.resetsAtUtc).ToString('o') }
        if ($b.knownAtUtc -and ([DateTime]$b.knownAtUtc) -gt [DateTime]::MinValue) {
            $row.knownAtUtc = ([DateTime]$b.knownAtUtc).ToString('o')
        }
        $out[$k] = $row
    }
    $body = @{ schemaVersion = $script:limitsSchema; orgKey = $Org; buckets = $out } |
        ConvertTo-Json -Compress -Depth 5

    $ownPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $tmp = '{0}.{1}.tmp' -f $Path, $ownPid
    $bak = '{0}.{1}.bak' -f $Path, $ownPid
    try {
        [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $Path) {

            [System.IO.File]::Replace($tmp, $Path, $bak)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        Write-DebugLog $_ -Scope 'limits-store-write'

        try { [System.IO.File]::WriteAllText($Path, $body, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    } finally {
        foreach ($leftover in @($tmp, $bak)) {
            try { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

function Sync-LimitsStore([string]$Path, [string]$Org, $Observations) {

    $mutexName = $null
    try {
        $sha = New-Object Security.Cryptography.SHA1Managed
        $tag = [BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))).Replace('-', '').Substring(0, 16)
        $mutexName = 'Local\claude-statusline-limits-' + $tag
    } catch { $mutexName = $null }

    $mutex = $null
    $held  = $false
    if ($mutexName) {
        try {
            $mutex = New-Object System.Threading.Mutex($false, $mutexName)

            try { $held = $mutex.WaitOne(250) }
            catch [System.Threading.AbandonedMutexException] {

                $held = $true
            }
        } catch { Write-DebugLog $_ -Scope 'limits-store-lock'; $held = $false }
    }

    try {
        $store = Read-LimitsStore $Path $Org
        foreach ($o in $Observations) {
            if (-not $o) { continue }
            Merge-LimitObservation $store $o.key $o.name $o.percent $o.resetsUtc $o.observedUtc $o.knownUtc
        }
        if ($held) { Write-LimitsStore $Path $Org $store }
        return $store
    } finally {
        if ($held -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { try { $mutex.Dispose() } catch {} }
    }
}

function Get-LiveBucket($Store, [string]$Key, [DateTime]$NowUtc) {
    if ($null -eq $Store) { return $null }
    $b = $Store[$Key]
    if ($null -eq $b) { return $null }
    if ($b.resetsAtUtc -and ([DateTime]$b.resetsAtUtc) -le $NowUtc) { return $null }
    return $b
}

function Get-ScopedLimitsPayload([string]$CachePath, [string]$Org) {

    $payload = @{
        attemptedAtUtc = [DateTime]::UtcNow.ToString('o')
        orgKey         = $Org
        status         = 'error'
        limits         = @()
        failures       = 0
    }
    try {
        if (Test-Path $CachePath) {
            $prev = Get-Content -Raw -LiteralPath $CachePath | ConvertFrom-Json
            if ([string]$prev.orgKey -eq $Org) {
                if ($prev.fetchedAtUtc) { $payload.fetchedAtUtc = [string]$prev.fetchedAtUtc }
                if ($prev.PSObject.Properties.Match('failures').Count -gt 0) {
                    $payload.failures = [int]$prev.failures
                }

                $payload.limits = @(@($prev.limits) |
                    Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.resetsAt) } |
                    ForEach-Object {

                    $k = [string]$_.kind
                    if ([string]::IsNullOrWhiteSpace($k)) { $k = 'weekly_scoped' }
                    @{ kind = $k; name = [string]$_.name; percent = [double]$_.percent; resetsAt = [string]$_.resetsAt }
                })
            }
        }
    } catch { Write-DebugLog $_ -Scope 'scoped-cache-read' }

    $credPath = [System.IO.Path]::Combine($claudeDir, '.credentials.json')
    if (-not (Test-Path $credPath)) { $payload.status = 'no-credentials'; return $payload }

    $token = $null
    try {
        $oauth = (Get-Content -Raw -LiteralPath $credPath | ConvertFrom-Json).claudeAiOauth
        if ($null -eq $oauth) { $payload.status = 'no-credentials'; return $payload }

        if ($oauth.expiresAt) {
            $expUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt).UtcDateTime
            if ($expUtc -le [DateTime]::UtcNow) { $payload.status = 'token-expired'; return $payload }
        }
        $token = [string]$oauth.accessToken
    } catch {
        Write-DebugLog $_ -Scope 'scoped-credentials'
        $payload.status = 'credentials-unreadable'
        return $payload
    }
    if ([string]::IsNullOrWhiteSpace($token)) { $payload.status = 'no-token'; return $payload }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
            -Method Get -TimeoutSec 10 -Headers @{
                'Authorization'  = "Bearer $token"
                'anthropic-beta' = 'oauth-2025-04-20'
                'Content-Type'   = 'application/json'
            }
    } catch {

        Write-DebugLog "usage endpoint request failed" -Scope 'scoped-fetch'
        $payload.status = 'request-failed'

        $payload.failures = [Math]::Min($payload.failures + 1, 6)
        return $payload
    } finally { $token = $null }

    $found = @()
    foreach ($lim in @($resp.limits)) {
        $kind = [string]$lim.kind
        if ($kind -ne 'session' -and $kind -ne 'weekly_all' -and $kind -ne 'weekly_scoped') { continue }
        $name = ''
        if ($lim.scope -and $lim.scope.model) { $name = [string]$lim.scope.model.display_name }

        if ($kind -eq 'weekly_scoped' -and [string]::IsNullOrWhiteSpace($name)) { continue }

        $rUtc = ConvertTo-ResetUtc $lim.resets_at
        $found += @{
            kind     = $kind
            name     = $name
            percent  = [double]$lim.percent
            resetsAt = $(if ($rUtc) { $rUtc.ToString('o') } else { '' })
        }
    }
    $payload.limits       = $found
    $payload.fetchedAtUtc = [DateTime]::UtcNow.ToString('o')
    $payload.status       = 'ok'
    $payload.failures     = 0
    return $payload
}

if ($RefreshScopedLimits) {
    $payload = Get-ScopedLimitsPayload $scopedCachePath $OrgKey
    try {
        $body = $payload | ConvertTo-Json -Compress -Depth 5 -ErrorAction Stop
        [System.IO.File]::WriteAllText($scopedCachePath, $body, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-DebugLog $_ -Scope 'scoped-cache-write' }
    try {
        Remove-Item -LiteralPath $scopedLockPath -Force -ErrorAction SilentlyContinue
    } catch { Write-DebugLog $_ -Scope 'scoped-lock-release' }
    exit 0
}

function Request-ScopedLimitsRefresh([string]$ScriptPath, [string]$LockPath, [string]$Org) {
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path $ScriptPath)) { return }

    $lockStaleSec = 120
    try {
        if (Test-Path $LockPath) {
            $lockAge = ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockPath).LastWriteTimeUtc).TotalSeconds
            if ($lockAge -gt $lockStaleSec) {
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            }
            return
        }
        $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $fs.Close()
    } catch { return }

    try {

        $exe = if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { 'pwsh' } else { 'powershell.exe' }
        try {
            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        } catch { Write-DebugLog $_ -Scope 'scoped-host-path' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $exe
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RefreshScopedLimits -OrgKey "{1}"' -f $ScriptPath, $Org
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true

        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-DebugLog $_ -Scope 'scoped-spawn'
        try {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        } catch { Write-DebugLog $_ -Scope 'scoped-lock-release' }
    }
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

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

$modelIdRaw = Get-HookField $hook 'model.id' -Fallback $null -NoLog

function script:Format-ModelIdAsName([string]$id) {
    if ([string]::IsNullOrEmpty($id)) { return $null }
    $name = $id
    if ($name.StartsWith('claude-')) { $name = $name.Substring(7) }

    $parts = $name.Split('-')
    if ($parts.Length -gt 0 -and $parts[0].Length -gt 0) {
        $parts[0] = $parts[0].Substring(0,1).ToUpper() + $parts[0].Substring(1)
    }
    return ($parts -join ' ')
}

$modelDisplay = Get-HookField $hook 'model.display_name' -Fallback $null
if ([string]::IsNullOrEmpty($modelDisplay)) {
    $derived = Format-ModelIdAsName $modelIdRaw
    if (-not [string]::IsNullOrEmpty($derived)) {
        $modelDisplay = $derived
    } else {
        $modelDisplay = 'model?'
    }
}
if ([string]::IsNullOrEmpty($modelIdRaw)) { $modelIdResolved = 'unknown' } else { $modelIdResolved = $modelIdRaw }

$cwdResolved = Get-HookField $hook 'workspace.current_dir' -Fallback $null -NoLog
if ([string]::IsNullOrEmpty($cwdResolved)) {
    $cwdResolved = Get-HookField $hook 'cwd' -Fallback $null
}
if ([string]::IsNullOrEmpty($cwdResolved)) {
    $cwdResolved = (Get-Location).Path
}

$transcriptPathResolved = Get-HookField $hook 'transcript_path' -Fallback $null
$sessionIdResolved      = Get-HookField $hook 'session_id'      -Fallback ''

$pct5hRaw    = Get-HookField $hook 'rate_limits.five_hour.used_percentage' -Fallback $null
$pct7dRaw    = Get-HookField $hook 'rate_limits.seven_day.used_percentage' -Fallback $null
$resets5hRaw = Get-HookField $hook 'rate_limits.five_hour.resets_at'       -Fallback $null
$resets7dRaw = Get-HookField $hook 'rate_limits.seven_day.resets_at'       -Fallback $null

$ctxPctRaw = Get-HookField $hook 'context_window.used_percentage' -Fallback $null -NoLog

$reset5hUtc  = ConvertTo-ResetUtc $resets5hRaw
$reset7dUtc  = ConvertTo-ResetUtc $resets7dRaw

$hookFields = [pscustomobject]@{
    transcript_path     = $transcriptPathResolved
    cwd                 = $cwdResolved
    session_id          = $sessionIdResolved
    model_display_name  = $modelDisplay
    model_id            = $modelIdResolved
    pct5h               = $pct5hRaw
    pct7d               = $pct7dRaw
    resets5h            = $reset5hUtc
    resets7d            = $reset7dUtc
    ctxPct              = $ctxPctRaw
}

function Fmt-Tokens([long]$n) {
    if ($n -ge 999950000) { '{0:0.00}B' -f ($n / 1000000000.0) }
    elseif ($n -ge 999950) { '{0:0.0}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000.0) }
    else { "$n" }
}

$prices = @{
    fable      = @{ input = 10.00; output = 50.00; cacheRead = 1.00; cacheW5m = 12.50; cacheW1h = 20.00 }
    opus       = @{ input =  5.00; output = 25.00; cacheRead = 0.50; cacheW5m =  6.25; cacheW1h = 10.00 }
    opusLegacy = @{ input = 15.00; output = 75.00; cacheRead = 1.50; cacheW5m = 18.75; cacheW1h = 30.00 }
    sonnet     = @{ input =  3.00; output = 15.00; cacheRead = 0.30; cacheW5m =  3.75; cacheW1h =  6.00 }
    haiku      = @{ input =  1.00; output =  5.00; cacheRead = 0.10; cacheW5m =  1.25; cacheW1h =  2.00 }
}
function Get-ModelFamily([string]$id) {

    if ($id -match 'fable|mythos') { return 'fable' }

    if ($id -match 'opus-4-1|opus-4-0|opus-4-2025|3-opus') { return 'opusLegacy' }
    if ($id -match 'opus')   { return 'opus' }

    if ($id -match 'sonnet') { return 'sonnet' }
    if ($id -match 'haiku')  { return 'haiku' }
    return 'opus'
}
function Fmt-Cost([double]$d) {
    if ($d -ge 1000) { return '${0:0.0}k' -f ($d / 1000.0) }
    if ($d -ge 100)  { return '${0:0}'   -f $d }
    if ($d -ge 1)    { return '${0:0.00}' -f $d }
    if ($d -gt 0)    { return '${0:0.00}' -f $d }
    return '$0.00'
}

function Fmt-Relative([TimeSpan]$ts) {
    if ($ts.TotalSeconds -le 0) { return 'now' }
    if ($ts.TotalSeconds -lt 60) { return '<1m' }
    $totalMin = [int][math]::Floor($ts.TotalMinutes)
    if ($totalMin -lt 60) { return ('{0}m' -f $totalMin) }
    $hours = [int][math]::Floor($ts.TotalHours)
    if ($hours -lt 24) {
        $mins = $totalMin - ($hours * 60)
        if ($mins -gt 0) { return ('{0}h{1}m' -f $hours, $mins) }
        return ('{0}h' -f $hours)
    }
    $days = [int][math]::Floor($ts.TotalDays)
    $remHours = $hours - ($days * 24)
    if ($remHours -gt 0) { return ('{0}d{1}h' -f $days, $remHours) }
    return ('{0}d' -f $days)
}

$tzLabelEnabled = -not ($env:STATUSLINE_TZ_LABEL -match '^(0|off|false|no)$')
$tzAbbrevByName = @{
    'UTC'                            = 'UTC'
    'Coordinated Universal Time'     = 'UTC'

    'Hawaiian Standard Time'         = 'HST'
    'Alaskan Standard Time'          = 'AKST'; 'Alaskan Daylight Time'          = 'AKDT'
    'Pacific Standard Time'          = 'PST';  'Pacific Daylight Time'          = 'PDT'
    'Mountain Standard Time'         = 'MST';  'Mountain Daylight Time'         = 'MDT'
    'US Mountain Standard Time'      = 'MST'
    'Central Standard Time'          = 'CST';  'Central Daylight Time'          = 'CDT'
    'Eastern Standard Time'          = 'EST';  'Eastern Daylight Time'          = 'EDT'
    'US Eastern Standard Time'       = 'EST';  'US Eastern Daylight Time'       = 'EDT'
    'Atlantic Standard Time'         = 'AST';  'Atlantic Daylight Time'         = 'ADT'
    'Newfoundland Standard Time'     = 'NST';  'Newfoundland Daylight Time'     = 'NDT'

    'GMT Standard Time'              = 'GMT';  'GMT Daylight Time'              = 'BST'
    'W. Europe Standard Time'        = 'CET';  'W. Europe Daylight Time'        = 'CEST'
    'Central Europe Standard Time'   = 'CET';  'Central Europe Daylight Time'   = 'CEST'
    'Central European Standard Time' = 'CET';  'Central European Daylight Time' = 'CEST'
    'Romance Standard Time'          = 'CET';  'Romance Daylight Time'          = 'CEST'
    'E. Europe Standard Time'        = 'EET';  'E. Europe Daylight Time'        = 'EEST'
    'GTB Standard Time'              = 'EET';  'GTB Daylight Time'              = 'EEST'
    'FLE Standard Time'              = 'EET';  'FLE Daylight Time'              = 'EEST'
    'W. Central Africa Standard Time' = 'WAT'
    'South Africa Standard Time'     = 'SAST'

    'Jerusalem Standard Time'        = 'IST';  'Jerusalem Daylight Time'        = 'IDT'
    'Israel Standard Time'           = 'IST';  'Israel Daylight Time'           = 'IDT'

    'India Standard Time'            = 'IST'
    'China Standard Time'            = 'CST'
    'Malay Peninsula Standard Time'  = 'SGT'
    'Singapore Standard Time'        = 'SGT'
    'Tokyo Standard Time'            = 'JST'
    'Korea Standard Time'            = 'KST'
    'W. Australia Standard Time'     = 'AWST'
    'AUS Central Standard Time'      = 'ACST'
    'Cen. Australia Standard Time'   = 'ACST'; 'Cen. Australia Daylight Time'   = 'ACDT'
    'AUS Eastern Standard Time'      = 'AEST'; 'AUS Eastern Daylight Time'      = 'AEDT'
    'E. Australia Standard Time'     = 'AEST'
    'Tasmania Standard Time'         = 'AEST'; 'Tasmania Daylight Time'         = 'AEDT'
    'New Zealand Standard Time'      = 'NZST'; 'New Zealand Daylight Time'      = 'NZDT'
}

function Get-TzAbbrev([DateTime]$utc, $zone) {

    if ($utc.Kind -ne [DateTimeKind]::Utc) {
        $utc = [DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc)
    }
    $tz = $zone
    if ($null -eq $tz) { $tz = [TimeZoneInfo]::Local }

    if ($tz.IsDaylightSavingTime([DateTimeOffset]::new($utc))) { $name = $tz.DaylightName }
    else                                                       { $name = $tz.StandardName }
    if ($tzAbbrevByName.ContainsKey($name)) { return $tzAbbrevByName[$name] }
    $off = $tz.GetUtcOffset($utc)
    if ($off -eq [TimeSpan]::Zero) { return 'UTC' }
    $sign = '+'; if ($off.Ticks -lt 0) { $sign = '-' }
    $h = [math]::Abs($off.Hours)
    $m = [math]::Abs($off.Minutes)
    if ($m -eq 0) { return ('UTC{0}{1}' -f $sign, $h) }
    return ('UTC{0}{1}:{2:D2}' -f $sign, $h, $m)
}

function Fmt-AbsLocal([DateTime]$utc, [bool]$includeDay) {

    if ($utc.Kind -ne [DateTimeKind]::Utc) {
        $utc = [DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc)
    }
    $local = $utc.ToLocalTime()
    $h = $local.Hour
    $m = $local.Minute
    $ampm = 'am'; if ($h -ge 12) { $ampm = 'pm' }
    $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    if ($m -eq 0) { $time = '{0}{1}' -f $h12, $ampm }
    else          { $time = '{0}:{1:D2}{2}' -f $h12, $m, $ampm }
    $zone = ''
    if ($tzLabelEnabled) { $zone = ' ' + (Get-TzAbbrev $utc) }
    if ($includeDay) {
        $day = $local.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture)
        return ('{0} {1}{2}' -f $day, $time, $zone)
    }
    return ('{0}{1}' -f $time, $zone)
}

function Fmt-Reset($value, [bool]$includeDay) {
    $resetUtc = ConvertTo-ResetUtc $value
    if ($null -eq $resetUtc) { return $null }
    $ts = $resetUtc - [DateTime]::UtcNow
    if ($ts.TotalSeconds -le 0) { return $null }
    return ('{0} @ {1}' -f (Fmt-Relative $ts), (Fmt-AbsLocal $resetUtc $includeDay))
}

$nowUtc = [DateTime]::UtcNow

$scanFloor = $nowUtc.AddDays(-7)

$cut5h = $nowUtc.AddHours(-5)
$cut7d = $scanFloor

$sessionGapMinutes = 30

$tok5h      = [long]0; $cost5h      = 0.0
$tok7d      = [long]0; $cost7d      = 0.0
$tokSession = [long]0; $costSession = 0.0

$lastModelTurns = @{}

$projectsDir       = [System.IO.Path]::Combine($claudeDir, 'projects')
$cachePath         = [System.IO.Path]::Combine($claudeDir, 'statusline-tokens.cache.json')
$statePath         = [System.IO.Path]::Combine($claudeDir, 'statusline-transcripts.cache.json')
$transcriptStateOut  = $null
$cachedSessionTok    = [long]0
$cachedSessionCost   = 0.0
$cachedSessionLatest = $null
$accountsPath      = [System.IO.Path]::Combine($claudeDir, 'statusline-accounts.json')

$devicesDir     = ([string]$env:STATUSLINE_DEVICES_DIR).Trim()
$deviceId       = ([string]$env:STATUSLINE_DEVICE_ID).Trim()
if ([string]::IsNullOrEmpty($deviceId)) { $deviceId = [string][Environment]::MachineName }
$deviceId       = ($deviceId.ToLowerInvariant() -replace '[^a-z0-9_-]', '-').Trim('-')
$devicesEnabled = (-not [string]::IsNullOrEmpty($devicesDir)) -and
                  (-not [string]::IsNullOrEmpty($deviceId)) -and
                  (Test-Path -LiteralPath $devicesDir -PathType Container)
$deviceSchema    = 1
$deviceBucketSec = 300

$deviceWriteMinSec = 60
$deviceFilePrefix  = 'statusline-device-'

$deviceBuckets = @{}
$unixEpoch     = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)

$orgTagMemo = @{}
function Get-OrgTag([string]$Org) {
    if ($null -eq $Org) { $Org = '' }
    if ($script:orgTagMemo.ContainsKey($Org)) { return $script:orgTagMemo[$Org] }
    $tag = 'none'
    if ($Org -ne '') {
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $tag = [BitConverter]::ToString(
                $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Org))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
        } finally { $sha.Dispose() }
    }
    $script:orgTagMemo[$Org] = $tag
    return $tag
}

function Write-DeviceFile([string]$Dir, [string]$Id, $Buckets) {
    $path = [System.IO.Path]::Combine($Dir, ($script:deviceFilePrefix + $Id + '.json'))
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('{{"schemaVersion":{0},"device":"{1}","bucketSeconds":{2},"orgs":{{' -f
        $script:deviceSchema, $Id, $script:deviceBucketSec))
    $firstOrg = $true
    foreach ($tag in @($Buckets.Keys | Sort-Object)) {
        if (-not $firstOrg) { [void]$sb.Append(',') }
        $firstOrg = $false
        [void]$sb.Append(('"{0}":[' -f $tag))
        $firstRow = $true
        foreach ($start in @($Buckets[$tag].Keys | Sort-Object)) {
            $row = $Buckets[$tag][$start]
            if (-not $firstRow) { [void]$sb.Append(',') }
            $firstRow = $false
            [void]$sb.Append(('[{0},{1},{2:0.####}]' -f [long]$start, [long]$row[0], [double]$row[1]))
        }
        [void]$sb.Append(']')
    }
    [void]$sb.Append('}}')
    $body = $sb.ToString()
    try {
        if (Test-Path -LiteralPath $path) {
            $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $path).LastWriteTimeUtc).TotalSeconds
            if ($age -ge 0 -and $age -lt $script:deviceWriteMinSec) { return }
            if ([System.IO.File]::ReadAllText($path) -eq $body) { return }
        }
        [System.IO.File]::WriteAllText($path, $body, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-DebugLog $_ -Scope 'device-file-write' }
}

function Read-PeerDevices([string]$Dir, [string]$Id, [string]$Tag,
                          [DateTime]$NowRef, [DateTime]$Cut5h, [DateTime]$Cut7d) {
    $sum = @{ tok5h = [long]0; cost5h = 0.0; tok7d = [long]0; cost7d = 0.0; devices = 0 }
    $own = $script:deviceFilePrefix + $Id + '.json'
    $files = @(Get-ChildItem -LiteralPath $Dir -Filter ($script:deviceFilePrefix + '*.json') -File -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        if ($f.Name -eq $own) { continue }

        if ($f.Length -le 0 -or $f.Length -gt 5MB) { continue }
        try {
            $doc = [System.IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -ErrorAction Stop
            if ([int]$doc.schemaVersion -ne $script:deviceSchema) { continue }
            $span = [long]$doc.bucketSeconds
            if ($span -le 0 -or $span -gt 3600) { continue }
            if ($null -eq $doc.orgs -or $doc.orgs.PSObject.Properties.Match($Tag).Count -eq 0) { continue }
            $counted = $false
            foreach ($row in @($doc.orgs.$Tag)) {
                if ($null -eq $row -or @($row).Count -lt 3) { continue }
                $start = [long]$row[0]; $tok = [long]$row[1]; $cost = [double]$row[2]
                if ($start -le 0 -or $tok -le 0 -or $cost -lt 0) { continue }
                $startUtc = $script:unixEpoch.AddSeconds($start)

                if ($startUtc -gt $NowRef) { continue }
                $endUtc = $startUtc.AddSeconds($span)
                if ($endUtc -gt $Cut7d) { $sum.tok7d += $tok; $sum.cost7d += $cost; $counted = $true }
                if ($endUtc -gt $Cut5h) { $sum.tok5h += $tok; $sum.cost5h += $cost; $counted = $true }
            }
            if ($counted) { $sum.devices++ }
        } catch { Write-DebugLog $_ -Scope 'device-file-read' }
    }
    return $sum
}

function Get-JsonObject([string]$content, [string]$keyName) {
    $needle = '"' + $keyName + '"'
    $start = $content.IndexOf($needle)
    if ($start -lt 0) { return $null }
    $braceStart = $content.IndexOf('{', $start)
    if ($braceStart -lt 0) { return $null }

    $interesting = [char[]]@('{','}','"','\')
    $i = $braceStart
    $depth = 0
    $inStr = $false
    while ($i -lt $content.Length) {
        if ($inStr) {

            $j = $content.IndexOfAny($interesting, $i)
            if ($j -lt 0) { return $null }
            $c = $content[$j]
            if ($c -eq '\') {

                $i = $j + 2
                continue
            }
            if ($c -eq '"') {
                $inStr = $false
                $i = $j + 1
                continue
            }

            $i = $j + 1
            continue
        }

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

                return $content.Substring($braceStart, $j - $braceStart + 1)
            }
            $i = $j + 1
            continue
        }

        $i = $j + 1
    }
    return $null
}

$currentAccount = $null
if (Test-Path $globalConfigPath) {
    try {

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

$checkpoints = @()
if (Test-Path $accountsPath) {
    try {

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

            $body = @{ checkpoints = $checkpoints } | ConvertTo-Json -Depth 4 -ErrorAction Stop
            [System.IO.File]::WriteAllText($accountsPath, $body, [System.Text.UTF8Encoding]::new($false))
        } catch { Write-DebugLog $_ -Scope 'accounts-write' }
    }
}

$sessionsPath    = [System.IO.Path]::Combine($projectsDir, 'statusline-sessions.json')
$sessionKeepDays = 8
$sessionsRaw     = ''
if (Test-Path -LiteralPath $sessionsPath) {
    try { $sessionsRaw = [System.IO.File]::ReadAllText($sessionsPath) } catch { Write-DebugLog $_ -Scope 'sessions-load' }
}
$sessionPoints = $null
function Get-SessionPoints {
    if ($null -ne $script:sessionPoints) { return $script:sessionPoints }
    $script:sessionPoints = @{}
    if (-not $script:sessionsRaw) { return $script:sessionPoints }
    try {
        $loaded = $script:sessionsRaw | ConvertFrom-Json -ErrorAction Stop
        if ($loaded.sessions) {
            foreach ($prop in $loaded.sessions.PSObject.Properties) { $script:sessionPoints[$prop.Name] = @($prop.Value) }
        }
    } catch { Write-DebugLog $_ -Scope 'sessions-load' }
    return $script:sessionPoints
}
if ($currentAccount -and $sessionIdResolved -and (Test-Path -LiteralPath $projectsDir)) {
    $knownOrg = ''
    $mSession = [regex]::Match($sessionsRaw, ('"{0}":\[([^\]]*)\]' -f [regex]::Escape($sessionIdResolved)))
    if ($mSession.Success) {
        $mOrgs = [regex]::Matches($mSession.Groups[1].Value, '"org":"([^"]*)"')
        if ($mOrgs.Count -gt 0) { $knownOrg = $mOrgs[$mOrgs.Count - 1].Groups[1].Value }
    }
    if ($knownOrg -ne $currentAccount.org) {
        $points = Get-SessionPoints
        $mine = @()
        if ($points.ContainsKey($sessionIdResolved)) { $mine = @($points[$sessionIdResolved]) }
        $points[$sessionIdResolved] = $mine + @(@{ from = $nowUtc.ToString('o'); org = $currentAccount.org })
        $keepFrom = $nowUtc.AddDays(-$sessionKeepDays)
        $keepSessions = @{}
        foreach ($sid in $points.Keys) {
            $pts = @($points[$sid])
            $lastFrom = ConvertTo-ResetUtc $pts[-1].from
            if ($null -ne $lastFrom -and $lastFrom -lt $keepFrom) { continue }
            $keepSessions[$sid] = $pts
        }
        $tmp = '{0}.{1}.tmp' -f $sessionsPath, [System.Diagnostics.Process]::GetCurrentProcess().Id
        try {
            $body = @{ sessions = $keepSessions } | ConvertTo-Json -Depth 5 -Compress -ErrorAction Stop
            [System.IO.File]::WriteAllText($tmp, $body, [System.Text.UTF8Encoding]::new($false))
            if (Test-Path -LiteralPath $sessionsPath) { Remove-Item -LiteralPath $sessionsPath -Force -ErrorAction SilentlyContinue }
            [System.IO.File]::Move($tmp, $sessionsPath)
        } catch {
            Write-DebugLog $_ -Scope 'sessions-write'
            try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { Write-DebugLog $_ -Scope 'sessions-write' }
        }
    }
}

function Get-Timeline($Points) {
    $list = New-Object System.Collections.ArrayList
    foreach ($cp in @($Points)) {
        $cpTime = ConvertTo-ResetUtc $cp.from
        if ($null -eq $cpTime) {
            Write-DebugLog "unparseable checkpoint 'from': $($cp.from)" -Scope 'checkpoint-parse'
            continue
        }
        [void]$list.Add(@{ time = $cpTime; cp = $cp })
    }
    return ,$list
}

function Get-SessionTimeline([System.IO.FileInfo]$File) {
    $sid = [System.IO.Path]::GetFileNameWithoutExtension($File.Name)
    if ($File.Directory.Name -eq 'subagents' -and $File.Directory.Parent) { $sid = $File.Directory.Parent.Name }
    $points = Get-SessionPoints
    if (-not $points.ContainsKey($sid)) { return $null }
    $timeline = Get-Timeline $points[$sid]
    if ($timeline.Count -eq 0) { return $null }
    return ,$timeline
}

$checkpointTimes = $null
function Account-At([DateTime]$t, $Timeline = $null) {
    if ($null -ne $Timeline) {
        $acct = $Timeline[0].cp
    } else {
        if (-not $script:checkpoints -or $script:checkpoints.Count -eq 0) { return $null }
        if ($null -eq $script:checkpointTimes) { $script:checkpointTimes = Get-Timeline $script:checkpoints }
        $Timeline = $script:checkpointTimes
        $acct = $script:checkpoints[0]
    }
    foreach ($e in $Timeline) {
        if ($t -ge $e.time) { $acct = $e.cp } else { break }
    }
    return $acct
}

$rxTs       = [regex]'"timestamp":"([^"]+)"'
$rxMsgId    = [regex]'"id":"(msg_[A-Za-z0-9]+)"'
$rxModel    = [regex]'"model":"(claude-[^"]+)"'
$rxInput    = [regex]'"input_tokens":(\d+)'
$rxOutput   = [regex]'"output_tokens":(\d+)'
$rxCacheC   = [regex]'"cache_creation_input_tokens":(\d+)'
$rxCacheR   = [regex]'"cache_read_input_tokens":(\d+)'
$rxCache5m  = [regex]'"ephemeral_5m_input_tokens":(\d+)'
$rxCache1h  = [regex]'"ephemeral_1h_input_tokens":(\d+)'

$cacheTtlSec = 20
$cacheTtlMaxSec = 300
$scanLockStaleSec = 60
$scanLockPath = [System.IO.Path]::Combine($claudeDir, 'statusline-tokens.scan.lock')
$scanLockHeld = $false
$cachedScanMs = $null
$cachedWindow5h = $null
$cachedWindow7d = $null
$cachedIncomplete = $false

function Test-ScanLock([string]$Path) {
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return $false }
        $age = ([DateTime]::UtcNow - (Get-Item -LiteralPath $Path).LastWriteTimeUtc).TotalSeconds
        return ($age -ge 0 -and $age -lt $script:scanLockStaleSec)
    } catch { return $false }
}
function Enter-ScanLock([string]$Path) {
    try {
        if ((Test-Path -LiteralPath $Path) -and -not (Test-ScanLock $Path)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $fs.Close()
        return $true
    } catch { return $false }
}

$cacheSchemaVersion = 4
$useCache = $false
$scanBudgetMs = 5000
$scanIncomplete = $false
$currentOrgKey = ''
if ($currentAccount) { $currentOrgKey = $currentAccount.org }

$transcriptCache = @{}

$storePeek = Read-LimitsStore $limitsStorePath $currentOrgKey
$storeReset5hUtc = $null
$storeReset7dUtc = $null
if ($storePeek[$limitsKey5h] -and $storePeek[$limitsKey5h].resetsAtUtc) {
    $storeReset5hUtc = [DateTime]$storePeek[$limitsKey5h].resetsAtUtc
}
if ($storePeek[$limitsKey7d] -and $storePeek[$limitsKey7d].resetsAtUtc) {
    $storeReset7dUtc = [DateTime]$storePeek[$limitsKey7d].resetsAtUtc
}

function Get-LaterStamp($a, $b) {
    if ($null -eq $a) { return $b }
    if ($null -eq $b) { return $a }
    if (([DateTime]$a) -ge ([DateTime]$b)) { return [DateTime]$a }
    return [DateTime]$b
}
$live5hUtc = Get-LaterStamp $reset5hUtc $storeReset5hUtc
$live7dUtc = Get-LaterStamp $reset7dUtc $storeReset7dUtc

if (Test-Path $cachePath) {
    try {
        $cache = [System.IO.File]::ReadAllText($cachePath) | ConvertFrom-Json -ErrorAction Stop

        $computedAt = ConvertTo-ResetUtc $cache.computedAtUtc
        $age = [double]::MaxValue
        if ($null -ne $computedAt) { $age = ($nowUtc - $computedAt).TotalSeconds }

        $cachedOrg = ''
        if ($cache.PSObject.Properties.Match('orgKey').Count -gt 0) { $cachedOrg = [string]$cache.orgKey }
        $cachedVer = 0
        if ($cache.PSObject.Properties.Match('schemaVersion').Count -gt 0) { $cachedVer = [int]$cache.schemaVersion }

        $sameWindow = $true
        foreach ($w in @(
            @{ live = $live5hUtc; field = 'window5h'; legacy = 'resets5h' },
            @{ live = $live7dUtc; field = 'window7d'; legacy = 'resets7d' }
        )) {
            if ($cachedOrg -ne $currentOrgKey -or $null -eq $w.live) { continue }
            $field = $w.field
            if ($cache.PSObject.Properties.Match($field).Count -eq 0) { $field = $w.legacy }
            if ($cache.PSObject.Properties.Match($field).Count -eq 0) { continue }
            $cachedReset = ConvertTo-ResetUtc $cache.$field
            if ($null -eq $cachedReset) { continue }
            if ([Math]::Abs((([DateTime]$w.live) - $cachedReset).TotalSeconds) -gt $limitsWindowTolSec) {
                $sameWindow = $false
            }
        }
        $ttl = [double]$cacheTtlSec
        if ($cache.scanMs) {
            $cachedScanMs = [double]$cache.scanMs
            $ttl = [math]::Max($ttl, [math]::Min([double]$cacheTtlMaxSec, $cachedScanMs / 100.0))
        }
        $cacheMine  = ($cachedOrg -eq $currentOrgKey -and $cachedVer -eq $cacheSchemaVersion)
        $cacheFresh = ($age -ge 0 -and $age -lt $ttl -and $cacheMine -and $sameWindow -and -not $cache.scanIncomplete)
        if ($cacheMine) {
            $cachedWindow5h   = $cache.window5h
            $cachedWindow7d   = $cache.window7d
            $cachedIncomplete = [bool]$cache.scanIncomplete
        }
        if ($cacheFresh -or ($cacheMine -and (Test-ScanLock $scanLockPath))) {
            $tok5h       = [long]$cache.tok5h
            $tok7d       = [long]$cache.tok7d
            $cost5h      = [double]$cache.cost5h
            $cost7d      = [double]$cache.cost7d

            $useCache    = $true
        }

        if ($useCache) {
            $cachedSessionTok    = [long]$cache.tokSession
            $cachedSessionCost   = [double]$cache.costSession
            $cachedSessionLatest = ConvertTo-ResetUtc $cache.sessionLatestUtc
        }

        if ($cachedOrg -eq $currentOrgKey) {
            if ($null -eq $reset5hUtc -and $cache.PSObject.Properties.Match('resets5h').Count -gt 0) {
                $reset5hUtc = ConvertTo-ResetUtc $cache.resets5h
            }
            if ($null -eq $reset7dUtc -and $cache.PSObject.Properties.Match('resets7d').Count -gt 0) {
                $reset7dUtc = ConvertTo-ResetUtc $cache.resets7d
            }

            if ($cache.PSObject.Properties.Match('lastModelTurns').Count -gt 0 -and $cache.lastModelTurns) {
                foreach ($prop in $cache.lastModelTurns.PSObject.Properties) {
                    $whenUtc = ConvertTo-ResetUtc $prop.Value
                    if ($null -eq $whenUtc) { continue }
                    $lastModelTurns[$prop.Name] = $whenUtc.Ticks
                }
            }
        }
    } catch { Write-DebugLog $_ -Scope 'cache-read' }
}

function Get-WindowStart([DateTime]$NowRef, $ResetUtc, [TimeSpan]$Length) {
    $floor = $NowRef - $Length
    if ($null -eq $ResetUtc) { return $floor }
    $r = [DateTime]$ResetUtc
    $start = $(if ($r -le $NowRef) { $r } else { $r - $Length })
    if ($start -lt $floor)  { return $floor }
    if ($start -gt $NowRef) { return $NowRef }
    return $start
}

if (-not $useCache -and (Test-Path $cachePath) -and (Test-Path $statePath)) {
    try {
        $state = [System.IO.File]::ReadAllText($statePath) | ConvertFrom-Json -ErrorAction Stop
        if ([int]$state.schemaVersion -eq $cacheSchemaVersion -and $state.transcripts) {
            foreach ($prop in $state.transcripts.PSObject.Properties) {
                $transcriptCache[$prop.Name] = $prop.Value
            }
        }
    } catch { Write-DebugLog $_ -Scope 'state-read' }
}

$cut5h = Get-WindowStart $nowUtc (Get-LaterStamp $reset5hUtc $storeReset5hUtc) ([TimeSpan]::FromHours(5))
$cut7d = Get-WindowStart $nowUtc (Get-LaterStamp $reset7dUtc $storeReset7dUtc) ([TimeSpan]::FromDays(7))

function Parse-UsageLine([string]$line, [DateTime]$cut7dRef) {
    if (-not $line) { return $null }
    if ($line.IndexOf('"role":"assistant"') -lt 0) { return $null }
    if ($line.IndexOf('"usage":{') -lt 0) { return $null }

    $mTs = $rxTs.Match($line)
    if (-not $mTs.Success) { return $null }

    $t = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($mTs.Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture,
            $script:utcParseStyles, [ref]$t)) {
        Write-DebugLog "unparseable turn timestamp: $($mTs.Groups[1].Value)" -Scope 'turn-timestamp-parse'
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

    if (($t5m + $t1h) -le 0) { $t5m = $tCacheC; $t1h = 0L }
    $cost = (
        $tIn     * $p.input     +
        $tOut    * $p.output    +
        $tCacheR * $p.cacheRead +
        $t5m     * $p.cacheW5m  +
        $t1h     * $p.cacheW1h
    ) / 1000000.0

    return @{ ticks = $t.Ticks; sum = $sum; cost = $cost; msgId = $msgId; modelId = $modelId }
}

function Get-LastUsageLineFromTail([string]$Path) {
    $found = $null
    $fs = $null; $sr = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $tail = 1048576
        $seeked = $fs.Length -gt $tail
        if ($seeked) { [void]$fs.Seek(-$tail, [System.IO.SeekOrigin]::End) }
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8, $false, 65536, $false)
        if ($seeked) { [void]$sr.ReadLine() }
        while (-not $sr.EndOfStream) {
            $line = $sr.ReadLine()
            if (-not $line) { continue }
            if ($line.IndexOf('"role":"assistant"') -lt 0) { continue }
            if ($line.IndexOf('"usage":{') -lt 0) { continue }
            $found = $line
        }
    } catch { Write-DebugLog $_ -Scope 'ctx-tail-read' }
    finally {
        if ($sr) { try { $sr.Dispose() } catch { Write-DebugLog $_ -Scope 'ctx-tail-read' } }
        elseif ($fs) { try { $fs.Dispose() } catch { Write-DebugLog $_ -Scope 'ctx-tail-read' } }
    }
    return $found
}

function Write-TranscriptState([string]$Path, $State) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(('{{"schemaVersion":{0},"transcripts":{{' -f $script:cacheSchemaVersion))
    $firstFile = $true
    foreach ($key in $State.Keys) {
        $entry = $State[$key]
        if (-not $firstFile) { [void]$sb.Append(',') }
        $firstFile = $false
        $name = ([string]$key).Replace('\', '\\').Replace('"', '\"')
        [void]$sb.Append(('"{0}":{{"length":{1},"lastScanOffset":{2},"turns":[' -f $name, [long]$entry.length, [long]$entry.lastScanOffset))
        $firstTurn = $true
        foreach ($t in $entry.turns) {
            if (-not $firstTurn) { [void]$sb.Append(',') }
            $firstTurn = $false
            [void]$sb.Append('[').Append([long]$t.ticks).Append(',').Append([long]$t.sum).Append(',')
            [void]$sb.Append(([double]$t.cost).ToString('0.######', [Globalization.CultureInfo]::InvariantCulture))
            [void]$sb.Append(',"').Append([string]$t.msgId).Append('","').Append([string]$t.modelId).Append('"]')
        }
        [void]$sb.Append(']}')
    }
    [void]$sb.Append('}}')
    $tmp = '{0}.{1}.tmp' -f $Path, [System.Diagnostics.Process]::GetCurrentProcess().Id
    try {
        [System.IO.File]::WriteAllText($tmp, $sb.ToString(), [System.Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
        [System.IO.File]::Move($tmp, $Path)
    } catch {
        Write-DebugLog $_ -Scope 'state-write'
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch { Write-DebugLog $_ -Scope 'state-write' }
    }
}

function Apply-Turn($turn, $Timeline = $null) {
    if (-not $turn) { return }
    if ($turn.msgId) {
        if ($script:seen.ContainsKey($turn.msgId)) { return }
        $script:seen[$turn.msgId] = $true
    }
    $t = [DateTime]::new([long]$turn.ticks, [DateTimeKind]::Utc)

    $turnAcct = Account-At $t $Timeline
    $isCurrent = $true
    if ($script:currentAccount) {
        $isCurrent = ($turnAcct -and [string]$turnAcct.org -eq $script:currentAccount.org)
    }

    if ($isCurrent) {

        if ($t -gt $script:cut7d) {
            $script:tok7d  += [long]$turn.sum
            $script:cost7d += [double]$turn.cost
        }
        if ($t -gt $script:cut5h) {
            $script:tok5h  += [long]$turn.sum
            $script:cost5h += [double]$turn.cost
        }
        if ($turn.modelId) {
            $mk = ([string]$turn.modelId).ToLowerInvariant()
            if (-not $script:lastModelTurns.ContainsKey($mk) -or
                [long]$turn.ticks -gt $script:lastModelTurns[$mk]) {
                $script:lastModelTurns[$mk] = [long]$turn.ticks
            }
        }
    }

    if ($script:devicesEnabled) {
        $tag = $null
        if (-not $script:currentAccount)        { $tag = Get-OrgTag '' }
        elseif ($turnAcct -and $turnAcct.org)   { $tag = Get-OrgTag ([string]$turnAcct.org) }
        if ($tag) {
            $sec   = [long][math]::Floor(($t - $script:unixEpoch).TotalSeconds)
            $start = $sec - ($sec % $script:deviceBucketSec)
            if (-not $script:deviceBuckets.ContainsKey($tag)) { $script:deviceBuckets[$tag] = @{} }
            $rows = $script:deviceBuckets[$tag]
            if ($rows.ContainsKey($start)) {
                $rows[$start][0] = [long]$rows[$start][0] + [long]$turn.sum
                $rows[$start][1] = [double]$rows[$start][1] + [double]$turn.cost
            } else {
                $rows[$start] = @([long]$turn.sum, [double]$turn.cost)
            }
        }
    }

    [void]$script:turns.Add(@{ ticks = $turn.ticks; sum = $turn.sum; cost = $turn.cost })
}

if (-not $useCache -and (Test-Path $projectsDir)) {
    $scanLockHeld = Enter-ScanLock $scanLockPath
    $seen = @{}

    $turns = New-Object System.Collections.ArrayList

    $transcriptStateOut = @{}
    $scanWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $files = Get-ChildItem -Path $projectsDir -Filter *.jsonl -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -gt $scanFloor }

    foreach ($f in $files) {
        $key = $f.FullName
        $currentLen = $f.Length
        $cached = $null
        if ($transcriptCache.ContainsKey($key)) { $cached = $transcriptCache[$key] }

        $resumeOffset = 0L
        $kept = New-Object System.Collections.ArrayList
        if ($cached) {
            $cachedLen = [long]$cached.length
            if ($currentLen -lt $cachedLen) {

                $resumeOffset = 0L
            } else {
                $resumeOffset = [long]$cached.lastScanOffset
                if ($cached.turns) {
                    foreach ($prev in $cached.turns) {
                        if ([long]$prev[0] -lt $scanFloor.Ticks) { continue }
                        [void]$kept.Add(@{ ticks = [long]$prev[0]; sum = [long]$prev[1]; cost = [double]$prev[2]; msgId = [string]$prev[3]; modelId = [string]$prev[4] })
                    }
                }
            }
        }

        $timeline = Get-SessionTimeline $f
        foreach ($k in $kept) { Apply-Turn $k $timeline }

        $reader = $null
        $stream = $null
        $endOffset = $resumeOffset
        $lastUsageLineThisFile = $null
        if ($cached -and $cached.PSObject.Properties.Match('lastUsageLine').Count -gt 0) {
            $lastUsageLineThisFile = [string]$cached.lastUsageLine
        }
        $newTurnsForCache = New-Object System.Collections.ArrayList
        $overBudget = $scanWatch.ElapsedMilliseconds -gt $scanBudgetMs
        if ($overBudget -and $resumeOffset -lt $currentLen) { $scanIncomplete = $true }
        if (-not $overBudget) {
            try {
                $stream = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                if ($resumeOffset -gt 0 -and $resumeOffset -le $stream.Length) {
                    [void]$stream.Seek($resumeOffset, [System.IO.SeekOrigin]::Begin)
                }

                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 4096, $false)
                while (-not $reader.EndOfStream) {
                    $line = $reader.ReadLine()
                    if (-not $line) { continue }
                    $turn = Parse-UsageLine $line $scanFloor
                    if (-not $turn) { continue }

                    $lastUsageLineThisFile = $line
                    $isRepeat = $turn.msgId -and $seen.ContainsKey($turn.msgId)
                    Apply-Turn $turn $timeline
                    if (-not $isRepeat) { [void]$newTurnsForCache.Add($turn) }
                }

                $endOffset = $reader.BaseStream.Position
                $reader.Close()
                $stream = $null
            } catch {
                Write-DebugLog $_ -Scope 'transcript-scan'
                if ($reader) { try { $reader.Close() } catch { Write-DebugLog $_ -Scope 'transcript-reader-close' } }
                if ($stream) { try { $stream.Close() } catch { Write-DebugLog $_ -Scope 'transcript-reader-close' } }
            }
        }

        [void]$kept.AddRange($newTurnsForCache)
        $transcriptStateOut[$key] = @{
            length         = $currentLen
            lastScanOffset = $endOffset
            turns          = $kept
        }
    }
}

if ($devicesEnabled -and -not $useCache) {

    if ($null -ne $turns -and -not $scanIncomplete) { Write-DeviceFile $devicesDir $deviceId $deviceBuckets }
    $peers = Read-PeerDevices $devicesDir $deviceId (Get-OrgTag $currentOrgKey) $nowUtc $cut5h $cut7d
    $tok5h  += $peers.tok5h;  $cost5h += $peers.cost5h
    $tok7d  += $peers.tok7d;  $cost7d += $peers.cost7d
}

$gapTicks = [long]$sessionGapMinutes * [TimeSpan]::TicksPerMinute
$sessionLatestTicks = [long]0
$scannedSessionTok  = [long]0
$scannedSessionCost = 0.0
if ($useCache) {
    $scannedSessionTok  = $cachedSessionTok
    $scannedSessionCost = $cachedSessionCost
    if ($cachedSessionLatest) { $sessionLatestTicks = ([DateTime]$cachedSessionLatest).Ticks }
} elseif ($turns -and $turns.Count -gt 0) {
    $n = $turns.Count
    $keys  = New-Object long[] $n
    $order = New-Object int[] $n
    for ($i = 0; $i -lt $n; $i++) { $keys[$i] = [long]$turns[$i].ticks; $order[$i] = $i }
    [Array]::Sort($keys, $order)
    $sessionLatestTicks = $keys[$n - 1]
    $prev = $sessionLatestTicks
    for ($i = $n - 1; $i -ge 0; $i--) {
        if (($prev - $keys[$i]) -gt $gapTicks) { break }
        $e = $turns[$order[$i]]
        $scannedSessionTok  += [long]$e.sum
        $scannedSessionCost += [double]$e.cost
        $prev = $keys[$i]
    }
}
if ($sessionLatestTicks -gt 0 -and ($nowUtc.Ticks - $sessionLatestTicks) -le $gapTicks) {
    $tokSession  = $scannedSessionTok
    $costSession = $scannedSessionCost
}

$pct5h = $hookFields.pct5h
$pct7d = $hookFields.pct7d

try {
    $payload = @{
        schemaVersion = $cacheSchemaVersion
        computedAtUtc = $(if ($useCache -and $computedAt) { ([DateTime]$computedAt).ToString('o') } else { $nowUtc.ToString('o') })
        orgKey        = $currentOrgKey
        tok5h         = $tok5h
        tok7d         = $tok7d
        cost5h        = $cost5h
        cost7d        = $cost7d

    }
    if ($null -ne $pct5h) { $payload.pct5h = [double]$pct5h }
    if ($null -ne $pct7d) { $payload.pct7d = [double]$pct7d }
    if ($null -ne $pct5h -or $null -ne $pct7d) {
        $payload.pctSavedAtUtc = $nowUtc.ToString('o')
    }

    if ($null -ne $reset5hUtc) { $payload.resets5h = $reset5hUtc.ToString('o') }
    if ($null -ne $reset7dUtc) { $payload.resets7d = $reset7dUtc.ToString('o') }
    if ($useCache) {
        if ($cachedIncomplete) { $payload.scanIncomplete = $true }
        if ($cachedWindow5h) { $payload.window5h = ([DateTime](ConvertTo-ResetUtc $cachedWindow5h)).ToString('o') }
        if ($cachedWindow7d) { $payload.window7d = ([DateTime](ConvertTo-ResetUtc $cachedWindow7d)).ToString('o') }
        if ($null -ne $cachedScanMs) { $payload.scanMs = $cachedScanMs }
    } else {
        if ($scanIncomplete) { $payload.scanIncomplete = $true }
        if ($null -ne $live5hUtc) { $payload.window5h = ([DateTime]$live5hUtc).ToString('o') }
        if ($null -ne $live7dUtc) { $payload.window7d = ([DateTime]$live7dUtc).ToString('o') }
        if ($scanWatch) { $payload.scanMs = [long]$scanWatch.ElapsedMilliseconds }
    }

    $modelTurnsOut = @{}
    foreach ($mk in $lastModelTurns.Keys) {
        $modelTurnsOut[$mk] = ([DateTime]::new([long]$lastModelTurns[$mk], [DateTimeKind]::Utc)).ToString('o')
    }
    $payload.lastModelTurns = $modelTurnsOut

    $payload.tokSession  = $scannedSessionTok
    $payload.costSession = $scannedSessionCost
    if ($sessionLatestTicks -gt 0) {
        $payload.sessionLatestUtc = ([DateTime]::new($sessionLatestTicks, [DateTimeKind]::Utc)).ToString('o')
    }
    $body = $payload | ConvertTo-Json -Compress -Depth 4 -ErrorAction Stop
    [System.IO.File]::WriteAllText($cachePath, $body, [System.Text.UTF8Encoding]::new($false))
    if ($null -ne $transcriptStateOut) { Write-TranscriptState $statePath $transcriptStateOut }
    if ($scanLockHeld) { Remove-Item -LiteralPath $scanLockPath -Force -ErrorAction SilentlyContinue }
} catch { Write-DebugLog $_ -Scope 'cache-write' }

$scopedLimits     = @()
$scopedFetchedUtc = $null
$scopedAttempted  = $null
$scopedFailures   = 0

$scopedEnabled = -not ($env:STATUSLINE_SCOPED_LIMITS -match '^(0|off|false|no)$')

if ($scopedEnabled -and (Test-Path $scopedCachePath)) {
    try {
        $sc = Get-Content -Raw -LiteralPath $scopedCachePath | ConvertFrom-Json

        if ([string]$sc.orgKey -eq $currentOrgKey) {
            $scopedFetchedUtc = ConvertTo-ResetUtc $sc.fetchedAtUtc
            $scopedAttempted  = ConvertTo-ResetUtc $sc.attemptedAtUtc
            $scopedLimits     = @(@($sc.limits) | Where-Object { $_ })
            if ($sc.PSObject.Properties.Match('failures').Count -gt 0) {
                $scopedFailures = [int]$sc.failures
            }
        }
    } catch { Write-DebugLog $_ -Scope 'scoped-cache-read' }
}

$scopedTtlSec = 900
if ($env:STATUSLINE_SCOPED_TTL -match '^\d+$') { $scopedTtlSec = [int]$env:STATUSLINE_SCOPED_TTL }

$scopedModelBars = @($scopedLimits | Where-Object {
    $_ -and ([string]$_.kind -eq 'weekly_scoped' -or [string]::IsNullOrWhiteSpace([string]$_.kind))
})

$scopedActiveTtlSec = 90
if ($env:STATUSLINE_SCOPED_ACTIVE_TTL -match '^\d+$') { $scopedActiveTtlSec = [int]$env:STATUSLINE_SCOPED_ACTIVE_TTL }

$scopedNeedles = @('fable', 'mythos')
foreach ($bar in $scopedModelBars) {
    $n = ([string]$bar.name).Trim().ToLowerInvariant()
    if ($n -and $scopedNeedles -notcontains $n) { $scopedNeedles += $n }
}
$scopedActivityUtc = $null
foreach ($mk in $lastModelTurns.Keys) {
    $hit = $false
    foreach ($needle in $scopedNeedles) {
        if ([string]$mk -like ('*{0}*' -f $needle)) { $hit = $true; break }
    }
    if (-not $hit) { continue }
    $when = [DateTime]::new([long]$lastModelTurns[$mk], [DateTimeKind]::Utc)
    if ($null -eq $scopedActivityUtc -or $when -gt $scopedActivityUtc) { $scopedActivityUtc = $when }
}

$scopedMoved = ($null -ne $scopedActivityUtc) -and
               (($null -eq $scopedFetchedUtc) -or ($scopedActivityUtc -gt $scopedFetchedUtc))

$scopedInterval = $scopedTtlSec
if ($scopedMoved) { $scopedInterval = $scopedActiveTtlSec }
if ($scopedFailures -gt 0) {
    $backoff = [Math]::Min($scopedTtlSec * [Math]::Pow(2, $scopedFailures), 3600)
    $scopedInterval = [Math]::Max($scopedInterval, $backoff)
}
$scopedAge = [double]::MaxValue
if ($null -ne $scopedAttempted) { $scopedAge = ($nowUtc - $scopedAttempted).TotalSeconds }

if ($scopedEnabled -and ($scopedAge -lt 0 -or $scopedAge -ge $scopedInterval)) {
    Request-ScopedLimitsRefresh $PSCommandPath $scopedLockPath $currentOrgKey
}

$limitsObs = New-Object System.Collections.ArrayList

$hookKnownUtc = [DateTime]::MinValue
if ($hookFields.transcript_path) {
    try {
        $tf = Get-Item -LiteralPath $hookFields.transcript_path -ErrorAction Stop
        $hookKnownUtc = $tf.LastWriteTimeUtc

        if ($hookKnownUtc -gt $nowUtc) { $hookKnownUtc = $nowUtc }
    } catch { Write-DebugLog $_ -Scope 'hook-known-at' }
}

[void]$limitsObs.Add(@{ key = $limitsKey5h; name = '5h'; percent = $pct5h; resetsUtc = $reset5hUtc; observedUtc = $nowUtc; knownUtc = $hookKnownUtc })
[void]$limitsObs.Add(@{ key = $limitsKey7d; name = '7d'; percent = $pct7d; resetsUtc = $reset7dUtc; observedUtc = $nowUtc; knownUtc = $hookKnownUtc })

if ($scopedEnabled -and $null -ne $scopedFetchedUtc) {
    foreach ($lim in $scopedLimits) {
        if (-not $lim) { continue }
        $kind = [string]$lim.kind
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'weekly_scoped' }
        $rUtc = ConvertTo-ResetUtc $lim.resetsAt

        if ($null -eq $rUtc) { continue }

        if ($kind -eq 'session') {
            [void]$limitsObs.Add(@{ key = $limitsKey5h; name = '5h'; percent = $lim.percent; resetsUtc = $rUtc; observedUtc = $scopedFetchedUtc; knownUtc = $scopedFetchedUtc })
        } elseif ($kind -eq 'weekly_all') {
            [void]$limitsObs.Add(@{ key = $limitsKey7d; name = '7d'; percent = $lim.percent; resetsUtc = $rUtc; observedUtc = $scopedFetchedUtc; knownUtc = $scopedFetchedUtc })
        } elseif ($kind -eq 'weekly_scoped') {
            $barName = ([string]$lim.name).Trim()
            if (-not [string]::IsNullOrWhiteSpace($barName)) {
                [void]$limitsObs.Add(@{ key = ('scoped:' + $barName); name = $barName; percent = $lim.percent; resetsUtc = $rUtc; observedUtc = $scopedFetchedUtc; knownUtc = $scopedFetchedUtc })
            }
        }
    }
}

$limitsStore = Sync-LimitsStore $limitsStorePath $currentOrgKey $limitsObs

$bucket5h = Get-LiveBucket $limitsStore $limitsKey5h $nowUtc
if ($bucket5h) {
    $pct5h = $bucket5h.percent
    if ($bucket5h.resetsAtUtc) { $reset5hUtc = $bucket5h.resetsAtUtc }
} else { $pct5h = $null }
$bucket7d = Get-LiveBucket $limitsStore $limitsKey7d $nowUtc
if ($bucket7d) {
    $pct7d = $bucket7d.percent
    if ($bucket7d.resetsAtUtc) { $reset7dUtc = $bucket7d.resetsAtUtc }
} else { $pct7d = $null }

$ctxTokens = [long]0
if ($hookFields.transcript_path -and (Test-Path $hookFields.transcript_path)) {
    $lastUsageLine = $null
    $tpath = [string]$hookFields.transcript_path

    $lastUsageLine = Get-LastUsageLineFromTail $tpath
    if (-not $lastUsageLine) {
        foreach ($line in [System.IO.File]::ReadLines($tpath)) {

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

$dir = ''
if ($hookFields.cwd) { $dir = Split-Path -Leaf $hookFields.cwd }

$gitBranch = ''
$cwd = $hookFields.cwd

if ($cwd -and (Test-Path $cwd)) {
    try {
        $gitPath = [System.IO.Path]::Combine($cwd, '.git')
        if (Test-Path $gitPath) {
            $gitDir = $gitPath
            $info = Get-Item $gitPath -Force -ErrorAction SilentlyContinue
            if ($info -and -not $info.PSIsContainer) {

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

$model = $hookFields.model_display_name

$esc = [char]27
$reset = "$esc[0m"
$fgDim = "$esc[38;5;245m"
$fgDir = "$esc[38;5;215m"
$fgGit = "$esc[38;5;180m"
$fgMod = "$esc[38;5;141m"
$fg5h      = "$esc[38;5;81m"
$fg7d      = "$esc[38;5;108m"
$fgScoped  = "$esc[38;5;176m"
$fgSession = "$esc[38;5;178m"
$fgCtx     = "$esc[38;5;110m"

$fgPctGreen  = "$esc[38;5;77m"
$fgPctYellow = "$esc[38;5;221m"
$fgPctRed    = "$esc[38;5;203m"

$pctWarn = 50.0
$pctCrit = 80.0
if ($env:STATUSLINE_PCT_THRESHOLDS -match '^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$') {
    $pctWarn = [double]$Matches[1]
    $pctCrit = [double]$Matches[2]
}

function Get-PctColor([object]$pct) {
    if ($null -eq $pct) { return $fgDim }
    $v = [double]$pct
    if ($v -ge $pctCrit) { return $fgPctRed }
    if ($v -ge $pctWarn) { return $fgPctYellow }
    return $fgPctGreen
}

function Color($fg, $text) { "$fg$text$reset" }

$parts = @()
if ($dir)       { $parts += (Color $fgDir $dir) }
if ($gitBranch) { $parts += (Color $fgGit $gitBranch.Trim()) }
if ($model)     { $parts += (Color $fgMod $model) }

$loading = '--%'

if ($null -ne $pct5h) {
    $p5 = '{0}%' -f [int][math]::Round([double]$pct5h, 0, [MidpointRounding]::AwayFromZero)
} else { $p5 = $loading }
if ($null -ne $pct7d) {
    $p7 = '{0}%' -f [int][math]::Round([double]$pct7d, 0, [MidpointRounding]::AwayFromZero)
} else { $p7 = $loading }

$r5 = Fmt-Reset $reset5hUtc $false
$r7 = Fmt-Reset $reset7dUtc $true
$body5h = "{0} tok, {1}" -f (Fmt-Tokens $tok5h), (Fmt-Cost $cost5h)
if ($r5) { $body5h = '{0}, resets {1}' -f $body5h, $r5 }
$body7d = "{0} tok, {1}" -f (Fmt-Tokens $tok7d), (Fmt-Cost $cost7d)
if ($r7) { $body7d = '{0}, resets {1}' -f $body7d, $r7 }

$pct5Color = if ($null -ne $pct5h) { Get-PctColor $pct5h } else { $fg5h }
$pct7Color = if ($null -ne $pct7d) { Get-PctColor $pct7d } else { $fg7d }
$p5Tinted = "$pct5Color$p5$reset$fg5h"
$p7Tinted = "$pct7Color$p7$reset$fg7d"
$parts += (Color $fg5h      ("5h {0} ({1})" -f $p5Tinted, $body5h))
$parts += (Color $fg7d      ("7d {0} ({1})" -f $p7Tinted, $body7d))

$scopedMaxAgeSec = 10800
foreach ($bar in $scopedModelBars) {
    $scopedName = ([string]$bar.name).Trim()
    if ([string]::IsNullOrWhiteSpace($scopedName)) { continue }

    $bucket = Get-LiveBucket $limitsStore ('scoped:' + $scopedName) $nowUtc
    $pScoped = $loading
    $pScopedColor = $fgScoped
    $rScoped = $null
    if ($bucket) {
        $fetchAge = [double]::MaxValue
        if ($bucket.observedAtUtc) {
            $fetchAge = ($nowUtc - [DateTime]$bucket.observedAtUtc).TotalSeconds
        }
        if ($fetchAge -ge 0 -and $fetchAge -lt $scopedMaxAgeSec) {
            $pScoped = '{0}%' -f [int][math]::Round([double]$bucket.percent, 0, [MidpointRounding]::AwayFromZero)
            $pScopedColor = Get-PctColor $bucket.percent
        }
        $rScoped = Fmt-Reset $bucket.resetsAtUtc $true
    }
    $bodyScoped = ''
    if ($rScoped) { $bodyScoped = ' (resets {0})' -f $rScoped }
    $pScopedTinted = "$pScopedColor$pScoped$reset$fgScoped"
    $parts += (Color $fgScoped ('{0} {1}{2}' -f $scopedName.ToLowerInvariant(), $pScopedTinted, $bodyScoped))
}

$parts += (Color $fgSession ("session {0} ({1})"     -f       (Fmt-Tokens $tokSession), (Fmt-Cost $costSession)))

$ctxText = 'ctx {0}' -f (Fmt-Tokens $ctxTokens)
if ($null -ne $hookFields.ctxPct) {
    $ctxText = '{0} ({1}%)' -f $ctxText,
        [int][math]::Round([double]$hookFields.ctxPct, 0, [MidpointRounding]::AwayFromZero)
}
$parts += (Color $fgCtx $ctxText)

$sep = " $fgDim|$reset "
[Console]::Out.Write([string]::Join($sep, $parts))
