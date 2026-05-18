# Multi-account attribution

Claude Code lets you sign in and out of different accounts (personal, team, work). The native `rate_limits` data Anthropic injects into the status-line hook is **per-account**: when you switch accounts, the 5h/7d percentages reset because the new account has its own quota.

The token totals on this status line, however, come from your *local* transcript directory, which mixes turns from every account you've ever used. Without attribution, switching accounts would show `5h 0% (105M tokens)` — quota empty, but the local pile of transcripts hasn't moved.

This doc explains how the script attributes each transcript turn to an account so the displayed tokens and costs line up with the percentage you actually have left.

## What's in the status line

| Segment | Filter | Window | Why it's there |
|---|---|---|---|
| `5h N% (X tok, $Y)` | current account only | rolling 5h | Matches the native 5-hour rate-limit %. Tokens now match the bucket the % is reporting. |
| `7d N% (X tok, $Y)` | current account only | rolling 7d | Matches the native weekly rate-limit %. |
| `session X tok ($Y)` | **every account in the burst** | contiguous activity (see [`SESSION.md`](SESSION.md)) | "How much have I used in my current work session, regardless of account?" |

The first two reset when you sign into a different account. The `session` segment is account-independent — it captures your current burst of work even if you switch accounts mid-session.

## How the account is identified

Claude Code writes its current account state to `~/.claude.json`. Inside, the `oauthAccount` object carries:

```json
"oauthAccount": {
  "emailAddress": "you@example.com",
  "organizationUuid": "98882986-849d-4a73-8a9f-781ddc03b20c",
  "organizationName": "Your Workspace",
  "organizationType": "claude_team",
  "organizationRateLimitTier": "default_raven"
}
```

This script reads only the `oauthAccount` sub-object (via a brace-walk — see "Why not `ConvertFrom-Json` on the whole file" below). The **`organizationUuid`** is the stable identifier:

- It survives token refreshes (the access token rotates; the UUID doesn't).
- It only changes when you actually switch to a different account or workspace.
- It never leaves your machine — the script doesn't make network calls.

`emailAddress` and `organizationName` are read for display purposes only (currently only the UUID is used in the line; email/name are stored in the checkpoints file for your reference).

## Checkpoints

The script maintains a sidecar file at `~/.claude/statusline-accounts.json`:

```json
{
  "checkpoints": [
    {
      "from":  "2026-05-10T14:32:00Z",
      "org":   "98882986-849d-4a73-8a9f-781ddc03b20c",
      "email": "you@example.com",
      "name":  "Personal"
    },
    {
      "from":  "2026-05-15T09:00:00Z",
      "org":   "a51b0c33-d49d-4b73-9c2c-1bd2e9a3f44e",
      "email": "you@work.com",
      "name":  "Work, Inc."
    }
  ]
}
```

Every time the status line runs:

1. Read the current `oauthAccount.organizationUuid` from `~/.claude.json`.
2. Compare to the last checkpoint's `org`.
3. If different (or no checkpoints exist yet), append a new checkpoint with the current timestamp.

That's it. The checkpoints file grows by one entry per actual sign-in change. No background process, no Claude-Code-hooks dependency — it's all driven by status-line renders.

## Per-turn attribution

When the script scans `~/.claude/projects/**/*.jsonl`, it knows the **timestamp** of each turn. To attribute a turn to an account it asks: "which checkpoint window contains this timestamp?"

```
checkpoints: A ────────► B ────────► C ────────► (now)
              │           │           │
              t1 ←── A    t2 ←── B    t3 ←── C
```

Mechanically:

```powershell
function Account-At([DateTime]$t) {
    if (no checkpoints) { return $null }
    $acct = checkpoints[0]              # pre-history default
    for each checkpoint in order {
        if (t >= checkpoint.from) { $acct = checkpoint }
        else                     { break }
    }
    return $acct
}
```

When `$acct.org` matches the current account, the turn's tokens go into the 5h/7d/today buckets. Otherwise, they're skipped for per-account totals but still count toward the `all` segment.

## Pre-install history

**If you install the script today, all your past transcript activity is attributed to the account you're signed into right now.** That's because the earliest checkpoint is "now"; anything older than the first checkpoint falls into the `Account-At` fallback ("earliest as default").

This is a deliberate trade-off. The alternative — attributing pre-install history to "unknown" — would make installing the script look like a usage reset, which is worse UX than the small inaccuracy of mis-attributing history that probably *was* on the current account anyway.

If you've actively been switching accounts before installing, the per-account 5h/7d totals during your first 7 days post-install may include some other-account work. Once each historical window scrolls past 7 days old, it self-corrects: from then on every checkpoint is real and attribution is exact.

## Edge cases

**Brand-new install with no `~/.claude.json`:** `currentAccount` is `null`, no checkpoints are written, and the per-account filter degrades gracefully to "every turn counts as current." Status line looks exactly like the pre-v0.2 single-account version. As soon as `~/.claude.json` appears, the first checkpoint is written on the next render.

**Token refreshes:** `~/.claude.json` updates fields like `accessToken` and `expiresAt` but **not** `organizationUuid`. The script ignores everything except the UUID, so refreshes don't generate spurious checkpoints.

**Concurrent renders from multiple Claude Code windows:** The accounts file write is non-atomic, but each write is the *full* checkpoints array, so the worst case is one duplicate checkpoint entry which the script tolerates (the duplicate just doesn't change attribution). No locking; the data is small enough that the race window is sub-millisecond.

**Account deletion / re-creation:** If you delete an account on Anthropic's side and create a new one with the same email, you'll get a new `organizationUuid` and the script will treat it as a separate account. Correct behavior — usage is genuinely tied to the org's quota.

**Switching back to a previous account:** Each switch appends a new checkpoint, so going `A → B → A → B → A` produces five checkpoints. Attribution still works correctly; it just makes the accounts file slightly longer. Manual prune is fine if you want to tidy it.

## Why not `ConvertFrom-Json` on the whole `~/.claude.json`?

PowerShell 5.1's `ConvertFrom-Json` rejects JSON objects with duplicate keys. `~/.claude.json` contains a `projects` map keyed by absolute path, and Windows is case-insensitive: `C:\Users\you\Github\Foo` and `C:\Users\you\github\foo` are the same directory but produce two literally-different JSON keys. Some users (especially anyone who's renamed a folder or switched between PowerShell and `cd` with different casing) hit this.

The script's `Get-JsonObject` helper walks the file character-by-character, tracks brace depth (respecting quoted strings and escape sequences), and returns just the `oauthAccount` block. That sub-object has no duplicate keys by construction, so `ConvertFrom-Json` parses it cleanly.

## Files involved

| Path | Purpose | Written by |
|---|---|---|
| `~/.claude.json` | Claude Code's own config; contains `oauthAccount` | Claude Code |
| `~/.claude/projects/**/*.jsonl` | Per-session transcripts with `usage` blocks | Claude Code |
| `~/.claude/statusline-accounts.json` | Account checkpoint history | this script |
| `~/.claude/statusline-tokens.cache.json` | 20s result cache, keyed by current org UUID | this script |

The cache invalidates whenever `orgKey` doesn't match the current account, so switching accounts forces a fresh scan on the next render rather than serving stale numbers for up to 20 seconds.

## Privacy

Nothing in this flow is transmitted off your machine. The script reads three local files (`~/.claude.json`, the transcripts directory, and the two sidecar files it owns), computes some sums, and writes a line to stdout for Claude Code to render. The `organizationUuid` and email are stored only in `~/.claude/statusline-accounts.json`, which lives entirely under your home directory.

If you want to omit the email even from local storage, edit the checkpoint-append block in `statusline-tokens.ps1` to drop the `email` field.
