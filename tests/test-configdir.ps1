#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root   = Join-Path $env:TEMP ('sl-configdir-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$main   = Join-Path $root '.claude'
$second = Join-Path $root 'profiles\second'
New-Item -ItemType Directory -Path (Join-Path $main 'projects\proj') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $second 'projects\proj') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-main'; emailAddress='a@e.com'; organizationName='A' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root '.claude.json') -Encoding utf8
@{ oauthAccount = @{ organizationUuid = 'org-second'; emailAddress='b@e.com'; organizationName='B' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $second '.claude.json') -Encoding utf8

$underTest = Join-Path $root 'statusline-under-test.ps1'
$src = [System.IO.File]::ReadAllText($ScriptPath)
$src = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $src, (New-Object System.Text.UTF8Encoding($false)))

$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
function E([DateTime]$u) { [long]($u - $epoch).TotalSeconds }

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
    if ($ok) { $script:pass++; "  PASS  $n" } else { $script:fail++; "  FAIL  $n`n        $d" }
}
function Write-Turn([string]$dir, [int]$tokens) {
    $ts = ([DateTime]::UtcNow).AddMinutes(-10).ToString('o')
    $line = '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_{1}","type":"message","role":"assistant","model":"claude-opus-5","usage":{{"input_tokens":{2},"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f `
        $ts, ([Guid]::NewGuid().ToString('N').Substring(0,12)), $tokens
    Set-Content -Path (Join-Path $dir 'projects\proj\session.jsonl') -Value $line -Encoding utf8
}
function Render($rateLimits, [string]$configDir = '') {
    $hook = @{ workspace=@{current_dir=$root}; model=@{display_name='Opus 5'}; transcript_path='' }
    if ($rateLimits) { $hook.rate_limits = $rateLimits }
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "`$env:USERPROFILE='$root'; `$env:CLAUDE_CONFIG_DIR='$configDir'; `$env:STATUSLINE_SCOPED_LIMITS='0'; & '$underTest'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
function Tok([string]$line, [string]$label) {
    if ($line -notmatch ("{0}\s+\S+\s+\(([0-9.]+)([kMB]?) tok" -f [regex]::Escape($label))) { return -1 }
    $n = [double]$Matches[1]
    switch ($Matches[2]) { 'k' { $n * 1000 } 'M' { $n * 1000000 } 'B' { $n * 1000000000 } default { $n } }
}
function Store-Org([string]$dir) {
    $p = Join-Path $dir 'statusline-limits.cache.json'
    if (-not (Test-Path $p)) { return '' }
    return [string]([System.IO.File]::ReadAllText($p) | ConvertFrom-Json).orgKey
}

$now = [DateTime]::UtcNow
Write-Turn $main   10000
Write-Turn $second 7000

"--- 1. the main login is unchanged"
$l = Render @{ five_hour = @{ used_percentage = 20; resets_at = (E $now.AddHours(2)) } }
Check 'shows the main percentage' ($l -match '5h 20%') $l
Check 'and the main transcripts'  ((Tok $l '5h') -eq 10000) $l
Check 'store belongs to the main account' ((Store-Org $main) -eq 'org-main') (Store-Org $main)

"--- 2. a session under CLAUDE_CONFIG_DIR reads its own profile"
$l = Render @{ five_hour = @{ used_percentage = 3; resets_at = (E $now.AddHours(4)) } } $second
Check 'shows the second account''s percentage' ($l -match '5h 3%') $l
Check 'and the second profile''s transcripts'   ((Tok $l '5h') -eq 7000) $l
Check 'its store is written in its own folder' ((Store-Org $second) -eq 'org-second') (Store-Org $second)
Check 'its cache is written in its own folder' (Test-Path (Join-Path $second 'statusline-tokens.cache.json')) 'no cache in the profile folder'

"--- 3. and leaves the main login's numbers alone"
Check 'main store still belongs to the main account' ((Store-Org $main) -eq 'org-main') (Store-Org $main)
$l = Render @{ five_hour = @{ used_percentage = 20; resets_at = (E $now.AddHours(2)) } }
Check 'main window still shows 20%' ($l -match '5h 20%') $l

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
