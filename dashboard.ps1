#Requires -Version 5.1
<#
.SYNOPSIS
    Thin launcher for claude-dashboard.ps1.

.DESCRIPTION
    Run from the cloned repo:  .\dashboard.ps1
    Forwards any args (e.g. -RefreshSeconds 10, -Once) to the dashboard.

    Prefers the installed copy at ~/.claude/claude-dashboard.ps1 so the
    dashboard you launch matches the version Claude Code's statusline is
    running. Falls back to the in-repo copy if you haven't run setup.ps1
    yet — handy for "I just cloned, let me see what it looks like."
#>
# No formal `param()` block — we want $args (the automatic remaining-args
# variable) to capture switch parameters like -Once intact and forward them
# to the real dashboard. ValueFromRemainingArguments + splatting drops the
# `-` prefix and the call binds positionally, which breaks -Once -> -RefreshSeconds.

$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $HOME }
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $env:USERPROFILE }

$installed = [System.IO.Path]::Combine($userProfile, '.claude', 'claude-dashboard.ps1')
$local     = [System.IO.Path]::Combine(
    (Split-Path -Parent $MyInvocation.MyCommand.Path),
    'claude-dashboard.ps1'
)

$target = $null
if (Test-Path $installed) { $target = $installed }
elseif (Test-Path $local) { $target = $local }
else {
    Write-Host "claude-dashboard.ps1 not found at either:" -ForegroundColor Red
    Write-Host "  $installed"
    Write-Host "  $local"
    Write-Host "Run .\setup.ps1 first or cd into the cloned repo."
    exit 1
}

& $target @args
