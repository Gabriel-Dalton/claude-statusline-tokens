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
- `stdin` — the hook JSON payload Claude Code passes to the status-line
  command on every render.

### What the script writes

- `~/.claude/statusline-accounts.json` (its own history).
- `~/.claude/statusline-tokens.cache.json` (its own cache).
- `~/.claude/statusline-tokens.log` — only when the `STATUSLINE_DEBUG`
  environment variable is set, and only with debug trace lines the script
  itself emits.

It does **not** modify `~/.claude.json`, the transcript JSONLs, or
`~/.claude/settings.json` (the setup script modifies `settings.json` once,
with a confirmation prompt and a `.bak` backup; the runtime statusline script
does not).

### What the script does not do

- **No network calls.** Zero `Invoke-WebRequest`, `Invoke-RestMethod`,
  `System.Net.*`, or equivalent. The script's render is purely local.
- **No telemetry.** Nothing about your usage, projects, or accounts leaves
  your machine.
- **No exfiltration.** OAuth state from `~/.claude.json` is read in-process
  to extract an account identifier and is never written to any output, log,
  or cache.
- **No process spawning** other than the optional `git rev-parse
  --abbrev-ref HEAD` invocation used to render the branch name. (An earlier
  pre-M1-09 implementation also shelled out to read `.git/HEAD`; that path
  has been removed.)

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
- **Cache/accounts files** (`statusline-tokens.cache.json`,
  `statusline-accounts.json`) contain token counts, dollar totals, and
  organization UUIDs. The UUIDs are not secrets per se, but they identify
  your Claude org; redact them if you're posting cache output publicly.

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
