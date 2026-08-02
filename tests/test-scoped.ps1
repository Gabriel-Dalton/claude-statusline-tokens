#Requires -Version 5.1
# Exercises the per-model (Fable) bar: that it renders through the shared
# store, that session/weekly_all rows from the usage endpoint feed the 5h
# and 7d buckets, and that the refresh fires on actual model usage rather
# than only when the 15-minute idle timer elapses.
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root = Join-Path $env:TEMP ('sl-scoped-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$claude = Join-Path $root '.claude'
New-Item -ItemType Directory -Path (Join-Path $claude 'projects\proj') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-test-1'; emailAddress = 't@example.com'; organizationName = 'Test' } } |
    ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $root '.claude.json') -Encoding utf8

# See the note in test-sync.ps1: the repo copy resolves its profile via
# [Environment]::GetFolderPath, which ignores a USERPROFILE override, so an
# unpatched run writes into the real ~/.claude — and here it would also fire
# real requests at the usage endpoint with the real credentials.
$underTest = Join-Path $root 'statusline-under-test.ps1'
$src = [System.IO.File]::ReadAllText($ScriptPath)
$src = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $src, (New-Object System.Text.UTF8Encoding($false)))
$ScriptPath = $underTest

$scopedPath = Join-Path $claude 'statusline-scoped-limits.cache.json'
$tokensPath = Join-Path $claude 'statusline-tokens.cache.json'
$lockPath   = Join-Path $claude 'statusline-scoped-limits.lock'
$transcript = Join-Path $claude 'projects\proj\session.jsonl'

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:pass++; "  PASS  $name" }
    else     { $script:fail++; "  FAIL  $name`n        $detail" }
}
function Render($rateLimits) {
    $hook = @{ workspace = @{ current_dir = $root }; model = @{ display_name = 'Opus 5' }; transcript_path = '' }
    if ($rateLimits) { $hook.rate_limits = $rateLimits }
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "`$env:USERPROFILE='$root'; & '$ScriptPath'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
function Write-ScopedCache([DateTime]$fetchedUtc, [DateTime]$attemptedUtc) {
    $now = [DateTime]::UtcNow
    @{
        schemaVersion  = 1
        orgKey         = 'org-test-1'
        status         = 'ok'
        failures       = 0
        fetchedAtUtc   = $fetchedUtc.ToString('o')
        attemptedAtUtc = $attemptedUtc.ToString('o')
        limits = @(
            @{ kind = 'session';       name = '';      percent = 44; resetsAt = $now.AddHours(3).ToString('o') },
            @{ kind = 'weekly_all';    name = '';      percent = 36; resetsAt = $now.AddDays(4).ToString('o') },
            @{ kind = 'weekly_scoped'; name = 'Fable'; percent = 4;  resetsAt = $now.AddDays(4).ToString('o') }
        )
    } | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $scopedPath -Encoding utf8
}
function Write-Transcript([string]$model, [DateTime]$whenUtc) {
    # Shaped like a real assistant turn, including "role":"assistant" —
    # the repo copy's parser uses that as a second anchor alongside
    # "usage":{ to avoid counting lines that merely mention usage, so a
    # fixture without it parses to zero turns and every activity assertion
    # below passes vacuously.
    $line = '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_{1}","type":"message","role":"assistant","model":"{2}","usage":{{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f `
        $whenUtc.ToString('o'), ([Guid]::NewGuid().ToString('N').Substring(0,12)), $model
    Set-Content -Path $transcript -Value $line -Encoding utf8
}
function Attempted { (Get-Content -Raw $scopedPath | ConvertFrom-Json).attemptedAtUtc }
function Fresh { Remove-Item $tokensPath -Force -ErrorAction SilentlyContinue
                 Remove-Item $lockPath   -Force -ErrorAction SilentlyContinue }
# Also drops the shared store. Needed by any check that backdates
# fetchedAtUtc: observedAtUtc is monotonic by design, so a bucket carrying a
# fresher stamp from an earlier check would (correctly) refuse to regress,
# and the check would be asserting against a state production never reaches.
# In production a scoped bucket's stamp IS its fetch time, because the
# endpoint is its only writer — so a clean store plus one old fetch is an
# exact reproduction of "the endpoint has been failing for hours".
function FreshAll { Fresh
                    Remove-Item (Join-Path $claude 'statusline-limits.cache.json') -Force -ErrorAction SilentlyContinue }

$now = [DateTime]::UtcNow

"--- 0. the fixture actually parses as a turn (guards every check below)"
Write-ScopedCache $now.AddMinutes(-5) $now.AddMinutes(-5)
Write-Transcript 'claude-opus-5' $now.AddMinutes(-2)
Fresh
$null = Render
$tc0 = Get-Content -Raw $tokensPath | ConvertFrom-Json
Check 'mock transcript counts as a turn' ($tc0.tok5h -gt 0) (Get-Content -Raw $tokensPath)
Check 'and is attributed to its model'   ($tc0.lastModelTurns.PSObject.Properties.Match('claude-opus-5').Count -gt 0) (Get-Content -Raw $tokensPath)

"--- 1. the per-model bar renders, and endpoint rows feed 5h and 7d"
Write-ScopedCache $now.AddMinutes(-5) $now.AddMinutes(-5)
Write-Transcript 'claude-opus-5' $now.AddMinutes(-2)
Fresh
$l = Render
Check 'fable bar renders 4%'          ($l -match 'fable 4%')          $l
Check '5h from endpoint reads 44%'    ($l -match '5h 44%')            $l
Check '7d from endpoint reads 36%'    ($l -match '7d 36%')            $l
Check 'no anonymous extra bars'       (($l -split '\|').Count -eq 7)  $l

"--- 2. opus-only activity does not trigger an early refresh"
Write-ScopedCache $now.AddMinutes(-5) $now.AddMinutes(-5)
$before = Attempted
Fresh
$null = Render
Start-Sleep -Seconds 6
Check 'idle interval respected (no refetch)' ((Attempted) -eq $before) "attempted $before -> $(Attempted)"

"--- 3. a fable turn newer than the last fetch triggers one promptly"
Write-ScopedCache $now.AddMinutes(-5) $now.AddMinutes(-5)
Write-Transcript 'claude-fable-5' $now.AddMinutes(-1)
$before = Attempted
Fresh
$null = Render
$advanced = $false
foreach ($i in 1..20) {
    Start-Sleep -Milliseconds 500
    if ((Attempted) -ne $before) { $advanced = $true; break }
}
Check 'fable usage forces a refetch' $advanced "attempted $before -> $(Attempted)"

"--- 4. the tokens cache carries the model-activity stamp across renders"
$tc = Get-Content -Raw $tokensPath | ConvertFrom-Json
$hasFable = $tc.lastModelTurns.PSObject.Properties.Match('claude-fable-5').Count -gt 0
Check 'lastModelTurns records claude-fable-5' $hasFable (Get-Content -Raw $tokensPath)

"--- 5. a fable turn OLDER than the last fetch does not re-trigger"
Write-ScopedCache $now.AddSeconds(-30) $now.AddSeconds(-30)
Write-Transcript 'claude-fable-5' $now.AddMinutes(-10)
$before = Attempted
Fresh
$null = Render
Start-Sleep -Seconds 6
Check 'already-seen usage does not refetch' ((Attempted) -eq $before) "attempted $before -> $(Attempted)"

"--- 6. a stale endpoint answer degrades the bar to --%, keeping its reset"
Write-ScopedCache $now.AddHours(-4) $now.AddSeconds(-10)
FreshAll
$l = Render
Check 'four-hour-old fable figure shows --%' ($l -match 'fable --%') $l
Check 'but its reset countdown survives'     ($l -match 'fable --% \(resets') $l

"--- 7. an older endpoint row must not drag the freshness stamp backwards"
# The hook says 49% right now; the cached endpoint answer says the same 49%
# but was fetched ten minutes ago. Merged second, it used to overwrite the
# hook's stamp with its own older one, so the bucket looked ten minutes
# stale the instant after it was confirmed live.
Write-ScopedCache $now.AddMinutes(-10) $now.AddSeconds(-5)
FreshAll
$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
$r5e = [long]($now.AddHours(3) - $epoch).TotalSeconds
$renderedAt = [DateTime]::UtcNow
$null = Render @{ five_hour = @{ used_percentage = 49; resets_at = $r5e } }
$store = Get-Content -Raw (Join-Path $claude 'statusline-limits.cache.json') | ConvertFrom-Json
$obs = [DateTime]::Parse($store.buckets.'5h'.observedAtUtc, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
Check '5h stamp stays at the live observation' ($obs -ge $renderedAt.AddSeconds(-2)) `
    "rendered $($renderedAt.ToString('o')), stamp $($store.buckets.'5h'.observedAtUtc)"
# The scoped bucket has no hook source, so its stamp is the fetch time and
# should be exactly that — older, and correctly so.
$sobs = [DateTime]::Parse($store.buckets.'scoped:Fable'.observedAtUtc, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal))
Check 'scoped stamp still reflects the fetch, not now' ($sobs -lt $renderedAt.AddMinutes(-5)) `
    "stamp $($store.buckets.'scoped:Fable'.observedAtUtc)"

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
