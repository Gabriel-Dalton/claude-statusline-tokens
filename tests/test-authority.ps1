#Requires -Version 5.1
# Regression suite for the poisoned-bucket failure: a reading that pairs a
# new window's resets_at with the previous window's percentage, which
# maximum-only merging then pinned in place for the whole window.
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root = Join-Path $env:TEMP ('sl-auth-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$claude = Join-Path $root '.claude'
New-Item -ItemType Directory -Path (Join-Path $claude 'projects\proj') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid='org-test-1'; emailAddress='t@e.com'; organizationName='T' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root '.claude.json') -Encoding utf8

$underTest = Join-Path $root 'statusline-under-test.ps1'
$src = [System.IO.File]::ReadAllText($ScriptPath)
$src = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $src, (New-Object System.Text.UTF8Encoding($false)))

$storePath  = Join-Path $claude 'statusline-limits.cache.json'
$scopedPath = Join-Path $claude 'statusline-scoped-limits.cache.json'
$transcript = Join-Path $claude 'projects\proj\session.jsonl'
$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
function E([DateTime]$u) { [long]($u - $epoch).TotalSeconds }

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
    if ($ok) { $script:pass++; "  PASS  $n" } else { $script:fail++; "  FAIL  $n`n        $d" }
}
# A window counts as having reason to know when its transcript was written
# moments ago. $AgeSec controls that: 0 = active window, 600 = idle one.
function Render($pct, $resetsAt, [int]$AgeSec, [switch]$NoTranscript) {
    Set-Content -Path $transcript -Value '{"type":"user","timestamp":"x"}' -Encoding utf8
    (Get-Item $transcript).LastWriteTimeUtc = ([DateTime]::UtcNow).AddSeconds(-1 * $AgeSec)
    $hook = @{ workspace=@{current_dir=$root}; model=@{display_name='Opus 5'}
               transcript_path = $(if ($NoTranscript) { '' } else { $transcript }) }
    if ($null -ne $pct) { $hook.rate_limits = @{ five_hour = @{ used_percentage = $pct; resets_at = $resetsAt } } }
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "`$env:USERPROFILE='$root'; `$env:STATUSLINE_SCOPED_LIMITS='0'; & '$underTest'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
function Pct([string]$l) { if ($l -match '5h\s+(--%|\d+%)') { $Matches[1] } else { '<none>' } }
function Fresh { Remove-Item $storePath -Force -ErrorAction SilentlyContinue
                 Remove-Item (Join-Path $claude 'statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue }

$now = [DateTime]::UtcNow
$rNew = E $now.AddHours(4.8)   # the window you are in now
$rOld = E $now.AddMinutes(-10) # the one that just ended

"--- 1. THE BUG: a new window's stamp arriving with the old window's number"
Fresh
$l = Render 50 $rNew 600          # idle window, no reason to know: 50%
Check 'a stale 50% still seeds an empty bucket' ((Pct $l) -eq '50%') $l
$l = Render 3 $rNew 0             # active window, just had a response: 3%
Check 'an active window corrects it down to 3%' ((Pct $l) -eq '3%') $l

"--- 2. and it stays corrected when the stale window renders again"
$l = Render 50 $rNew 600
Check 'stale 50% cannot climb back' ((Pct $l) -eq '3%') $l

"--- 3. the original complaint still holds: stale-low never wins"
Fresh
$l = Render 44 $rNew 0            # active window: 44%
Check 'active 44% recorded'          ((Pct $l) -eq '44%') $l
$l = Render 42 $rNew 600           # idle window still on 42%
Check 'idle 42% does not drag it down' ((Pct $l) -eq '44%') $l

"--- 4. an active window still reports a genuine climb"
$l = Render 47 $rNew 0
Check 'active 47% accepted' ((Pct $l) -eq '47%') $l

"--- 5. a window with no transcript at all is treated as having no standing"
$l = Render 5 $rNew 0 -NoTranscript
Check 'transcript-less low reading refused' ((Pct $l) -eq '47%') $l

"--- 6. the endpoint corrects downward even with every window idle"
Fresh
$null = Render 50 $rNew 600
@{ schemaVersion=1; orgKey='org-test-1'; status='ok'; failures=0
   fetchedAtUtc=([DateTime]::UtcNow).ToString('o'); attemptedAtUtc=([DateTime]::UtcNow).ToString('o')
   limits=@(@{ kind='session'; name=''; percent=3; resetsAt=$now.AddHours(4.8).ToString('o') })
} | ConvertTo-Json -Depth 6 -Compress | Set-Content $scopedPath -Encoding utf8
Remove-Item (Join-Path $claude 'statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue
$hook = @{ workspace=@{current_dir=$root}; model=@{display_name='Opus 5'}; transcript_path='' } |
    ConvertTo-Json -Depth 6 -Compress
$l = (($hook | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -Command "`$env:USERPROFILE='$root'; & '$underTest'") -join '') -replace "$([char]27)\[[0-9;]*m", ''
Check 'endpoint pulls 50% down to 3%' ((Pct $l) -eq '3%') $l

"--- 7. a rolled window still resets outright"
Fresh
$null = Render 44 $rNew 0
$l = Render 2 (E $now.AddHours(9.8)) 0
Check 'later stamp replaces regardless' ((Pct $l) -eq '2%') $l

"--- 8. an endpoint row with no reset stamp is dropped, not merged blind"
Fresh
$null = Render 44 $rNew 0
@{ schemaVersion=1; orgKey='org-test-1'; status='ok'; failures=0
   fetchedAtUtc=([DateTime]::UtcNow).ToString('o'); attemptedAtUtc=([DateTime]::UtcNow).ToString('o')
   limits=@(@{ kind='session'; name=''; percent=0; resetsAt='' })
} | ConvertTo-Json -Depth 6 -Compress | Set-Content $scopedPath -Encoding utf8
Remove-Item (Join-Path $claude 'statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue
$l = (($hook | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -Command "`$env:USERPROFILE='$root'; & '$underTest'") -join '') -replace "$([char]27)\[[0-9;]*m", ''
Check 'stampless 0% row ignored' ((Pct $l) -eq '44%') $l

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
