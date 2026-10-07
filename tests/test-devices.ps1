#Requires -Version 5.1
# Exercises cross-device token totals: two isolated profiles standing in for
# two machines on one account, sharing a folder through STATUSLINE_DEVICES_DIR.
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root   = Join-Path $env:TEMP ('sl-devices-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$desk   = Join-Path $root 'desk'
$lap    = Join-Path $root 'lap'
$shared = Join-Path $root 'shared'
New-Item -ItemType Directory -Path $shared -Force | Out-Null
foreach ($p in @($desk, $lap)) {
    New-Item -ItemType Directory -Path (Join-Path $p '.claude\projects\proj') -Force | Out-Null
    @{ oauthAccount = @{ organizationUuid = 'org-test-1'; emailAddress='t@e.com'; organizationName='T' } } |
        ConvertTo-Json -Depth 4 | Set-Content (Join-Path $p '.claude.json') -Encoding utf8
}

# See test-sync.ps1 for why the profile resolution is patched.
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
function Fresh([string]$profileRoot) {
    Remove-Item (Join-Path $profileRoot '.claude\statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $profileRoot '.claude\statusline-limits.cache.json') -Force -ErrorAction SilentlyContinue
}
# One turn per entry: @{ minutesAgo = N; tokens = M }
function Write-Turns([string]$profileRoot, $entries) {
    $lines = foreach ($e in $entries) {
        $ts = ([DateTime]::UtcNow).AddMinutes(-1 * $e.minutesAgo).ToString('o')
        '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_{1}","type":"message","role":"assistant","model":"claude-opus-5","usage":{{"input_tokens":{2},"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f `
            $ts, ([Guid]::NewGuid().ToString('N').Substring(0,12)), $e.tokens
    }
    Set-Content -Path (Join-Path $profileRoot '.claude\projects\proj\session.jsonl') -Value $lines -Encoding utf8
}
# One render as the given machine. $dir = $null leaves the feature unset.
function Render([string]$profileRoot, [string]$device, $dir) {
    $hook = @{ workspace=@{current_dir=$profileRoot}; model=@{display_name='Opus 5'}; transcript_path='' }
    $envs = "`$env:USERPROFILE='$profileRoot'; `$env:STATUSLINE_SCOPED_LIMITS='0'; `$env:STATUSLINE_DEVICE_ID='$device'; "
    if ($dir) { $envs += "`$env:STATUSLINE_DEVICES_DIR='$dir'; " }
    else      { $envs += "`$env:STATUSLINE_DEVICES_DIR=`$null; " }
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command ($envs + "& '$underTest'")
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
# "5h 44% (12.0k tok, $0.06, ...)" -> 12000
function Tok([string]$line, [string]$label) {
    if ($line -notmatch ("{0}\s+\S+\s+\(([0-9.]+)([kMB]?) tok" -f [regex]::Escape($label))) { return -1 }
    $n = [double]$Matches[1]
    switch ($Matches[2]) { 'k' { $n * 1000 } 'M' { $n * 1000000 } 'B' { $n * 1000000000 } default { $n } }
}
function SessionTok([string]$line) {
    if ($line -notmatch 'session\s+([0-9.]+)([kMB]?)\s+\(') { return -1 }
    $n = [double]$Matches[1]
    switch ($Matches[2]) { 'k' { $n * 1000 } 'M' { $n * 1000000 } 'B' { $n * 1000000000 } default { $n } }
}
function OrgTag([string]$org) {
    $sha = [Security.Cryptography.SHA256]::Create()
    [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($org))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
}
function Write-Peer([string]$name, [string]$tag, $rows) {
    $body = '{{"schemaVersion":1,"device":"{0}","bucketSeconds":300,"orgs":{{"{1}":[{2}]}}}}' -f `
        $name, $tag, (($rows | ForEach-Object { '[{0},{1},{2}]' -f $_[0], $_[1], $_[2] }) -join ',')
    [System.IO.File]::WriteAllText((Join-Path $shared "statusline-device-$name.json"), $body, (New-Object System.Text.UTF8Encoding($false)))
}

$now     = [DateTime]::UtcNow
$deskFile = Join-Path $shared 'statusline-device-desk.json'
$lapFile  = Join-Path $shared 'statusline-device-lap.json'
$myTag    = OrgTag 'org-test-1'

# The desktop did most of the week's work; the laptop has one small turn.
Write-Turns $desk @(
    @{ minutesAgo = 360; tokens = 60000 },
    @{ minutesAgo = 10;  tokens = 40000 }
)
Write-Turns $lap @( @{ minutesAgo = 20; tokens = 5000 } )

"--- 1. unset, the totals are this machine's own and nothing leaves ~/.claude"
Fresh $lap
$l = Render $lap 'lap' $null
Check 'laptop 7d is its own 5k' ((Tok $l '7d') -eq 5000) $l
Check 'shared folder untouched' (@(Get-ChildItem $shared).Count -eq 0) ((Get-ChildItem $shared).Name -join ', ')

"--- 2. a device publishes its buckets and does not count them twice"
Fresh $desk
$l = Render $desk 'desk' $shared
Check 'desktop file written' (Test-Path $deskFile) ((Get-ChildItem $shared).Name -join ', ')
Check 'desktop 5h is its own 40k'  ((Tok $l '5h') -eq 40000)  $l
Check 'desktop 7d is its own 100k' ((Tok $l '7d') -eq 100000) $l
$raw = [System.IO.File]::ReadAllText($deskFile)
Check 'file carries no org id'      ($raw -notmatch 'org-test-1') $raw
Check 'file carries no message ids' ($raw -notmatch 'msg_')       $raw
Check 'file is filed under the org tag' ($raw -match [regex]::Escape($myTag)) $raw

"--- 3. the other device adds them to its own totals, per window"
Fresh $lap
$l = Render $lap 'lap' $shared
Check 'laptop 5h = 5k + 40k'   ((Tok $l '5h') -eq 45000)  $l
Check 'laptop 7d = 5k + 100k'  ((Tok $l '7d') -eq 105000) $l
Check 'laptop session stays local' ((SessionTok $l) -eq 5000) $l
Check 'laptop file written' (Test-Path $lapFile) ((Get-ChildItem $shared).Name -join ', ')

"--- 4. both machines now agree"
Fresh $desk
$l = Render $desk 'desk' $shared
Check 'desktop 5h = 45k'  ((Tok $l '5h') -eq 45000)  $l
Check 'desktop 7d = 105k' ((Tok $l '7d') -eq 105000) $l

"--- 5. a render inside the cache TTL shows the same combined total"
$l = Render $lap 'lap' $shared
Check 'cache hit keeps 105k' ((Tok $l '7d') -eq 105000) $l

"--- 6. another account's usage on a shared folder is not ours"
Write-Peer 'other' (OrgTag 'org-somebody-else') @(,@((E $now.AddMinutes(-30)), 9000000, 45))
Fresh $lap
$l = Render $lap 'lap' $shared
Check 'other org ignored' ((Tok $l '7d') -eq 105000) $l

"--- 7. buckets outside the window, or from the future, are not counted"
Write-Peer 'old' $myTag @(
    @((E $now.AddDays(-8)),   7000000, 35),
    @((E $now.AddHours(2)),   7000000, 35)
)
Fresh $lap
$l = Render $lap 'lap' $shared
Check 'stale and future buckets ignored' ((Tok $l '7d') -eq 105000) $l

"--- 8. a single in-window bucket from a third device counts"
Write-Peer 'old' $myTag @(,@((E $now.AddMinutes(-30)), 895000, 4.5))
Fresh $lap
$l = Render $lap 'lap' $shared
Check 'third device lands in 7d' ((Tok $l '7d') -eq 1000000) $l
Check 'third device lands in 5h' ((Tok $l '5h') -eq 940000)  $l
Remove-Item (Join-Path $shared 'statusline-device-old.json') -Force

"--- 9. a half-synced peer file costs that peer, not the render"
Set-Content -Path $deskFile -Value '{"schemaVersion":1,"device":"desk","bucketSec' -Encoding utf8 -NoNewline
Fresh $lap
$l = Render $lap 'lap' $shared
Check 'torn peer falls back to local 5k' ((Tok $l '7d') -eq 5000) $l

"--- 10. a folder that is not there degrades to local totals"
Fresh $lap
$l = Render $lap 'lap' (Join-Path $root 'no-such-folder')
Check 'missing folder renders local 5k' ((Tok $l '7d') -eq 5000) $l

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
