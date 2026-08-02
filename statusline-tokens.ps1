#Requires -Version 5.1
# Custom status line: 5h + 7d windows with native percentages AND token totals.
# Percentages come from rate_limits.{five_hour,seven_day}.used_percentage injected
# by Claude Code on stdin. Tokens are summed from ~/.claude/projects/**/*.jsonl
# entries whose timestamps fall inside the rolling 5h / 7d window.

param(
    # Set only on the detached child this script spawns to refresh the
    # per-model weekly quota out of band. See the scoped-limits block below.
    [switch]$RefreshScopedLimits,
    [string]$OrgKey = ''
)

[System.Threading.Thread]::CurrentThread.CurrentCulture =
    [System.Globalization.CultureInfo]::InvariantCulture

# Timestamp parsing contract, applied everywhere this script reads a time:
#   AdjustToUniversal - a stamp carrying an offset is converted to UTC
#   AssumeUniversal   - a stamp carrying none is read as UTC, NOT as local
# Without the second flag, a naive timestamp is interpreted in the host's
# timezone, so the same transcript would produce different windows on a
# Pacific machine than on a UTC one.
$script:utcParseStyles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor `
                         [Globalization.DateTimeStyles]::AssumeUniversal

# Stub: M2-05 will route to a rotating log at ~/.claude/statusline-tokens.log
# when $env:STATUSLINE_DEBUG is set. For now this swallows quietly.
function Write-DebugLog {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline=$true, Position=0)]
        [object]$Message,
        [string]$Scope = ''
    )
    # Intentional no-op until M2-05.
}

# Normalize an arbitrary timestamp into a UTC [DateTime], or $null.
#
# `rate_limits.*.resets_at` is not a fixed shape. Claude Code sends a Unix
# epoch (seconds), this script's own cache round-trips ISO-8601, and
# ConvertFrom-Json hands back a live [DateTime] on some payload shapes.
# The previous implementation called [DateTime]::Parse directly, which threw
# on the epoch form; the catch swallowed it and the reset countdown silently
# never rendered — the failure looked exactly like "Claude Code didn't send
# the field", so it survived a debugging pass.
#
# Timezone contract: the returned value is always Kind=Utc. A timestamp that
# carries offset information is converted; one that carries none is *assumed*
# to be UTC rather than machine-local, so output never varies with the host's
# timezone. Conversion to local time happens only at render.
function ConvertTo-ResetUtc($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [DateTime]) {
        # Kind is load-bearing: ToUniversalTime() on an Unspecified DateTime
        # treats it as local and shifts it by the host offset (7-8 hours on
        # US Pacific, depending on DST).
        if ($value.Kind -eq [DateTimeKind]::Utc)   { return $value }
        if ($value.Kind -eq [DateTimeKind]::Local) { return $value.ToUniversalTime() }
        return [DateTime]::SpecifyKind($value, [DateTimeKind]::Utc)
    }
    $text = ([string]$value).Trim()
    if ([string]::IsNullOrEmpty($text)) { return $null }
    if ($text -match '^\d+$') {
        $n = 0L
        if (-not [long]::TryParse($text, [ref]$n)) { return $null }
        if ($n -le 0) { return $null }
        $epoch = New-Object DateTime(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
        # 1e11 seconds lands in the year 5138, so anything larger is millis.
        if ($n -gt 100000000000) { return $epoch.AddMilliseconds($n) }
        return $epoch.AddSeconds($n)
    }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse($text, [Globalization.CultureInfo]::InvariantCulture,
                             $script:utcParseStyles, [ref]$parsed)) {
        return [DateTime]::SpecifyKind($parsed, [DateTimeKind]::Utc)
    }
    Write-DebugLog "unparseable timestamp: $text" -Scope 'timestamp-parse'
    return $null
}

# Safe dotted-path accessor for the parsed hook JSON (M1-10).
# Anthropic can rename or remove any field in Claude Code's stdin hook
# payload between releases; reaching into $hook.X.Y directly silently
# produces $null when the path is broken, which downstream segments then
# render as blanks or zeroes with no indication of why. Get-HookField
# walks the dotted path defensively, returns $Fallback when any segment
# is missing, and emits exactly one Write-DebugLog line per fallback
# (scope 'hook-field-missing') so the regression is surface-able once
# M2-05 wires the log file.
function Get-HookField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][AllowNull()]$Hook,
        [Parameter(Mandatory=$true)][string]$DottedPath,
        [Parameter()]$Fallback = $null,
        [Parameter()][switch]$NoLog
    )
    $node = $Hook
    if ($null -eq $node) {
        if (-not $NoLog) {
            Write-DebugLog "missing hook.$DottedPath (no hook)" -Scope 'hook-field-missing'
        }
        return $Fallback
    }
    foreach ($seg in $DottedPath.Split('.')) {
        if ($null -eq $node) {
            if (-not $NoLog) {
                Write-DebugLog "missing hook.$DottedPath" -Scope 'hook-field-missing'
            }
            return $Fallback
        }
        # PSCustomObject (the shape ConvertFrom-Json returns) exposes
        # PSObject.Properties; missing properties give $null without
        # throwing. Test for the property's existence before reading so
        # we don't accept a property that's literally set to $null vs
        # one that's absent. Both behave identically for our callers
        # (the fallback path fires), but the distinction matters for
        # future consumers that might want to differentiate.
        $hasProp = $false
        if ($node -is [System.Management.Automation.PSCustomObject]) {
            $hasProp = ($node.PSObject.Properties.Match($seg).Count -gt 0)
        } elseif ($node -is [System.Collections.IDictionary]) {
            $hasProp = $node.Contains($seg)
        } else {
            # Last resort: try the property via reflection. Don't blow
            # up on primitive types (strings, ints) that happen to land
            # here when a dotted path runs past a leaf.
            try { $hasProp = ($null -ne $node.$seg) } catch { $hasProp = $false }
        }
        if (-not $hasProp) {
            if (-not $NoLog) {
                Write-DebugLog "missing hook.$DottedPath" -Scope 'hook-field-missing'
            }
            return $Fallback
        }
        $node = $node.$seg
    }
    if ($null -eq $node) {
        # The full path resolved but the leaf itself is JSON null. For
        # our callers that's indistinguishable from "missing" — surface
        # the fallback and log.
        if (-not $NoLog) {
            Write-DebugLog "missing hook.$DottedPath (null leaf)" -Scope 'hook-field-missing'
        }
        return $Fallback
    }
    return $node
}

# Cross-platform user profile resolution. [Environment]::GetFolderPath
# returns "" rather than $null on non-Windows when the folder is unknown,
# so we explicitly fall through. $HOME is set by PowerShell on all
# platforms; $env:USERPROFILE is Windows-only and kept as a last resort.
# Resolved this early because the scoped-limits child below runs before the
# stdin read and needs the same paths the render path uses.
$userProfile = [Environment]::GetFolderPath('UserProfile')
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $HOME }
if ([string]::IsNullOrEmpty($userProfile)) { $userProfile = $env:USERPROFILE }

# --- per-model weekly quota (Fable) ---------------------------------------
# Claude Code meters its premium models on their own weekly window — today
# Fable 5, which it tracks internally as 'seven_day_overage_included' and
# labels "Fable 5 limit". It does NOT forward that bucket on the status line
# hook: the payload it builds carries five_hour and seven_day and nothing
# else, so there is no field to read no matter how the hook JSON is parsed.
#
# The number is only reachable from GET /api/oauth/usage — the same endpoint
# /usage draws its bars from — where it arrives as a limits[] entry with
# kind 'weekly_scoped' and scope.model.display_name set to the model.
#
# So this script fetches it itself, out of band, in two halves:
#   * the render path NEVER makes a network call; it reads a cache file
#   * when that cache is older than $scopedTtlSec, the render spawns a
#     detached copy of this same script with -RefreshScopedLimits, which
#     does the fetch and rewrites the cache for the *next* render
# A status line that blocked on HTTP would violate the "always print
# something fast" contract the bounded stdin read below exists to protect,
# so the value shown is always up to one refresh interval behind. For a
# seven-day window that is invisible.
#
# Credential handling: the OAuth access token is read from
# ~/.claude/.credentials.json into memory for the duration of the request
# and is never logged, printed, or written to the cache — the cache holds
# only percentages and reset timestamps. An expired token short-circuits
# before any request is made. Refreshing it is Claude Code's job, not ours:
# racing it on the refresh endpoint could invalidate the live session.
# On platforms where Claude Code keeps credentials in an OS keychain rather
# than that file (macOS), the file is simply absent and the segment stays
# hidden — no prompt, no keychain access, no error surfaced to the user.
$scopedCachePath = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-scoped-limits.cache.json')
$scopedLockPath  = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-scoped-limits.lock')

# --- shared limit store: one set of numbers for every open window ---------
# The percentages on this line arrive on the hook stdin, and Claude Code
# fills rate_limits in per session: a window only learns the new figure when
# *it* gets an API response. Two windows open side by side therefore drift
# apart — the one you just used reads 44%, the one idle since lunch still
# reads 42% — and both are honestly reporting what they were handed. The
# quota itself is one number per account, so the disagreement is an artifact
# of where the number is kept, not of what it is.
#
# This file is that one number, on disk, shared by every window. Each render
# folds in whatever its own hook just said, then renders what the store
# holds rather than what it was personally told.
#
# Merge rule, per bucket:
#   * resets_at is the window's identity. A later one means the window
#     rolled, so the incoming observation replaces the old outright — usage
#     drops to near zero at a reset, and a high-water mark would otherwise
#     pin the display at the previous window's number.
#   * Within one window, the observation whose *information* is most recent
#     wins, in either direction. Ties break on the larger figure, since
#     usage only accumulates inside a window.
#
# The load-bearing idea is that second clause, and specifically that it
# compares information age rather than values. Every observation carries
# when its observer last actually heard from the server:
#   * a hook payload -> that window's transcript mtime. Claude Code
#     refreshes rate_limits when the session gets an API response and writes
#     the assistant turn at the same moment, so the file's mtime is a local,
#     network-free proxy for "when was this window last told the truth".
#   * an endpoint reading -> when it was fetched.
#
# The first shape of this took the maximum instead, reasoning that usage is
# monotonic within a fixed window so the larger figure must be the newer
# one. That is true of the underlying quota and false of the readings.
# Claude Code can advance five_hour.resets_at before it refreshes
# five_hour.used_percentage, so a reading arrives pairing the NEW window's
# stamp with the OLD window's number: the roll clause accepts it, the
# maximum clause then refuses every honest lower reading that follows, and
# the segment sits on that number for a full five hours. Observed in the
# wild — 50% shown against a real usage of 3%.
#
# Comparing information age handles both directions with one rule. An idle
# window re-rendering its own stale 42% loses to a live 44% because its
# transcript is twenty minutes cold, not because 42 < 44 — and that same
# rule refuses the same window's stale 50% after a roll, which the maximum
# could not.
$limitsStorePath = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-limits.cache.json')
# 2: buckets carry knownAtUtc (information age). A v1 store's values have no
# provenance, so they are discarded rather than trusted.
$limitsSchema    = 2
# Same-window tolerance. Two observations of one window carry the same
# resets_at give or take precision: the hook sends whole epoch seconds, the
# usage endpoint sends microseconds. Distinct windows are five hours or
# seven days apart, so anything under two minutes is the same window.
$limitsWindowTolSec = 120

# Bucket keys. '5h' and '7d' are fed by both the hook and the usage
# endpoint; 'scoped:<name>' only ever by the endpoint, because Claude Code
# does not forward per-model quotas on the status line hook at all.
$limitsKey5h = '5h'
$limitsKey7d = '7d'

function Read-LimitsStore([string]$Path, [string]$Org) {
    $buckets = @{}
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path $Path)) { return $buckets }
    $raw = $null
    # Opened sharing ReadWrite *and* Delete so this read can never make
    # another window's swap fail. File.ReadAllText would deny Delete, which
    # turns a reader into the reason a writer loses its update. One retry
    # covers the instant the file is mid-swap; a torn or locked read
    # degrades this render to hook-only values, which is the pre-store
    # behavior rather than a wrong number.
    foreach ($attempt in 1..2) {
        $fs = $null; $sr = $null
        try {
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
            $sr = New-Object System.IO.StreamReader($fs)
            $raw = $sr.ReadToEnd()
            break
        } catch { Start-Sleep -Milliseconds 20 }
        finally {
            if ($sr) { try { $sr.Dispose() } catch {} }
            if ($fs) { try { $fs.Dispose() } catch {} }
        }
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $buckets }
    try {
        $doc = $raw | ConvertFrom-Json -ErrorAction Stop
        # Quota windows are per-account. Replaying another org's percentage
        # after a switch would be a confident lie, so a store belonging to
        # anyone else is discarded rather than migrated.
        if ([string]$doc.orgKey -ne $Org) { return $buckets }
        if ([int]$doc.schemaVersion -ne $script:limitsSchema) { return $buckets }
        foreach ($prop in $doc.buckets.PSObject.Properties) {
            $b = $prop.Value
            if ($null -eq $b) { continue }
            $entry = @{
                name          = [string]$b.name
                percent       = [double]$b.percent
                observedAtUtc = ConvertTo-ResetUtc $b.observedAtUtc
                resetsAtUtc   = ConvertTo-ResetUtc $b.resetsAtUtc
                knownAtUtc    = ConvertTo-ResetUtc $b.knownAtUtc
            }
            if ($null -eq $entry.observedAtUtc) { continue }
            if ($null -eq $entry.knownAtUtc) { $entry.knownAtUtc = [DateTime]::MinValue }
            $buckets[$prop.Name] = $entry
        }
    } catch { Write-DebugLog $_ -Scope 'limits-store-read' }
    return $buckets
}

# Fold one observation into $Store, which is mutated in place.
#   $Percent      0-100
#   $ResetsUtc    the window this figure belongs to, or $null
#   $ObservedUtc  when this render looked (drives the staleness gate)
#   $KnownAtUtc   when the *observer* last learned its figure — see above
function Merge-LimitObservation($Store, [string]$Key, [string]$Name, $Percent, $ResetsUtc, [DateTime]$ObservedUtc, $KnownAtUtc) {
    if ($null -eq $Store -or [string]::IsNullOrEmpty($Key) -or $null -eq $Percent) { return }
    $p = $null
    if ($Percent -is [double] -or $Percent -is [int] -or $Percent -is [long] -or
        $Percent -is [decimal] -or $Percent -is [single]) {
        $p = [double]$Percent
    } else {
        $parsed = 0.0
        if ([double]::TryParse([string]$Percent, [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { $p = $parsed }
    }
    if ($null -eq $p) { return }
    # A figure outside 0-100 means the payload shape changed under us.
    # Refusing it keeps a renamed field from writing nonsense into a store
    # every other window then reads back as gospel.
    if ($p -lt 0 -or $p -gt 100) {
        Write-DebugLog "out-of-range percent for $Key`: $p" -Scope 'limits-merge'
        return
    }

    $known = [DateTime]::MinValue
    if ($KnownAtUtc) { $known = [DateTime]$KnownAtUtc }

    $incoming = @{ name = $Name; percent = $p; observedAtUtc = $ObservedUtc
                   resetsAtUtc = $ResetsUtc; knownAtUtc = $known }
    $old = $Store[$Key]
    if ($null -eq $old) { $Store[$Key] = $incoming; return }

    # Window identity first: a later resets_at means the window rolled and
    # everything about the old one is void, whoever reports it.
    if ($old.resetsAtUtc -and $ResetsUtc) {
        $delta = ($ResetsUtc - $old.resetsAtUtc).TotalSeconds
        if ($delta -gt $script:limitsWindowTolSec)  { $Store[$Key] = $incoming; return }
        if ($delta -lt -$script:limitsWindowTolSec) { return }
    }

    # Within one window, the observer who learned its figure most recently
    # wins — in either direction. Ties break on the larger figure, since
    # usage only accumulates.
    $oldKnown = [DateTime]::MinValue
    if ($old.knownAtUtc) { $oldKnown = [DateTime]$old.knownAtUtc }
    if (($known -gt $oldKnown) -or ($known -eq $oldKnown -and $p -gt [double]$old.percent)) {
        # Keep whichever reset stamp we have; the endpoint's is more precise
        # than the hook's whole-second epoch but they describe the same
        # instant, so either is correct to display.
        if (-not $incoming.resetsAtUtc) { $incoming.resetsAtUtc = $old.resetsAtUtc }
        # observedAtUtc only ever moves forward. One render merges the hook
        # observation (stamped now) and then the cached endpoint observation
        # (stamped when it was *fetched*, minutes older); the second would
        # otherwise drag the freshness stamp backwards, and the staleness
        # gate reads that stamp, so a stamp that can go backwards is a stamp
        # that can blank a live bar.
        if ($old.observedAtUtc -and ([DateTime]$old.observedAtUtc) -gt $ObservedUtc) {
            $incoming.observedAtUtc = $old.observedAtUtc
        }
        $Store[$Key] = $incoming
        return
    }

    # This observer knows nothing more recent than what we already hold, so
    # its figure is refused whichever way it points. observedAtUtc still
    # moves forward, because something did just confirm the bucket is being
    # watched — it must not look stale merely because the number is settled.
    if ((-not $old.observedAtUtc) -or ($ObservedUtc -gt [DateTime]$old.observedAtUtc)) {
        $old.observedAtUtc = $ObservedUtc
    }
    if (-not $old.resetsAtUtc -and $ResetsUtc) { $old.resetsAtUtc = $ResetsUtc }
    $Store[$Key] = $old
}

function Write-LimitsStore([string]$Path, [string]$Org, $Store) {
    if ([string]::IsNullOrEmpty($Path) -or $null -eq $Store) { return }
    $out = @{}
    foreach ($k in $Store.Keys) {
        $b = $Store[$k]
        $row = @{ name = [string]$b.name; percent = [double]$b.percent }
        # ISO-8601 round-trip ('o'), never a raw [DateTime]: ConvertTo-Json
        # writes those as "\/Date(...)\/", which pins the file to one
        # serializer's private format.
        if ($b.observedAtUtc) { $row.observedAtUtc = ([DateTime]$b.observedAtUtc).ToString('o') }
        if ($b.resetsAtUtc)   { $row.resetsAtUtc   = ([DateTime]$b.resetsAtUtc).ToString('o') }
        if ($b.knownAtUtc -and ([DateTime]$b.knownAtUtc) -gt [DateTime]::MinValue) {
            $row.knownAtUtc = ([DateTime]$b.knownAtUtc).ToString('o')
        }
        $out[$k] = $row
    }
    $body = @{ schemaVersion = $script:limitsSchema; orgKey = $Org; buckets = $out } |
        ConvertTo-Json -Compress -Depth 5
    # Write-then-swap so a concurrent reader sees either the whole old file
    # or the whole new one, never half of each. The pid suffix keeps two
    # windows from fighting over one temp name.
    $ownPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
    $tmp = '{0}.{1}.tmp' -f $Path, $ownPid
    $bak = '{0}.{1}.bak' -f $Path, $ownPid
    try {
        [System.IO.File]::WriteAllText($tmp, $body, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path $Path) {
            # The backup path is required, not optional. File.Replace has no
            # two-argument overload, and passing $null for the third one
            # does not reach .NET as null: PowerShell binds it to a [string]
            # parameter as "", and ReplaceFile rejects that with "The path
            # is not of a legal form". That exception landed in the catch
            # below, so every write after the very first one silently did
            # nothing and the store froze at its initial value while each
            # window still rendered its own merge correctly — which made it
            # look like a display bug rather than a write that never landed.
            [System.IO.File]::Replace($tmp, $Path, $bak)
        } else {
            [System.IO.File]::Move($tmp, $Path)
        }
    } catch {
        Write-DebugLog $_ -Scope 'limits-store-write'
        # Last resort: a plain overwrite. It gives up atomicity, so a reader
        # can catch it mid-write — which Read-LimitsStore already treats as
        # "no store this render" rather than as bad data.
        try { [System.IO.File]::WriteAllText($Path, $body, (New-Object System.Text.UTF8Encoding($false))) } catch {}
    } finally {
        foreach ($leftover in @($tmp, $bak)) {
            try { Remove-Item -LiteralPath $leftover -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

# Read, merge, write — all inside one cross-process lock, because they are
# one operation. Without it two windows can read the same store, each fold
# in its own observation, and the second write erases the first: the very
# lost update this file exists to prevent. An uncontended mutex costs
# microseconds, and the whole critical section is one small file.
#
# $Observations is a list of hashtables: key, name, percent, resetsUtc,
# observedUtc. Returns the merged store whether or not the lock was taken,
# so a render that loses the lock still displays correct numbers — it just
# does not contribute its own observation this time round.
function Sync-LimitsStore([string]$Path, [string]$Org, $Observations) {
    # Named per store path so an isolated profile (a test, a second user)
    # never contends with the real one. 'Local\' scopes it to the logon
    # session, which is the same boundary the profile directory has.
    $mutexName = $null
    try {
        $sha = New-Object Security.Cryptography.SHA1Managed
        $tag = [BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant()))).Replace('-', '').Substring(0, 16)
        $mutexName = 'Local\claude-statusline-limits-' + $tag
    } catch { $mutexName = $null }

    $mutex = $null
    $held  = $false
    if ($mutexName) {
        try {
            $mutex = New-Object System.Threading.Mutex($false, $mutexName)
            # A render that cannot get in within a quarter second is better
            # off rendering than blocking the prompt on a file lock.
            try { $held = $mutex.WaitOne(250) }
            catch [System.Threading.AbandonedMutexException] {
                # Held by a window that was killed. The lock is ours now,
                # and the store is a plain merge target, so there is no
                # half-finished state to repair.
                $held = $true
            }
        } catch { Write-DebugLog $_ -Scope 'limits-store-lock'; $held = $false }
    }

    try {
        $store = Read-LimitsStore $Path $Org
        foreach ($o in $Observations) {
            if (-not $o) { continue }
            Merge-LimitObservation $store $o.key $o.name $o.percent $o.resetsUtc $o.observedUtc $o.knownUtc
        }
        if ($held) { Write-LimitsStore $Path $Org $store }
        return $store
    } finally {
        if ($held -and $mutex) { try { $mutex.ReleaseMutex() } catch {} }
        if ($mutex) { try { $mutex.Dispose() } catch {} }
    }
}

# A bucket whose window has already elapsed holds a percentage for a quota
# period that no longer exists. Nobody has refreshed it yet, so the honest
# render is '--%' rather than last window's number.
function Get-LiveBucket($Store, [string]$Key, [DateTime]$NowUtc) {
    if ($null -eq $Store) { return $null }
    $b = $Store[$Key]
    if ($null -eq $b) { return $null }
    if ($b.resetsAtUtc -and ([DateTime]$b.resetsAtUtc) -le $NowUtc) { return $null }
    return $b
}

function Get-ScopedLimitsPayload([string]$CachePath, [string]$Org) {
    # Seed from whatever is already on disk so a failed refresh keeps the
    # last good numbers instead of blanking the segment. A cache belonging
    # to a different org is discarded outright — quota windows are
    # per-account, and replaying another account's percentage is a
    # confident lie rather than a stale truth.
    $payload = @{
        attemptedAtUtc = [DateTime]::UtcNow.ToString('o')
        orgKey         = $Org
        status         = 'error'
        limits         = @()
        failures       = 0
    }
    try {
        if (Test-Path $CachePath) {
            $prev = Get-Content -Raw -LiteralPath $CachePath | ConvertFrom-Json
            if ([string]$prev.orgKey -eq $Org) {
                if ($prev.fetchedAtUtc) { $payload.fetchedAtUtc = [string]$prev.fetchedAtUtc }
                if ($prev.PSObject.Properties.Match('failures').Count -gt 0) {
                    $payload.failures = [int]$prev.failures
                }
                # A row with no reset stamp is unusable downstream — the
                # window guard cannot run on it — and re-seeding it on every
                # failed refresh keeps it alive forever. Drop it here so one
                # bad reading does not become permanent.
                $payload.limits = @(@($prev.limits) |
                    Where-Object { $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.resetsAt) } |
                    ForEach-Object {
                    # A cache written before this file carried per-kind rows
                    # holds weekly_scoped entries and nothing else, so an
                    # absent kind is that. Assuming it keeps an upgrade from
                    # discarding the last good per-model number.
                    $k = [string]$_.kind
                    if ([string]::IsNullOrWhiteSpace($k)) { $k = 'weekly_scoped' }
                    @{ kind = $k; name = [string]$_.name; percent = [double]$_.percent; resetsAt = [string]$_.resetsAt }
                })
            }
        }
    } catch { Write-DebugLog $_ -Scope 'scoped-cache-read' }

    $credPath = [System.IO.Path]::Combine($userProfile, '.claude', '.credentials.json')
    if (-not (Test-Path $credPath)) { $payload.status = 'no-credentials'; return $payload }

    $token = $null
    try {
        $oauth = (Get-Content -Raw -LiteralPath $credPath | ConvertFrom-Json).claudeAiOauth
        if ($null -eq $oauth) { $payload.status = 'no-credentials'; return $payload }
        # expiresAt is Unix milliseconds. Firing a request we already know
        # will 401 just burns a round trip and adds auth noise on the
        # account; Claude Code refreshes the token on its own schedule and
        # the next render picks it up.
        if ($oauth.expiresAt) {
            $expUtc = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$oauth.expiresAt).UtcDateTime
            if ($expUtc -le [DateTime]::UtcNow) { $payload.status = 'token-expired'; return $payload }
        }
        $token = [string]$oauth.accessToken
    } catch {
        Write-DebugLog $_ -Scope 'scoped-credentials'
        $payload.status = 'credentials-unreadable'
        return $payload
    }
    if ([string]::IsNullOrWhiteSpace($token)) { $payload.status = 'no-token'; return $payload }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' `
            -Method Get -TimeoutSec 10 -Headers @{
                'Authorization'  = "Bearer $token"
                'anthropic-beta' = 'oauth-2025-04-20'
                'Content-Type'   = 'application/json'
            }
    } catch {
        # Deliberately logged without the exception's response body: an auth
        # failure can echo request headers, and the token is one of them.
        Write-DebugLog "usage endpoint request failed" -Scope 'scoped-fetch'
        $payload.status = 'request-failed'
        # Only a request that actually went out counts toward the backoff.
        # The short-circuit paths above (expired token, no credentials file)
        # cost the endpoint nothing, so they retry on the normal interval.
        $payload.failures = [Math]::Min($payload.failures + 1, 6)
        return $payload
    } finally { $token = $null }

    # limits[] holds one entry per bar /usage draws. All three kinds are
    # kept now, not just the per-model one:
    #   session       -> the 5h window, the same quota the hook reports
    #   weekly_all    -> the 7d window, likewise
    #   weekly_scoped -> a per-model weekly quota ('Fable' today),
    #                    identified by scope.model.display_name
    # The first two look redundant against the hook, and are, right up
    # until every window has been idle long enough that no hook has carried
    # a fresh figure. This endpoint is account-wide and does not care which
    # window asks, so it is what lets an idle window converge on the truth
    # without needing a turn of its own first.
    # Any other kind is ignored, so a new bar appearing server-side cannot
    # corrupt the segment.
    $found = @()
    foreach ($lim in @($resp.limits)) {
        $kind = [string]$lim.kind
        if ($kind -ne 'session' -and $kind -ne 'weekly_all' -and $kind -ne 'weekly_scoped') { continue }
        $name = ''
        if ($lim.scope -and $lim.scope.model) { $name = [string]$lim.scope.model.display_name }
        # A scoped bar with no model name cannot be labelled or keyed, so
        # it is dropped rather than rendered as an anonymous percentage.
        if ($kind -eq 'weekly_scoped' -and [string]::IsNullOrWhiteSpace($name)) { continue }
        # Normalized to ISO-8601 UTC here rather than stringified raw.
        # ConvertFrom-Json hands back a plain string today, but on a payload
        # shape where it materializes a [DateTime] instead, a bare [string]
        # cast would emit machine-local wall-clock with no offset — which
        # the reader then takes as UTC and shifts by the host's offset.
        $rUtc = ConvertTo-ResetUtc $lim.resets_at
        $found += @{
            kind     = $kind
            name     = $name
            percent  = [double]$lim.percent
            resetsAt = $(if ($rUtc) { $rUtc.ToString('o') } else { '' })
        }
    }
    $payload.limits       = $found
    $payload.fetchedAtUtc = [DateTime]::UtcNow.ToString('o')
    $payload.status       = 'ok'
    $payload.failures     = 0
    return $payload
}

# Child entry point. Runs before the stdin read on purpose: the detached
# process has no hook JSON to wait on, it would otherwise burn the 200 ms
# stdin budget and print the "no hook input" fallback, and this branch must
# never fall through into the render path.
if ($RefreshScopedLimits) {
    $payload = Get-ScopedLimitsPayload $scopedCachePath $OrgKey
    try {
        $body = $payload | ConvertTo-Json -Compress -Depth 5 -ErrorAction Stop
        [System.IO.File]::WriteAllText($scopedCachePath, $body, (New-Object System.Text.UTF8Encoding($false)))
    } catch { Write-DebugLog $_ -Scope 'scoped-cache-write' }
    try {
        Remove-Item -LiteralPath $scopedLockPath -Force -ErrorAction SilentlyContinue
    } catch { Write-DebugLog $_ -Scope 'scoped-lock-release' }
    exit 0
}

# Named Request- rather than Start-: it asks for a refresh and frequently
# declines to do one (another window holds the lock, the TTL has not
# elapsed). Start- would also promise ShouldProcess support that a status
# line has no way to honour.
function Request-ScopedLimitsRefresh([string]$ScriptPath, [string]$LockPath, [string]$Org) {
    if ([string]::IsNullOrWhiteSpace($ScriptPath) -or -not (Test-Path $ScriptPath)) { return }
    # CreateNew is the atomic part: with several Claude Code windows open,
    # every one of them re-renders on its own schedule, and exactly one
    # wins this race and spawns the fetch. A lock left behind by a killed
    # child would otherwise wedge refreshes forever, so one older than
    # $lockStaleSec is cleared — this render then skips and the next takes
    # the lock cleanly, which keeps the recovery path off the hot path.
    $lockStaleSec = 120
    try {
        if (Test-Path $LockPath) {
            $lockAge = ([DateTime]::UtcNow - (Get-Item -LiteralPath $LockPath).LastWriteTimeUtc).TotalSeconds
            if ($lockAge -gt $lockStaleSec) {
                Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
            }
            return
        }
        $fs = [System.IO.File]::Open($LockPath, [System.IO.FileMode]::CreateNew,
                                     [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $fs.Close()
    } catch { return }

    try {
        # Reuse whichever host is already running this script rather than
        # assuming one is on PATH. $IsWindows is undefined on 5.1, where the
        # PSEdition test short-circuits before it is read.
        $exe = if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { 'pwsh' } else { 'powershell.exe' }
        try {
            $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        } catch { Write-DebugLog $_ -Scope 'scoped-host-path' }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName  = $exe
        $psi.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RefreshScopedLimits -OrgKey "{1}"' -f $ScriptPath, $Org
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow  = $true
        # The child must not inherit this process's stdout: a single stray
        # byte from it would land in the middle of the rendered status line.
        $psi.RedirectStandardInput  = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError  = $true
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-DebugLog $_ -Scope 'scoped-spawn'
        try {
            Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        } catch { Write-DebugLog $_ -Scope 'scoped-lock-release' }
    }
}

# Without this, non-ASCII glyphs like ⎇ ✱ get downgraded to '?' by the
# system code page on Windows when PowerShell flushes stdout.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom

# Bounded stdin read: Claude Code pipes JSON, but if the script is launched
# from a TTY (manual invocation, debug) or the spawn forgot to attach stdin,
# a blocking ReadToEnd() would hang the statusline forever. The contract
# is "always print something fast"; bail with a fallback line if no input
# arrives within 200 ms.
#
# Implementation note: [Console]::In.ReadToEndAsync() looks tempting but
# isn't truly async on PS 5.1's StreamReader-wrapped console stream — the
# task only completes when the underlying blocking read returns, so
# Wait(200) routinely waits seconds instead of milliseconds. Going one
# layer lower to the raw byte stream via OpenStandardInput + BeginRead
# uses Win32 async pipe I/O, which does honor the timeout.
if (-not [Console]::IsInputRedirected) {
    [Console]::Out.Write("statusline-tokens: no hook input")
    exit 0
}
$stdin = ''
try {
    $stdinStream = [Console]::OpenStandardInput()
    $stdinBuf    = New-Object byte[] 4096
    $stdinMem    = New-Object System.IO.MemoryStream
    $stdinEnd    = [DateTime]::UtcNow.AddMilliseconds(200)
    while ($true) {
        $remaining = [int]([math]::Max(0, ($stdinEnd - [DateTime]::UtcNow).TotalMilliseconds))
        if ($remaining -le 0) { break }
        $iar = $stdinStream.BeginRead($stdinBuf, 0, $stdinBuf.Length, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($remaining)) { break }
        $n = $stdinStream.EndRead($iar)
        if ($n -le 0) { break }
        $stdinMem.Write($stdinBuf, 0, $n)
    }
    $stdinBytes = $stdinMem.ToArray()
    # Strip a leading UTF-8 BOM if present — Encoding.UTF8.GetString does
    # not auto-strip it the way StreamReader does, and PS 5.1's
    # ConvertFrom-Json rejects a leading U+FEFF with "Invalid JSON
    # primitive: ." Powershell's piping layer prepends a BOM in 5.1.
    if ($stdinBytes.Length -ge 3 -and $stdinBytes[0] -eq 0xEF -and $stdinBytes[1] -eq 0xBB -and $stdinBytes[2] -eq 0xBF) {
        $stdin = [System.Text.Encoding]::UTF8.GetString($stdinBytes, 3, $stdinBytes.Length - 3)
    } else {
        $stdin = [System.Text.Encoding]::UTF8.GetString($stdinBytes)
    }
} catch {
    Write-DebugLog $_ -Scope 'stdin-read'
    $stdin = ''
}
if ([string]::IsNullOrWhiteSpace($stdin)) {
    [Console]::Out.Write("statusline-tokens: no hook input")
    exit 0
}
try { $hook = $stdin | ConvertFrom-Json -ErrorAction Stop } catch {
    Write-DebugLog $_ -Scope 'hook-parse'
    $hook = $null
}

# M1-10: normalize every $hook.X access through documented fallbacks so a
# future Anthropic rename/removal degrades visibly (one debug-log line per
# missing field) instead of silently emitting blanks. Downstream code reads
# $hookFields, not $hook, so the fallback policy lives in one place. When
# $hook itself is $null (parse failure — the no-stdin path already
# short-circuited above), every Get-HookField call resolves to its
# fallback and logs once; the statusline still prints something sensible.

# model.id first — model.display_name needs it as a fallback. Get-HookField
# is called with -NoLog when we're only using the field as a fallback
# source for another field, to avoid logging the same absence twice.
$modelIdRaw = Get-HookField $hook 'model.id' -Fallback $null -NoLog

# Derive a friendly fallback name from model.id by stripping the
# 'claude-' prefix and title-casing the family segment. 'claude-opus-4-7'
# becomes 'Opus 4 7'; 'claude-sonnet-4-5' becomes 'Sonnet 4 5'. Crude but
# strictly better than emitting the raw id or "model?" when display_name
# is the only missing field.
function script:Format-ModelIdAsName([string]$id) {
    if ([string]::IsNullOrEmpty($id)) { return $null }
    $name = $id
    if ($name.StartsWith('claude-')) { $name = $name.Substring(7) }
    # First segment is the family (opus/sonnet/haiku/etc.); title-case
    # it, leave version tokens (4-7, 3-5) as-is.
    $parts = $name.Split('-')
    if ($parts.Length -gt 0 -and $parts[0].Length -gt 0) {
        $parts[0] = $parts[0].Substring(0,1).ToUpper() + $parts[0].Substring(1)
    }
    return ($parts -join ' ')
}

$modelDisplay = Get-HookField $hook 'model.display_name' -Fallback $null
if ([string]::IsNullOrEmpty($modelDisplay)) {
    $derived = Format-ModelIdAsName $modelIdRaw
    if (-not [string]::IsNullOrEmpty($derived)) {
        $modelDisplay = $derived
    } else {
        $modelDisplay = 'model?'
    }
}
if ([string]::IsNullOrEmpty($modelIdRaw)) { $modelIdResolved = 'unknown' } else { $modelIdResolved = $modelIdRaw }

# cwd resolution: hook.workspace.current_dir wins, then hook.cwd, then the
# current process cwd. Get-Location is dependable: PowerShell always has
# one. Logging differs by site: we don't fire 'hook-field-missing' for
# workspace.current_dir because Claude Code only populates it when a
# workspace is active — its absence is normal, not a regression signal.
$cwdResolved = Get-HookField $hook 'workspace.current_dir' -Fallback $null -NoLog
if ([string]::IsNullOrEmpty($cwdResolved)) {
    $cwdResolved = Get-HookField $hook 'cwd' -Fallback $null
}
if ([string]::IsNullOrEmpty($cwdResolved)) {
    $cwdResolved = (Get-Location).Path
}

$transcriptPathResolved = Get-HookField $hook 'transcript_path' -Fallback $null
$sessionIdResolved      = Get-HookField $hook 'session_id'      -Fallback ''

# rate_limits.* stay $null on absence — downstream renders '--%' for
# null already, so the access just needs to not blow up.
$pct5hRaw    = Get-HookField $hook 'rate_limits.five_hour.used_percentage' -Fallback $null
$pct7dRaw    = Get-HookField $hook 'rate_limits.seven_day.used_percentage' -Fallback $null
$resets5hRaw = Get-HookField $hook 'rate_limits.five_hour.resets_at'       -Fallback $null
$resets7dRaw = Get-HookField $hook 'rate_limits.seven_day.resets_at'       -Fallback $null
# Context fill percentage, straight from the hook (M4-02).
#
# The token count alone can't tell you how full the window is, because it says
# nothing about the window's size: 63k reads like a third of a 200k model but
# is 6% of a 1M one. Claude Code computes this against the actual window, so it
# is the only correct signal — the token count stays as the fallback for
# clients too old to send it.
#
# -NoLog because absence is normal, not a regression: the field is null early
# in a session and immediately after /compact. Logging it would fire on every
# render once the debug log (#17) is wired up.
$ctxPctRaw = Get-HookField $hook 'context_window.used_percentage' -Fallback $null -NoLog
# Normalized to UTC [DateTime] once, here, so every consumer downstream
# (render, cache write) works with one shape instead of re-parsing.
$reset5hUtc  = ConvertTo-ResetUtc $resets5hRaw
$reset7dUtc  = ConvertTo-ResetUtc $resets7dRaw

$hookFields = [pscustomobject]@{
    transcript_path     = $transcriptPathResolved
    cwd                 = $cwdResolved
    session_id          = $sessionIdResolved
    model_display_name  = $modelDisplay
    model_id            = $modelIdResolved
    pct5h               = $pct5hRaw
    pct7d               = $pct7dRaw
    resets5h            = $reset5hUtc
    resets7d            = $reset7dUtc
    ctxPct              = $ctxPctRaw
}

# A 7d window on a heavy plan runs past a billion tokens, where "1354.0M" is
# both wider and harder to read than "1.35B". B keeps two decimals because one
# would round a 60M-token swing away.
#
# Each threshold is the point where the tier below would *round* to 1000, not
# where it reaches it: 999,949,999 still renders as "999.9M" at one decimal,
# but 999,950,000 rounds up to "1000.0M", so that is where B has to take over.
function Fmt-Tokens([long]$n) {
    if ($n -ge 999950000) { '{0:0.00}B' -f ($n / 1000000000.0) }
    elseif ($n -ge 999950) { '{0:0.0}M' -f ($n / 1000000.0) }
    elseif ($n -ge 1000) { '{0:0.0}k' -f ($n / 1000.0) }
    else { "$n" }
}

# --- pricing (USD per 1M tokens) ------------------------------------------
# Source: Anthropic's published API rates. Update when they change.
# Cache read = 0.1x input. Cache write: 5m ephemeral = 1.25x input,
# 1h ephemeral = 2x input. Every row is derived from its own input rate.
#
# Opus is deliberately split across two rows. Opus 4.5 and everything after
# it (4.6, 4.7, 4.8, Opus 5) is $5/$25; Opus 4.1, Opus 4.0 and Opus 3 were
# $15/$75. Charging all Opus traffic at the legacy rate overstates a current
# session by 3x, which is the difference between "$60 of work" and "$20".
$prices = @{
    fable      = @{ input = 10.00; output = 50.00; cacheRead = 1.00; cacheW5m = 12.50; cacheW1h = 20.00 }
    opus       = @{ input =  5.00; output = 25.00; cacheRead = 0.50; cacheW5m =  6.25; cacheW1h = 10.00 }
    opusLegacy = @{ input = 15.00; output = 75.00; cacheRead = 1.50; cacheW5m = 18.75; cacheW1h = 30.00 }
    sonnet     = @{ input =  3.00; output = 15.00; cacheRead = 0.30; cacheW5m =  3.75; cacheW1h =  6.00 }
    haiku      = @{ input =  1.00; output =  5.00; cacheRead = 0.10; cacheW5m =  1.25; cacheW1h =  2.00 }
}
function Get-ModelFamily([string]$id) {
    # Fable 5 / Mythos 5 — top tier, priced above Opus.
    if ($id -match 'fable|mythos') { return 'fable' }
    # Pre-price-drop Opus, matched ahead of the generic 'opus' arm.
    if ($id -match 'opus-4-1|opus-4-0|opus-4-2025|3-opus') { return 'opusLegacy' }
    if ($id -match 'opus')   { return 'opus' }
    # Sonnet 5 has an introductory $2/$10 rate through 2026-08-31; $3/$15 is
    # the standing rate and the conservative one to bill against.
    if ($id -match 'sonnet') { return 'sonnet' }
    if ($id -match 'haiku')  { return 'haiku' }
    return 'opus'  # unknown model: assume current Opus rather than guess low
}
function Fmt-Cost([double]$d) {
    if ($d -ge 1000) { return '${0:0.0}k' -f ($d / 1000.0) }
    if ($d -ge 100)  { return '${0:0}'   -f $d }
    if ($d -ge 1)    { return '${0:0.00}' -f $d }
    if ($d -gt 0)    { return '${0:0.00}' -f $d }   # e.g. $0.04
    return '$0.00'
}

# Compact relative duration: "45m" / "2h15m" / "3d12h" / "5d". Computed from
# a TimeSpan between two UTC instants, which makes it DST-proof — a window
# spanning a clock change still reports the true hours remaining.
function Fmt-Relative([TimeSpan]$ts) {
    if ($ts.TotalSeconds -le 0) { return 'now' }
    if ($ts.TotalSeconds -lt 60) { return '<1m' }   # avoids a bare "0m"
    $totalMin = [int][math]::Floor($ts.TotalMinutes)
    if ($totalMin -lt 60) { return ('{0}m' -f $totalMin) }
    $hours = [int][math]::Floor($ts.TotalHours)
    if ($hours -lt 24) {
        $mins = $totalMin - ($hours * 60)
        if ($mins -gt 0) { return ('{0}h{1}m' -f $hours, $mins) }
        return ('{0}h' -f $hours)
    }
    $days = [int][math]::Floor($ts.TotalDays)
    $remHours = $hours - ($days * 24)
    if ($remHours -gt 0) { return ('{0}d{1}h' -f $days, $remHours) }
    return ('{0}d' -f $days)
}

# Local clock time, lowercase am/pm; optional day-of-week prefix for far-out
# resets. ToLocalTime() resolves the offset for that specific instant against
# the OS timezone database, so a reset on the far side of a DST boundary
# prints the correct wall clock rather than one shifted by an hour.
function Fmt-AbsLocal([DateTime]$utc, [bool]$includeDay) {
    # ToLocalTime() only shifts a value whose Kind is Utc. On an Unspecified
    # one it is a silent no-op, printing the UTC time as though it were local.
    if ($utc.Kind -ne [DateTimeKind]::Utc) {
        $utc = [DateTime]::SpecifyKind($utc, [DateTimeKind]::Utc)
    }
    $local = $utc.ToLocalTime()
    $h = $local.Hour
    $m = $local.Minute
    $ampm = 'am'; if ($h -ge 12) { $ampm = 'pm' }
    $h12 = $h % 12; if ($h12 -eq 0) { $h12 = 12 }
    if ($m -eq 0) { $time = '{0}{1}' -f $h12, $ampm }
    else          { $time = '{0}:{1:D2}{2}' -f $h12, $m, $ampm }
    if ($includeDay) {
        $day = $local.ToString('ddd', [Globalization.CultureInfo]::InvariantCulture)
        return ('{0} {1}' -f $day, $time)
    }
    return $time
}

# "2h15m @ 7:30pm" — returns $null on missing/unparseable/elapsed timestamps.
# Accepts any shape ConvertTo-ResetUtc understands: epoch seconds, epoch
# milliseconds, ISO-8601 (with or without offset), or a [DateTime].
function Fmt-Reset($value, [bool]$includeDay) {
    $resetUtc = ConvertTo-ResetUtc $value
    if ($null -eq $resetUtc) { return $null }
    $ts = $resetUtc - [DateTime]::UtcNow
    if ($ts.TotalSeconds -le 0) { return $null }
    return ('{0} @ {1}' -f (Fmt-Relative $ts), (Fmt-AbsLocal $resetUtc $includeDay))
}

# --- token sums across the rolling windows ---------------------------------
$nowUtc = [DateTime]::UtcNow

# Floor for *finding* work, distinct from the per-window cutoffs below. No
# transcript older than seven days can matter to any window here, so this is
# what filters the file list, bounds the parse, and ages out cached turns. It
# must stay independent of the window cutoffs: the moment the 7d quota resets
# its cutoff jumps to roughly now, and filtering files by that would hide the
# last five hours of turns from the 5h window, which has its own unrelated
# window.
$scanFloor = $nowUtc.AddDays(-7)

# Provisional. Resolved from the quota's own reset stamps after the cache
# read below, once those stamps are known.
$cut5h = $nowUtc.AddHours(-5)
$cut7d = $scanFloor

# "Session" = the most recent contiguous burst of activity, walking backward
# until we hit a gap larger than this many minutes between consecutive turns.
# This survives clock-midnight, Claude Code restarts, and account switches —
# it's about *your* continuous work, not the calendar or the active account.
$sessionGapMinutes = 30

$tok5h      = [long]0; $cost5h      = 0.0
$tok7d      = [long]0; $cost7d      = 0.0
$tokSession = [long]0; $costSession = 0.0   # all accounts contributing to the current burst

# Latest turn per model id, as UTC ticks, for the current account only.
# Feeds the scoped-quota refresh decision further down: a per-model weekly
# bar has no hook source at all, so the only way to know it is out of date
# is to notice that the model behind it has run since we last asked. Keyed
# by the raw model id rather than by family so a scoped bar for a model
# this script has never heard of still matches on name.
$lastModelTurns = @{}

# $userProfile is resolved near the top of the script, before the stdin
# read, because the scoped-limits child needs it there too.
#
# [IO.Path]::Combine handles per-OS separators and works in PS 5.1
# (whose Join-Path is two-arg only) as well as pwsh 7.
$projectsDir       = [System.IO.Path]::Combine($userProfile, '.claude', 'projects')
$cachePath         = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-tokens.cache.json')
$globalConfigPath  = [System.IO.Path]::Combine($userProfile, '.claude.json')
$accountsPath      = [System.IO.Path]::Combine($userProfile, '.claude', 'statusline-accounts.json')

# --- detect current account ----------------------------------------------
# ~/.claude.json carries oauthAccount.{organizationUuid, emailAddress, ...}
# We use organizationUuid as the stable identifier — it survives token
# refreshes and only changes when you actually sign into a different
# account/org.
#
# We can't ConvertFrom-Json the whole file: ~/.claude.json contains a
# projects map keyed by absolute path, and Windows-case-insensitive
# filesystems produce duplicate keys (e.g. "...\GitHub\MyRepo" and
# "...\github\myrepo") that PS 5.1's parser rejects. Instead, walk the
# JSON to extract just the oauthAccount object and parse that.
#
# Implementation note: we navigate by [string]::IndexOf / IndexOfAny rather
# than iterating $content[$i] one [char] at a time. The earlier per-char
# walk worked on ASCII names but read each UTF-16 code unit independently,
# which means a non-BMP codepoint (e.g. emoji 🚀 in organizationName) is
# decomposed into two lone surrogates during iteration. The brace counter
# itself is fine (braces are ASCII), but per-char state-machine logic on
# lone surrogates is fragile under PS 5.1's [char]/[string] coercion rules.
# Seeking the next interesting ASCII byte sidesteps that class of bug
# entirely and is faster on the multi-KB ~/.claude.json file.
function Get-JsonObject([string]$content, [string]$keyName) {
    $needle = '"' + $keyName + '"'
    $start = $content.IndexOf($needle)
    if ($start -lt 0) { return $null }
    $braceStart = $content.IndexOf('{', $start)
    if ($braceStart -lt 0) { return $null }
    # Significant characters: opening/closing brace, string delimiter,
    # backslash (escape inside string). Everything else — including any
    # high/low surrogate halves of an astral codepoint — is skipped.
    $interesting = [char[]]@('{','}','"','\')
    $i = $braceStart
    $depth = 0
    $inStr = $false
    while ($i -lt $content.Length) {
        if ($inStr) {
            # Inside a string: only " (terminator) and \ (next char is escaped)
            # matter. IndexOfAny jumps directly to the next one.
            $j = $content.IndexOfAny($interesting, $i)
            if ($j -lt 0) { return $null }
            $c = $content[$j]
            if ($c -eq '\') {
                # Skip the escaped character. \uXXXX is fine: we resume two
                # positions later and IndexOfAny will find the next " anyway,
                # whatever the four hex digits are.
                $i = $j + 2
                continue
            }
            if ($c -eq '"') {
                $inStr = $false
                $i = $j + 1
                continue
            }
            # Stray { or } inside a string — not interesting, advance past it.
            $i = $j + 1
            continue
        }
        # Outside any string: braces change depth, " opens a string. \ is not
        # meaningful here (JSON doesn't allow bare backslashes outside strings).
        $j = $content.IndexOfAny($interesting, $i)
        if ($j -lt 0) { return $null }
        $c = $content[$j]
        if ($c -eq '"') {
            $inStr = $true
            $i = $j + 1
            continue
        }
        if ($c -eq '{') {
            $depth++
            $i = $j + 1
            continue
        }
        if ($c -eq '}') {
            $depth--
            if ($depth -eq 0) {
                # Both endpoints are ASCII braces, so this substring slice
                # cannot bisect a surrogate pair; the returned block is
                # well-formed UTF-16 even when organizationName contains
                # astral-plane characters.
                return $content.Substring($braceStart, $j - $braceStart + 1)
            }
            $i = $j + 1
            continue
        }
        # Backslash outside a string — shouldn't happen in valid JSON, but
        # don't loop forever on it.
        $i = $j + 1
    }
    return $null
}

$currentAccount = $null
if (Test-Path $globalConfigPath) {
    try {
        # -Encoding UTF8 because Claude Code writes ~/.claude.json without a
        # BOM; PS 5.1's default reader assumes the system code page and
        # mangles non-ASCII org names (accented characters, CJK, etc).
        $raw = Get-Content -Raw -Encoding UTF8 $globalConfigPath -ErrorAction Stop
        $block = Get-JsonObject $raw 'oauthAccount'
        if ($block) {
            $oa = $block | ConvertFrom-Json -ErrorAction Stop
            if ($oa.organizationUuid) {
                $currentAccount = @{
                    org   = [string]$oa.organizationUuid
                    email = [string]$oa.emailAddress
                    name  = [string]$oa.organizationName
                }
            }
        }
    } catch { Write-DebugLog $_ -Scope 'oauth-parse' }
}

# --- load and update account checkpoints ---------------------------------
# Append a new checkpoint whenever the current organizationUuid differs
# from the last recorded one. Each checkpoint owns the time-range from
# its 'from' value to the next checkpoint's 'from' (or now).
$checkpoints = @()
if (Test-Path $accountsPath) {
    try {
        # ReadAllText is BOM-tolerant by default (auto-detects UTF-8/16
        # BOMs, falls back to UTF-8) and behaves identically on PS 5.1 and
        # pwsh 7 — unlike Get-Content -Encoding UTF8, which writes the
        # BOM in PS 5.1 but not in pwsh 7.
        $loaded = [System.IO.File]::ReadAllText($accountsPath) | ConvertFrom-Json -ErrorAction Stop
        if ($loaded.checkpoints) { $checkpoints = @($loaded.checkpoints) }
    } catch { Write-DebugLog $_ -Scope 'accounts-load' }
}
if ($currentAccount) {
    $last = $null
    if ($checkpoints.Count -gt 0) { $last = $checkpoints[-1] }
    if (-not $last -or [string]$last.org -ne $currentAccount.org) {
        $checkpoints += @{
            from  = $nowUtc.ToString('o')
            org   = $currentAccount.org
            email = $currentAccount.email
            name  = $currentAccount.name
        }
        try {
            # WriteAllText with UTF8Encoding($false) is the only way to
            # produce a no-BOM file that's byte-identical across PS 5.1
            # and pwsh 7. Set-Content -Encoding utf8 emits a BOM on PS
            # 5.1 and no BOM on pwsh 7.
            $body = @{ checkpoints = $checkpoints } | ConvertTo-Json -Depth 4 -ErrorAction Stop
            [System.IO.File]::WriteAllText($accountsPath, $body, [System.Text.UTF8Encoding]::new($false))
        } catch { Write-DebugLog $_ -Scope 'accounts-write' }
    }
}

# Map a UTC timestamp to the account that owned it at that moment.
# Pre-first-checkpoint history is attributed to the earliest checkpoint —
# i.e., "if you install this script while signed into account A, all your
# past usage shows as A; future switches are tracked correctly from
# install onward."
function Account-At([DateTime]$t) {
    if (-not $script:checkpoints -or $script:checkpoints.Count -eq 0) { return $null }
    $acct = $script:checkpoints[0]
    foreach ($cp in $script:checkpoints) {
        # Checkpoints are written by this script as round-trip ISO ('o'), but
        # go through the same normalizer so a hand-edited or legacy file can't
        # produce a timezone-shifted attribution boundary.
        $cpTime = ConvertTo-ResetUtc $cp.from
        if ($null -eq $cpTime) {
            Write-DebugLog "unparseable checkpoint 'from': $($cp.from)" -Scope 'checkpoint-parse'
            continue
        }
        if ($t -ge $cpTime) { $acct = $cp } else { break }
    }
    return $acct
}

# Field-level regex extraction — ConvertFrom-Json per line is too slow on 19MB+.
$rxTs       = [regex]'"timestamp":"([^"]+)"'
$rxMsgId    = [regex]'"id":"(msg_[A-Za-z0-9]+)"'
$rxModel    = [regex]'"model":"(claude-[^"]+)"'
$rxInput    = [regex]'"input_tokens":(\d+)'
$rxOutput   = [regex]'"output_tokens":(\d+)'
$rxCacheC   = [regex]'"cache_creation_input_tokens":(\d+)'
$rxCacheR   = [regex]'"cache_read_input_tokens":(\d+)'
$rxCache5m  = [regex]'"ephemeral_5m_input_tokens":(\d+)'
$rxCache1h  = [regex]'"ephemeral_1h_input_tokens":(\d+)'

# Cache: full scan takes ~600-800ms over 19MB+, but the statusline re-renders
# on every turn. Reuse the cached numbers if computed within the last 20s.
$cacheTtlSec = 20
# Bumped to 3 for the per-turn modelId that lastModelTurns is built from.
# A v2 cache's replayed turns carry no model, so resuming from one would
# leave the scoped-refresh trigger permanently blind; discarding it costs
# a single full rescan on upgrade.
$cacheSchemaVersion = 3   # bump when on-disk shape changes; older caches discarded
$useCache = $false
$currentOrgKey = ''
if ($currentAccount) { $currentOrgKey = $currentAccount.org }
# Per-transcript tail cache (M1-04): keyed by absolute path, each entry
# carries `length`, `lastScanOffset`, `lastUsageLine`, and `turns` from
# the previous scan. Always loaded (even on top-level cache HIT) so the
# next MISS can resume cheaply.
$transcriptCache = @{}

# Peek at the shared store's reset stamps. Another window may already have
# seen a roll, and this one would otherwise spend a cache TTL summing tokens
# against a window that has ended.
#
# These land in their own variables and must stay there. $reset5hUtc is this
# window's own account of which window its percentage belongs to, and the
# merge relies on that to reject a reading from a window that has since
# rolled. An earlier version of this peek wrote the newer stamp straight into
# $reset5hUtc, which re-labelled a stale percentage as belonging to the
# current window and walked straight back into the failure the merge rule
# exists to prevent.
$storePeek = Read-LimitsStore $limitsStorePath $currentOrgKey
$storeReset5hUtc = $null
$storeReset7dUtc = $null
if ($storePeek[$limitsKey5h] -and $storePeek[$limitsKey5h].resetsAtUtc) {
    $storeReset5hUtc = [DateTime]$storePeek[$limitsKey5h].resetsAtUtc
}
if ($storePeek[$limitsKey7d] -and $storePeek[$limitsKey7d].resetsAtUtc) {
    $storeReset7dUtc = [DateTime]$storePeek[$limitsKey7d].resetsAtUtc
}
# Reset stamps only move forward, so the later of the two is the current
# window. Used for the token cutoffs and the cache-validity test below, never
# for labelling an observation.
function Get-LaterStamp($a, $b) {
    if ($null -eq $a) { return $b }
    if ($null -eq $b) { return $a }
    if (([DateTime]$a) -ge ([DateTime]$b)) { return [DateTime]$a }
    return [DateTime]$b
}

if (Test-Path $cachePath) {
    try {
        $cache = [System.IO.File]::ReadAllText($cachePath) | ConvertFrom-Json -ErrorAction Stop
        # An unparseable or missing stamp counts as infinitely old, so the
        # scan reruns rather than trusting numbers of unknown vintage.
        $computedAt = ConvertTo-ResetUtc $cache.computedAtUtc
        $age = [double]::MaxValue
        if ($null -ne $computedAt) { $age = ($nowUtc - $computedAt).TotalSeconds }
        # Invalidate if the active account changed since last scan — otherwise
        # the cached per-account numbers belong to the wrong org.
        $cachedOrg = ''
        if ($cache.PSObject.Properties.Match('orgKey').Count -gt 0) { $cachedOrg = [string]$cache.orgKey }
        $cachedVer = 0
        if ($cache.PSObject.Properties.Match('schemaVersion').Count -gt 0) { $cachedVer = [int]$cache.schemaVersion }
        # Whole-cache validity: TTL, account match, AND schema match. An
        # older-shape cache (schemaVersion == 0 here, because the field
        # didn't exist before M1-04) is treated as a MISS so the next
        # scan rebuilds the per-file tail cache from scratch and M1-02's
        # session-recompute has data to work with.
        # A rolled quota window invalidates the totals even inside the TTL.
        # tok5h was summed from the previous window's start, so the instant
        # resets_at advances that number describes a window that has ended.
        # Without this the segment keeps the old window's tokens for up to a
        # full cache TTL after the percentage has already dropped to zero.
        $sameWindow = $true
        foreach ($w in @(
            @{ live = (Get-LaterStamp $reset5hUtc $storeReset5hUtc); field = 'resets5h' },
            @{ live = (Get-LaterStamp $reset7dUtc $storeReset7dUtc); field = 'resets7d' }
        )) {
            if ($cachedOrg -ne $currentOrgKey -or $null -eq $w.live) { continue }
            if ($cache.PSObject.Properties.Match($w.field).Count -eq 0) { continue }
            $cachedReset = ConvertTo-ResetUtc $cache.($w.field)
            if ($null -eq $cachedReset) { continue }
            if ([Math]::Abs((([DateTime]$w.live) - $cachedReset).TotalSeconds) -gt $limitsWindowTolSec) {
                $sameWindow = $false
            }
        }
        if ($age -ge 0 -and $age -lt $cacheTtlSec -and $cachedOrg -eq $currentOrgKey -and $cachedVer -eq $cacheSchemaVersion -and $sameWindow) {
            $tok5h       = [long]$cache.tok5h
            $tok7d       = [long]$cache.tok7d
            $cost5h      = [double]$cache.cost5h
            $cost7d      = [double]$cache.cost7d
            # M1-02: tokSession / costSession are NOT restored from the
            # top-level cache. They're recomputed below from the per-file
            # tail cache ($transcriptCache) every render so a new turn
            # arriving mid-TTL is reflected immediately. The 5h/7d totals
            # drift slowly enough that a 20s lag is acceptable; the
            # session window does not (it can flip from "active" to
            # "ended" the moment 30 minutes of silence elapse).
            $useCache    = $true
        }
        # Per-transcript tail cache is only readable when the on-disk
        # shape matches what this script writes. An older cache from
        # v0.3 or earlier carries no `transcripts` dict; an even older
        # cache from a future incompatible bump would not be safe to
        # reuse. In either case, fall back to a full rescan — the
        # invalidation is automatic (we just don't populate
        # $transcriptCache here, so every file looks new).
        if ($cachedVer -eq $cacheSchemaVersion -and $cache.PSObject.Properties.Match('transcripts').Count -gt 0 -and $cache.transcripts) {
            foreach ($prop in $cache.transcripts.PSObject.Properties) {
                $transcriptCache[$prop.Name] = $prop.Value
            }
        }
        # Reset timestamps are restored outside the TTL gate on purpose. The
        # token totals go stale in 20 seconds, but a 5-hour reset stamp stays
        # true for hours and a 7-day one for days — so when the hook omits
        # rate_limits (every render before Claude Code's first response of a
        # session) the last-seen value is still the correct answer, and the
        # countdown keeps running instead of vanishing.
        #
        # They ARE gated on the account: quota windows are per-account, so
        # replaying the previous org's reset time after a switch would be a
        # confident lie. Fmt-Reset drops anything already elapsed, so a stale
        # value expires on its own rather than lingering.
        if ($cachedOrg -eq $currentOrgKey) {
            if ($null -eq $reset5hUtc -and $cache.PSObject.Properties.Match('resets5h').Count -gt 0) {
                $reset5hUtc = ConvertTo-ResetUtc $cache.resets5h
            }
            if ($null -eq $reset7dUtc -and $cache.PSObject.Properties.Match('resets7d').Count -gt 0) {
                $reset7dUtc = ConvertTo-ResetUtc $cache.resets7d
            }
            # Also restored outside the TTL gate, because the scoped-refresh
            # decision needs it on every render including the ones that skip
            # the scan. Apply-Turn only ever moves a stamp forward, so a
            # carried-over entry for a model that has since gone quiet stays
            # harmlessly old rather than re-triggering anything.
            if ($cache.PSObject.Properties.Match('lastModelTurns').Count -gt 0 -and $cache.lastModelTurns) {
                foreach ($prop in $cache.lastModelTurns.PSObject.Properties) {
                    $whenUtc = ConvertTo-ResetUtc $prop.Value
                    if ($null -eq $whenUtc) { continue }
                    $lastModelTurns[$prop.Name] = $whenUtc.Ticks
                }
            }
        }
    } catch { Write-DebugLog $_ -Scope 'cache-read' }
}

# --- resolve the quota windows --------------------------------------------
# The percentage and the token total have to describe the same window, or the
# segment contradicts itself. They did not. The percentage comes from a fixed
# window ending at resets_at; these cutoffs were a rolling "last five hours
# from now". Close enough to agree most of the time, and maximally wrong at
# precisely the moment a window resets — the percentage falls to zero while
# the tokens carry on reporting the window that just ended.
#
# So the cutoff comes from the reset stamp rather than from the clock:
#   * window still open -> it began one window-length before it ends
#   * window elapsed    -> the next one began the instant the old one ended,
#                          so that instant is the cutoff, and the totals show
#                          only what has been spent since
# Clamped to one window length in either direction, so a reset stamp that has
# gone stale — nothing has refreshed it for hours — cannot widen the window
# and over-count. With no stamp at all the old rolling behaviour stands,
# which is the best available guess.
function Get-WindowStart([DateTime]$NowRef, $ResetUtc, [TimeSpan]$Length) {
    $floor = $NowRef - $Length
    if ($null -eq $ResetUtc) { return $floor }
    $r = [DateTime]$ResetUtc
    $start = $(if ($r -le $NowRef) { $r } else { $r - $Length })
    if ($start -lt $floor)  { return $floor }
    if ($start -gt $NowRef) { return $NowRef }
    return $start
}
# Fed by the best-known stamp — this window's, or a newer one another window
# already recorded. Which window's percentage we are looking at is a separate
# question, decided by the merge; this one is only "where does the current
# quota period begin".
$cut5h = Get-WindowStart $nowUtc (Get-LaterStamp $reset5hUtc $storeReset5hUtc) ([TimeSpan]::FromHours(5))
$cut7d = Get-WindowStart $nowUtc (Get-LaterStamp $reset7dUtc $storeReset7dUtc) ([TimeSpan]::FromDays(7))

# Extract a turn from a single line. Returns a hashtable with ticks,
# sum, cost, msgId on success, or $null when the line isn't an
# assistant usage row (or carries no positive token count). The
# two-anchor probe is the M1-03 false-positive guard. Returning a
# hashtable lets the caller append to $turns and to the per-file
# cache without re-parsing.
function Parse-UsageLine([string]$line, [DateTime]$cut7dRef) {
    if (-not $line) { return $null }
    if ($line.IndexOf('"role":"assistant"') -lt 0) { return $null }
    if ($line.IndexOf('"usage":{') -lt 0) { return $null }

    $mTs = $rxTs.Match($line)
    if (-not $mTs.Success) { return $null }
    # TryParse with AssumeUniversal rather than Parse().ToUniversalTime().
    # Transcript stamps carry a Z today, but on any that didn't, Parse yields
    # an Unspecified DateTime and ToUniversalTime() would read it as host-local
    # and shift it forward by the UTC offset (7-8h on US Pacific), pulling
    # turns into the 5h window that don't belong there. TryParse also avoids
    # throwing once per malformed line on a hot path walking 19MB+ of JSONL.
    $t = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($mTs.Groups[1].Value,
            [Globalization.CultureInfo]::InvariantCulture,
            $script:utcParseStyles, [ref]$t)) {
        Write-DebugLog "unparseable turn timestamp: $($mTs.Groups[1].Value)" -Scope 'turn-timestamp-parse'
        return $null
    }
    if ($t -lt $cut7dRef) { return $null }

    $msgId = $null
    $mId = $rxMsgId.Match($line)
    if ($mId.Success) { $msgId = $mId.Groups[1].Value }

    $tIn = 0L; $tOut = 0L; $tCacheC = 0L; $tCacheR = 0L; $t5m = 0L; $t1h = 0L
    $m = $rxInput.Match($line)   ; if ($m.Success) { $tIn     = [long]$m.Groups[1].Value }
    $m = $rxOutput.Match($line)  ; if ($m.Success) { $tOut    = [long]$m.Groups[1].Value }
    $m = $rxCacheC.Match($line)  ; if ($m.Success) { $tCacheC = [long]$m.Groups[1].Value }
    $m = $rxCacheR.Match($line)  ; if ($m.Success) { $tCacheR = [long]$m.Groups[1].Value }
    $m = $rxCache5m.Match($line) ; if ($m.Success) { $t5m     = [long]$m.Groups[1].Value }
    $m = $rxCache1h.Match($line) ; if ($m.Success) { $t1h     = [long]$m.Groups[1].Value }

    $sum = $tIn + $tOut + $tCacheC + $tCacheR
    if ($sum -le 0) { return $null }

    $modelId = ''
    $mm = $rxModel.Match($line); if ($mm.Success) { $modelId = $mm.Groups[1].Value }
    $p = $prices[(Get-ModelFamily $modelId)]
    # If the 5m/1h breakdown isn't present (older transcripts),
    # fall back to charging all cache creation at the 5m rate
    # (the API default and the cheaper of the two).
    if (($t5m + $t1h) -le 0) { $t5m = $tCacheC; $t1h = 0L }
    $cost = (
        $tIn     * $p.input     +
        $tOut    * $p.output    +
        $tCacheR * $p.cacheRead +
        $t5m     * $p.cacheW5m  +
        $t1h     * $p.cacheW1h
    ) / 1000000.0

    # modelId rides along so Apply-Turn can note which models have run
    # recently. It is what tells the scoped-quota refresh that the bar it
    # is showing is behind — see $lastModelTurns.
    return @{ ticks = $t.Ticks; sum = $sum; cost = $cost; msgId = $msgId; modelId = $modelId }
}

# Apply a parsed turn to the rolling aggregates and the session-turn
# list. Dedupes by msgId (assistant turns get re-logged once per
# content block; counting all of them would triple-count tokens).
# Mutates the script-scope aggregates directly because PowerShell
# functions can't return-by-ref in PS 5.1.
function Apply-Turn($turn) {
    if (-not $turn) { return }
    if ($turn.msgId) {
        if ($script:seen.ContainsKey($turn.msgId)) { return }
        $script:seen[$turn.msgId] = $true
    }
    $t = [DateTime]::new([long]$turn.ticks, [DateTimeKind]::Utc)

    # Attribute the turn to the account that was active at
    # its timestamp. If no checkpoints exist yet (first run, no
    # ~/.claude.json), $turnAcct is $null and we fall back to
    # treating every turn as "current" — preserves the old
    # single-account behavior.
    $turnAcct = Account-At $t
    $isCurrent = $true
    if ($script:currentAccount) {
        $isCurrent = ($turnAcct -and [string]$turnAcct.org -eq $script:currentAccount.org)
    }

    if ($isCurrent) {
        # Each window tests its own cutoff. 7d used to be unconditional
        # because the parse floor *was* the 7d cutoff; those became two
        # different things once the cutoff tracks the quota, not the clock.
        if ($t -gt $script:cut7d) {
            $script:tok7d  += [long]$turn.sum
            $script:cost7d += [double]$turn.cost
        }
        if ($t -gt $script:cut5h) {
            $script:tok5h  += [long]$turn.sum
            $script:cost5h += [double]$turn.cost
        }
        if ($turn.modelId) {
            $mk = ([string]$turn.modelId).ToLowerInvariant()
            if (-not $script:lastModelTurns.ContainsKey($mk) -or
                [long]$turn.ticks -gt $script:lastModelTurns[$mk]) {
                $script:lastModelTurns[$mk] = [long]$turn.ticks
            }
        }
    }
    # Capture every turn (any account) for session detection
    # below — session is account-independent.
    [void]$script:turns.Add(@{ ticks = $turn.ticks; sum = $turn.sum; cost = $turn.cost })
}

if (-not $useCache -and (Test-Path $projectsDir)) {
    $seen = @{}
    # All scanned turns, regardless of account, used after the scan to
    # detect the session boundary by walking backward through time.
    $turns = New-Object System.Collections.ArrayList
    # Updated per-transcript state written back to the cache file at the
    # end of this block. Built from $transcriptCache, mutated in-place
    # as we scan / resume each file.
    $transcriptStateOut = @{}
    $files = Get-ChildItem -Path $projectsDir -Filter *.jsonl -Recurse `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -gt $scanFloor }

    foreach ($f in $files) {
        $key = $f.FullName
        $currentLen = $f.Length
        $cached = $null
        if ($transcriptCache.ContainsKey($key)) { $cached = $transcriptCache[$key] }
        # Per-file scan plan:
        #  - resumeOffset = bytes to skip at file open. 0 means full scan.
        #  - kept[]       = previously-parsed turns we still trust (only
        #                   the cache-resume path populates this).
        # Reasons to *not* resume:
        #   1. No cached entry — first time we've seen this file.
        #   2. Cached length > current length — file rotated or truncated.
        #   3. The cached schemaVersion didn't match (handled above by
        #      $transcriptCache being empty).
        $resumeOffset = 0L
        $kept = @()
        if ($cached) {
            $cachedLen = [long]$cached.length
            if ($currentLen -lt $cachedLen) {
                # Rotated / truncated. Discard the cache entry and full-scan.
                $resumeOffset = 0L
            } else {
                $resumeOffset = [long]$cached.lastScanOffset
                if ($cached.PSObject.Properties.Match('turns').Count -gt 0 -and $cached.turns) {
                    foreach ($prev in $cached.turns) {
                        # Drop cached turns that have aged past the scan
                        # floor since the last scan. Deliberately the floor
                        # and not $cut7d: the per-file cache is the input to
                        # every window, so narrowing it to the 7d quota
                        # window would starve the 5h one.
                        if ([long]$prev.ticks -lt $scanFloor.Ticks) { continue }
                        $kept += ,(@{ ticks = [long]$prev.ticks; sum = [long]$prev.sum; cost = [double]$prev.cost; msgId = [string]$prev.msgId })
                    }
                }
            }
        }

        # Replay cached turns first so $seen captures their msgIds before
        # any new-byte scan runs. This makes the dedup symmetric: an
        # assistant turn that was already in the cache won't be re-counted
        # if for some reason the resume seek lands mid-turn.
        foreach ($k in $kept) { Apply-Turn $k }

        $reader = $null
        $stream = $null
        $endOffset = $resumeOffset
        $lastUsageLineThisFile = $null
        if ($cached -and $cached.PSObject.Properties.Match('lastUsageLine').Count -gt 0) {
            $lastUsageLineThisFile = [string]$cached.lastUsageLine
        }
        $newTurnsForCache = New-Object System.Collections.ArrayList
        try {
            $stream = [System.IO.File]::Open($f.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            if ($resumeOffset -gt 0 -and $resumeOffset -lt $stream.Length) {
                [void]$stream.Seek($resumeOffset, [System.IO.SeekOrigin]::Begin)
            }
            # BOM detection disabled: when resumeOffset > 0 we've seeked
            # past the start, so any "BOM-shaped" bytes there would just
            # be random JSON content. Claude Code's transcripts are
            # plain UTF-8 without a BOM anyway.
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $false, 4096, $false)
            while (-not $reader.EndOfStream) {
                $line = $reader.ReadLine()
                if (-not $line) { continue }
                $turn = Parse-UsageLine $line $scanFloor
                if (-not $turn) { continue }
                # Track the latest assistant usage line in this file so
                # the per-file cache can record it (used by context-token
                # readouts and future consumers).
                $lastUsageLineThisFile = $line
                Apply-Turn $turn
                [void]$newTurnsForCache.Add($turn)
            }
            # Position after the read is the resume point for the next
            # render. BaseStream.Position is the byte offset; even though
            # StreamReader buffers, .Position reflects the stream's actual
            # read head, which is what we want.
            $endOffset = $reader.BaseStream.Position
            $reader.Close()
            $stream = $null
        } catch {
            Write-DebugLog $_ -Scope 'transcript-scan'
            if ($reader) { try { $reader.Close() } catch { Write-DebugLog $_ -Scope 'transcript-reader-close' } }
            if ($stream) { try { $stream.Close() } catch { Write-DebugLog $_ -Scope 'transcript-reader-close' } }
        }

        # Combine kept (cache) + new turns for the next run's cache entry.
        $turnsForCache = @()
        foreach ($k in $kept)         { $turnsForCache += ,$k }
        foreach ($n in $newTurnsForCache) { $turnsForCache += ,$n }
        $transcriptStateOut[$key] = @{
            length         = $currentLen
            lastScanOffset = $endOffset
            lastUsageLine  = $lastUsageLineThisFile
            turns          = $turnsForCache
        }
    }
}

# --- session boundary ----------------------------------------------------
# A session is the current burst of contiguous activity, defined as
# "the chain of turns ending at the most recent one, where no gap
# between consecutive turns exceeds $sessionGapMinutes — AND the
# most recent turn itself is within $sessionGapMinutes of now."
#
# If the latest turn is older than that, no session is "active" right
# now and we report 0. The next new turn seeds a fresh session.
#
# M1-02: the session is recomputed on EVERY render (cache HIT or MISS).
# On a MISS, $turns was populated by Apply-Turn during the scan above.
# On a HIT, we never scanned, so build the same flat list from the
# per-file tail cache ($transcriptCache) we always load. This is fast
# because $transcriptCache is already in memory — no file I/O — and
# the turn count across all transcripts is small (hundreds, not
# millions). The cost is dominated by the Sort-Object, which is O(n
# log n) on the same data either path.
if ($useCache) {
    $turns = New-Object System.Collections.ArrayList
    foreach ($entry in $transcriptCache.Values) {
        if (-not $entry) { continue }
        if ($entry.PSObject.Properties.Match('turns').Count -le 0) { continue }
        if (-not $entry.turns) { continue }
        foreach ($t in $entry.turns) {
            # Same floor as the scan path so stale cached turns don't
            # keep contributing to the session window forever.
            if ([long]$t.ticks -lt $scanFloor.Ticks) { continue }
            [void]$turns.Add(@{ ticks = [long]$t.ticks; sum = [long]$t.sum; cost = [double]$t.cost })
        }
    }
}
if ($turns -and $turns.Count -gt 0) {
    $gapTicks = [long]$sessionGapMinutes * [TimeSpan]::TicksPerMinute
    $sorted = @($turns | Sort-Object -Property { $_.ticks } -Descending)
    $latestTicks = $sorted[0].ticks
    if (($nowUtc.Ticks - $latestTicks) -le $gapTicks) {
        $prev = $latestTicks
        foreach ($e in $sorted) {
            if (($prev - $e.ticks) -gt $gapTicks) { break }
            $tokSession  += [long]$e.sum
            $costSession += [double]$e.cost
            $prev = $e.ticks
        }
    }
}

# --- native percentages from hook stdin -----------------------------------
# Resolved during the M1-10 normalization block at the top: missing fields
# arrive here as $null, with one debug-log line already emitted per
# absence. Downstream rendering treats $null as "loading" and prints '--%'.
$pct5h = $hookFields.pct5h
$pct7d = $hookFields.pct7d

# Always rewrite the cache so claude-dashboard.ps1 (which reads this same
# file) picks up fresh percentages on every Claude Code turn, even on cache
# HIT paths where we skipped re-scanning tokens. The pcts come from the hook
# stdin which is provided on every invocation; tokens come from either the
# fresh scan above or the prior cache values loaded earlier in the script.
try {
    $payload = @{
        schemaVersion = $cacheSchemaVersion
        computedAtUtc = $nowUtc.ToString('o')
        orgKey        = $currentOrgKey
        tok5h         = $tok5h
        tok7d         = $tok7d
        cost5h        = $cost5h
        cost7d        = $cost7d
        # M1-02: tokSession / costSession are deliberately *not* cached.
        # They're recomputed every render from per-file turns so the
        # session window can flip from "active" to "ended" the moment
        # the 30-min idle threshold is crossed, instead of lagging by
        # up to one cache-TTL cycle (20 s).
    }
    if ($null -ne $pct5h) { $payload.pct5h = [double]$pct5h }
    if ($null -ne $pct7d) { $payload.pct7d = [double]$pct7d }
    if ($null -ne $pct5h -or $null -ne $pct7d) {
        $payload.pctSavedAtUtc = $nowUtc.ToString('o')
    }
    # Persisted as round-trip ISO-8601 UTC ('o'), never as the raw hook value.
    # The hook sends an epoch integer, and ConvertTo-Json would write a
    # [DateTime] as "\/Date(...)\/" — pinning one unambiguous on-disk shape
    # keeps the reader (and claude-dashboard.ps1) from having to guess.
    if ($null -ne $reset5hUtc) { $payload.resets5h = $reset5hUtc.ToString('o') }
    if ($null -ne $reset7dUtc) { $payload.resets7d = $reset7dUtc.ToString('o') }
    # Ticks are the scan's working form; ISO-8601 is the on-disk form, so
    # the file stays legible to claude-dashboard.ps1 and to anything else
    # that opens it.
    $modelTurnsOut = @{}
    foreach ($mk in $lastModelTurns.Keys) {
        $modelTurnsOut[$mk] = ([DateTime]::new([long]$lastModelTurns[$mk], [DateTimeKind]::Utc)).ToString('o')
    }
    $payload.lastModelTurns = $modelTurnsOut
    # Persist the per-transcript tail cache (M1-04). On a top-level
    # cache HIT (or when no projects dir exists) we didn't scan, so
    # carry forward whatever we loaded from the previous cache file
    # so the next MISS still has resume offsets to seek to.
    if ($useCache -or -not (Test-Path $projectsDir)) {
        if ($transcriptCache.Count -gt 0) { $payload.transcripts = $transcriptCache }
    } else {
        $payload.transcripts = $transcriptStateOut
    }
    # Depth 6 covers transcripts -> <path> -> turns -> <turn-hashtable>
    # without flattening the per-turn fields into strings.
    $body = $payload | ConvertTo-Json -Compress -Depth 6 -ErrorAction Stop
    [System.IO.File]::WriteAllText($cachePath, $body, [System.Text.UTF8Encoding]::new($false))
} catch { Write-DebugLog $_ -Scope 'cache-write' }

# --- per-model weekly quota: read cache, refresh out of band --------------
# Read side of the block defined near the top of the script. Costs one small
# file read per render; the network call happens in a detached child, and
# only when the cache has aged past the TTL.
$scopedLimits     = @()
$scopedFetchedUtc = $null
$scopedAttempted  = $null
$scopedFailures   = 0

# This is the one part of the status line that leaves the machine, so it is
# switchable off in one place: STATUSLINE_SCOPED_LIMITS=0 (or off/false/no)
# skips the cache read, the spawn, and the segment entirely, restoring the
# fully local behavior everything else here still has.
$scopedEnabled = -not ($env:STATUSLINE_SCOPED_LIMITS -match '^(0|off|false|no)$')

if ($scopedEnabled -and (Test-Path $scopedCachePath)) {
    try {
        $sc = Get-Content -Raw -LiteralPath $scopedCachePath | ConvertFrom-Json
        # An account switch invalidates both the numbers and the refresh
        # timer: leaving $scopedAttempted null forces an immediate refetch
        # for the org now signed in.
        if ([string]$sc.orgKey -eq $currentOrgKey) {
            $scopedFetchedUtc = ConvertTo-ResetUtc $sc.fetchedAtUtc
            $scopedAttempted  = ConvertTo-ResetUtc $sc.attemptedAtUtc
            $scopedLimits     = @(@($sc.limits) | Where-Object { $_ })
            if ($sc.PSObject.Properties.Match('failures').Count -gt 0) {
                $scopedFailures = [int]$sc.failures
            }
        }
    } catch { Write-DebugLog $_ -Scope 'scoped-cache-read' }
}

# 15 minutes. The endpoint rate-limits, and Claude Code polls it too — this
# is a seven-day window, so a tighter interval buys precision no one can use
# while making it likelier that a 429 lands on the user's own /usage command.
# Override with the STATUSLINE_SCOPED_TTL env var (seconds).
$scopedTtlSec = 900
if ($env:STATUSLINE_SCOPED_TTL -match '^\d+$') { $scopedTtlSec = [int]$env:STATUSLINE_SCOPED_TTL }

# The per-model bars, separated from the session/weekly_all rows the same
# cache now carries. A row from a cache written before those existed has no
# kind and is a model bar by definition.
$scopedModelBars = @($scopedLimits | Where-Object {
    $_ -and ([string]$_.kind -eq 'weekly_scoped' -or [string]::IsNullOrWhiteSpace([string]$_.kind))
})

# --- has the scoped quota moved since we last asked? ----------------------
# 900 seconds is the right cadence for a bar nobody is currently moving and
# the wrong one for a bar you are actively spending: a Fable turn lands and
# the segment sits on a number up to fifteen minutes old, which reads as
# broken rather than as throttled. The hook cannot help here — Claude Code
# forwards five_hour and seven_day and no per-model bucket at all — so the
# only available evidence that the displayed figure is behind is that the
# model behind it has run since the last successful fetch.
#
# That is what $lastModelTurns is for. Match each scoped bar's display name
# against the model ids that actually produced turns ('Fable' against
# claude-fable-5), and if any of them ran after the last good fetch, drop to
# a short floor instead of the idle interval.
#
# Seeded with the fable/mythos family so the very first such turn on a
# machine with no scoped cache yet still triggers promptly, before any bar
# names are known.
$scopedActiveTtlSec = 90
if ($env:STATUSLINE_SCOPED_ACTIVE_TTL -match '^\d+$') { $scopedActiveTtlSec = [int]$env:STATUSLINE_SCOPED_ACTIVE_TTL }

$scopedNeedles = @('fable', 'mythos')
foreach ($bar in $scopedModelBars) {
    $n = ([string]$bar.name).Trim().ToLowerInvariant()
    if ($n -and $scopedNeedles -notcontains $n) { $scopedNeedles += $n }
}
$scopedActivityUtc = $null
foreach ($mk in $lastModelTurns.Keys) {
    $hit = $false
    foreach ($needle in $scopedNeedles) {
        if ([string]$mk -like ('*{0}*' -f $needle)) { $hit = $true; break }
    }
    if (-not $hit) { continue }
    $when = [DateTime]::new([long]$lastModelTurns[$mk], [DateTimeKind]::Utc)
    if ($null -eq $scopedActivityUtc -or $when -gt $scopedActivityUtc) { $scopedActivityUtc = $when }
}
# Compared against the last *successful* fetch, not the last attempt: a
# failed request tells us nothing about the number, so it must not count as
# having seen the new one. After a success only turns newer than it can
# re-trigger, which bounds a sustained burst to one request per floor.
$scopedMoved = ($null -ne $scopedActivityUtc) -and
               (($null -eq $scopedFetchedUtc) -or ($scopedActivityUtc -gt $scopedFetchedUtc))

# Exponential backoff on consecutive failed requests, capped at an hour, so a
# 429 or an outage is not answered by knocking every interval indefinitely.
# Only requests that actually reached the network increment the counter; a
# success resets it to zero. The backoff deliberately overrides the activity
# floor above — being mid-burst is not a reason to keep knocking on an
# endpoint that just refused us.
$scopedInterval = $scopedTtlSec
if ($scopedMoved) { $scopedInterval = $scopedActiveTtlSec }
if ($scopedFailures -gt 0) {
    $backoff = [Math]::Min($scopedTtlSec * [Math]::Pow(2, $scopedFailures), 3600)
    $scopedInterval = [Math]::Max($scopedInterval, $backoff)
}
$scopedAge = [double]::MaxValue
if ($null -ne $scopedAttempted) { $scopedAge = ($nowUtc - $scopedAttempted).TotalSeconds }
# A negative age means the stamp is in the future — a clock change, not a
# fresh fetch — so treat it as stale rather than trusting it indefinitely.
if ($scopedEnabled -and ($scopedAge -lt 0 -or $scopedAge -ge $scopedInterval)) {
    Request-ScopedLimitsRefresh $PSCommandPath $scopedLockPath $currentOrgKey
}

# --- fold this render's observations into the shared store ----------------
$limitsObs = New-Object System.Collections.ArrayList

# What this particular window was handed on stdin. It may well be behind
# what another window already knows; the merge is what decides that, not the
# fact that this render happens to be the one running.

# When did *this* window last actually hear from the server? Claude Code
# refreshes rate_limits on an API response and writes the assistant turn to
# the transcript at the same moment, so the transcript's mtime dates this
# window's figures without a network call. A window sitting idle carries a
# correspondingly old stamp, and the merge weighs it accordingly rather than
# treating every render as equally informed.
#
# DateTime.MinValue when there is no transcript to date it by: a figure of
# unknown vintage can seed an empty bucket but never displace a dated one.
$hookKnownUtc = [DateTime]::MinValue
if ($hookFields.transcript_path) {
    try {
        $tf = Get-Item -LiteralPath $hookFields.transcript_path -ErrorAction Stop
        $hookKnownUtc = $tf.LastWriteTimeUtc
        # A file stamped in the future (clock change, or a copy that kept its
        # mtime) would outrank every honest observation forever.
        if ($hookKnownUtc -gt $nowUtc) { $hookKnownUtc = $nowUtc }
    } catch { Write-DebugLog $_ -Scope 'hook-known-at' }
}

[void]$limitsObs.Add(@{ key = $limitsKey5h; name = '5h'; percent = $pct5h; resetsUtc = $reset5hUtc; observedUtc = $nowUtc; knownUtc = $hookKnownUtc })
[void]$limitsObs.Add(@{ key = $limitsKey7d; name = '7d'; percent = $pct7d; resetsUtc = $reset7dUtc; observedUtc = $nowUtc; knownUtc = $hookKnownUtc })

# What the usage endpoint last returned, stamped with when it was actually
# fetched rather than with now. Covers every bar, including the per-model
# ones no hook ever carries.
if ($scopedEnabled -and $null -ne $scopedFetchedUtc) {
    foreach ($lim in $scopedLimits) {
        if (-not $lim) { continue }
        $kind = [string]$lim.kind
        if ([string]::IsNullOrWhiteSpace($kind)) { $kind = 'weekly_scoped' }
        $rUtc = ConvertTo-ResetUtc $lim.resetsAt
        # A row with no usable reset stamp is dropped rather than merged
        # window-blind. Without a stamp the window guard cannot run, so the
        # figure would be applied to whatever window happens to be current —
        # and the endpoint does emit such rows: a session bar read in the
        # instant after a reset came back with a null resets_at, and the
        # failure path then carried that row forward indefinitely.
        if ($null -eq $rUtc) { continue }
        # An endpoint reading is dated by when it was fetched — it is a
        # direct point-in-time read of the account, so its information is
        # exactly as old as the request that produced it.
        if ($kind -eq 'session') {
            [void]$limitsObs.Add(@{ key = $limitsKey5h; name = '5h'; percent = $lim.percent; resetsUtc = $rUtc; observedUtc = $scopedFetchedUtc; knownUtc = $scopedFetchedUtc })
        } elseif ($kind -eq 'weekly_all') {
            [void]$limitsObs.Add(@{ key = $limitsKey7d; name = '7d'; percent = $lim.percent; resetsUtc = $rUtc; observedUtc = $scopedFetchedUtc; knownUtc = $scopedFetchedUtc })
        } elseif ($kind -eq 'weekly_scoped') {
            $barName = ([string]$lim.name).Trim()
            if (-not [string]::IsNullOrWhiteSpace($barName)) {
                [void]$limitsObs.Add(@{ key = ('scoped:' + $barName); name = $barName; percent = $lim.percent; resetsUtc = $rUtc; observedUtc = $scopedFetchedUtc; knownUtc = $scopedFetchedUtc })
            }
        }
    }
}

$limitsStore = Sync-LimitsStore $limitsStorePath $currentOrgKey $limitsObs

# Render from the store, not from this window's stdin. A window whose hook
# has not caught up — or has not sent rate_limits at all yet, which is every
# render before its first API response of the session — now shows the
# account's real figure instead of its own stale one or '--%'.
$bucket5h = Get-LiveBucket $limitsStore $limitsKey5h $nowUtc
if ($bucket5h) {
    $pct5h = $bucket5h.percent
    if ($bucket5h.resetsAtUtc) { $reset5hUtc = $bucket5h.resetsAtUtc }
} else { $pct5h = $null }
$bucket7d = Get-LiveBucket $limitsStore $limitsKey7d $nowUtc
if ($bucket7d) {
    $pct7d = $bucket7d.percent
    if ($bucket7d.resetsAtUtc) { $reset7dUtc = $bucket7d.resetsAtUtc }
} else { $pct7d = $null }

# --- context tokens: last usage block in the current session transcript --
# Fast path (M1-04): the projects-dir scan already captured the last
# assistant usage line for every transcript it processed. Reuse it
# instead of re-walking the file from byte 0. Falls through to the
# full walk if the active transcript isn't in our per-file cache
# (e.g. brand-new session whose file post-dates the last scan).
$ctxTokens = [long]0
if ($hookFields.transcript_path -and (Test-Path $hookFields.transcript_path)) {
    $lastUsageLine = $null
    $tpath = [string]$hookFields.transcript_path
    # Look up by exact path first, then by FullName-normalised form —
    # transcript_path arrives from the hook as the same string Claude
    # Code uses, but our scan keyed by FileInfo.FullName which
    # canonicalises separators. Try the path verbatim first, then a
    # normalised lookup.
    $hit = $null
    if ($transcriptStateOut -and $transcriptStateOut.ContainsKey($tpath)) {
        $hit = $transcriptStateOut[$tpath]
    } elseif ($transcriptCache -and $transcriptCache.ContainsKey($tpath)) {
        $hit = $transcriptCache[$tpath]
    } else {
        try {
            $normalized = (Get-Item -LiteralPath $tpath -ErrorAction Stop).FullName
            if ($transcriptStateOut -and $transcriptStateOut.ContainsKey($normalized)) {
                $hit = $transcriptStateOut[$normalized]
            } elseif ($transcriptCache -and $transcriptCache.ContainsKey($normalized)) {
                $hit = $transcriptCache[$normalized]
            }
        } catch { Write-DebugLog $_ -Scope 'ctx-path-normalize' }
    }
    if ($hit -and $hit.lastUsageLine) {
        $lastUsageLine = [string]$hit.lastUsageLine
    } else {
        foreach ($line in [System.IO.File]::ReadLines($tpath)) {
            # Anchor on JSON shape: require both `"role":"assistant"` and
            # `"usage":{` on the same line. A bare `"usage"` substring match
            # used to false-positive on user messages quoting the word
            # `usage`, clobbering $lastUsageLine and producing a 0-token
            # context readout. Claude Code writes one turn per line, so
            # both anchors will appear together iff this is a real
            # assistant turn with a usage block.
            if ($line.IndexOf('"role":"assistant"') -lt 0) { continue }
            if ($line.IndexOf('"usage":{') -lt 0) { continue }
            $lastUsageLine = $line
        }
    }
    if ($lastUsageLine) {
        $sum = [long]0
        $m = $rxInput.Match($lastUsageLine) ; if ($m.Success) { $sum += [long]$m.Groups[1].Value }
        $m = $rxCacheC.Match($lastUsageLine); if ($m.Success) { $sum += [long]$m.Groups[1].Value }
        $m = $rxCacheR.Match($lastUsageLine); if ($m.Success) { $sum += [long]$m.Groups[1].Value }
        $ctxTokens = $sum
    }
}

# --- working dir + git ----------------------------------------------------
# $hookFields.cwd is guaranteed non-null (M1-10): falls back to
# (Get-Location).Path if both hook.workspace.current_dir and hook.cwd are
# missing, so the statusline always renders a directory segment.
$dir = ''
if ($hookFields.cwd) { $dir = Split-Path -Leaf $hookFields.cwd }

$gitBranch = ''
$cwd = $hookFields.cwd
# Read .git/HEAD directly instead of shelling out to git. Shelling out
# costs ~30-80 ms per render, fragments the rendering budget, and leaks
# $LASTEXITCODE up to the caller. .git/HEAD is a one-line file:
#   "ref: refs/heads/<name>"  → branch <name>
#   "<40-char SHA>"           → detached HEAD, render first 7
# Worktrees use .git as a *file* pointing at the real gitdir; resolve
# that before reading HEAD.
if ($cwd -and (Test-Path $cwd)) {
    try {
        $gitPath = [System.IO.Path]::Combine($cwd, '.git')
        if (Test-Path $gitPath) {
            $gitDir = $gitPath
            $info = Get-Item $gitPath -Force -ErrorAction SilentlyContinue
            if ($info -and -not $info.PSIsContainer) {
                # .git is a file: "gitdir: <path>"
                $pointer = [System.IO.File]::ReadAllText($gitPath).Trim()
                if ($pointer.StartsWith('gitdir:')) {
                    $resolved = $pointer.Substring(7).Trim()
                    if (-not [System.IO.Path]::IsPathRooted($resolved)) {
                        $resolved = [System.IO.Path]::GetFullPath(
                            [System.IO.Path]::Combine($cwd, $resolved))
                    }
                    $gitDir = $resolved
                }
            }
            $headPath = [System.IO.Path]::Combine($gitDir, 'HEAD')
            if (Test-Path $headPath) {
                $head = [System.IO.File]::ReadAllText($headPath).Trim()
                if ($head.StartsWith('ref:')) {
                    $ref = $head.Substring(4).Trim()
                    if ($ref.StartsWith('refs/heads/')) {
                        $gitBranch = $ref.Substring(11)
                    } else {
                        $gitBranch = $ref
                    }
                } elseif ($head -match '^[0-9a-fA-F]{40}$') {
                    $gitBranch = $head.Substring(0, 7)
                }
            }
        }
    } catch { Write-DebugLog $_ -Scope 'git-head' }
}

# M1-10: $hookFields.model_display_name is guaranteed non-empty —
# falls back through model.id -> 'model?' so the statusline always
# prints a model segment, even when the hook payload is empty.
$model = $hookFields.model_display_name

# --- compose --------------------------------------------------------------
$esc = [char]27
$reset = "$esc[0m"
$fgDim = "$esc[38;5;245m"
$fgDir = "$esc[38;5;215m"
$fgGit = "$esc[38;5;180m"
$fgMod = "$esc[38;5;141m"
$fg5h      = "$esc[38;5;81m"
$fg7d      = "$esc[38;5;108m"
$fgScoped  = "$esc[38;5;176m"   # per-model weekly quota, e.g. Fable (orchid)
$fgSession = "$esc[38;5;178m"   # current work-burst, every account (gold)
$fgCtx     = "$esc[38;5;110m"

# Headroom palette for the % readout, layered over the segment color.
# Thresholds: <50 green, 50-79 yellow, >=80 red. Override with the
# STATUSLINE_PCT_THRESHOLDS env var, e.g. "65,85" to shift the bands.
$fgPctGreen  = "$esc[38;5;77m"    # 77  = soft green, easy on the eye
$fgPctYellow = "$esc[38;5;221m"   # 221 = warm amber
$fgPctRed    = "$esc[38;5;203m"   # 203 = clear red without screaming

$pctWarn = 50.0
$pctCrit = 80.0
if ($env:STATUSLINE_PCT_THRESHOLDS -match '^\s*(\d{1,3})\s*,\s*(\d{1,3})\s*$') {
    $pctWarn = [double]$Matches[1]
    $pctCrit = [double]$Matches[2]
}

function Get-PctColor([object]$pct) {
    if ($null -eq $pct) { return $fgDim }
    $v = [double]$pct
    if ($v -ge $pctCrit) { return $fgPctRed }
    if ($v -ge $pctWarn) { return $fgPctYellow }
    return $fgPctGreen
}

function Color($fg, $text) { "$fg$text$reset" }

$parts = @()
if ($dir)       { $parts += (Color $fgDir $dir) }
if ($gitBranch) { $parts += (Color $fgGit $gitBranch.Trim()) }
if ($model)     { $parts += (Color $fgMod $model) }

# Pure-ASCII placeholder for the loading state (percentages not yet supplied
# by the hook — typical at session start or right after an account switch).
# Earlier versions used a U+2014 em-dash, but even with the script saved as
# UTF-8-with-BOM and the glyph constructed via [char]0x2014, some consumers
# of the status-line output still decoded the bytes as Windows-1252 and
# rendered 'â€"'. ASCII removes that failure mode entirely.
$loading = '--%'
# MidpointRounding::AwayFromZero because .NET defaults to banker's rounding,
# which resolves .5 toward the nearest even integer — 42.5% renders as "42%"
# but 43.5% renders as "44%". Parity-dependent rounding is indefensible in a
# quota readout.
if ($null -ne $pct5h) {
    $p5 = '{0}%' -f [int][math]::Round([double]$pct5h, 0, [MidpointRounding]::AwayFromZero)
} else { $p5 = $loading }
if ($null -ne $pct7d) {
    $p7 = '{0}%' -f [int][math]::Round([double]$pct7d, 0, [MidpointRounding]::AwayFromZero)
} else { $p7 = $loading }
# Reset countdown + clock time, e.g. "resets 2h15m @ 7:30pm" for the 5h window
# and "resets 3d12h @ Wed 3pm" for the 7d one. The countdown is a UTC-to-UTC
# delta (DST can't skew it) and the clock time resolves the offset for that
# specific instant, so it stays correct across a DST boundary.
#
# $reset5hUtc / $reset7dUtc rather than $hookFields.*: the hook fields hold
# only this render's payload, while these also carry the cached fallback for
# renders where Claude Code sent no rate_limits at all (every render before
# its first response of a session). Renders nothing when neither source has a
# timestamp, rather than guessing.
$r5 = Fmt-Reset $reset5hUtc $false
$r7 = Fmt-Reset $reset7dUtc $true
$body5h = "{0} tok, {1}" -f (Fmt-Tokens $tok5h), (Fmt-Cost $cost5h)
if ($r5) { $body5h = '{0}, resets {1}' -f $body5h, $r5 }
$body7d = "{0} tok, {1}" -f (Fmt-Tokens $tok7d), (Fmt-Cost $cost7d)
if ($r7) { $body7d = '{0}, resets {1}' -f $body7d, $r7 }

# The percentage gets its own headroom color (green/yellow/red) layered
# over the segment's identity color so the surrounding "5h … (…)" still
# reads as the 5h block. Loading state ('--%') stays in the segment color.
$pct5Color = if ($null -ne $pct5h) { Get-PctColor $pct5h } else { $fg5h }
$pct7Color = if ($null -ne $pct7d) { Get-PctColor $pct7d } else { $fg7d }
$p5Tinted = "$pct5Color$p5$reset$fg5h"
$p7Tinted = "$pct7Color$p7$reset$fg7d"
$parts += (Color $fg5h      ("5h {0} ({1})" -f $p5Tinted, $body5h))
$parts += (Color $fg7d      ("7d {0} ({1})" -f $p7Tinted, $body7d))

# Per-model weekly quota — today that is Fable 5, which Claude Code meters
# separately from the plan-wide weekly limit above. One segment per bar the
# account actually has, so an account without a scoped limit renders nothing
# rather than an empty placeholder.
#
# Freshness gate: a percentage we have not been able to refresh for three
# hours degrades to '--%' instead of presenting a stale number as current.
# Three rather than one, because the failure backoff above can legitimately
# stretch to hourly retries — a gate tighter than the retry interval would
# blank a number that is merely waiting, not wrong. Three consecutive failed
# hours is a real fault worth showing.
#
# The reset countdown deliberately survives that gate — a weekly reset
# timestamp stays true for days, the same reasoning the cached resets7d
# fallback rests on, and Fmt-Reset drops it once it has elapsed.
$scopedMaxAgeSec = 10800
foreach ($bar in $scopedModelBars) {
    $scopedName = ([string]$bar.name).Trim()
    if ([string]::IsNullOrWhiteSpace($scopedName)) { continue }
    # Read through the shared store like every other segment, so two
    # windows cannot disagree about this bar either — even though only one
    # of them may have been the window that fetched it.
    $bucket = Get-LiveBucket $limitsStore ('scoped:' + $scopedName) $nowUtc
    $pScoped = $loading
    $pScopedColor = $fgScoped
    $rScoped = $null
    if ($bucket) {
        $fetchAge = [double]::MaxValue
        if ($bucket.observedAtUtc) {
            $fetchAge = ($nowUtc - [DateTime]$bucket.observedAtUtc).TotalSeconds
        }
        if ($fetchAge -ge 0 -and $fetchAge -lt $scopedMaxAgeSec) {
            $pScoped = '{0}%' -f [int][math]::Round([double]$bucket.percent, 0, [MidpointRounding]::AwayFromZero)
            $pScopedColor = Get-PctColor $bucket.percent
        }
        $rScoped = Fmt-Reset $bucket.resetsAtUtc $true
    }
    $bodyScoped = ''
    if ($rScoped) { $bodyScoped = ' (resets {0})' -f $rScoped }
    $pScopedTinted = "$pScopedColor$pScoped$reset$fgScoped"
    $parts += (Color $fgScoped ('{0} {1}{2}' -f $scopedName.ToLowerInvariant(), $pScopedTinted, $bodyScoped))
}

$parts += (Color $fgSession ("session {0} ({1})"     -f       (Fmt-Tokens $tokSession), (Fmt-Cost $costSession)))
# "ctx 63.0k (6%)" when the hook supplies the fill percentage, "ctx 63.0k"
# when it doesn't. Explicit $null test, not truthiness: a genuine 0% is
# falsy in PowerShell, and [double]$null silently coerces to 0 — either
# would render "(0%)" for "unknown" and "" for a genuinely empty window.
$ctxText = 'ctx {0}' -f (Fmt-Tokens $ctxTokens)
if ($null -ne $hookFields.ctxPct) {
    $ctxText = '{0} ({1}%)' -f $ctxText,
        [int][math]::Round([double]$hookFields.ctxPct, 0, [MidpointRounding]::AwayFromZero)
}
$parts += (Color $fgCtx $ctxText)

$sep = " $fgDim|$reset "
[Console]::Out.Write([string]::Join($sep, $parts))
