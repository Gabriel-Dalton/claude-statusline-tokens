#Requires -Version 5.1
# Exercises the quota-aligned token windows: that tok/cost describe the same
# window the percentage does, and that both fall together when it resets.
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root = Join-Path $env:TEMP ('sl-reset-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$claude = Join-Path $root '.claude'
New-Item -ItemType Directory -Path (Join-Path $claude 'projects\proj') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-test-1'; emailAddress='t@e.com'; organizationName='T' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root '.claude.json') -Encoding utf8

# See test-sync.ps1 for why the profile resolution is patched.
$underTest = Join-Path $root 'statusline-under-test.ps1'
$src = [System.IO.File]::ReadAllText($ScriptPath)
$src = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $src, (New-Object System.Text.UTF8Encoding($false)))

$transcript = Join-Path $claude 'projects\proj\session.jsonl'
$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
function E([DateTime]$u) { [long]($u - $epoch).TotalSeconds }

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
    if ($ok) { $script:pass++; "  PASS  $n" } else { $script:fail++; "  FAIL  $n`n        $d" }
}
function Fresh {
    Remove-Item (Join-Path $claude 'statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $claude 'statusline-limits.cache.json') -Force -ErrorAction SilentlyContinue
}
# One turn per entry: @{ minutesAgo = N; tokens = M }
function Write-Turns($entries) {
    $lines = foreach ($e in $entries) {
        $ts = ([DateTime]::UtcNow).AddMinutes(-1 * $e.minutesAgo).ToString('o')
        '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_{1}","type":"message","role":"assistant","model":"claude-opus-5","usage":{{"input_tokens":{2},"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f `
            $ts, ([Guid]::NewGuid().ToString('N').Substring(0,12)), $e.tokens
    }
    Set-Content -Path $transcript -Value $lines -Encoding utf8
}
function Render($rateLimits) {
    $hook = @{ workspace=@{current_dir=$root}; model=@{display_name='Opus 5'}; transcript_path='' }
    if ($rateLimits) { $hook.rate_limits = $rateLimits }
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "`$env:USERPROFILE='$root'; `$env:STATUSLINE_SCOPED_LIMITS='0'; & '$underTest'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
# "5h 44% (12.0k tok, $0.06, ...)" -> 12000
function Tok([string]$line, [string]$label) {
    if ($line -notmatch ("{0}\s+\S+\s+\(([0-9.]+)([kM]?) tok" -f [regex]::Escape($label))) { return -1 }
    $n = [double]$Matches[1]
    switch ($Matches[2]) { 'k' { $n * 1000 } 'M' { $n * 1000000 } default { $n } }
}

$now = [DateTime]::UtcNow

# 4 turns of 10k each: 6h ago, 4h ago, 2h ago, 10 min ago.
# A rolling 5h lookback sees the last three (30k).
Write-Turns @(
    @{ minutesAgo = 360; tokens = 10000 },
    @{ minutesAgo = 240; tokens = 10000 },
    @{ minutesAgo = 120; tokens = 10000 },
    @{ minutesAgo = 10;  tokens = 10000 }
)

"--- 1. with no reset stamp at all, the old rolling behaviour stands"
Fresh
$l = Render $null
Check 'rolling 5h sees 30k' ((Tok $l '5h') -eq 30000) $l

"--- 2. an open window counts only what falls inside it"
# Window ends in 2h, so it began 3h ago: only the 2h-ago and 10m-ago turns.
Fresh
$l = Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddHours(2)) } }
Check '3h-old window sees 20k, not 30k' ((Tok $l '5h') -eq 20000) $l
Check 'and still shows its percentage'  ($l -match '5h 40%') $l

"--- 3. the reset drops the tokens with the percentage"
# Stamp elapsed 5 minutes ago: the new window began then, so only the
# 10-minutes-ago turn... which predates it. Nothing spent yet this window.
Fresh
$l = Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddMinutes(-5)) } }
Check 'elapsed window shows --%' ($l -match '5h --%') $l
Check 'and 0 tok, not 30k'       ((Tok $l '5h') -eq 0) $l

"--- 4. spend after the reset shows up, and only that"
Write-Turns @(
    @{ minutesAgo = 360; tokens = 10000 },
    @{ minutesAgo = 120; tokens = 10000 },
    @{ minutesAgo = 2;   tokens = 7000  }
)
Fresh
$l = Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddMinutes(-5)) } }
Check 'only the post-reset turn counts (7k)' ((Tok $l '5h') -eq 7000) $l

"--- 5. a badly stale stamp cannot widen the window past one length"
# Elapsed 30 hours ago. Unclamped that would sum 30 hours of turns into a
# five-hour window; clamped it can reach no further back than 5h.
Write-Turns @(
    @{ minutesAgo = 1200; tokens = 50000 },
    @{ minutesAgo = 120;  tokens = 10000 },
    @{ minutesAgo = 2;    tokens = 7000  }
)
Fresh
$l = Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddHours(-30)) } }
Check 'clamped to 5h: 17k, not 67k' ((Tok $l '5h') -eq 17000) $l

"--- 6. a 7d reset must not blank the 5h window"
# The regression the $scanFloor split exists to prevent: filtering the file
# list by a freshly reset 7d cutoff would hide every turn from 5h too.
Write-Turns @(
    @{ minutesAgo = 120; tokens = 10000 },
    @{ minutesAgo = 2;   tokens = 7000  }
)
Fresh
# Ends in 2.5h, so the window began 2.5h ago and holds both turns.
$l = Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddHours(2.5)) }
               seven_day = @{ used_percentage = 10; resets_at = (E $now.AddMinutes(-1)) } }
Check '7d reset to 0 tok'          ((Tok $l '7d') -eq 0) $l
Check 'but 5h still sees its 17k'  ((Tok $l '5h') -eq 17000) $l

"--- 7. a roll invalidates the cache inside its TTL"
Fresh
$null  = Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddHours(2.5)) } }
$before = Tok (Render @{ five_hour = @{ used_percentage = 40; resets_at = (E $now.AddHours(2.5)) } }) '5h'
# Same instant, new window: a cached total would still read 17k.
$after = Tok (Render @{ five_hour = @{ used_percentage = 1; resets_at = (E $now.AddHours(5)) } }) '5h'
Check 'cached 17k before the roll' ($before -eq 17000) "got $before"
Check 'recomputed to 0 on the roll, not served from cache' ($after -eq 0) "got $after"

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
