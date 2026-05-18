#Requires -Version 5.1
<#
.SYNOPSIS
    One-command installer for claude-statusline-tokens + claude-dashboard.

.DESCRIPTION
    Clone the repo, then run this. It does three things:

      1. Copies statusline-tokens.ps1 and claude-dashboard.ps1 into ~/.claude/
      2. Shows the JSON block it wants to merge into ~/.claude/settings.json
         and asks Y/n before writing. A backup of the existing file is saved
         to settings.json.bak first.
      3. Optionally launches the dashboard once so you can see what you got.

    Safe to run repeatedly — it diffs before each write and skips no-ops.

.PARAMETER NonInteractive
    Skip the Y/n prompt and merge settings.json automatically. Suitable for
    CI or scripted setups where you've already reviewed what this does.

.PARAMETER SkipDashboardPreview
    Don't launch the dashboard at the end. Useful in headless environments.

.PARAMETER Uninstall
    Reverse the install: remove the statusLine block from settings.json
    (restoring settings.json.bak if present), and delete the copied scripts
    from ~/.claude/. Cache and accounts files are kept since they may
    represent useful history; remove them manually if you want a clean slate.

.PARAMETER DryRun
    Print exactly what would happen — file copies, the settings.json diff,
    the launcher choice — without writing anything to disk. Use this to
    preview before you commit.
#>
[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [switch]$SkipDashboardPreview,
    [switch]$Uninstall,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# Source = the directory this setup script lives in. We deliberately copy
# from-here rather than symlink so the install survives a `rm -rf` of the
# cloned repo and so the install isn't sensitive to the clone's path.
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- Cross-platform user-profile resolution -------------------------------
# Matches the pattern statusline-tokens.ps1 and claude-dashboard.ps1 use,
# so the three files agree on where ~/.claude lives regardless of OS or
# PowerShell edition.
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $HOME }
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $env:USERPROFILE }
if ([string]::IsNullOrEmpty($userProfile)) {
    throw "Could not determine your home directory. Set `$HOME or `$env:USERPROFILE and re-run."
}

$claudeDir    = [System.IO.Path]::Combine($userProfile, '.claude')
$settingsPath = [System.IO.Path]::Combine($claudeDir, 'settings.json')
$backupPath   = [System.IO.Path]::Combine($claudeDir, 'settings.json.bak')

# Files that should live in ~/.claude/ after a successful install.
$filesToCopy = @(
    @{
        src = [System.IO.Path]::Combine($repoRoot, 'statusline-tokens.ps1')
        dst = [System.IO.Path]::Combine($claudeDir, 'statusline-tokens.ps1')
    }
    @{
        src = [System.IO.Path]::Combine($repoRoot, 'claude-dashboard.ps1')
        dst = [System.IO.Path]::Combine($claudeDir, 'claude-dashboard.ps1')
    }
)

# --- Picking the right PowerShell launcher --------------------------------
# Prefer `pwsh` (PowerShell 7+) — the scripts now use 3-arg Join-Path and
# other 7+ features, and pwsh is cross-platform. Fall back to `powershell`
# on Windows only with a heads-up that some features may complain.
function Get-PSLauncher {
    $pwsh = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($pwsh) { return @{ exe = 'pwsh'; isCore = $true; warning = $null } }
    if ($PSVersionTable.Platform -eq 'Unix') {
        throw "pwsh (PowerShell 7+) is required on Linux/macOS. Install from https://github.com/PowerShell/PowerShell."
    }
    $winPS = Get-Command powershell -ErrorAction SilentlyContinue
    if ($winPS) {
        return @{
            exe     = 'powershell'
            isCore  = $false
            warning = "pwsh (PowerShell 7+) is not installed. Falling back to Windows PowerShell 5.1. PS 7+ is recommended — install with `winget install Microsoft.PowerShell` and re-run setup to switch."
        }
    }
    throw "Neither 'pwsh' nor 'powershell' is on PATH. Cannot wire up the statusline."
}

# --- Logging helpers ------------------------------------------------------
function Write-Step([string]$msg) { Write-Host "  $msg" }
function Write-OK  ([string]$msg) { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn([string]$msg) { Write-Host "  $msg" -ForegroundColor Yellow }
function Write-Err ([string]$msg) { Write-Host "  $msg" -ForegroundColor Red }
function Write-Rule {
    $w = try { [Console]::WindowWidth - 4 } catch { 60 }
    if ($w -lt 20) { $w = 60 }
    Write-Host ('  ' + ('-' * $w)) -ForegroundColor DarkGray
}
function Confirm-YesNo([string]$prompt, [bool]$default = $true) {
    if ($NonInteractive) { return $default }
    $suffix = if ($default) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "  $prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return ($answer.Trim() -match '^(y|yes)$')
}

# ---------------------------------------------------------------------------
# Uninstall path
# ---------------------------------------------------------------------------
function Invoke-Uninstall {
    Write-Host ''
    Write-Host "  Uninstalling claude-statusline-tokens + dashboard" -ForegroundColor Cyan
    Write-Rule

    foreach ($f in $filesToCopy) {
        if (Test-Path $f.dst) {
            Remove-Item $f.dst -Force
            Write-OK ("Removed {0}" -f $f.dst)
        } else {
            Write-Step ("Skipped {0} (not present)" -f $f.dst)
        }
    }

    if (Test-Path $settingsPath) {
        if (Test-Path $backupPath) {
            $reply = Confirm-YesNo "Restore settings.json from settings.json.bak?" $true
            if ($reply) {
                Copy-Item $backupPath $settingsPath -Force
                Write-OK "Restored settings.json from backup."
            } else {
                Write-Step "Leaving settings.json as-is. (Backup remains at $backupPath.)"
            }
        } else {
            # No backup — surgically remove the statusLine block we own.
            try {
                $raw = Get-Content -Raw -Encoding UTF8 $settingsPath
                $obj = $raw | ConvertFrom-Json
                if ($obj.PSObject.Properties.Name -contains 'statusLine') {
                    $obj.PSObject.Properties.Remove('statusLine')
                    $obj | ConvertTo-Json -Depth 32 | Set-Content -Path $settingsPath -Encoding utf8
                    Write-OK "Removed statusLine block from settings.json."
                } else {
                    Write-Step "settings.json has no statusLine block to remove."
                }
            } catch {
                Write-Warn "Could not safely edit settings.json: $($_.Exception.Message)"
            }
        }
    }
    Write-Host ''
    Write-OK "Uninstall complete."
    Write-Host ''
    Write-Host "  Note: ~/.claude/statusline-tokens.cache.json and statusline-accounts.json"
    Write-Host "  were left in place (history files). Delete them by hand if you want a clean slate."
}

if ($Uninstall) {
    Invoke-Uninstall
    return
}

# ---------------------------------------------------------------------------
# Install path
# ---------------------------------------------------------------------------
Write-Host ''
Write-Host "  Installing claude-statusline-tokens + dashboard" -ForegroundColor Cyan
Write-Rule

# Sanity-check that we're running from a cloned repo, not from a one-off
# Invoke-WebRequest of just this file. If the source scripts aren't sitting
# next to us, the user followed the wrong instructions.
foreach ($f in $filesToCopy) {
    if (-not (Test-Path $f.src)) {
        Write-Err  "Missing $($f.src)."
        Write-Host "  setup.ps1 has to run from inside the cloned repository — it copies"
        Write-Host "  files that sit next to it. Run:"
        Write-Host ""
        Write-Host "    git clone https://github.com/Gabriel-Dalton/claude-statusline-tokens"
        Write-Host "    cd claude-statusline-tokens"
        Write-Host "    .\setup.ps1"
        Write-Host ""
        exit 1
    }
}

# Make sure ~/.claude exists. Claude Code creates this on first run, but
# new users sometimes haven't launched it yet.
if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir | Out-Null
    Write-OK ("Created $claudeDir")
}

# Pick the launcher BEFORE copying files so we fail fast if PowerShell is
# missing entirely. Surface any soft warnings (e.g. PS 5.1 fallback) up
# front so the user can bail out before we touch anything.
$launcher = Get-PSLauncher
Write-Step ("Launcher: {0}" -f $launcher.exe)
if ($launcher.warning) {
    Write-Warn $launcher.warning
    if (-not $NonInteractive -and -not $DryRun) {
        $proceed = Confirm-YesNo "Continue with $($launcher.exe) anyway?" $true
        if (-not $proceed) {
            Write-Host ''
            Write-Host "  No changes made. Install pwsh and re-run when ready."
            exit 0
        }
    }
}

# Step 1: copy the scripts ----------------------------------------------
foreach ($f in $filesToCopy) {
    $name = Split-Path -Leaf $f.src
    # Identical-content short-circuit: avoids needlessly re-touching files
    # if the user re-runs setup, which would invalidate the cache for no
    # reason and could perturb running statusline invocations.
    $same = $false
    if (Test-Path $f.dst) {
        try {
            $srcHash = (Get-FileHash $f.src -Algorithm SHA1).Hash
            $dstHash = (Get-FileHash $f.dst -Algorithm SHA1).Hash
            $same = ($srcHash -eq $dstHash)
        } catch {}
    }
    if ($same) {
        Write-Step ("Copy {0,-26} unchanged" -f $name)
    } elseif ($DryRun) {
        Write-Step ("Copy {0,-26} -> {1}   [dry-run]" -f $name, $f.dst)
    } else {
        Copy-Item $f.src $f.dst -Force
        Write-OK ("Copy {0,-26} -> {1}   OK" -f $name, $f.dst)
    }
}

# Step 2: settings.json merge -------------------------------------------
$commandString = '{0} -NoProfile -ExecutionPolicy Bypass -File "{1}"' -f `
    $launcher.exe, (Join-Path $claudeDir 'statusline-tokens.ps1')

$desiredStatusLine = [ordered]@{
    type    = 'command'
    command = $commandString
    padding = 0
}

# Load existing settings, if any. We treat parse failures as a hard stop
# rather than silently overwriting — the user's existing config is more
# valuable than this script's convenience.
$existing = $null
$existingHasStatusLine = $false
$existingMatches = $false
if (Test-Path $settingsPath) {
    try {
        $existing = Get-Content -Raw -Encoding UTF8 $settingsPath | ConvertFrom-Json
    } catch {
        Write-Err "Could not parse $settingsPath as JSON: $($_.Exception.Message)"
        Write-Host "  Fix the file (or delete it) and re-run setup.ps1."
        exit 1
    }
    if ($existing.PSObject.Properties.Name -contains 'statusLine') {
        $existingHasStatusLine = $true
        $existingMatches = ($existing.statusLine.type -eq $desiredStatusLine.type) -and
                           ($existing.statusLine.command -eq $desiredStatusLine.command)
    }
} else {
    # Start from an empty PSCustomObject so the "set property" path below
    # works the same regardless of whether settings.json existed.
    $existing = [pscustomobject]@{}
}

if ($existingMatches) {
    Write-Host ''
    Write-OK "settings.json already wires the statusline correctly. Nothing to merge."
} else {
    Write-Host ''
    Write-Host "  About to add this block to $settingsPath" -ForegroundColor Cyan
    Write-Host ''
    $previewJson = $desiredStatusLine | ConvertTo-Json -Depth 8
    foreach ($line in ($previewJson -split "`n")) { Write-Host "    $line" }
    Write-Host ''
    if ($existingHasStatusLine) {
        Write-Warn "Note: an existing statusLine block will be REPLACED."
    }
    Write-Host "  A backup will be saved to $backupPath."

    if ($DryRun) {
        Write-Step "[dry-run] would write settings.json (and back up to settings.json.bak)"
    } else {
        $proceed = Confirm-YesNo "Proceed?" $true
        if (-not $proceed) {
            Write-Host ''
            Write-Warn "Skipped settings.json. Statusline files are copied but Claude Code won't pick them up until you wire the block above into settings.json yourself."
        } else {
            if (Test-Path $settingsPath) {
                Copy-Item $settingsPath $backupPath -Force
                Write-Step "Backed up settings.json -> settings.json.bak"
            }
            # Convert hashtable to a PSCustomObject so it round-trips through
            # ConvertTo-Json with the same shape as JSON-loaded objects.
            $statusLineObj = New-Object psobject -Property $desiredStatusLine
            if ($existing.PSObject.Properties.Name -contains 'statusLine') {
                $existing.statusLine = $statusLineObj
            } else {
                $existing | Add-Member -NotePropertyName 'statusLine' -NotePropertyValue $statusLineObj
            }
            $existing | ConvertTo-Json -Depth 32 | Set-Content -Path $settingsPath -Encoding utf8
            Write-OK "Wrote settings.json."
        }
    }
}

# Step 3: smoke-test the statusline -------------------------------------
Write-Host ''
Write-Host "  Verifying the statusline can run..." -ForegroundColor Cyan
$statuslineDst = Join-Path $claudeDir 'statusline-tokens.ps1'
$smokeOk = $false
try {
    # The statusline reads its JSON payload from stdin; piping "{}" gives
    # it a valid (but empty) hook object so it falls through to the no-hook
    # path. If anything is fundamentally broken (syntax error, missing
    # paths) we'll see it now rather than next time Claude Code runs.
    $output = '{}' | & $launcher.exe -NoProfile -ExecutionPolicy Bypass -File $statuslineDst 2>&1
    if ($LASTEXITCODE -eq 0 -and $output) {
        $smokeOk = $true
        Write-OK "OK. Sample output:"
        Write-Host ''
        Write-Host "    $output"
    } else {
        Write-Warn "Statusline ran but produced no output. Hook code path may still work; check after starting Claude Code."
    }
} catch {
    Write-Err "Statusline failed to run: $($_.Exception.Message)"
}

# Step 4: summary --------------------------------------------------------
Write-Host ''
Write-Rule
Write-Host "  Done." -ForegroundColor Green
Write-Host ''
Write-Host "  Statusline:"
Write-Host "    Open a NEW Claude Code session to see it. The current session"
Write-Host "    won't pick up the settings.json change."
Write-Host ''
Write-Host "  Dashboard:"
$dashboardDst = Join-Path $claudeDir 'claude-dashboard.ps1'
Write-Host "    $($launcher.exe) -NoProfile -ExecutionPolicy Bypass -File `"$dashboardDst`""
Write-Host ''
Write-Host "    Or from inside the cloned repo:"
Write-Host "      .\dashboard.ps1"
Write-Host ''
Write-Host "  Uninstall:   .\setup.ps1 -Uninstall"
Write-Host ''

# Step 5: optional dashboard preview ------------------------------------
if (-not $SkipDashboardPreview -and $smokeOk) {
    $preview = Confirm-YesNo "Launch the dashboard once now to see it?" $true
    if ($preview) {
        Write-Host ''
        & $launcher.exe -NoProfile -ExecutionPolicy Bypass -File $dashboardDst -Once
        Write-Host ''
    }
}
