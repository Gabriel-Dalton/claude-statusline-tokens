#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root = Join-Path $env:TEMP ('sl-scale-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$claude = Join-Path $root '.claude'
New-Item -ItemType Directory -Path (Join-Path $claude 'projects\proj') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-test-1'; emailAddress='t@e.com'; organizationName='T' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root '.claude.json') -Encoding utf8

$underTest = Join-Path $root 'statusline-under-test.ps1'
$src = [System.IO.File]::ReadAllText($ScriptPath)
$src = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $src, (New-Object System.Text.UTF8Encoding($false)))

$transcript = Join-Path $claude 'projects\proj\session.jsonl'
$cachePath  = Join-Path $claude 'statusline-tokens.cache.json'
$storePath  = Join-Path $claude 'statusline-limits.cache.json'
$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
function E([DateTime]$u) { [long]($u - $epoch).TotalSeconds }

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
    if ($ok) { $script:pass++; "  PASS  $n" } else { $script:fail++; "  FAIL  $n`n        $d" }
}
function Fresh {
    Remove-Item $cachePath -Force -ErrorAction SilentlyContinue
    Remove-Item $storePath -Force -ErrorAction SilentlyContinue
}
function Write-Turns($entries) {
    $lines = foreach ($e in $entries) {
        $ts = ([DateTime]::UtcNow).AddMinutes(-1 * $e.minutesAgo).ToString('o')
        '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_{1}","type":"message","role":"assistant","model":"claude-opus-5","usage":{{"input_tokens":{2},"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f `
            $ts, ([Guid]::NewGuid().ToString('N').Substring(0,12)), $e.tokens
    }
    Set-Content -Path $transcript -Value $lines -Encoding utf8
}
function Render($rateLimits, [string]$transcriptPath = '') {
    $hook = @{ workspace=@{current_dir=$root}; model=@{display_name='Opus 5'}; transcript_path=$transcriptPath }
    if ($rateLimits) { $hook.rate_limits = $rateLimits }
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "`$env:USERPROFILE='$root'; `$env:STATUSLINE_SCOPED_LIMITS='0'; & '$underTest'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
function Tok([string]$line, [string]$label) {
    if ($line -notmatch ("{0}\s+\S+\s+\(([0-9.]+)([kMB]?) tok" -f [regex]::Escape($label))) { return -1 }
    $n = [double]$Matches[1]
    switch ($Matches[2]) { 'k' { $n * 1000 } 'M' { $n * 1000000 } 'B' { $n * 1000000000 } default { $n } }
}
function Read-Cache { [System.IO.File]::ReadAllText($cachePath) }
function Cached-Turns { ([regex]::Matches((Read-Cache), '"ticks":')).Count }
function Expire-Cache {
    $old = [DateTime]::UtcNow.AddMinutes(-10).ToString('o')
    $body = (Read-Cache) -replace '"computedAtUtc":"[^"]+"', ('"computedAtUtc":"{0}"' -f $old)
    [System.IO.File]::WriteAllText($cachePath, $body, (New-Object System.Text.UTF8Encoding($false)))
}
function Seed-Store($buckets) {
    @{ orgKey = 'org-test-1'; schemaVersion = 2; buckets = $buckets } |
        ConvertTo-Json -Depth 5 -Compress | Set-Content -Path $storePath -Encoding utf8
}

$now = [DateTime]::UtcNow

Write-Turns @(
    @{ minutesAgo = 120; tokens = 10000 },
    @{ minutesAgo = 60;  tokens = 10000 },
    @{ minutesAgo = 10;  tokens = 10000 }
)

"--- 1. an unchanged transcript is not read again"
Fresh
$l = Render $null
Check 'first scan sees 30k' ((Tok $l '5h') -eq 30000) $l
$turnsAfterFirst = Cached-Turns
foreach ($i in 1..3) { Expire-Cache; $l = Render $null }
Check 'three rescans later the total is still 30k' ((Tok $l '5h') -eq 30000) $l
Check 'and the cache holds the same turns, not four copies' ((Cached-Turns) -eq $turnsAfterFirst) ("{0} then {1}" -f $turnsAfterFirst, (Cached-Turns))

"--- 2. a turn logged once per content block is cached once"
$dup = (Get-Content $transcript)[0]
Add-Content -Path $transcript -Value $dup -Encoding utf8
Add-Content -Path $transcript -Value $dup -Encoding utf8
Fresh
$l = Render $null
Check 'repeats do not inflate the total' ((Tok $l '5h') -eq 30000) $l
Check 'or the cache' ((Cached-Turns) -eq 3) ("{0} cached" -f (Cached-Turns))

"--- 3. a store stamp that differs from the hook's still allows a cache hit"
Fresh
Seed-Store @{ '5h' = @{ name = '5h'; percent = 5; observedAtUtc = $now.ToString('o'); knownAtUtc = $now.ToString('o'); resetsAtUtc = $now.AddHours(4).ToString('o') } }
$hook = @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddHours(1)) } }
$null = Render $hook
$stampA = [regex]::Match((Read-Cache), '"computedAtUtc":"([^"]+)"').Groups[1].Value
$null = Render $hook
$stampB = [regex]::Match((Read-Cache), '"computedAtUtc":"([^"]+)"').Groups[1].Value
Check 'second render reuses the scan' ($stampA -eq $stampB) "$stampA then $stampB"

"--- 4. a hit does not push the scan time forward"
$null = Render $hook
$stampC = [regex]::Match((Read-Cache), '"computedAtUtc":"([^"]+)"').Groups[1].Value
Check 'third render leaves the scan time alone' ($stampA -eq $stampC) "$stampA then $stampC"

"--- 5. a wrong stored reset is corrected by a better-informed reading"
Fresh
Seed-Store @{ '7d' = @{ name = '7d'; percent = 0; observedAtUtc = $now.AddDays(-2).ToString('o'); resetsAtUtc = $now.AddDays(3).ToString('o') } }
$l = Render @{ seven_day = @{ used_percentage = 37; resets_at = (E $now.AddDays(2)) } } $transcript
Check 'shows the reported 37%, not the stored 0%' ($l -match '7d 37%') $l

"--- 6. a window that has rolled still loses to the stored one"
Fresh
Seed-Store @{ '5h' = @{ name = '5h'; percent = 3; observedAtUtc = $now.ToString('o'); knownAtUtc = $now.AddMinutes(-30).ToString('o'); resetsAtUtc = $now.AddHours(4).ToString('o') } }
$l = Render @{ five_hour = @{ used_percentage = 50; resets_at = (E $now.AddMinutes(-20)) } } $transcript
Check 'stays on the current 3%, not the old window''s 50%' ($l -match '5h 3%') $l

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
