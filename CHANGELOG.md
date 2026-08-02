# Changelog

All notable changes to `claude-statusline-tokens` are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

_Nothing yet._

## [0.6.0] - 2026-08-01

### Added

- **One set of numbers across every open window.** `rate_limits` is per-session hook data: Claude Code refreshes it for a window when *that* window gets an API response, so two terminals side by side would show 44% and 42% and both were honestly reporting what they had been told. The quota is one number per account; only its storage was per-window.

  The figures now go through a shared, account-scoped store at `~/.claude/statusline-limits.cache.json`. Each render folds in what its own hook said and then draws what the store holds. Reads and writes run inside a cross-process mutex, so two windows rendering at once cannot lose each other's update.

  A window also no longer shows `--%` before its first API response of the session — it picks up the account's real figure immediately.

- **`STATUSLINE_SCOPED_ACTIVE_TTL`** (default `90` seconds). A per-model bar has no hook source at all, so it used to move only on the flat 15-minute poll: a Fable turn would land and the segment would sit on a number up to fifteen minutes old. The script now watches transcripts for turns on a model that has a bar, and refreshes on the short interval when one has run since the last successful fetch. Idle models still poll at `STATUSLINE_SCOPED_TTL`, and the failure backoff overrides both.

- **`refreshInterval` in the documented settings snippet.** Claude Code's status line events go quiet while a session is idle, which would leave an idle window drawing whatever it last drew — including numbers the other windows have since moved past.

- **A test suite**, `tests/run-all.ps1`: 53 assertions across four files, each driving the real script end to end with hook JSON on stdin and asserting against the rendered line. Suites build a throwaway profile, so nothing touches your `~/.claude`.

### Fixed

- **Token and cost totals now describe the same window as the percentage.** They never did: the percentage came from a fixed window ending at `resets_at`, while the totals were a rolling "last five hours from now". Close enough to agree most of the time, and maximally wrong at the moment a window resets — the percentage dropped to zero while the totals carried on reporting the window that had just ended. Cutoffs are now derived from the reset stamp, clamped to one window length so a stale stamp cannot widen the window and over-count, and a roll invalidates the token cache immediately rather than at the end of its TTL.

- **A per-model bar's reset timestamp is normalised to UTC when it is cached**, rather than being stringified as-is. `ConvertFrom-Json` returns a string for it today, but on a payload shape where it materialises a `[DateTime]`, the previous cast would have written machine-local wall-clock with no offset — which the reader takes as UTC and shifts by the host's offset.

- **An endpoint row with no reset timestamp is dropped rather than merged window-blind**, and is no longer carried forward forever by the failure path. The usage endpoint does emit such rows: a session bar read in the instant after a reset came back with a null `resets_at`.

### Changed

- Token cache schema `2` -> `3` (per-turn model id, for the activity-driven refresh above). Older caches are discarded, costing one full rescan on upgrade.

## [0.5.0] - 2026-08-01

### Added

- **Fable 5 weekly limit.** Claude Code meters its premium models on a weekly window separate from the plan-wide weekly limit — `/usage` draws it as its own bar, and internally it is the `seven_day_overage_included` bucket, labelled "Fable 5 limit". Exhausting it takes Fable off the table for the rest of the week while the ordinary weekly limit still has headroom, which is precisely the state worth seeing coming.

  ```
  7d 17% (4.8M tok, $18.20, resets 4d6h @ Sun 6am) | fable 61% (resets 4d6h @ Sun 6am)
  ```

  **It is not in the hook payload, and cannot be made to be.** Claude Code builds the status line's `rate_limits` object from `five_hour` and `seven_day` alone. The Fable window, `seven_day_opus` and `seven_day_sonnet` are all live in the same process — parsed off the `anthropic-ratelimit-unified-*` response headers — and none of them are forwarded. That is why no status line shows this number, this one included until now.

  It is fetched instead from `GET /api/oauth/usage`, the endpoint `/usage` itself reads, where the window arrives as a `limits[]` entry with `kind: "weekly_scoped"` and `scope.model.display_name`. The segment is built from whatever scoped windows the account actually has rather than a hardcoded "Fable", so a second one appearing server-side renders without a code change, and an account with none renders nothing at all.

  **The render path still makes no network call.** It reads a small cache file; when that cache passes its TTL the render spawns a *detached* copy of the script to do the fetch, and the result lands on the next render. Blocking the status line on HTTP would stall the prompt on every miss, and a seven-day window does not move fast enough for the extra interval to be visible. Measured: renders stay flat, and the fetch adds nothing to them.

  The spawn is guarded by an atomically created lock file (`File.Open` with `CreateNew`), so ten Claude Code windows re-rendering on their own schedules produce one request per interval between them rather than ten. A lock orphaned by a killed process is cleared after 120 seconds by the render that finds it, and the *next* render takes it cleanly — recovery stays off the hot path.

  **The interval is 15 minutes, not 5, and failures back off.** The endpoint rate-limits — discovered the direct way, by earning a 429 during development — and Claude Code polls it too, so an over-eager status line can land a 429 on the user's own `/usage` command. On a seven-day window a tighter interval buys precision nobody can act on. Consecutive failed requests double the interval to a one-hour ceiling and a success resets it, so an outage is not answered by knocking every fifteen minutes indefinitely. Only requests that actually reached the network count; the short-circuit paths (expired token, no credentials file) cost the endpoint nothing and retry normally.

  Staleness degrades honestly rather than silently: a percentage that has not refreshed in three hours renders `--%` instead of passing an old number off as current. Three rather than one, because the backoff can legitimately stretch to hourly retries and a gate tighter than the retry interval would blank a number that is merely waiting rather than wrong. The reset countdown deliberately survives that gate, on the same reasoning as the cached `resets7d` fallback — a weekly reset timestamp stays true for days, and elapsed values are dropped anyway. The cache is account-scoped like every other window here, so a switch discards it and refetches instead of replaying the previous org's percentage.

  Credential handling: the OAuth access token is read from `~/.claude/.credentials.json`, held in memory for the request, and never logged, printed, or written to the cache — `~/.claude/statusline-scoped-limits.cache.json` carries percentages and timestamps only, and the failure path deliberately logs no response body, since an auth failure can echo the request headers back. An expired token short-circuits before any request is made; refreshing it is Claude Code's job, and racing it on the refresh endpoint could invalidate the live session. Where credentials live in an OS keychain rather than that file, the segment stays hidden — no prompt, no keychain access.

- **`STATUSLINE_SCOPED_LIMITS=0`** (`off` / `false` / `no`) disables the segment, the cache read and the network call in one switch, and **`STATUSLINE_SCOPED_TTL`** sets the refresh interval in seconds (default `900`).

### Changed

- **The README's "No network calls, no telemetry" claim is now accurate again.** It was a headline feature and this release breaks half of it, so the bullet says what is actually true: no telemetry and no third parties, one endpoint of Anthropic's own, off the render path, and one environment variable back to fully local. Quietly leaving the old wording in place would have been the worst version of this change.

## [0.4.1] - 2026-07-29

### Added

- **Priciest-turn readout in `claude-dashboard.ps1`** (#30) — the companion to the loop watch, covering the other failure shape in the same critique: one turn that costs a fortune on its own rather than a loop of cheap ones.

  Reported but **not alarmed on by default**, because the shape turns out not to be reachable. A single turn is capped by the context window plus max output, fixing its worst case at $13.20 on Opus 5, $26.40 on Fable 5, $7.92 on Sonnet 5. Against an observed 5-hour window of ~$187, the absolute worst an Opus 5 turn can do is 7.1% of it — one turn cannot blow a 5-hour budget, while an accumulating loop demonstrably can.

  An absolute threshold also misfires in practice. The priciest turn in a real session was $7.47; inspection showed 740,427 tokens of *cache creation* against 1,968 tokens of output — a one-off cache priming that makes every subsequent turn cheap. Expensive, entirely healthy, and precisely what a $2.00 floor would have flagged red. `STATUSLINE_SPIKE_FLOOR` opts into an alarm for anyone who wants one (worth it on legacy Opus, ceiling $39.60).

  This closes out #30 without implementing its σ-based design, which #41 replaced.

- **Loop watch in `claude-dashboard.ps1`** (#41). Flags a repeating tool pattern that is burning tokens — an agent re-running the same command, or cycling between two files, without making progress.

  Detection is by **repetition, not cost anomaly**. #30 proposed a 3-sigma-above-mean test, which fails on precisely the case most worth catching: a loop of individually cheap turns drags the session mean toward itself and collapses the variance, so it scores *lower* the longer it runs (0.17 sigma at 5 turns, 0.07 at 80, in simulation). Worse, it inverts — past ~40 loop turns an ordinary turn scores 4.4 sigma and gets flagged as the anomaly instead. Repetition is a structural property of the call sequence, so no estimator can be contaminated.

  Repetition alone is not the alarm: a deliberate poll-until-ready loop repeats too. The alarm is repetition **plus** accumulated tokens crossing a floor — polling stays cheap and renders as `repeating but cheap`, while a runaway loop re-reads the whole context each turn and crosses it fast.

  A sliding window is used rather than consecutive-identical matching, so an alternating A,B,A,B loop is caught (verified: it trips at 2 distinct calls, where consecutive matching would score 0 repeats). The flagged stretch grows outward from the worst window while it stays repetitive, so the reported span is the loop rather than an arbitrary 10-turn slice.

  Thresholds default to `10,3,1000000` and are overridable with `STATUSLINE_LOOP_WATCH=window,maxDistinct,tokenFloor`. Calibrated against 18 real sessions / 1,000 tool calls in which healthy work never dropped below 8 distinct calls per 10-turn window, and exact identical consecutive calls never occurred at all.

  Confined to the dashboard: no change to `statusline-tokens.ps1`, no cache-schema bump, and nothing added to the per-render hot path. Only lines containing `"tool_use"` get a full JSON parse (~100 of many thousands), and the harvest runs before the message-id de-duplication, which would otherwise discard the tool_use lines in favour of a turn's first content block.

  Design credit: @Keesan12 on #30.

## [0.4.0] - 2026-07-29

### Added

- **Context fill percentage** (#27). The `ctx` segment now renders `ctx 63.0k (6%)`, taking the percentage from `context_window.used_percentage` in the hook payload. A raw token count can't say how full the window is, because it says nothing about the window's size: 63k reads like a third of a 200k model but is 6% of a 1M one. When the field is absent — older Claude Code, early in a session, or just after `/compact` — output is byte-identical to before, and the token count remains the fallback.

- **`scripts/verify-tokens.ps1` — independently re-derives the token totals.** "It says I used 168 million tokens today" is the most common reaction to this status line, and the honest answer needed evidence rather than a hand-wave. The verifier deliberately shares no code with the status line: that one extracts fields with regex for speed, this one does a full `ConvertFrom-Json` parse of every transcript line. Two independent implementations landing on the same total means the number isn't an artifact of the parsing strategy — on the reference run they agreed to 0.00%. It also breaks the total into the four billing categories (a measured session was 97.7% cache read, 2.3% genuinely new work), prints the confirming `turns × average context = cache-read total` arithmetic, and reports the pre-dedupe line count so the de-duplication can be seen working rather than trusted.
- **FAQ section on the landing page**, with matching `FAQPage` structured data — leading with why the token number looks impossibly large, since that's the question that costs the project trust.
- **`robots.txt`, `sitemap.xml` and `llms.txt`.** The last is a plain-text summary aimed at answer engines, covering the token-accounting explanation and the full pricing table.
- **`scripts/make-og-card.ps1`** generates the 1200×630 social card, so the card can be regenerated whenever the sample status line changes instead of drifting out of date.
- **Fable 5 / Mythos 5 pricing** — $10.00 / $50.00 per MTok (cache read $1.00, 5m write $12.50, 1h write $20.00), matched on `fable|mythos`. `claude-dashboard.ps1` gains a matching bucket in its per-model breakdown, shown only once Fable has usage so the existing layout is unchanged for everyone else.
- **The reset countdown now survives a payload with no `rate_limits`.** The last-seen reset timestamp is persisted to `~/.claude/statusline-tokens.cache.json` (`resets5h`, `resets7d`, stored as round-trip ISO-8601 UTC) and reused on renders where Claude Code omits the field — which is every render before its first response of a session. The fallback is scoped to the signed-in account, so a switch discards the previous org's window instead of replaying it, and elapsed values are dropped rather than shown stale.
- Durations under a minute render as `<1m` instead of a bare `0m`.

### Changed

- The reset countdown is now labelled: `5h 42% (15.3M tok, $25.07, resets 2h14m @ 12:38pm)`. Previously the countdown sat unlabelled at the end of the parenthesised group, where `3d15h @ Wed 3pm` was easy to read as something other than a reset time.

- **`claude-dashboard.ps1` — full-screen live usage dashboard.** Run it in its own PowerShell window for a re-rendering view of the 5-hour and 7-day rate-limit windows (with progress bars + the same authoritative percentages the statusline shows), the current session, a top-projects table, a per-model (opus/sonnet/haiku) tokens-and-cost breakdown, and a 24-hour activity sparkline. Reuses the statusline's JSONL scan and account-attribution logic so the two views agree on every number. Refresh interval is configurable (`-RefreshSeconds`, default 20s); `-Once` renders a single frame and exits.
- **`setup.ps1` — one-command installer.** `git clone … && cd … && .\setup.ps1` copies both scripts into `~/.claude/`, shows a JSON diff and asks before merging the `statusLine` block into `~/.claude/settings.json`, backs up the original to `settings.json.bak`, smoke-tests the statusline, and offers to launch the dashboard once so you can see what you got. Flags: `-DryRun` (preview-only), `-NonInteractive` (CI mode), `-SkipDashboardPreview`, `-Uninstall` (reverses the install and optionally restores the backup).
- **`dashboard.ps1` — thin launcher at the repo root.** Forwards args (`-Once`, `-RefreshSeconds`, …) to the installed `~/.claude/claude-dashboard.ps1`, or falls back to the in-repo copy if you haven't run setup yet. Lets new users `git clone … && cd … && .\dashboard.ps1 -Once` to see the dashboard immediately, before deciding whether to install.
- `statusline-tokens.ps1` now persists the most recent `rate_limits.{five_hour,seven_day}.used_percentage` values from the hook payload into `~/.claude/statusline-tokens.cache.json` (new fields: `pct5h`, `pct7d`, `pctSavedAtUtc`). The dashboard reads these so its progress bars reflect the authoritative quota numbers — not a local approximation. Stale values (>10 min old) fall back to a "--%" rendering rather than misleading.
- The statusline now rewrites `~/.claude/statusline-tokens.cache.json` on every invocation (previously only on cache miss). This keeps the persisted percentages fresh for the dashboard even when the token totals come from the cache. Cost is negligible — the write is a few hundred bytes of JSON.
- All reads of `~/.claude.json`, `~/.claude/statusline-accounts.json`, and `~/.claude/statusline-tokens.cache.json` now use `Get-Content -Raw -Encoding UTF8`. Prevents corruption when an organization name or other JSON field contains non-ASCII characters.
- README install section rewritten with a fast path (one-liner download + JSON merge) and a guided path (eight verifiable steps + troubleshooting block) so first-time Claude Code users can install without prior PowerShell or `settings.json` experience.

### Fixed

- **Documentation described features that do not exist.** `SECURITY.md` listed `~/.claude/statusline-tokens.log` among the files the script writes, under a heading that is the whole point of a security document — but `Write-DebugLog` is an intentional no-op stub, so that file is never created under any circumstances. `docs/ARCHITECTURE.md` described the script as "~240 lines" against an actual 1,179. The cache-schema examples in `ARCHITECTURE.md` and `CUSTOMIZE.md` still showed the five-field v0.2 payload, omitting `schemaVersion`, `orgKey`, `pct5h`/`pct7d`, `resets5h`/`resets7d` and the per-transcript tail cache. `docs/MULTI-ACCOUNT.md` referred to a `today` bucket and an `all` segment that the status line has never rendered.

- **Social previews produced no image at all.** `og:image` pointed at a relative path (`./docs/img/statusline.png`); crawlers don't resolve those, so Twitter, LinkedIn, Slack and Discord had nothing to render. Now an absolute URL to a purpose-built 1200×630 card — the previous image was a 940×106 strip at a 24:1 ratio, which no social crop handles.
- **Landing page showed pre-price-drop figures.** Every sample dollar amount was computed at the old $15/$75 Opus rate and was therefore ~3× too high; the model was shown as Opus 4.7, and the `session` segment was missing from both the sample line and the segment table ("six segments" when the bar renders seven). Samples now show the reset countdown too.
- Page-level SEO gaps: no canonical URL, no `og:url` / `og:type` / `og:site_name`, no Twitter title/description/image, no structured data. Google Fonts loaded render-blocking from a third-party origin, which shows up directly in Largest Contentful Paint; now loaded non-blockingly with a `<noscript>` fallback.

- **The reset countdown never rendered.** `Fmt-Reset` parsed `resets_at` with `[DateTime]::Parse`, but Claude Code sends it as a **Unix epoch integer** — the parse threw, the `catch` swallowed it, and the segment was silently omitted on every render. Because the failure was indistinguishable from "the hook didn't send the field", it survived an earlier debugging pass. Timestamps now go through a `ConvertTo-ResetUtc` normalizer that accepts epoch seconds, epoch milliseconds, ISO-8601 with or without an offset, and a live `[DateTime]`.
- **Opus was billed at 3× its actual rate.** `$prices.opus` carried $15/$75 per MTok, the pre-Opus-4.5 rate. Opus 4.5 and everything after it (4.6, 4.7, 4.8, Opus 5) is $5/$25, so every cost figure for current traffic was roughly tripled. Split into `opus` ($5/$25) and `opusLegacy` ($15/$75, for Opus 4.1 / 4.0 / Opus 3), matched by model ID so a transcript spanning both eras still totals correctly.
- **Timezone-dependent timestamp handling.** Every `[DateTime]::Parse(...).ToUniversalTime()` has been replaced with `TryParse` under `AssumeUniversal | AdjustToUniversal`. The old form reads a timestamp *without* an offset as host-local, so the same transcript produced different 5h/7d windows depending on the machine's timezone — on US Pacific, a naive stamp shifted 7–8 hours into the future and pulled turns into the window that didn't belong there. `Fmt-AbsLocal` now also guards `DateTimeKind`, since `ToLocalTime()` is a silent no-op on an `Unspecified` value and would print UTC as though it were local.
- Percentages rounded with banker's rounding, so `42.5%` rendered as `42%` while `43.5%` rendered as `44%`. Now uses `MidpointRounding::AwayFromZero`.
- A cached scan whose `computedAtUtc` was missing or unparseable was treated as fresh. It now counts as infinitely old, forcing a rescan rather than trusting numbers of unknown vintage.
- **Mojibake on the 5h / 7d segments while the percentages are loading** (when `rate_limits` is absent from the hook payload — typical at session start or right after an account switch). The earlier two-part fix (UTF-8 BOM on the source file + runtime `[char]0x2014` for the em-dash) was insufficient: some terminals / status-line consumers still decoded the UTF-8 bytes (`0xE2 0x80 0x94`) as Windows-1252 and rendered `â€"`. The loading-state placeholder is now plain ASCII (`--%`, e.g. `5h --% (103.8M tok, $300)`), which removes the encoding failure mode entirely. The BOM and runtime construction are retained as defence-in-depth for any other non-ASCII glyphs that may appear in user-supplied fields (org names, directory names, etc.).

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
