# Security policy

`claude-statusline-tokens` is a single PowerShell script that reads local
Claude Code state files in order to render a status line. It does enough
filesystem reading that it's worth being explicit about its threat model and
what it deliberately doesn't do.

## Threat model

### What the script accesses

The script reads from your local filesystem only. Specifically:

- `~/.claude.json` — to identify the currently signed-in Claude account
  (`oauthAccount.organizationUuid`). The file also contains the OAuth tokens
  Claude Code uses to talk to Anthropic; the script **reads** that file but
  never logs, prints, caches, or transmits the OAuth fields.
- `~/.claude/projects/**/*.jsonl` — Claude Code's transcripts. The script
  reads each line and extracts only the `usage` block (token counts, cache
  metadata) and turn-level identifiers needed for dedupe. **Message bodies
  (your prompts and Claude's responses) are read off disk but are not parsed,
  logged, cached, or otherwise retained** beyond the per-line regex match.
- `~/.claude/statusline-accounts.json` — the script's own multi-account
  history file. Owned by the script. See `docs/MULTI-ACCOUNT.md`.
- `~/.claude/statusline-tokens.cache.json` — the script's own 20-second
  result cache. Owned by the script.
- `~/.claude/statusline-scoped-limits.cache.json` — the script's own cache
  of per-model weekly quotas. Owned by the script.
- `~/.claude/.credentials.json` — **read only by the detached refresh child**
  described below, and only for `claudeAiOauth.accessToken`, which is held in
  memory for the duration of one HTTPS request and never logged, printed, or
  cached. The render path does not open this file at all. Where Claude Code
  keeps credentials in an OS keychain rather than this file, nothing is read
  and no keychain prompt is raised.
- `stdin` — the hook JSON payload Claude Code passes to the status-line
  command on every render.

### What the script writes

- `~/.claude/statusline-accounts.json` (its own history).
- `~/.claude/statusline-tokens.cache.json` (its own cache).
- `~/.claude/statusline-scoped-limits.cache.json` (its own cache — percentages
  and reset timestamps only; no token, no credential material).
- `~/.claude/statusline-scoped-limits.lock` (a zero-byte spawn guard, created
  and then removed by the refresh child).

That is the complete list. Those four files are the only things the script
creates or modifies.

> A debug log at `~/.claude/statusline-tokens.log`, gated behind a
> `STATUSLINE_DEBUG` environment variable, is [planned][debug-log] but **not
> implemented** — `Write-DebugLog` is currently an intentional no-op, so no
> log file is written under any circumstances. This document previously
> listed it as though it shipped.

[debug-log]: https://github.com/Gabriel-Dalton/claude-statusline-tokens/issues/17

It does **not** modify `~/.claude.json`, the transcript JSONLs, or
`~/.claude/settings.json` (the setup script modifies `settings.json` once,
with a confirmation prompt and a `.bak` backup; the runtime statusline script
does not).

### The one network call

As of v0.5.0 the script makes exactly one outbound request, and it is worth
stating precisely because earlier versions of this document promised none.

- **Endpoint:** `GET https://api.anthropic.com/api/oauth/usage` — Anthropic's
  own usage endpoint, the same one Claude Code's `/usage` command reads. No
  third-party host is contacted, ever.
- **Why:** the per-model weekly quota (today, the Fable 5 limit) exists in no
  local file and is not included in the status-line hook payload, which
  carries the `five_hour` and `seven_day` buckets only. There is no local
  source to read it from.
- **What is sent:** the `Authorization: Bearer` header and nothing else. No
  request body, no telemetry, no identifier the script invents. Nothing about
  your projects, prompts, transcripts, or costs is transmitted.
- **What is received and kept:** a percentage and a reset timestamp per
  scoped window, written to `statusline-scoped-limits.cache.json`. The access
  token is never written to it. The failure path deliberately logs no
  response body, because an auth failure can echo request headers back.
- **Where it runs:** in a detached child process, never on the render path,
  at most once per `STATUSLINE_SCOPED_TTL` (default 900 s) across every open
  Claude Code window, guarded by an atomically created lock file.
- **How to disable it:** `STATUSLINE_SCOPED_LIMITS=0` (or `off`/`false`/`no`)
  skips the segment, the cache read and the request. With that set, the
  statements below about network access hold unconditionally.

The script never refreshes the OAuth token itself. An expired token
short-circuits before any request is made; renewal is Claude Code's job, and
racing it on the refresh endpoint could invalidate a live session.

### What the script does not do

- **No telemetry.** Nothing about your usage, projects, or accounts leaves
  your machine. The one request above sends no data about you beyond the
  credential that authenticates it.
- **No third-party hosts.** The only origin contacted is
  `api.anthropic.com`, which Claude Code itself already talks to.
- **No exfiltration.** OAuth state from `~/.claude.json` and the access token
  from `~/.claude/.credentials.json` are read in-process and are never
  written to any output, log, or cache.
- **No credential writes.** The script never modifies `.credentials.json` and
  never attempts a token refresh.
- **No process spawning** other than the optional `git rev-parse
  --abbrev-ref HEAD` invocation used to render the branch name, and the
  detached copy of itself that performs the refresh above (spawned with
  stdout/stderr redirected away from the status line, at most once per
  refresh interval). (An earlier pre-M1-09 implementation also shelled out to
  read `.git/HEAD`; that path has been removed.)

## What's sensitive

If you publicly post the script's output or any of its supporting files,
keep these in mind:

- **OAuth tokens in `~/.claude.json`** are the most sensitive thing on the
  filesystem the script touches. The script never surfaces them, but if you
  share that file you're sharing your Claude Code login. Don't.
- **Transcript content in `~/.claude/projects/**/*.jsonl`** can contain
  anything you've ever pasted into Claude Code — source code, secrets,
  customer data. The script only parses `usage` blocks, but the files on disk
  contain everything. Treat the transcripts directory like you'd treat a
  shell history file: don't share it without redaction.
- **The access token in `~/.claude/.credentials.json`** is the same class of
  secret. The refresh child reads it and never persists it, but the file
  itself is your Claude Code login — don't share it.
- **Cache/accounts files** (`statusline-tokens.cache.json`,
  `statusline-accounts.json`, `statusline-scoped-limits.cache.json`) contain
  token counts, dollar totals, quota percentages, and organization UUIDs. The
  UUIDs are not secrets per se, but they identify your Claude org; redact
  them if you're posting cache output publicly.

## Reporting a vulnerability

Please **do not** open a public issue for security reports. Instead, use
GitHub's private Security Advisory workflow:

[Report a vulnerability](https://github.com/Gabriel-Dalton/claude-statusline-tokens/security/advisories/new)

That keeps the conversation private until a fix is ready and gives you a
formal CVE/GHSA channel if the issue warrants one.

If for some reason you can't use GitHub Security Advisories, open a regular
issue that says only "security report, please contact me out-of-band" — no
details — and I'll reach out.

I'll acknowledge security reports on a best-effort basis (this is a small
hobby project, not a funded program), and I'll prioritize anything that
involves the script reading or writing outside its documented files,
exfiltrating local state, executing untrusted input, or accidentally logging
OAuth tokens.

## Supported versions

This is a pre-1.0 project still iterating through v2. Only the **latest
released version** receives security fixes during v2 development. If you're
running a fork or an older commit, please update to the latest tag before
filing a report — or include a clear note that you've reproduced the issue
on the latest `main`.
