# settings.json examples

Three platform variants of the Claude Code `settings.json` entry that wires up `statusline-tokens.ps1` as the status line.

| Platform | File | PowerShell |
|----------|------|------------|
| Windows  | `settings.windows.json` | Windows PowerShell 5.1 (`powershell.exe`) |
| macOS    | `settings.macos.json`   | PowerShell 7 (`pwsh`) — install via `brew install --cask powershell` |
| Linux    | `settings.linux.json`   | PowerShell 7 (`pwsh`) — install per https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux |

Merge one of these into your existing `settings.json` at:

- Windows: `%USERPROFILE%\.claude\settings.json`
- macOS / Linux: `$HOME/.claude/settings.json`

If your Claude Code already has a `statusLine` block, replace it. If it doesn't, add it at the top level of the JSON object.
