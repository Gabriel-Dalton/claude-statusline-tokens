# Contributing

Thanks for considering a contribution. This project is intentionally small — a single PowerShell script plus docs — and the goal is to stay that way. The contribution bar is therefore "does this make the script clearly better without growing its scope?"

## What's wanted

High-priority work, in rough order:

1. **bash / zsh port** — macOS and Linux users have the same `~/.claude/projects/**/*.jsonl` layout. A roughly equivalent shell script (or pwsh-7 cross-platform variant) would let this whole project work everywhere.
2. **Price-table updates** — when Anthropic publishes new rates, a PR that updates `$prices` and `docs/PRICING.md` is appreciated. Include a link to the announcement in the PR body.
3. **New model family rates** — if you use a Claude model variant or a proxy that emits Claude-compatible `usage` blocks, adding it to `$prices` and `Get-ModelFamily` is a small, useful PR.
4. **Bug fixes** with reproductions — especially anything where the displayed numbers diverge from what `ccusage` reports for the same window.

## What's not wanted

- **Scope creep.** This is a status line. It isn't a full analytics dashboard, billing exporter, alert system, or Prometheus integration. Those are great projects — they aren't this project.
- **Dependencies.** No npm packages, no `Install-Module`, no .NET nugets. The point of this script is "drop in one file, it works."
- **Refactors for their own sake.** If the diff doesn't change observable behavior or measurably improve perf, it probably isn't worth reviewing.

## Development setup

You need:

- Windows 10 or 11 (or Server equivalent)
- PowerShell 5.1 (ships with Windows) — *not* PowerShell 7 for compatibility testing
- `git` on `PATH`
- A populated `~/.claude/projects/` directory (i.e. you've used Claude Code at least a bit)

Run the script with a synthetic hook for fast iteration:

```powershell
$j = '{"session_id":"test","model":{"display_name":"Opus 4.7"},"workspace":{"current_dir":"."},"transcript_path":"","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":"2026-01-01T00:00:00Z"},"seven_day":{"used_percentage":17,"resets_at":"2026-01-01T00:00:00Z"}}}'
$j | powershell -NoProfile -ExecutionPolicy Bypass -File .\statusline-tokens.ps1
```

Set `$cacheTtlSec = 0` while iterating so each run rescans.

## Code style

- Target **PowerShell 5.1**. No `??`, no `?:`, no `-ErrorAction Stop` chains that depend on PS7 behavior.
- Prefer `[Console]::Out.Write(...)` over `Write-Host` for the final output (avoids extra newlines and respects redirection).
- Use `[regex]` cached objects for any pattern run in a hot loop; `-match` re-parses the regex per call.
- Keep functions short. The script is mostly top-level for a reason — it reads like a recipe, not an object graph.

## Submitting a PR

1. Fork, branch from `main`.
2. Make the change, run the test invocation above, verify the output looks right.
3. Update `CHANGELOG.md` under `[Unreleased]` with one bullet describing the change.
4. Open the PR with:
   - What changed and why (one paragraph)
   - A before/after of the rendered status line, if your change is visual
   - A note if you changed anything in `$prices` or `Get-ModelFamily`, with a source link for the new rate

I'll review on a best-effort basis. Small, focused PRs land faster.

## Reporting issues

When opening an issue, include:

- Claude Code version (`claude-code --version` or check the about/help screen)
- PowerShell version (`$PSVersionTable.PSVersion`)
- Windows version (`winver`)
- The exact status line you see vs. what you expected
- If pricing looks wrong: the output of running the script and the output of `ccusage` for comparison

A few minutes of context up front saves an hour of back-and-forth.

## License

By contributing you agree your code is offered under the [MIT License](LICENSE).
