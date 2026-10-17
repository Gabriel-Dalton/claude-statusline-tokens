#Requires -Version 5.1
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root     = Join-Path $env:TEMP ('sl-shared-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$main     = Join-Path $root '.claude'
$personal = Join-Path $root '.claude-personal'
$proj     = Join-Path $main 'projects\proj'
New-Item -ItemType Directory -Path (Join-Path $proj 'sess-personal\subagents') -Force | Out-Null
New-Item -ItemType Directory -Path $personal -Force | Out-Null
New-Item -ItemType Junction -Path (Join-Path $personal 'projects') -Target (Join-Path $main 'projects') | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-main'; emailAddress='a@example.com'; organizationName='A' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root '.claude.json') -Encoding utf8
@{ oauthAccount = @{ organizationUuid = 'org-personal'; emailAddress='b@example.com'; organizationName='B' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $personal '.claude.json') -Encoding utf8

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
function Write-Turn([string]$path, [int]$tokens, [int]$minutesAgo = 10) {
    $ts = ([DateTime]::UtcNow).AddMinutes(-$minutesAgo).ToString('o')
    $line = '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_{1}","type":"message","role":"assistant","model":"claude-opus-5","usage":{{"input_tokens":{2},"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f `
        $ts, ([Guid]::NewGuid().ToString('N').Substring(0,12)), $tokens
    Add-Content -Path $path -Value $line -Encoding utf8
}
function Fresh {
    foreach ($d in @($main, $personal)) {
        Remove-Item (Join-Path $d 'statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue
    }
}
function Render([string]$sessionId, [string]$configDir = '') {
    $hook = @{ workspace=@{current_dir=$root}; model=@{display_name='Opus 5'}; transcript_path=''
               session_id=$sessionId
               rate_limits=@{ five_hour = @{ used_percentage = 20; resets_at = (E ([DateTime]::UtcNow).AddHours(2)) } } }
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
function Registry {
    $p = Join-Path $main 'projects\statusline-sessions.json'
    if (-not (Test-Path $p)) { return $null }
    return [System.IO.File]::ReadAllText($p) | ConvertFrom-Json
}
function Last-Org($reg, [string]$id) {
    if (-not $reg -or -not $reg.sessions) { return '' }
    return [string]@($reg.sessions.$id)[-1].org
}

Write-Turn (Join-Path $proj 'sess-main.jsonl')                          10000
Write-Turn (Join-Path $proj 'sess-personal.jsonl')                       7000
Write-Turn (Join-Path $proj 'sess-personal\subagents\agent-a1.jsonl')     500
Write-Turn (Join-Path $proj 'sess-old.jsonl')                             300

"--- 1. each profile records the session it runs, in the shared folder"
[void](Render 'sess-main')
[void](Render 'sess-personal' $personal)
$reg = Registry
Check 'the record sits beside the shared transcripts' ($null -ne $reg) 'no projects\statusline-sessions.json'
Check 'the main session is under the main account' ((Last-Org $reg 'sess-main') -eq 'org-main') ($reg | ConvertTo-Json -Depth 5 -Compress)
Check 'the personal session is under its own account' ((Last-Org $reg 'sess-personal') -eq 'org-personal') ($reg | ConvertTo-Json -Depth 5 -Compress)

"--- 2. the 5h total counts only the account's own sessions"
Fresh
$l = Render 'sess-main'
Check 'main counts its session and the unrecorded one' ((Tok $l '5h') -eq 10300) $l
$l = Render 'sess-personal' $personal
Check 'personal counts its session, its subagent and the unrecorded one' ((Tok $l '5h') -eq 7800) $l

"--- 3. a sign-in change inside a session splits that session"
Fresh
@{ oauthAccount = @{ organizationUuid = 'org-other'; emailAddress='c@example.com'; organizationName='C' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $personal '.claude.json') -Encoding utf8
[void](Render 'sess-personal' $personal)
$reg = Registry
Check 'the session gains a second point' ($reg -and @($reg.sessions.'sess-personal').Count -eq 2) ($reg | ConvertTo-Json -Depth 5 -Compress)
Check 'the main session is untouched' ((Last-Org $reg 'sess-main') -eq 'org-main') ($reg | ConvertTo-Json -Depth 5 -Compress)
Write-Turn (Join-Path $proj 'sess-personal.jsonl') 200 0
Fresh
$l = Render 'sess-personal' $personal
Check 'only the turn after the change counts for the new account' ((Tok $l '5h') -eq 200) $l

""
"$pass passed, $fail failed"
[System.IO.Directory]::Delete((Join-Path $personal 'projects'))
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
