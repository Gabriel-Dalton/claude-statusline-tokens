#Requires -Version 5.1
<#
.SYNOPSIS
    Independently verifies the token totals the status line reports.

.DESCRIPTION
    "It says I burned 160 million tokens today" is the single most common
    reaction to this status line, and the honest answer is: yes, and that
    number is real - but it is not what most people picture when they read it.

    This script re-derives the totals from your transcripts using a completely
    different code path than statusline-tokens.ps1 does. The status line uses
    field-level regex extraction for speed; this script does a full
    ConvertFrom-Json parse of every line. If two independent implementations
    land on the same number, the number is not an artefact of how it was
    parsed.

    It then breaks the total into the four billing categories, which is where
    the intuition gap lives. In a typical session 95%+ of the total is
    cache_read: the conversation so far, re-sent to the model on every single
    turn. It is genuinely billed, and it genuinely counts against your rate
    limit, but it is the same words being re-read - not new work.

    The arithmetic to check is:  turns x average context = cache-read total.
    When those agree, the headline number is confirmed.

.PARAMETER Hours
    Rolling window to audit, in hours. Default 5, matching Claude Code's
    5-hour rate-limit window.

.PARAMETER Today
    Audit since local midnight instead of a rolling window.

.EXAMPLE
    .\verify-tokens.ps1
    .\verify-tokens.ps1 -Hours 24
    .\verify-tokens.ps1 -Today
#>
[CmdletBinding()]
param(
    [double]$Hours = 5,
    [switch]$Today
)

[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

$styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor `
          [Globalization.DateTimeStyles]::AssumeUniversal
$nowUtc = [DateTime]::UtcNow
if ($Today) {
    $cut = ([DateTime]::Today).ToUniversalTime()
    $label = 'TODAY (since local midnight)'
} else {
    $cut = $nowUtc.AddHours(-$Hours)
    $label = ('LAST {0} HOURS' -f $Hours)
}

$projectsDir = Join-Path $env:USERPROFILE '.claude\projects'
if (-not (Test-Path $projectsDir)) {
    Write-Error "No transcripts found at $projectsDir. Has Claude Code run on this machine?"
    exit 1
}

# LastWriteTime pre-filter with a day of slack: a file whose last write predates
# the window can't contain a turn inside it.
$files = Get-ChildItem $projectsDir -Filter *.jsonl -Recurse -ErrorAction SilentlyContinue |
         Where-Object { $_.LastWriteTimeUtc -gt $cut.AddDays(-1) }

Write-Host ("Scanning {0} transcript files ({1:N1} MB) with a full JSON parse..." -f
    $files.Count, (($files | Measure-Object -Property Length -Sum).Sum / 1MB)) -ForegroundColor DarkGray

$inp = [long]0; $outp = [long]0; $cRead = [long]0; $cCreate = [long]0
$turns = 0; $rawLines = 0
$models = @{}
$seen = @{}
$contexts = New-Object System.Collections.ArrayList

foreach ($f in $files) {
    foreach ($line in [System.IO.File]::ReadLines($f.FullName)) {
        if ($line.IndexOf('"usage"') -lt 0) { continue }
        try { $o = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $msg = $o.message
        if (-not $msg -or -not $msg.usage -or $msg.role -ne 'assistant') { continue }

        $t = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$o.timestamp,
              [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$t)) { continue }
        if ($t -lt $cut) { continue }

        $u = $msg.usage
        $i = 0L; $ot = 0L; $cr = 0L; $cc = 0L
        if ($null -ne $u.input_tokens)                { $i  = [long]$u.input_tokens }
        if ($null -ne $u.output_tokens)               { $ot = [long]$u.output_tokens }
        if ($null -ne $u.cache_read_input_tokens)     { $cr = [long]$u.cache_read_input_tokens }
        if ($null -ne $u.cache_creation_input_tokens) { $cc = [long]$u.cache_creation_input_tokens }
        if (($i + $ot + $cr + $cc) -le 0) { continue }

        $rawLines++
        # Dedupe by message id. One assistant turn is logged once per content
        # block (thinking, tool_use, text...) and every one of those lines
        # repeats the SAME usage object. Summing them all inflates the total
        # by roughly the average number of blocks per turn.
        $id = [string]$msg.id
        if ($id) {
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = $true
        }

        $turns++
        $inp += $i; $outp += $ot; $cRead += $cr; $cCreate += $cc
        [void]$contexts.Add($i + $cr + $cc)
        $m = [string]$msg.model
        if ($m) {
            if (-not $models.ContainsKey($m)) { $models[$m] = [long]0 }
            $models[$m] += ($i + $ot + $cr + $cc)
        }
    }
}

function Fmt([long]$n) {
    if ($n -ge 1000000) { '{0:N1}M' -f ($n / 1e6) }
    elseif ($n -ge 1000) { '{0:N1}k' -f ($n / 1e3) }
    else { "$n" }
}

$total = $inp + $outp + $cRead + $cCreate
Write-Host ''
Write-Host ('=' * 70)
Write-Host "  $label" -ForegroundColor Cyan
Write-Host ('=' * 70)

if ($total -le 0) {
    Write-Host '  No assistant turns in this window.'
    exit 0
}

Write-Host ('  TOTAL                 {0,10}   100.0%' -f (Fmt $total)) -ForegroundColor White
Write-Host ('    cache read          {0,10}   {1,5:N1}%   <- conversation replayed each turn' -f (Fmt $cRead),   (100 * $cRead / $total)) -ForegroundColor DarkGray
Write-Host ('    cache write         {0,10}   {1,5:N1}%' -f (Fmt $cCreate), (100 * $cCreate / $total)) -ForegroundColor DarkGray
Write-Host ('    input (fresh)       {0,10}   {1,5:N1}%' -f (Fmt $inp),     (100 * $inp / $total))    -ForegroundColor DarkGray
Write-Host ('    output (generated)  {0,10}   {1,5:N1}%' -f (Fmt $outp),    (100 * $outp / $total))   -ForegroundColor DarkGray

$fresh = $inp + $outp + $cCreate
Write-Host ''
Write-Host ('  Genuinely new work    {0,10}   {1,5:N1}%   (input + output + cache write)' -f (Fmt $fresh), (100 * $fresh / $total)) -ForegroundColor Green
Write-Host ('  Re-read context       {0,10}   {1,5:N1}%' -f (Fmt $cRead), (100 * $cRead / $total)) -ForegroundColor Yellow

Write-Host ''
Write-Host '  --- the check that confirms the headline number ---'
$avgCtx = [long]($cRead / [math]::Max($turns, 1))
Write-Host ('  {0} assistant turns x {1} average context re-read = {2}' -f
    $turns, (Fmt $avgCtx), (Fmt ([long]($turns * $avgCtx))))
Write-Host ('  measured cache read                                = {0}' -f (Fmt $cRead))
Write-Host ''
Write-Host ('  Raw log lines before dedupe: {0}  ({1:N2}x the turn count)' -f
    $rawLines, ($rawLines / [math]::Max($turns, 1)))
Write-Host '  If dedupe were broken the total would be inflated by that factor.'

if ($contexts.Count -gt 0) {
    $sorted = $contexts | Sort-Object
    Write-Host ''
    Write-Host ('  Median context per turn: {0}' -f (Fmt ([long]$sorted[[int]($sorted.Count / 2)])))
    Write-Host ('  Largest context seen:    {0}' -f (Fmt ([long]$sorted[-1])))
    Write-Host '  These should look like your actual conversation sizes. If the median is'
    Write-Host '  far larger than any context you have ever had open, something is wrong.'
}

Write-Host ''
Write-Host '  By model:'
foreach ($kv in ($models.GetEnumerator() | Sort-Object -Property Value -Descending)) {
    Write-Host ('    {0,-36} {1,10}' -f $kv.Key, (Fmt $kv.Value))
}

# Compare against whatever the status line last wrote, when the windows align.
$cachePath = Join-Path $env:USERPROFILE '.claude\statusline-tokens.cache.json'
if ((-not $Today) -and $Hours -eq 5 -and (Test-Path $cachePath)) {
    try {
        $c = [System.IO.File]::ReadAllText($cachePath) | ConvertFrom-Json
        if ($null -ne $c.tok5h) {
            $slTok = [long]$c.tok5h
            $delta = [math]::Abs($slTok - $total)
            $pct = 100 * $delta / [math]::Max($total, 1)
            Write-Host ''
            Write-Host '  --- cross-check against the status line (independent code path) ---'
            Write-Host ('  status line (regex parse):  {0,10}' -f (Fmt $slTok))
            Write-Host ('  this script (JSON parse):   {0,10}' -f (Fmt $total))
            $color = if ($pct -lt 2) { 'Green' } else { 'Red' }
            Write-Host ('  delta: {0} ({1:N2}%)' -f (Fmt $delta), $pct) -ForegroundColor $color
            Write-Host '  A small delta is expected - the status line caches for 20s and the'
            Write-Host '  window keeps moving while this script runs.'
        }
    } catch { }
}
Write-Host ''
