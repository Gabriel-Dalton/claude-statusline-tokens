#Requires -Version 5.1
# Exercises the shared-limits sync in statusline-tokens.ps1 against an
# isolated USERPROFILE, so nothing here touches the real cache files.
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$root = Join-Path $env:TEMP ('sl-sync-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path (Join-Path $root '.claude') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $root '.claude\projects') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-test-1'; emailAddress = 't@example.com'; organizationName = 'Test' } } |
    ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $root '.claude.json') -Encoding utf8

# The repo copy resolves its profile with [Environment]::GetFolderPath,
# which on Windows ignores a USERPROFILE override — so an unpatched run of
# this suite writes mock percentages straight into the real ~/.claude store.
# Test a copy whose first resolution step reads the env var instead;
# everything else is byte-identical. Read/written through System.IO so the
# round trip cannot re-encode the non-ASCII glyphs in the file.
$underTest = Join-Path $root 'statusline-under-test.ps1'
$src = [System.IO.File]::ReadAllText($ScriptPath)
$src = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $src, (New-Object System.Text.UTF8Encoding($false)))
$ScriptPath = $underTest

$storePath = Join-Path $root '.claude\statusline-limits.cache.json'
$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
function E([DateTime]$utc) { [long]($utc - $epoch).TotalSeconds }

$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) { $script:pass++; "  PASS  $name" }
    else     { $script:fail++; "  FAIL  $name`n        $detail" }
}

# One render. Returns the plain-text status line with ANSI stripped.
function Render($rateLimits) {
    $hook = @{
        workspace       = @{ current_dir = $root }
        model           = @{ display_name = 'Opus 5' }
        transcript_path = ''
    }
    if ($rateLimits) { $hook.rate_limits = $rateLimits }
    $json = $hook | ConvertTo-Json -Depth 6 -Compress
    $out = $json | & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
        -Command "`$env:USERPROFILE='$root'; `$env:STATUSLINE_SCOPED_LIMITS='0'; & '$ScriptPath'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}
function Pct([string]$line, [string]$label) {
    if ($line -match ("{0}\s+(--%|\d+%)" -f [regex]::Escape($label))) { return $Matches[1] }
    return '<none>'
}
function StoreBucket([string]$key) {
    if (-not (Test-Path $storePath)) { return $null }
    $d = Get-Content -Raw $storePath | ConvertFrom-Json
    if ($d.buckets.PSObject.Properties.Match($key).Count -eq 0) { return $null }
    return $d.buckets.$key
}

$now = [DateTime]::UtcNow
$r5  = E $now.AddHours(3)     # 5h window resets in 3h
$r7  = E $now.AddDays(4)      # 7d window resets in 4d

"--- 1. first render seeds the store from the hook"
$l = Render @{ five_hour = @{ used_percentage = 44; resets_at = $r5 }
               seven_day = @{ used_percentage = 36; resets_at = $r7 } }
Check '5h renders 44%' ((Pct $l '5h') -eq '44%') $l
Check '7d renders 36%' ((Pct $l '7d') -eq '36%') $l
Check 'store holds 44' ((StoreBucket '5h').percent -eq 44) (Get-Content -Raw $storePath)

"--- 2. a second window still on the old number does not win"
$l = Render @{ five_hour = @{ used_percentage = 42; resets_at = $r5 }
               seven_day = @{ used_percentage = 36; resets_at = $r7 } }
Check 'stale 42% renders as 44%' ((Pct $l '5h') -eq '44%') $l
Check 'store still holds 44'     ((StoreBucket '5h').percent -eq 44) (Get-Content -Raw $storePath)

"--- 3. a window that has had no API response yet inherits the shared value"
$l = Render $null
Check 'no rate_limits still renders 44%' ((Pct $l '5h') -eq '44%') $l
Check 'no rate_limits still renders 36%' ((Pct $l '7d') -eq '36%') $l

"--- 4. a higher observation propagates"
$l = Render @{ five_hour = @{ used_percentage = 47; resets_at = $r5 }
               seven_day = @{ used_percentage = 36; resets_at = $r7 } }
Check '47% wins' ((Pct $l '5h') -eq '47%') $l
$l = Render @{ five_hour = @{ used_percentage = 42; resets_at = $r5 } }
Check 'and a stale window now reads 47%' ((Pct $l '5h') -eq '47%') $l

"--- 5. the window rolling resets the bucket outright"
$r5b = E $now.AddHours(8)
$l = Render @{ five_hour = @{ used_percentage = 3; resets_at = $r5b } }
Check 'new window drops to 3%' ((Pct $l '5h') -eq '3%') $l
Check 'reset stamp advanced' `
    (([DateTime](StoreBucket '5h').resetsAtUtc).ToUniversalTime() -gt $now.AddHours(7)) (Get-Content -Raw $storePath)

"--- 6. an observation from the window that already rolled is refused"
$l = Render @{ five_hour = @{ used_percentage = 47; resets_at = $r5 } }
Check 'old-window 47% rejected' ((Pct $l '5h') -eq '3%') $l

"--- 7. a bucket whose window has elapsed renders --%, not a dead number"
$d = Get-Content -Raw $storePath | ConvertFrom-Json
$d.buckets.'5h'.resetsAtUtc = $now.AddMinutes(-5).ToString('o')
$d | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $storePath -Encoding utf8
$l = Render $null
Check 'elapsed window renders --%' ((Pct $l '5h') -eq '--%') $l

"--- 8. a store belonging to another account is ignored"
$d = Get-Content -Raw $storePath | ConvertFrom-Json
$d.orgKey = 'org-somebody-else'
$d.buckets.'7d'.percent = 99
$d | ConvertTo-Json -Depth 6 -Compress | Set-Content -Path $storePath -Encoding utf8
$l = Render @{ seven_day = @{ used_percentage = 12; resets_at = $r7 } }
Check "other org's 99% not shown" ((Pct $l '7d') -eq '12%') $l
Check 'store reclaimed for this org' ((Get-Content -Raw $storePath | ConvertFrom-Json).orgKey -eq 'org-test-1') (Get-Content -Raw $storePath)

"--- 9. a truncated store degrades to hook-only, it does not crash"
Set-Content -Path $storePath -Value '{"schemaVersion":1,"orgKey":"org-test-1","buck' -Encoding utf8 -NoNewline
$l = Render @{ five_hour = @{ used_percentage = 21; resets_at = $r5 } }
Check 'torn store still renders' ((Pct $l '5h') -eq '21%') $l

"--- 10. eight concurrent renders leave one valid store"
Remove-Item $storePath -Force -ErrorAction SilentlyContinue
$jobs = 1..8 | ForEach-Object {
    $p = 30 + $_
    Start-Job -ScriptBlock {
        param($sp, $rt, $pct, $r5, $r7)
        $hook = @{ workspace = @{ current_dir = $rt }; model = @{ display_name = 'Opus 5' }
                   transcript_path = ''
                   rate_limits = @{ five_hour = @{ used_percentage = $pct; resets_at = $r5 }
                                    seven_day = @{ used_percentage = 36; resets_at = $r7 } } }
        ($hook | ConvertTo-Json -Depth 6 -Compress) |
            & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
                -Command "`$env:USERPROFILE='$rt'; `$env:STATUSLINE_SCOPED_LIMITS='0'; & '$sp'"
    } -ArgumentList $ScriptPath, $root, $p, $r5, $r7
}
$jobs | Wait-Job -Timeout 120 | Out-Null
$jobs | Remove-Job -Force
$ok = $false; $val = '?'
try { $b = StoreBucket '5h'; $val = $b.percent; $ok = ($b.percent -eq 38) } catch { $val = $_.Exception.Message }
Check 'concurrent writers converge on the max (38)' $ok "got $val; file: $(Get-Content -Raw $storePath)"
$leftovers = @(Get-ChildItem (Join-Path $root '.claude') -Filter '*.tmp' -ErrorAction SilentlyContinue)
Check 'no temp files left behind' ($leftovers.Count -eq 0) ($leftovers.Name -join ', ')

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
