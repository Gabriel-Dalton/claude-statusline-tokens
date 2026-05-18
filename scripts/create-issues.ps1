<#
.SYNOPSIS
    Bulk-creates v2 roadmap issues + labels on GitHub.

.DESCRIPTION
    Idempotently creates labels (milestone:M1..M5, effort:S/M/L, type:*) and
    then opens 38 issues on the current `origin` remote. Safe to re-run; will
    skip labels that already exist. Issues will be created with duplicates if
    re-run — check `gh issue list` before re-running if interrupted.

.PARAMETER DryRun
    Prints what would be created without calling gh.

.EXAMPLE
    pwsh ./scripts/create-issues.ps1
    pwsh ./scripts/create-issues.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# --- Preflight ----------------------------------------------------------------

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Host "gh CLI not found. Install: winget install GitHub.cli  (then: gh auth login)" -ForegroundColor Red
    exit 1
}

$ghStatus = gh auth status 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host "gh is not authenticated. Run: gh auth login" -ForegroundColor Red
    Write-Host $ghStatus
    exit 1
}

$repo = (gh repo view --json nameWithOwner --jq '.nameWithOwner') 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "Could not detect GitHub repo for current directory." -ForegroundColor Red
    exit 1
}
Write-Host "Target repo: $repo" -ForegroundColor Cyan

# --- Labels -------------------------------------------------------------------

$labels = @(
    @{ name = 'milestone:M1'; color = 'b60205'; description = 'Stabilize (v1.0.0)' }
    @{ name = 'milestone:M2'; color = 'd93f0b'; description = 'Refactor' }
    @{ name = 'milestone:M3'; color = 'fbca04'; description = 'Polish (tests/CI)' }
    @{ name = 'milestone:M4'; color = '0e8a16'; description = 'Features' }
    @{ name = 'milestone:M5'; color = '1d76db'; description = 'Release (v2.0.0)' }
    @{ name = 'effort:S'    ; color = 'c2e0c6'; description = '<1 day' }
    @{ name = 'effort:M'    ; color = 'fef2c0'; description = '1-3 days' }
    @{ name = 'effort:L'    ; color = 'f9d0c4'; description = '>3 days' }
    @{ name = 'type:bug'    ; color = 'd73a4a'; description = 'Something is broken' }
    @{ name = 'type:refactor'; color = '6f42c1'; description = 'Code reshape, no behavior change' }
    @{ name = 'type:feature'; color = 'a2eeef'; description = 'New capability' }
    @{ name = 'type:chore'  ; color = 'e4e669'; description = 'Infra / tooling' }
    @{ name = 'type:docs'   ; color = '0075ca'; description = 'Documentation' }
    @{ name = 'type:release'; color = '1d76db'; description = 'Release management' }
    @{ name = 'good first issue'; color = '7057ff'; description = 'Good starter task' }
)

Write-Host "`nEnsuring labels..." -ForegroundColor Cyan
foreach ($l in $labels) {
    if ($DryRun) { Write-Host "  [dry] label: $($l.name)"; continue }
    $null = gh label create $l.name --color $l.color --description $l.description --force 2>&1
    if ($LASTEXITCODE -eq 0) { Write-Host "  ok: $($l.name)" -ForegroundColor Green } else { Write-Host "  fail: $($l.name)" -ForegroundColor Yellow }
}

# --- Issues -------------------------------------------------------------------

function New-IssueDef {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string[]]$Labels,
        [Parameter(Mandatory)][string]$Body
    )
    [pscustomobject]@{ Code = $Code; Title = $Title; Labels = $Labels; Body = $Body }
}

$issues = @()

# ============================================================================
# M1 — STABILIZE
# ============================================================================

$issues += New-IssueDef -Code 'M1-01' `
    -Title '[M1-01] Untrack scripts/node_modules and patch .gitignore' `
    -Labels @('milestone:M1','effort:S','type:chore','good first issue') `
    -Body @'
## Problem

`scripts/node_modules/` is committed (175 Playwright files). `.gitignore` lists editor cruft but not `node_modules/`. Confirmed via `git ls-files --error-unmatch scripts/node_modules/playwright/package.json` (exit 0). This bloats clones, leaks vendor code into PR diffs, and inflates the repo on GitHub.

## Acceptance criteria

- [ ] `node_modules/` added to `.gitignore` (root-level so it applies to any nested location).
- [ ] `git rm -r --cached scripts/node_modules` committed in a single dedicated commit.
- [ ] Repo size drops noticeably (`git count-objects -vH` before/after).
- [ ] CI (once it exists) green after untrack.

## Effort

S (<1 day)

## References

- `.gitignore`
- `scripts/node_modules/` (tracked)
- `scripts/package.json`, `scripts/package-lock.json` (stay tracked)

## Dependencies

None — should be first commit landed.
'@

$issues += New-IssueDef -Code 'M1-02' `
    -Title '[M1-02] Fix cache-hit skipping session detection' `
    -Labels @('milestone:M1','effort:M','type:bug') `
    -Body @'
## Problem

On cache hit (`statusline-tokens.ps1:196`), the `$turns` array is not rebuilt — `tokSession` / `costSession` come from the cache and can be up to 20 s stale. Session-end transitions can be missed entirely for one cache cycle.

## Acceptance criteria

- [ ] Session segment recomputes on every render even when 5h/7d totals are cached, OR the cache persists enough turn metadata to recompute the session window cheaply (< 5 ms).
- [ ] After M3 tests exist: Pester test for "cache valid → new turn arrives → session still detected within one render."
- [ ] No new full-transcript scans introduced by the fix (works with M1-04).

## Effort

M (1–3 days)

## References

- `statusline-tokens.ps1:184-211` (cache load/save)
- `statusline-tokens.ps1:293, 317` (session computation)

## Dependencies

Coordinate with M1-04 (transcript tail cache) — both touch the scan path.
'@

$issues += New-IssueDef -Code 'M1-03' `
    -Title '[M1-03] Fix IndexOf(''"usage"'') false-positive matcher' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

Line 351 picks the last JSONL line containing the literal string `"usage"`. A user message whose text contains those characters (verbatim) will clobber `$lastUsageLine`, producing a 0-token context readout.

## Acceptance criteria

- [ ] Match is anchored to JSON structure (e.g., probe for `"message":{...,"role":"assistant"...,"usage":{`), or the line is parsed as JSON and the usage block extracted only when `message.role == "assistant"` and `message.usage` exists.
- [ ] Regression fixture: a transcript with a user message containing the literal `"usage"` string does not affect the ctx readout.
- [ ] No measurable perf regression (compare with `Measure-Command` on a 10k-line fixture).

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:350-358`

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M1-04' `
    -Title '[M1-04] Replace full-transcript rescan with tail/length cache' `
    -Labels @('milestone:M1','effort:M','type:bug') `
    -Body @'
## Problem

Every render reads the entire transcript with `ReadLines` (line 350). Long sessions (10k+ lines) get re-scanned from byte 0 each tick.

## Acceptance criteria

- [ ] Per-file scan position cached as `(path, length, lastScanOffset, lastUsageLine)`; subsequent renders read only new bytes since `lastScanOffset`.
- [ ] On file shrink/rotate (current length < cached length), fall back to full scan.
- [ ] Bench on a 50 MB synthetic transcript: cold render < 100 ms, warm render < 20 ms (measure in PR).
- [ ] Cache file shape change is migrated cleanly (or versioned so old caches are discarded).

## Effort

M (1–3 days)

## References

- `statusline-tokens.ps1:213-220, 350-358`

## Dependencies

Coordinate with M1-02 (cache-hit session bug).
'@

$issues += New-IssueDef -Code 'M1-05' `
    -Title '[M1-05] Replace global SilentlyContinue with scoped error handling' `
    -Labels @('milestone:M1','effort:M','type:refactor') `
    -Body @'
## Problem

`$ErrorActionPreference = ''SilentlyContinue''` (line 7) hides all errors globally. 18 `catch {}` blocks discard everything else. Real bugs never surface — including the ones in M1-02..M1-04.

## Acceptance criteria

- [ ] Global preference removed (script-scoped default is the PS default, `Continue`).
- [ ] Each risky call uses `-ErrorAction Stop` inside a `try/catch` that decides whether to swallow or log.
- [ ] All swallowed errors funnel through a single `Write-DebugLog` helper (no-op stub for now — M2-05 wires up the real log file).
- [ ] Statusline still prints something on every failure mode (golden tests: empty stdin, malformed JSON, missing transcript file, missing model).

## Effort

M (1–3 days)

## References

- `statusline-tokens.ps1:7` and every `catch {}` site (18 of them).

## Dependencies

Lands before M2-05 (rotating log) and M3-01 (tests assert error fallback behavior).
'@

$issues += New-IssueDef -Code 'M1-06' `
    -Title '[M1-06] Fix Unicode surrogate splitting in brace matcher' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

The hand-rolled JSON brace matcher walks `$content[$i]` as `[char]`, splitting astral-plane codepoints (emoji, CJK extension, math symbols). Org names containing surrogate pairs corrupt the parse.

## Acceptance criteria

- [ ] Either: index via `[System.Globalization.StringInfo]` text elements, **or** replace the hand-rolled matcher with a proper streaming parse + `ConvertFrom-Json` on the extracted balanced substring.
- [ ] Regression fixture: an org name containing 🚀 parses correctly and survives a round-trip through the account-history file.
- [ ] No new dependencies.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:86-102`

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M1-07' `
    -Title '[M1-07] Cross-platform user-profile resolution' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

`$env:USERPROFILE` (line 63) is Windows-only. pwsh 7 on macOS/Linux receives `$null`, and downstream `Join-Path` calls produce relative or invalid paths.

## Acceptance criteria

- [ ] Use `[Environment]::GetFolderPath(''UserProfile'')` (cross-platform) with `$HOME` fallback.
- [ ] All path joins use multi-segment `Join-Path` (no embedded `\` literals).
- [ ] Smoke test in CI: script runs end-to-end on `ubuntu-latest` + `macos-latest` with pwsh 7 + a fixture hook JSON; exits 0 and prints something to stdout.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:63-66` (path setup)
- Any other place that hardcodes `\` separators

## Dependencies

Sets up M5-04 (multi-platform example settings).
'@

$issues += New-IssueDef -Code 'M1-08' `
    -Title '[M1-08] Normalize UTF-8 BOM handling across PS 5.1 and PS 7' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

`Get-Content -Encoding UTF8` and `Set-Content -Encoding utf8` produce different BOM behavior on PS 5.1 vs PS 7. Files round-tripped across versions end up inconsistent.

## Acceptance criteria

- [ ] All writes go through `[System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))` (UTF-8 no BOM).
- [ ] All reads use a BOM-tolerant approach (`[System.IO.File]::ReadAllText` with an explicit UTF-8 encoding that accepts BOM, or `Get-Content -Raw` + manual BOM strip).
- [ ] CI assertion: identical files produced by PS 5.1 and pwsh 7 (byte-compare a fixture round-trip in tests).

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:134, 149-151, 190` (cache + account-history I/O)

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M1-09' `
    -Title '[M1-09] Cache git branch lookup by .git/HEAD mtime' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

`git -C $cwd rev-parse --abbrev-ref HEAD` is shelled out every render (line 374). Slow, sensitive to PATH, and leaks `$LASTEXITCODE` to the caller. The branch only changes when `.git/HEAD` changes.

## Acceptance criteria

- [ ] Branch lookup is keyed on `(cwd, fileinfo(.git/HEAD).LastWriteTimeUtc)`; refreshes only when mtime changes.
- [ ] Missing or unreadable `.git/HEAD` produces no branch segment (no exception thrown, no `$LASTEXITCODE` leak).
- [ ] Detached HEAD is detected and rendered as a short SHA (or omitted — pick one and document).
- [ ] No fork of `git.exe` happens on warm cache hits.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:374-378`

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M1-10' `
    -Title '[M1-10] Graceful fallbacks for missing hook fields' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

The script assumes `hook.transcript_path`, `hook.model.display_name`, `rate_limits.five_hour.used_percentage`, etc. always exist. Anthropic schema drift silently zeroes segments.

## Acceptance criteria

- [ ] Every consumed field has a documented fallback (e.g., `model.display_name` → `model.id` with friendly formatting → `"model?"`).
- [ ] Missing required fields produce a minimal fallback statusline (e.g., model name + cwd) instead of a blank line.
- [ ] Each fallback fires a `Write-DebugLog` entry naming the missing field.
- [ ] Fixture tests cover: empty hook input, hook with `model.id` only, hook missing `rate_limits`, hook missing `transcript_path`.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:341-378`

## Dependencies

Builds on M1-05 (Write-DebugLog helper stub).
'@

$issues += New-IssueDef -Code 'M1-11' `
    -Title '[M1-11] Add stdin read timeout' `
    -Labels @('milestone:M1','effort:S','type:bug') `
    -Body @'
## Problem

`[Console]::In.ReadToEnd()` (line 17) blocks forever if Claude Code spawns the statusline without piping JSON (TTY-attached stdin). The statusline can hang past the 300 ms budget.

## Acceptance criteria

- [ ] If stdin is a TTY (no piped input) or no data arrives within 200 ms, print a "no hook input" fallback line and exit 0.
- [ ] Total statusline runtime never exceeds 300 ms regardless of stdin state.
- [ ] Bench: simulate empty-stdin invocation; measured runtime < 250 ms.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:17`

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M1-12' `
    -Title '[M1-12] Tag retroactive releases + cut v1.0.0' `
    -Labels @('milestone:M1','effort:S','type:release') `
    -Body @'
## Problem

`CHANGELOG.md` lists v0.1.0, v0.2.0, v0.3.0 but no git tags exist. v1.0.0 is the planned cut after M1-01..M1-11 land.

## Acceptance criteria

- [ ] `git tag v0.1.0 / v0.2.0 / v0.3.0` placed on the correct historical commits (cross-reference CHANGELOG dates against `git log`).
- [ ] All M1-01..M1-11 issues closed.
- [ ] `CHANGELOG.md [Unreleased]` promoted to `[1.0.0] — YYYY-MM-DD`.
- [ ] `git tag v1.0.0` and pushed.
- [ ] GitHub Release created for each tag (manual UI until M5-07 release workflow exists).

## Effort

S (<1 day)

## References

- `CHANGELOG.md`

## Dependencies

Blocked by all of M1-01..M1-11.
'@

# ============================================================================
# M2 — REFACTOR
# ============================================================================

$issues += New-IssueDef -Code 'M2-01' `
    -Title '[M2-01] Split monolith into pure-input/pure-output modules' `
    -Labels @('milestone:M2','effort:L','type:refactor') `
    -Body @'
## Problem

The 412-line `statusline-tokens.ps1` mutates script-scoped variables (`$tok5h`, `$tok7d`, ...) throughout — nothing is testable in isolation. This blocks Pester unit tests (M3-01).

## Acceptance criteria

- [ ] New module structure (single `.psm1` is acceptable; no install required):
  - `Read-HookInput` — parses stdin, returns `[pscustomobject]StatuslineHookInput`.
  - `Get-Accounts` — reads `~/.claude.json` + `statusline-accounts.json`, returns active account + checkpoint history.
  - `Get-TokenUsage` — given (transcript paths, account, windows), returns a typed usage struct.
  - `Format-StatusLine` — given usage struct + config, returns the ANSI-formatted string.
- [ ] `statusline-tokens.ps1` becomes a thin orchestrator (~50 lines).
- [ ] No script-scoped mutable state remains in the orchestrator.
- [ ] All M1 fixes preserved; golden-output byte-identical to pre-refactor for canonical fixtures.

## Effort

L (>3 days)

## References

- All of `statusline-tokens.ps1`

## Dependencies

Blocked by all of M1.
'@

$issues += New-IssueDef -Code 'M2-02' `
    -Title '[M2-02] Hook-contract layer for stdin JSON' `
    -Labels @('milestone:M2','effort:M','type:refactor') `
    -Body @'
## Problem

The shape of Claude Code's stdin JSON is referenced from many points in the script. A rename by Anthropic = silent breakage in N spots.

## Acceptance criteria

- [ ] One internal struct `StatuslineHookInput` with documented fields and a `schemaVersion` stamp.
- [ ] `Read-HookInput` is the *only* place that maps raw JSON → struct.
- [ ] No other code references `$hook.X` directly.
- [ ] Unknown shapes log a single Write-DebugLog warning naming the missing/extra fields.

## Effort

M (1–3 days)

## References

- Every `$hook.X` access across the codebase

## Dependencies

Blocked by M2-01.
'@

$issues += New-IssueDef -Code 'M2-03' `
    -Title '[M2-03] Externalize pricing to pricing.json' `
    -Labels @('milestone:M2','effort:M','type:refactor') `
    -Body @'
## Problem

Pricing is hardcoded in three places — `statusline-tokens.ps1:29-33`, `README.md:241-249`, `docs/PRICING.md:21-25`. Drift-prone.

## Acceptance criteria

- [ ] New `pricing.json` shipped alongside the script:
  ```json
  {
    "version": "1.0.0",
    "capturedOn": "2026-MM-DD",
    "families": {
      "opus":  { "input": 15, "output": 75, "cacheRead": 1.50, "cacheWrite5m": 18.75, "cacheWrite1h": 30, "sourceUrl": "..." },
      "sonnet": { ... },
      "haiku":  { ... }
    }
  }
  ```
- [ ] Script loads it once per render, caches in memory.
- [ ] `pricingVersion` recorded in the disk cache; cache invalidates when version changes.
- [ ] README pricing table removed; README links to `docs/PRICING.md`. PRICING.md is generated from `pricing.json` (or trivially derivable).
- [ ] Unknown model family logs a Write-DebugLog warning instead of silently mapping to opus.

## Effort

M (1–3 days)

## References

- `statusline-tokens.ps1:29-33, 246-260`
- `README.md:241-249`
- `docs/PRICING.md:21-25`

## Dependencies

Blocked by M2-01.
'@

$issues += New-IssueDef -Code 'M2-04' `
    -Title '[M2-04] Externalize config to ~/.claude/statusline-tokens.config.json' `
    -Labels @('milestone:M2','effort:M','type:feature') `
    -Body @'
## Problem

All customization (session gap, cache TTL, segment order, colors, thresholds) requires editing the script. No safe upgrade path.

## Acceptance criteria

- [ ] Config schema documented; loaded from `~/.claude/statusline-tokens.config.json` if present.
- [ ] Hot-reloaded on mtime change (no Claude Code restart).
- [ ] Missing fields fall back to current defaults; unknown fields warn to debug log.
- [ ] Configurable: segment list/order, color tokens, session-gap minutes, cache TTL, anomaly threshold (M4-05), refresh interval.
- [ ] `$schema` pointer to a JSON Schema committed at `schemas/config.schema.json`.
- [ ] Documented in `docs/CUSTOMIZE.md`.

## Effort

M (1–3 days)

## References

- `statusline-tokens.ps1:57` (session gap), `:184` (cache TTL)
- `docs/CUSTOMIZE.md`

## Dependencies

Blocked by M2-01.
'@

$issues += New-IssueDef -Code 'M2-05' `
    -Title '[M2-05] Optional rotating debug log' `
    -Labels @('milestone:M2','effort:S','type:feature') `
    -Body @'
## Problem

After M1-05 lands `Write-DebugLog`, it needs an actual destination.

## Acceptance criteria

- [ ] Log path: `~/.claude/statusline-tokens.log`.
- [ ] Gated on `$env:STATUSLINE_DEBUG` being set (any truthy value); otherwise the helper is a no-op.
- [ ] Rotates at 1 MB (single backup `.log.1`); never grows unbounded.
- [ ] Append-only; lines are `[YYYY-MM-DDTHH:MM:SSZ] [scope] message`.
- [ ] Writing never blocks the statusline beyond 5 ms (best-effort write with timeout).
- [ ] Documented in README troubleshooting section.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1` `catch {}` sites (after M1-05 refactor)

## Dependencies

Blocked by M1-05.
'@

$issues += New-IssueDef -Code 'M2-06' `
    -Title '[M2-06] $scriptVersion constant + bump.ps1' `
    -Labels @('milestone:M2','effort:S','type:chore') `
    -Body @'
## Problem

No version constant in the script; CHANGELOG entries are manual; nothing to surface in `--version` or telemetry.

## Acceptance criteria

- [ ] `$scriptVersion = ''1.0.0''` constant at the top of the orchestrator.
- [ ] `scripts/bump.ps1 <major|minor|patch>`:
  - Updates `$scriptVersion` in the script.
  - Updates the version in `.psd1` manifest (once M5-01 lands).
  - Promotes `CHANGELOG.md [Unreleased]` to a dated version section.
  - Commits with `chore: release vX.Y.Z`.
- [ ] `--version` flag prints version and exits 0.
- [ ] Pester test for `bump.ps1` patch/minor/major.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1` top
- `CHANGELOG.md`
- new file `scripts/bump.ps1`

## Dependencies

Blocked by M2-01.
'@

# ============================================================================
# M3 — POLISH
# ============================================================================

$issues += New-IssueDef -Code 'M3-01' `
    -Title '[M3-01] Pester 5 unit tests for pure functions' `
    -Labels @('milestone:M3','effort:M','type:chore') `
    -Body @'
## Problem

No tests anywhere. A regression in any helper function would never surface.

## Acceptance criteria

- [ ] `tests/` directory with Pester 5 (no install required — bootstrapped in CI).
- [ ] Unit coverage for: `Format-TokenCount`, `Format-Cost`, `Get-ModelFamily`, hook input parsing, account-history JSON round-trip, brace matcher (or replacement).
- [ ] All tests pass on PS 5.1 + pwsh 7 locally.
- [ ] Coverage report generated (do not enforce % yet — just measure).
- [ ] `tests/README.md` documents how to run locally.

## Effort

M (1–3 days)

## References

- formatter/helper functions in `statusline-tokens.ps1` (post-M2-01 module split)

## Dependencies

Blocked by M2-01.
'@

$issues += New-IssueDef -Code 'M3-02' `
    -Title '[M3-02] Golden-string snapshot tests with fixture transcripts' `
    -Labels @('milestone:M3','effort:M','type:chore') `
    -Body @'
## Problem

Even with unit tests on helpers, the rendered output line is the actual user-visible contract. Without snapshot tests, refactors silently change the user experience.

## Acceptance criteria

- [ ] `tests/fixtures/projects/` contains 5–10 fixture JSONL transcripts:
  - empty session
  - single turn
  - multi-account checkpoint
  - session-end transition (>30 min gap)
  - 5h near limit
  - missing `usage` blocks
  - Unicode org name (emoji)
  - user message containing literal `"usage"` (regression fixture for M1-03)
- [ ] For each fixture + hook JSON, an ANSI-stripped golden string is committed to `tests/golden/`.
- [ ] Test failure prints a unified diff and instructs the maintainer to re-record via `pwsh tests/record.ps1 <fixture>`.

## Effort

M (1–3 days)

## References

- new files under `tests/`

## Dependencies

Blocked by M3-01.
'@

$issues += New-IssueDef -Code 'M3-03' `
    -Title '[M3-03] CI workflow matrix (PS 5.1 + pwsh 7 across Windows/Ubuntu/macOS)' `
    -Labels @('milestone:M3','effort:M','type:chore') `
    -Body @'
## Problem

No CI; every merge is local-trust.

## Acceptance criteria

- [ ] `.github/workflows/ci.yml` runs on push to `main` and on every PR.
- [ ] Matrix:
  - `windows-latest` × PS 5.1 (Windows PowerShell)
  - `windows-latest` × pwsh 7
  - `ubuntu-latest` × pwsh 7
  - `macos-latest` × pwsh 7
- [ ] Steps per cell: install Pester 5 → `Invoke-Pester -CI` → `Invoke-ScriptAnalyzer -Settings ./PSScriptAnalyzerSettings.psd1 -Severity Warning -EnableExit`.
- [ ] Separate job: `node scripts/responsive-check.mjs` (already exits non-zero on overflow).
- [ ] Branch protection on `main` requires all CI cells green to merge.

## Effort

M (1–3 days)

## References

- new file `.github/workflows/ci.yml`

## Dependencies

Blocked by M3-01 and M3-04.
'@

$issues += New-IssueDef -Code 'M3-04' `
    -Title '[M3-04] PSScriptAnalyzer configuration' `
    -Labels @('milestone:M3','effort:S','type:chore') `
    -Body @'
## Problem

No lint config; PSScriptAnalyzer defaults are too noisy for an intentional-console-write script.

## Acceptance criteria

- [ ] `PSScriptAnalyzerSettings.psd1` at repo root.
- [ ] Excludes `PSAvoidUsingWriteHost` (script intentionally uses `[Console]::Out.Write`).
- [ ] Other excludes documented inline with one-line justification per rule.
- [ ] Zero warnings at `-Severity Warning` against current codebase.

## Effort

S (<1 day)

## References

- new file `PSScriptAnalyzerSettings.psd1`

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M3-05' `
    -Title '[M3-05] .editorconfig' `
    -Labels @('milestone:M3','effort:S','type:chore','good first issue') `
    -Body @'
## Problem

No consistent indentation/encoding declaration. Contributors with different editor defaults will introduce churn.

## Acceptance criteria

- [ ] `.editorconfig` at root with:
  - `*` → LF, UTF-8, final newline, trim trailing whitespace.
  - `*.ps1, *.psd1, *.psm1` → 4 spaces.
  - `*.{js,mjs,html,json,yml,yaml,md}` → 2 spaces.
  - `*.md` → preserve trailing whitespace (markdown line breaks).
- [ ] No file diffs needed beyond creating the config (existing files are already mostly conformant).

## Effort

S (<1 day)

## References

- new file `.editorconfig`

## Dependencies

None.
'@

$issues += New-IssueDef -Code 'M3-06' `
    -Title '[M3-06] Dependabot configuration' `
    -Labels @('milestone:M3','effort:S','type:chore','good first issue') `
    -Body @'
## Problem

No dependency update automation. `scripts/package.json` Playwright will drift.

## Acceptance criteria

- [ ] `.github/dependabot.yml`:
  - ecosystem `npm` rooted at `/scripts`, weekly cadence, grouped minor/patch.
  - ecosystem `github-actions` rooted at `/`, weekly cadence.
- [ ] First Dependabot PRs land green against CI (assuming M3-03 exists).

## Effort

S (<1 day)

## References

- new file `.github/dependabot.yml`

## Dependencies

Best landed after M3-03 so PRs have CI to satisfy.
'@

$issues += New-IssueDef -Code 'M3-07' `
    -Title '[M3-07] Issue/PR templates + SECURITY.md + community files' `
    -Labels @('milestone:M3','effort:S','type:chore') `
    -Body @'
## Problem

None of the standard OSS scaffolding exists. CONTRIBUTING.md asks for fields but enforces nothing.

## Acceptance criteria

- [ ] `.github/ISSUE_TEMPLATE/bug.yml` — gates fields: PS version, Claude Code version, OS, expected vs actual, redacted hook JSON.
- [ ] `.github/ISSUE_TEMPLATE/feature_request.yml` — gates the scope-creep filter ("does this fit reliability & polish or is it v3?").
- [ ] `.github/ISSUE_TEMPLATE/config.yml` — disables blank issues, links to Discussions if enabled.
- [ ] `.github/PULL_REQUEST_TEMPLATE.md` — checklist incl. CHANGELOG entry, tests added/updated, screenshots for UI.
- [ ] `SECURITY.md` — script reads `~/.claude.json` (oauth state); document threat model + private report channel.
- [ ] `CODE_OF_CONDUCT.md` — Contributor Covenant 2.1.
- [ ] `CODEOWNERS` — assign reviews to repo owner.
- [ ] `.github/FUNDING.yml` — sponsor links if any (else omit).

## Effort

S (<1 day)

## References

- new files under `.github/`
- existing `CONTRIBUTING.md`

## Dependencies

None.
'@

# ============================================================================
# M4 — FEATURES
# ============================================================================

$issues += New-IssueDef -Code 'M4-01' `
    -Title '[M4-01] Honor refreshInterval from hook input' `
    -Labels @('milestone:M4','effort:S','type:feature') `
    -Body @'
## Problem

Claude Code passes a `refreshInterval` hint in stdin. We ignore it, so countdowns (M4-03) and rate-limit percentages do not visibly tick when the user is idle.

## Acceptance criteria

- [ ] Read `refreshInterval` from hook input via the M2-02 contract.
- [ ] Trim cache TTL to `min(20s, refreshInterval / 2)` so M4-03 countdowns visibly update.
- [ ] No effect when the field is absent (preserves current behavior).
- [ ] Documented in `docs/ARCHITECTURE.md` cache section.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1` cache logic
- M2-02 contract

## Dependencies

Blocked by M2-02.
'@

$issues += New-IssueDef -Code 'M4-02' `
    -Title '[M4-02] Context% bar from context_window.used_percentage' `
    -Labels @('milestone:M4','effort:S','type:feature') `
    -Body @'
## Problem

The hook provides `context_window.used_percentage` directly, but we compute ctx from raw tokens and ignore the official percentage.

## Acceptance criteria

- [ ] New segment: `ctx 42% ▓▓▓▓░░░░░░` driven by the hook-provided percentage.
- [ ] Falls back to current token-based calc if the field is missing.
- [ ] Auto-compact threshold (configurable via M2-04) tints the bar yellow/red.
- [ ] ASCII fallback (no Unicode block glyphs) controlled by M2-04 config flag for terminals without Nerd Font.
- [ ] Documented in `docs/SESSION.md`.

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:341-358`

## Dependencies

Blocked by M2-02.
'@

$issues += New-IssueDef -Code 'M4-03' `
    -Title '[M4-03] Block-reset countdown from rate_limits.*.resets_at' `
    -Labels @('milestone:M4','effort:S','type:feature') `
    -Body @'
## Problem

The hook exposes `resets_at` timestamps for each rate-limit window — currently unused.

## Acceptance criteria

- [ ] 5h and 7d segments render `(resets in 1h 12m)` after the percentage.
- [ ] Format precision is config-driven: minutes only when `<1h`, hours+minutes otherwise.
- [ ] M4-01 ensures it visibly ticks when the user is idle.
- [ ] If `resets_at` is missing, no countdown is rendered (no fallback math).

## Effort

S (<1 day)

## References

- `statusline-tokens.ps1:341-352`

## Dependencies

Blocked by M2-02; benefits from M4-01.
'@

$issues += New-IssueDef -Code 'M4-04' `
    -Title '[M4-04] --once smoke test + --debug JSON dump' `
    -Labels @('milestone:M4','effort:S','type:feature') `
    -Body @'
## Problem

No way to test the script in isolation without invoking Claude Code. Hard to bug-report ("what does *your* statusline produce?").

## Acceptance criteria

- [ ] `statusline-tokens.ps1 --once < fixture.json` reads stdin, prints one line, exits 0. No cache writes (or writes to a temp dir that''s cleaned up).
- [ ] `--debug` dumps the internal struct (hook input + computed usage + resolved config) as pretty JSON to stdout instead of the rendered line.
- [ ] `--version` prints version (delivered by M2-06).
- [ ] `--help` prints usage.
- [ ] All flags documented in README "Troubleshooting" section.

## Effort

S (<1 day)

## References

- new CLI handling at script top

## Dependencies

Blocked by M2-01.
'@

$issues += New-IssueDef -Code 'M4-05' `
    -Title '[M4-05] Anomaly badge for runaway-cost turns' `
    -Labels @('milestone:M4','effort:M','type:feature') `
    -Body @'
## Problem

A runaway tool loop or other unexpected spend spike is invisible until the 5h bar moves. Users want a louder signal.

## Acceptance criteria

- [ ] During session-scope computation, compute mean + stddev of per-turn cost.
- [ ] If the most recent turn is `>3σ` above mean AND absolute > $0.10, render a `⚠` badge in the session segment.
- [ ] Badge clears on next normal turn.
- [ ] Threshold (σ multiplier, absolute floor) configurable via M2-04.
- [ ] Pester test: synthetic 20-turn fixture with one anomalous turn → badge renders; remove anomaly → badge clears.

## Effort

M (1–3 days)

## References

- `statusline-tokens.ps1:293-317` (session computation)

## Dependencies

Blocked by M2-01.
'@

# ============================================================================
# M5 — RELEASE
# ============================================================================

$issues += New-IssueDef -Code 'M5-01' `
    -Title '[M5-01] .psd1 manifest + PSGallery publish' `
    -Labels @('milestone:M5','effort:M','type:release') `
    -Body @'
## Problem

Install is README copy-paste only. No discoverable package on PSGallery.

## Acceptance criteria

- [ ] `claude-statusline-tokens.psd1` declares module metadata: author, license, version (driven by M2-06), tags, description, project URL.
- [ ] Manual one-time `Publish-Module -Repository PSGallery` succeeds.
- [ ] Listing page renders cleanly with README excerpt.
- [ ] `PSGALLERY_API_KEY` secret stored in repo settings for use by M5-07 release workflow.

## Effort

M (1–3 days)

## References

- new file `claude-statusline-tokens.psd1`

## Dependencies

Blocked by M2-06, M3-03.
'@

$issues += New-IssueDef -Code 'M5-02' `
    -Title '[M5-02] Hosted install.ps1 one-liner' `
    -Labels @('milestone:M5','effort:M','type:release') `
    -Body @'
## Problem

Manual `settings.json` editing is the install. `irm <url> | iex` is the expected Windows-tool install UX.

## Acceptance criteria

- [ ] `install.ps1` served from a stable URL (raw.githubusercontent on a release tag, or GitHub Pages).
- [ ] Idempotent:
  - Detects existing `settings.json` `statusLine` block; backs it up to `settings.json.bak.YYYYMMDD-HHMMSS`.
  - Installs latest release to `%USERPROFILE%\.claude\statusline-tokens.ps1`.
  - Writes/merges the canonical `settings.json` snippet.
  - Prints "next steps" hint.
- [ ] Re-running upgrades in place.
- [ ] `--Uninstall` flag restores the backup and removes the statusLine block.
- [ ] Documented in README "Install in 30 seconds" section (and the index.html hero claim becomes truthful).

## Effort

M (1–3 days)

## References

- new file `install.ps1`

## Dependencies

Blocked by M5-01.
'@

$issues += New-IssueDef -Code 'M5-03' `
    -Title '[M5-03] Scoop manifest' `
    -Labels @('milestone:M5','effort:S','type:release') `
    -Body @'
## Problem

Scoop is the dominant Windows package manager for dev tools. Submitting the manifest enables `scoop install`.

## Acceptance criteria

- [ ] `bucket/claude-statusline-tokens.json` committed to a `scoop-bucket` branch (or to the main repo under `bucket/`).
- [ ] Manifest validates against the Scoop schema.
- [ ] `scoop bucket add claude-statusline-tokens https://github.com/Gabriel-Dalton/claude-statusline-tokens && scoop install claude-statusline-tokens` works end-to-end.
- [ ] Manifest auto-updates via the `autoupdate` block on each new tag.
- [ ] README documents the scoop install path.

## Effort

S (<1 day)

## References

- new file `bucket/claude-statusline-tokens.json`

## Dependencies

Blocked by M5-01.
'@

$issues += New-IssueDef -Code 'M5-04' `
    -Title '[M5-04] Multi-platform example settings' `
    -Labels @('milestone:M5','effort:S','type:docs','good first issue') `
    -Body @'
## Problem

`examples/settings.json` uses `%USERPROFILE%` + backslashes. macOS/Linux users get broken paths.

## Acceptance criteria

- [ ] `examples/settings.macos.json` and `examples/settings.linux.json` use `$HOME` + forward slashes.
- [ ] Existing `examples/settings.json` renamed to `examples/settings.windows.json`.
- [ ] README install section shows all three side-by-side (collapsible sections or tabs in the rendered HTML).
- [ ] Each file matches the canonical hook-JSON fixture flow.

## Effort

S (<1 day)

## References

- `examples/settings.json`
- `README.md` install section

## Dependencies

Blocked by M1-07 (cross-platform paths in the script itself).
'@

$issues += New-IssueDef -Code 'M5-05' `
    -Title '[M5-05] Docs accuracy pass' `
    -Labels @('milestone:M5','effort:M','type:docs') `
    -Body @'
## Problem

Several doc files reference removed v0.2 segments, wrong line counts, or duplicate pricing tables.

## Acceptance criteria

- [ ] `docs/MULTI-ACCOUNT.md:96` — remove stale `today`/`all` segment references; describe current segment set.
- [ ] `docs/ARCHITECTURE.md:3` — fix "~240 lines" (drop the number or auto-generate).
- [ ] `docs/ARCHITECTURE.md:204-213` and `docs/CUSTOMIZE.md:184-191` — regenerate cache-schema example to include `orgKey`, `tokSession`, `costSession`, `pricingVersion`.
- [ ] README pricing table removed; README links to `docs/PRICING.md`. `docs/PRICING.md` generated from `pricing.json` (M2-03) or trivially derivable.
- [ ] One canonical hook-JSON fixture in `tests/fixtures/` is referenced from README, CONTRIBUTING, and ARCHITECTURE.
- [ ] `docs/PRICING.md` stamped "as of YYYY-MM-DD" + note that 1M-context Opus pricing assumption (sub-200k context) is unverified pending Anthropic confirmation.
- [ ] `docs/UPGRADING.md` started (covers v0.3 → v2.0 migration; full content lands in M5-08).

## Effort

M (1–3 days)

## References

- `README.md`, `CHANGELOG.md`, `docs/*.md`

## Dependencies

Blocked by M2-01..M2-04 (the changes the docs need to describe).
'@

$issues += New-IssueDef -Code 'M5-06' `
    -Title '[M5-06] index.html v2 rebuild' `
    -Labels @('milestone:M5','effort:L','type:docs') `
    -Body @'
## Problem

The landing page documents the v0.1 product. Install snippets are invalid JSON. A11y checks fail. The page never shows the real screenshot (only a CSS recreation).

## Acceptance criteria

### Content
- [ ] Demo statusline matches v2 reality (session segment, multi-account state).
- [ ] Install snippet matches `examples/settings.windows.json` byte-for-byte (extract via a build step or inline a `<code>` populated from the file).

### Accessibility
- [ ] `<main>` landmark and a skip-to-content link.
- [ ] `scroll-margin-top` on anchored sections (sticky nav no longer eats anchor offsets).
- [ ] `<h4>` headings in methodology section instead of `<strong>`.
- [ ] `aria-hidden` on decorative brand glyphs `‹` / `›`.
- [ ] Hero pseudo-terminal text marked `aria-hidden` so screen readers don''t read it twice with the figcaption.

### Contrast
- [ ] `--fg-faint #a3a3a3` used only on purely decorative elements; semantic `—` glyphs in the comparison table use a WCAG AA color.

### Real screenshot
- [ ] `docs/img/statusline.png` displayed in the hero (or alongside the CSS recreation, with the CSS version clearly marked as illustrative).

### UX
- [ ] Copy-to-clipboard button on every `<pre>` block.
- [ ] Comparison table date-stamped ("As of YYYY-MM-DD").
- [ ] Footer link: "Report a pricing inaccuracy".

### SEO/meta
- [ ] `<meta name="theme-color">`.
- [ ] Absolute OG image URL.
- [ ] `<link rel="canonical">`.
- [ ] JSON-LD `SoftwareApplication` schema (name, OS, license, downloadUrl).

### Theme
- [ ] `prefers-color-scheme: dark` variant ships (page is locked to light today).

### Verification
- [ ] `scripts/responsive-check.mjs` passes on the rebuilt page across all 5 viewport widths.
- [ ] `scripts/find-overflow.mjs` passes.
- [ ] Lighthouse a11y score ≥ 95.

## Effort

L (>3 days)

## References

- `index.html`
- `docs/img/statusline.png`
- `scripts/responsive-check.mjs`, `scripts/find-overflow.mjs`

## Dependencies

Should land after M2 complete (so it can describe the actual v2 product).
'@

$issues += New-IssueDef -Code 'M5-07' `
    -Title '[M5-07] release.yml automated release workflow' `
    -Labels @('milestone:M5','effort:S','type:chore') `
    -Body @'
## Problem

Releases are manual. Tag pushes don''t produce artifacts, GitHub Releases, or PSGallery publishes.

## Acceptance criteria

- [ ] `.github/workflows/release.yml` triggers on `v*` tag push.
- [ ] Steps:
  1. Run full CI matrix (re-use M3-03 workflow via `workflow_call`).
  2. Build release zip: `{statusline-tokens.ps1, claude-statusline-tokens.psd1, pricing.json, LICENSE, examples/*}`.
  3. Create GitHub Release with body from `CHANGELOG.md` for that version.
  4. `Publish-Module -Repository PSGallery -NuGetApiKey ${{ secrets.PSGALLERY_API_KEY }}`.
- [ ] Failure on any step aborts the publish.
- [ ] Test against a `vX.Y.Z-rc1` pre-release tag before tagging v2.0.0.

## Effort

S (<1 day)

## References

- new file `.github/workflows/release.yml`

## Dependencies

Blocked by M2-06, M3-03, M5-01.
'@

$issues += New-IssueDef -Code 'M5-08' `
    -Title '[M5-08] v2.0.0 release notes + announcement' `
    -Labels @('milestone:M5','effort:S','type:release') `
    -Body @'
## Problem

Need a single coherent v2 changelog + migration note for users coming from v0.3/v1.0.

## Acceptance criteria

- [ ] `CHANGELOG.md` `[2.0.0] — YYYY-MM-DD` section enumerates every M1–M5 deliverable, grouped by Added / Changed / Fixed / Removed.
- [ ] `docs/UPGRADING.md` covers:
  - New config file location (`~/.claude/statusline-tokens.config.json`).
  - Pricing.json externalization.
  - Debug log opt-in (`$env:STATUSLINE_DEBUG`).
  - New CLI flags (`--once`, `--debug`, `--version`).
  - Hook contract changes (user-visible: none).
- [ ] GitHub Release body links to UPGRADING.md + lists top 5 user-facing changes.
- [ ] README banner ("v2 is here") with link to release notes.
- [ ] `git tag v2.0.0` and pushed (triggers M5-07).

## Effort

S (<1 day)

## References

- `CHANGELOG.md`
- new `docs/UPGRADING.md`
- `README.md`

## Dependencies

Blocked by all preceding milestones.
'@

# --- Create issues ------------------------------------------------------------

Write-Host "`nCreating $($issues.Count) issues..." -ForegroundColor Cyan

$created = @()
foreach ($i in $issues) {
    if ($DryRun) {
        Write-Host "  [dry] $($i.Code): $($i.Title)" -ForegroundColor Gray
        continue
    }

    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, $i.Body, [System.Text.UTF8Encoding]::new($false))

        $labelArgs = @()
        foreach ($l in $i.Labels) { $labelArgs += '--label'; $labelArgs += $l }

        $url = & gh issue create --title $i.Title --body-file $tmp @labelArgs 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  ok: $($i.Code) -> $url" -ForegroundColor Green
            $created += [pscustomobject]@{ Code = $i.Code; Url = $url }
        } else {
            Write-Host "  fail: $($i.Code): $url" -ForegroundColor Red
        }
    } finally {
        Remove-Item -Path $tmp -ErrorAction SilentlyContinue
    }
}

if (-not $DryRun) {
    Write-Host "`nCreated $($created.Count) / $($issues.Count) issues." -ForegroundColor Cyan
    $created | Format-Table -AutoSize | Out-String | Write-Host
}
