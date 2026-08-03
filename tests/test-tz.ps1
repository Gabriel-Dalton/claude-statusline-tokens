#Requires -Version 5.1
# Exercises the timezone suffix on reset times: that the abbreviation is the
# one for the instant being printed rather than for today, that unmapped
# zones degrade to an unambiguous UTC offset instead of a wrong three-letter
# guess, and that STATUSLINE_TZ_LABEL=0 takes it back off.
param([Parameter(Mandatory=$true)][string]$ScriptPath)

$ErrorActionPreference = 'Stop'
[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d) {
    if ($ok) { $script:pass++; "  PASS  $n" } else { $script:fail++; "  FAIL  $n`n        $d" }
}

# --- unit half: the map and the abbreviation, lifted out of the script ------
# Everything between the enable flag and the next function is self-contained,
# so it can be evaluated here without running the whole render.
$src = [System.IO.File]::ReadAllText($ScriptPath)
$start = $src.IndexOf('$tzLabelEnabled = -not')
$end   = $src.IndexOf('# Local clock time,')
if ($start -lt 0 -or $end -le $start) { throw 'could not locate the timezone block in the script' }
# Dot-sourced so the map and the function land in this scope.
. ([ScriptBlock]::Create($src.Substring($start, $end - $start)))

# FindSystemTimeZoneById throws rather than returning null, and the set of
# installed zones varies by OS build — a zone that is simply absent is a skip,
# not a failure.
function Get-ZoneOrNull([string]$id) {
    try { return [TimeZoneInfo]::FindSystemTimeZoneById($id) }
    catch { return $null }
}

# A summer and a winter instant, so the DST arm is chosen per instant.
$jul = New-Object DateTime(2026,7,15,20,0,0,[DateTimeKind]::Utc)
$jan = New-Object DateTime(2026,1,15,20,0,0,[DateTimeKind]::Utc)

# id, summer abbreviation, winter abbreviation. A zone that does not observe
# DST names the same string twice.
$cases = @(
    @{ id = 'Pacific Standard Time';      summer = 'PDT';  winter = 'PST'  },
    @{ id = 'Eastern Standard Time';      summer = 'EDT';  winter = 'EST'  },
    @{ id = 'Alaskan Standard Time';      summer = 'AKDT'; winter = 'AKST' },
    @{ id = 'Newfoundland Standard Time'; summer = 'NDT';  winter = 'NST'  },
    # London is the reason this is a lookup table and not string initials:
    # initialising "GMT Standard Time" gives GST, a zone four hours east.
    @{ id = 'GMT Standard Time';          summer = 'BST';  winter = 'GMT'  },
    @{ id = 'W. Europe Standard Time';    summer = 'CEST'; winter = 'CET'  },
    @{ id = 'GTB Standard Time';          summer = 'EEST'; winter = 'EET'  },
    @{ id = 'India Standard Time';        summer = 'IST';  winter = 'IST'  },
    @{ id = 'Tokyo Standard Time';        summer = 'JST';  winter = 'JST'  },
    @{ id = 'Israel Standard Time';       summer = 'IDT';  winter = 'IST'  },
    @{ id = 'Singapore Standard Time';    summer = 'SGT';  winter = 'SGT'  },
    @{ id = 'AUS Eastern Standard Time';  summer = 'AEST'; winter = 'AEDT' },
    @{ id = 'New Zealand Standard Time';  summer = 'NZST'; winter = 'NZDT' },
    @{ id = 'UTC';                        summer = 'UTC';  winter = 'UTC'  }
)

"--- 1. the mapped zones, in summer and in winter"
foreach ($c in $cases) {
    $tz = Get-ZoneOrNull $c.id
    if ($null -eq $tz) { "  SKIP  $($c.id) is not on this system"; continue }
    $s = Get-TzAbbrev $jul $tz
    $w = Get-TzAbbrev $jan $tz
    Check "$($c.id) in July"    ($s -eq $c.summer) "expected $($c.summer), got $s"
    Check "$($c.id) in January" ($w -eq $c.winter) "expected $($c.winter), got $w"
}

"--- 2. an unmapped zone degrades to an offset, never to a wrong guess"
# Nepal is deliberately absent from the map: no widely used abbreviation, and
# a :45 offset that a naive formatter would round away.
$np = Get-ZoneOrNull 'Nepal Standard Time'
if ($null -eq $np) { "  SKIP  Nepal Standard Time is not on this system" }
else { Check 'Nepal falls back to UTC+5:45' ((Get-TzAbbrev $jul $np) -eq 'UTC+5:45') (Get-TzAbbrev $jul $np) }

$sa = Get-ZoneOrNull 'SA Eastern Standard Time'
if ($null -eq $sa) { "  SKIP  SA Eastern Standard Time is not on this system" }
else { Check 'a negative whole offset reads UTC-3' ((Get-TzAbbrev $jul $sa) -eq 'UTC-3') (Get-TzAbbrev $jul $sa) }

"--- 3. an Unspecified-Kind stamp is not read as local time"
$unspec = New-Object DateTime(2026,1,15,20,0,0,[DateTimeKind]::Unspecified)
$pacific = Get-ZoneOrNull 'Pacific Standard Time'
if ($null -eq $pacific) { "  SKIP  Pacific Standard Time is not on this system" }
else { Check 'Unspecified is treated as UTC' ((Get-TzAbbrev $unspec $pacific) -eq 'PST') (Get-TzAbbrev $unspec $pacific) }

# --- end-to-end half: the suffix as it reaches the rendered line ------------
# See test-sync.ps1 for why the profile resolution is patched.
$root = Join-Path $env:TEMP ('sl-tz-test-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
$claude = Join-Path $root '.claude'
New-Item -ItemType Directory -Path (Join-Path $claude 'projects\proj') -Force | Out-Null
@{ oauthAccount = @{ organizationUuid = 'org-tz-1'; emailAddress='t@e.com'; organizationName='T' } } |
    ConvertTo-Json -Depth 4 | Set-Content (Join-Path $root '.claude.json') -Encoding utf8

$underTest = Join-Path $root 'statusline-under-test.ps1'
$patched = $src.Replace("[Environment]::GetFolderPath('UserProfile')", '$env:USERPROFILE')
[System.IO.File]::WriteAllText($underTest, $patched, (New-Object System.Text.UTF8Encoding($false)))

$transcript = Join-Path $claude 'projects\proj\session.jsonl'
$ts = ([DateTime]::UtcNow).AddMinutes(-10).ToString('o')
Set-Content -Path $transcript -Encoding utf8 -Value (
    '{{"type":"assistant","timestamp":"{0}","message":{{"id":"msg_tz1","type":"message","role":"assistant","model":"claude-opus-5","usage":{{"input_tokens":120000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}}}}' -f $ts)

$epoch = New-Object DateTime(1970,1,1,0,0,0,[DateTimeKind]::Utc)
function Render([string]$labelEnv) {
    $now = [DateTime]::UtcNow
    $hook = @{
        workspace = @{ current_dir = $root }
        model = @{ display_name = 'Opus 5' }
        transcript_path = $transcript
        rate_limits = @{
            five_hour = @{ used_percentage = 42; resets_at = [long](($now.AddHours(2)) - $epoch).TotalSeconds }
            seven_day = @{ used_percentage = 18; resets_at = [long](($now.AddDays(3)) - $epoch).TotalSeconds }
        }
    }
    Remove-Item (Join-Path $claude 'statusline-tokens.cache.json') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $claude 'statusline-limits.cache.json') -Force -ErrorAction SilentlyContinue
    $out = ($hook | ConvertTo-Json -Depth 6 -Compress) |
        & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -Command "`$env:USERPROFILE='$root'; `$env:STATUSLINE_SCOPED_LIMITS='0'; `$env:STATUSLINE_TZ_LABEL='$labelEnv'; & '$underTest'"
    return ($out -join '') -replace "$([char]27)\[[0-9;]*m", ''
}

"--- 4. the rendered line carries the zone on both windows"
$expected = Get-TzAbbrev ([DateTime]::UtcNow.AddHours(2))
$line = Render ''
Check '5h reset names the zone' ($line -match ("5h .*resets \S+ @ \d[^,)]*{0}\)" -f [regex]::Escape($expected))) $line
Check '7d reset names the zone' ($line -match ("7d .*resets \S+ @ \w{3} \d[^,)]*" + [regex]::Escape($expected) + '\)')) $line

"--- 5. STATUSLINE_TZ_LABEL=0 takes it back off"
$off = Render '0'
Check 'no zone suffix when disabled' ($off -notmatch ("@ [^,)]*{0}" -f [regex]::Escape($expected))) $off
Check 'the clock time itself survives' ($off -match '5h .*resets \S+ @ \d') $off

""
"$pass passed, $fail failed"
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail -gt 0) { exit 1 }
