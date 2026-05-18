# Changelog

All notable changes to `claude-statusline-tokens` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.3.0] — 2026-05-18

### Changed (breaking)

- **Removed** the `today` (current-account, calendar-day) and `all` (every-account, calendar-day) segments.
- **Added** a single `session` segment that captures your current burst of contiguous work — independent of clock-midnight, Claude Code restarts, and account switches.

### Why

Calendar-day boundaries split coding sessions in half whenever midnight falls in the middle of a burst. The `today` and `all` segments also reported the same number whenever you didn't switch accounts that day, which was visual noise. Replacing both with an activity-driven session segment eliminates both problems.

### Added

- `$sessionGapMinutes` config knob (default `30`). A session ends when the gap between consecutive turns exceeds this many minutes.
- "No active session" UX: if your most recent turn is more than the gap threshold ago, the session segment renders `0` instead of freezing on the last burst's stale total. New activity seeds a fresh session.
- New doc: [`docs/SESSION.md`](../docs/SESSION.md) covering the session rule, rationale, tuning, and edge cases.

### Removed

- `tokDayA`, `costDayA`, `tokDayAll`, `costDayAll` from the cache schema. Replaced by `tokSession` / `costSession`. The cache file format is incompatible with v0.2.x — delete `~/.claude/statusline-tokens.cache.json` after upgrading (or just wait 20 seconds for it to expire and be overwritten).

## [0.2.0] — 2026-05-18

### Added

- **Multi-account attribution.** Reads `oauthAccount.organizationUuid` from `~/.claude.json` to detect the currently signed-in account; appends a new checkpoint to `~/.claude/statusline-accounts.json` whenever the org UUID changes.
- 5h, 7d, and "today" totals now **filter to the current account**, so they match the percentage shown.
- New **"all today"** segment summing today's tokens + cost **across every account** (since local-time midnight).
- Cache invalidates automatically when the active account changes (cache file now stores `orgKey`).
- `Get-JsonObject` brace-walking helper to extract sub-objects from `~/.claude.json` without parsing the whole file (sidesteps PS 5.1's rejection of duplicate keys in the `projects` map).
- New doc: [`docs/MULTI-ACCOUNT.md`](../docs/MULTI-ACCOUNT.md) covering the attribution model, checkpoint format, edge cases, and privacy posture.

### Changed

- The 5h and 7d numbers are no longer "all transcripts in window" — they're "current account's transcripts in window." On a fresh install this is identical; after your first account switch, they correctly reset.
- README pricing table now refers to "API-equivalent" cost explicitly to keep subscription users from being surprised.

## [0.1.0] — 2026-05-17

Initial release.

### Added

- 5-hour and 7-day rate-limit windows rendered with **percentage + token count + dollar cost**.
- Per-turn pricing using each turn's `message.model` — sessions that mix model families produce correctly blended costs.
- 5m vs 1h ephemeral cache-write rates applied separately, read from `cache_creation.ephemeral_{5m,1h}_input_tokens` when present.
- Regex-based JSONL scanning across `~/.claude/projects/**/*.jsonl` (mtime-filtered to the last 7 days).
- Dedup by `message.id` to avoid triple-counting multi-content-block assistant turns.
- 20-second on-disk result cache at `~/.claude/statusline-tokens.cache.json`.
- UTF-8 forced output encoding to prevent code-page downgrade of glyphs/em-dashes/etc.
- Working-directory, git-branch, model-display-name, and context-tokens segments.
- 256-color ANSI output, all swappable in one place near the bottom of the script.
- Embedded Anthropic price table for Opus / Sonnet / Haiku 4.x.
