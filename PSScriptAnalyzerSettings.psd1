@{
    # M3-03 CI lints at Warning + Error and fails on any finding. Anything
    # listed in ExcludeRules below has been reviewed and judged a
    # style/false-positive call rather than a defect; everything else stays
    # enforced so real bugs (e.g. PSAvoidUsingPlainTextForPassword,
    # PSUseDeclaredVarsMoreThanAssignments, PSPossibleIncorrectComparisonWithNull)
    # still break the build.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # The statusline writes to stdout exclusively via [Console]::Out.Write
        # (see the two call sites in statusline-tokens.ps1). Write-Host is
        # never invoked, so this rule has nothing to flag here; keeping it
        # enabled would only create noise if someone later added a Write-Host
        # they meant to be Write-Output.
        'PSAvoidUsingWriteHost'

        # Write-DebugLog is an intentional no-op stub for M2-05 (rotating
        # debug log at ~/.claude/statusline-tokens.log). The $Message and
        # $Scope parameters are part of the public signature callers across
        # the script already use; dropping them now would mean rewriting
        # every call site again in M2-05. Re-enable once M2-05 lands and
        # the body actually consumes the parameters.
        'PSReviewUnusedParameter'

        # Same Write-DebugLog stub: it declares ValueFromPipeline on
        # $Message so future callers can pipe errors into it, but the
        # current body is a no-op and adding an empty process { } block
        # purely to satisfy the analyzer would be cargo-culted noise.
        # Re-enable in M2-05 alongside PSReviewUnusedParameter.
        'PSUseProcessBlockForPipelineCommand'

        # Fmt-Tokens / Fmt-Cost / Account-At are script-local helpers, not
        # exported cmdlets. The short Fmt- prefix mirrors the surrounding
        # numeric-formatting style and reads more naturally in the compose
        # block than Format-Tokens / Format-Cost would. Account-At likewise
        # describes a lookup ("account at time t"), which the approved verb
        # list does not cover cleanly. Cosmetic preference, no behavioral
        # impact.
        'PSUseApprovedVerbs'

        # Fmt-Tokens formats a token *count* (plural) — renaming to
        # Fmt-Token would imply it formats a single token, which is
        # misleading. The plural is load-bearing for readability at call
        # sites like (Fmt-Tokens $tok7d).
        'PSUseSingularNouns'
    )
}
