#Requires -Version 5.1
<#
.SYNOPSIS
    Runs every statusline-tokens suite and reports a single pass/fail.

.DESCRIPTION
    Each suite drives the real script end to end: it builds a throwaway
    profile directory, feeds hook JSON on stdin exactly as Claude Code does,
    and asserts against the rendered line rather than against internals.

    Nothing here touches your real ~/.claude. Each suite copies the script
    under test and rewrites its one profile-resolution call, because
    [Environment]::GetFolderPath('UserProfile') reads the shell API rather
    than $env:USERPROFILE on Windows — so an unpatched run would write mock
    percentages into the live cache files, and with credentials present it
    would fire real requests at the usage endpoint.

.PARAMETER ScriptPath
    Which copy to exercise. Defaults to the statusline-tokens.ps1 beside this
    tests directory. Point it at ~/.claude/statusline-tokens.ps1 to check an
    installed copy has not drifted.

.EXAMPLE
    .\tests\run-all.ps1
    .\tests\run-all.ps1 -ScriptPath "$env:USERPROFILE\.claude\statusline-tokens.ps1"
#>
[CmdletBinding()]
param(
    [string]$ScriptPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'statusline-tokens.ps1')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Error "No script to test at $ScriptPath"
    exit 2
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path

# Parse before running anything: a syntax error surfaces here as one clear
# message instead of as every suite failing to render.
$parseErrors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$null, [ref]$parseErrors)
if ($parseErrors -and $parseErrors.Count -gt 0) {
    Write-Host "SYNTAX ERRORS in $ScriptPath" -ForegroundColor Red
    $parseErrors | ForEach-Object {
        Write-Host ("  line {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red
    }
    exit 2
}

$suites = @(
    @{ file = 'test-sync.ps1';      what = 'shared store: one set of numbers across windows' },
    @{ file = 'test-scoped.ps1';    what = 'per-model bar and its activity-driven refresh' },
    @{ file = 'test-reset.ps1';     what = 'token windows aligned to the quota, not the clock' },
    @{ file = 'test-authority.ps1'; what = 'information age decides, so a bucket can be corrected' },
    @{ file = 'test-tz.ps1';        what = 'reset times name their zone, per instant, not per today' }
)

Write-Host "testing $ScriptPath`n"
$totalPass = 0
$totalFail = 0
$broken = @()

foreach ($suite in $suites) {
    $path = Join-Path $PSScriptRoot $suite.file
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host ("MISSING  {0}" -f $suite.file) -ForegroundColor Red
        $broken += $suite.file
        continue
    }
    $output = & $path -ScriptPath $ScriptPath
    $summary = @($output | Where-Object { $_ -match '^\d+ passed, \d+ failed$' }) | Select-Object -Last 1
    $failures = @($output | Where-Object { $_ -match '^\s+FAIL\s' })

    $p = 0; $f = 0
    if ($summary -match '^(\d+) passed, (\d+) failed$') { $p = [int]$Matches[1]; $f = [int]$Matches[2] }
    else { $broken += $suite.file }
    $totalPass += $p
    $totalFail += $f

    $colour = if ($f -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("{0,-20} {1,3} passed  {2,3} failed   {3}" -f $suite.file, $p, $f, $suite.what) -ForegroundColor $colour
    # Only the failing assertions, with the rendered line that produced them.
    if ($f -gt 0) { $output | Select-Object -Skip 0 | Where-Object { $_ -match 'FAIL|^\s{8}' } | ForEach-Object { Write-Host "    $_" -ForegroundColor Red } }
}

Write-Host ("`n{0} passed, {1} failed" -f $totalPass, $totalFail)
if ($broken.Count -gt 0) {
    Write-Host ("suites that did not report a result: {0}" -f ($broken -join ', ')) -ForegroundColor Red
    exit 2
}
if ($totalFail -gt 0) { exit 1 }
Write-Host 'all green' -ForegroundColor Green
exit 0
