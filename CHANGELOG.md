# Changelog

All notable changes to `claude-statusline-tokens` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.4.0] - 2026-07-29

### Added

- **`scripts/verify-tokens.ps1` — independently re-derives the token totals.** "It says I used 168 million tokens today" is the most common reaction to this status line, and the honest answer needed evidence rather than a hand-wave. The verifier deliberately shares no code with the status line: that one extracts fields with regex for speed, this one does a full `ConvertFrom-Json` parse of every transcript line. Two independent implementations landing on the same total means the number isn't an artifact of the parsing strategy — on the reference run they agreed to 0.00%. It also breaks the total into the four billing categories (a measured session was 97.7% cache read, 2.3% genuinely new work), prints the confirming `turns × average context = cache-read total` arithmetic, and reports the pre-dedupe line count so the de-duplication can be seen working rather than trusted.
- **FAQ section on the landing page**, with matching `FAQPage` structured data — leading with why the token number looks impossibly large, since that's the question that costs the project trust.
- **`robots.txt`, `sitemap.xml` and `llms.txt`.** The last is a plain-text summary aimed at answer engines, covering the token-accounting explanation and the full pricing table.
- **`scripts/make-og-card.ps1`** generates the 1200×630 social card, so the card can be regenerated whenever the sample status line changes instead of drifting out of date.

### Fixed

- **Social previews produced no image at all.** `og:image` pointed at a relative path (`./docs/img/statusline.png`); crawlers don't resolve those, so Twitter, LinkedIn, Slack and Discord had nothing to render. Now an absolute URL to a purpose-built 1200×630 card — the previous image was a 940×106 strip at a 24:1 ratio, which no social crop handles.
- **Landing page showed pre-price-drop figures.** Every sample dollar amount was computed at the old $15/$75 Opus rate and was therefore ~3× too high; the model was shown as Opus 4.7, and the `session` segment was missing from both the sample line and the segment table ("six segments" when the bar renders seven). Samples now show the reset countdown too.
- Page-level SEO gaps: no canonical URL, no `og:url` / `og:type` / `og:site_name`, no Twitter title/description/image, no structured data. Google Fonts loaded render-blocking from a third-party origin, which shows up directly in Largest Contentful Paint; now loaded non-blockingly with a `<noscript>` fallback.

- **The reset countdown never rendered.** `Fmt-Reset` parsed `resets_at` with `[DateTime]::Parse`, but Claude Code sends it as a **Unix epoch integer** — the parse threw, the `catch` swallowed it, and the segment was silently omitted on every render. Because the failure was indistinguishable from "the hook didn't send the field", it survived an earlier debugging pass. Timestamps now go through a `ConvertTo-ResetUtc` normalizer that accepts epoch seconds, epoch milliseconds, ISO-8601 with or without an offset, and a live `[DateTime]`.
- **Opus was billed at 3× its actual rate.** `$prices.opus` carried $15/$75 per MTok, the pre-Opus-4.5 rate. Opus 4.5 and everything after it (4.6, 4.7, 4.8, Opus 5) is $5/$25, so every cost figure for current traffic was roughly tripled. Split into `opus` ($5/$25) and `opusLegacy` ($15/$75, for Opus 4.1 / 4.0 / Opus 3), matched by model ID so a transcript spanning both eras still totals correctly.
- **Timezone-dependent timestamp handling.** Every `[DateTime]::Parse(...).ToUniversalTime()` has been replaced with `TryParse` under `AssumeUniversal | AdjustToUniversal`. The old form reads a timestamp *without* an offset as host-local, so the same transcript produced different 5h/7d windows depending on the machine's timezone — on US Pacific, a naive stamp shifted 7–8 hours into the future and pulled turns into the window that didn't belong there. `Fmt-AbsLocal` now also guards `DateTimeKind`, since `ToLocalTime()` is a silent no-op on an `Unspecified` value and would print UTC as though it were local.
- Percentages rounded with banker's rounding, so `42.5%` rendered as `42%` while `43.5%` rendered as `44%`. Now uses `MidpointRounding::AwayFromZero`.
- A cached scan whose `computedAtUtc` was missing or unparseable was treated as fresh. It now counts as infinitely old, forcing a rescan rather than trusting numbers of unknown vintage.

### Added

- **Fable 5 / Mythos 5 pricing** — $10.00 / $50.00 per MTok (cache read $1.00, 5m write $12.50, 1h write $20.00), matched on `fable|mythos`. `claude-dashboard.ps1` gains a matching bucket in its per-model breakdown, shown only once Fable has usage so the existing layout is unchanged for everyone else.
- **The reset countdown now survives a payload with no `rate_limits`.** The last-seen reset timestamp is persisted to `~/.claude/statusline-tokens.cache.json` (`resets5h`, `resets7d`, stored as round-trip ISO-8601 UTC) and reused on renders where Claude Code omits the field — which is every render before its first response of a session. The fallback is scoped to the signed-in account, so a switch discards the previous org's window instead of replaying it, and elapsed values are dropped rather than shown stale.
- Durations under a minute render as `<1m` instead of a bare `0m`.

### Changed

- The reset countdown is now labelled: `5h 42% (15.3M tok, $25.07, resets 2h14m @ 12:38pm)`. Previously the countdown sat unlabelled at the end of the parenthesised group, where `3d15h @ Wed 3pm` was easy to read as something other than a reset time.

- **`claude-dashboard.ps1` — full-screen live usage dashboard.** Run it in its own PowerShell window for a re-rendering view of the 5-hour and 7-day rate-limit windows (with progress bars + the same authoritative percentages the statusline shows), the current session, a top-projects table, a per-model (opus/sonnet/haiku) tokens-and-cost breakdown, and a 24-hour activity sparkline. Reuses the statusline's JSONL scan and account-attribution logic so the two views agree on every number. Refresh interval is configurable (`-RefreshSeconds`, default 20s); `-Once` renders a single frame and exits.
- **`setup.ps1` — one-command installer.** `git clone … && cd … && .\setup.ps1` copies both scripts into `~/.claude/`, shows a JSON diff and asks before merging the `statusLine` block into `~/.claude/settings.json`, backs up the original to `settings.json.bak`, smoke-tests the statusline, and offers to launch the dashboard once so you can see what you got. Flags: `-DryRun` (preview-only), `-NonInteractive` (CI mode), `-SkipDashboardPreview`, `-Uninstall` (reverses the install and optionally restores the backup).
- **`dashboard.ps1` — thin launcher at the repo root.** Forwards args (`-Once`, `-RefreshSeconds`, …) to the installed `~/.claude/claude-dashboard.ps1`, or falls back to the in-repo copy if you haven't run setup yet. Lets new users `git clone … && cd … && .\dashboard.ps1 -Once` to see the dashboard immediately, before deciding whether to install.
- `statusline-tokens.ps1` now persists the most recent `rate_limits.{five_hour,seven_day}.used_percentage` values from the hook payload into `~/.claude/statusline-tokens.cache.json` (new fields: `pct5h`, `pct7d`, `pctSavedAtUtc`). The dashboard reads these so its progress bars reflect the authoritative quota numbers — not a local approximation. Stale values (>10 min old) fall back to a "--%" rendering rather than misleading.

### Changed

- The statusline now rewrites `~/.claude/statusline-tokens.cache.json` on every invocation (previously only on cache miss). This keeps the persisted percentages fresh for the dashboard even when the token totals come from the cache. Cost is negligible — the write is a few hundred bytes of JSON.

### Fixed

- **Mojibake on the 5h / 7d segments while the percentages are loading** (when `rate_limits` is absent from the hook payload — typical at session start or right after an account switch). The earlier two-part fix (UTF-8 BOM on the source file + runtime `[char]0x2014` for the em-dash) was insufficient: some terminals / status-line consumers still decoded the UTF-8 bytes (`0xE2 0x80 0x94`) as Windows-1252 and rendered `â€"`. The loading-state placeholder is now plain ASCII (`--%`, e.g. `5h --% (103.8M tok, $300)`), which removes the encoding failure mode entirely. The BOM and runtime construction are retained as defence-in-depth for any other non-ASCII glyphs that may appear in user-supplied fields (org names, directory names, etc.).

### Changed

- All reads of `~/.claude.json`, `~/.claude/statusline-accounts.json`, and `~/.claude/statusline-tokens.cache.json` now use `Get-Content -Raw -Encoding UTF8`. Prevents corruption when an organization name or other JSON field contains non-ASCII characters.
- README install section rewritten with a fast path (one-liner download + JSON merge) and a guided path (eight verifiable steps + troubleshooting block) so first-time Claude Code users can install without prior PowerShell or `settings.json` experience.

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
