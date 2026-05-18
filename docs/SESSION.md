# Session-based "current burst" tracking

The `session` segment is a deliberately fuzzy concept: it shows the tokens and cost of your **current burst of contiguous work** — independent of clock-midnight, calendar day, or which Claude account is signed in.

This doc explains the rule, the rationale, and the edge cases.

## The rule

A "session" is the chain of turns ending at the most recent one, where:

1. The most recent turn is **within `$sessionGapMinutes` of now** (default: 30 minutes), AND
2. Every consecutive pair of turns in the chain has a gap **≤ `$sessionGapMinutes`**.

In plain English: "the most recent stretch where you didn't step away for more than 30 minutes."

The chain is computed across **every** transcript on disk — every project, every Claude Code window, every account. Account identity is irrelevant for this calculation.

## Why session, not "today"

A naïve "today" implementation has three failure modes that all show up in real use:

1. **Midnight cuts your session in half.** If you're heads-down at 11:50 PM, the count resets at 00:00 — same workload, two reported numbers, no useful boundary.
2. **Account switches across midnight create phantom redundancy.** "Today on this account" and "today across all accounts" look identical until you mix accounts, then they look weirdly the same anyway when one account dominates.
3. **It doesn't match how you experience work.** Coding bursts have natural rhythms — sprint, break, sprint. "Today" lumps lunch breaks, meetings, and overnight breaks together with active work.

The session rule fixes all three by anchoring the window to your actual activity pattern rather than the wall clock.

## What the number means

```
session 1.2M ($4.50)
```

This is "**total tokens and cost** across the contiguous burst leading up to right now." If you've been alternating between accounts during that burst — say, debugging on a work account and answering questions on a personal one — both contribute to this number. That's by design: the session is *your* work session, not the account's.

If you want to know the per-account portion of the session, look at `5h`. The 5h window is current-account-only and almost always overlaps the session (a session can't be longer than 5h of active work without crossing the 5h boundary). The difference between `session` and `5h` is roughly "what you spent on other accounts during this same burst."

## Boundary semantics

**No active session.** If your most recent turn is more than `$sessionGapMinutes` ago, there's nothing to display — `session 0 ($0.00)`. This means "you don't have a session in progress right now." When you send your next message, that turn seeds a new session.

**Single turn.** A brand-new session shows just the seed turn's numbers — small, growing as you go.

**Gap exactly at the threshold.** A gap of *exactly* 30 minutes is considered "within session." Only gaps strictly greater terminate the walk.

**Multiple bursts in the past.** Only the **most recent** burst is reported. Earlier bursts (separated by a gap > threshold) are ignored.

**Continuing a long burst.** If you've been working continuously for 7 hours, the session captures all 7 hours — there's no upper limit. Long sessions are fine; the only thing that ends a session is inactivity.

**Boundary independence from the 5h rate-limit block.** Anthropic's 5h block resets on a schedule tied to your account, not your activity. Your session can span a 5h rate-limit reset and stays unified. The `5h` segment will reset; the `session` segment won't.

## Tuning the gap threshold

`$sessionGapMinutes` is the single knob, set near the top of `statusline-tokens.ps1`:

```powershell
$sessionGapMinutes = 30
```

| Value | Effect | Good if you… |
|---|---|---|
| 15 | Tight — bathroom breaks split sessions | want fine-grained burst detection |
| 30 (default) | Industry-standard "active session" | …match most people's intuition |
| 60 | Loose — long thinking breaks stay in session | take long calls or pair frequently |
| 120 | Very loose — lunch counts as part of one session | want "morning" vs "afternoon" granularity |
| 240 | Coarse — almost entirely "today-without-overnight" | want big work-block granularity |

Set it once, change it any time. The cache auto-invalidates per scan, so changes take effect within the next ~20 seconds of activity.

## Performance

Session detection runs after the main transcript scan. It:

1. Builds an in-memory list of every `(timestamp, tokens, cost)` tuple seen during scan.
2. Sorts the list descending by timestamp.
3. Walks from newest to oldest, stopping at the first gap > threshold.

On a 19MB transcript pile with ~8000 turns, this adds roughly 70ms to the cold scan. Subsequent renders within 20s hit the cache and skip the work entirely.

## Edge cases

**Clock skew.** Transcript timestamps come from Claude Code (which stamps them at API request time using its own clock). The script compares them to `[DateTime]::UtcNow`. If your machine clock drifts a few minutes, the "is the latest turn within 30 min of now" check is forgiving enough to handle that.

**Sub-second turns.** A burst of rapid tool calls produces many turns within seconds. Each is one entry; the gap is microseconds. No issue.

**Daylight saving transitions.** Everything is in UTC internally. DST has no effect.

**Sessions spanning the 7-day file-mtime filter.** The scan only opens `.jsonl` files modified within the last 7 days. A session that started >7d ago is theoretically possible (constant activity for 7+ days), but at that point you have bigger problems than a status line.

## Why not key on `session_id` from the hook?

Claude Code does inject a `session_id` field into the status-line hook JSON. We could in principle filter transcripts by `sessionId` to get "this Claude Code window's session." But that misses the user-intuitive meaning of "session":

- A Claude Code restart starts a new `session_id` but is the same coding burst → bad split.
- Two Claude Code windows have different `session_id`s but are the same continuous work → bad split.
- A long break with no restart keeps the same `session_id` but is intuitively a separate session → bad merge.

Activity-based session detection (gap walking) matches the user's mental model much better than process identity.
