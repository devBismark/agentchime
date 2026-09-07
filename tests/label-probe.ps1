# Runs one project-label expectation against an arbitrary copy of the notifier.
#
# tests/project-label-contract.ps1 uses this to prove its own oracles can fail:
# it writes a deliberately broken copy of src/notify.ps1 and expects the probe
# to report KILLED. Running the same probe against the unmodified notifier must
# report SURVIVED, otherwise a probe that always reported KILLED would look
# like proof.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Notifier,

    [Parameter(Mandatory = $true)]
    [ValidateSet('repo-root', 'nested-dir', 'nearest', 'worktree', 'fallback', 'leak', 'privacy', 'delivery', 'toolless', 'account-boundary')]
    [string]$Probe,

    [Parameter(Mandatory = $true)]
    [string]$Fixture
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Loads the functions only; the dot-source guard suppresses the main flow.
. $Notifier 'finished'

function Join-Fixture([string]$Relative) {
    return (Join-Path $Fixture ($Relative -replace '/', '\'))
}

function New-LabelPayload([string]$WorkingDirectory) {
    return ([ordered]@{ cwd = $WorkingDirectory } | ConvertTo-Json -Compress | ConvertFrom-Json)
}

# Every directory the fixture offers, paired with the label it must produce.
function Get-FixtureExpectations {
    return [ordered]@{
        'solo-repo'                         = 'solo-repo'
        'solo-repo/apps/web'                = 'solo-repo'
        'solo-repo/packages/api'            = 'solo-repo'
        'solo-repo/src'                     = 'solo-repo'
        'outer-repo'                        = 'outer-repo'
        'outer-repo/vendor/inner-repo'      = 'inner-repo'
        'outer-repo/vendor/inner-repo/src'  = 'inner-repo'
        'wt-feature'                        = 'wt-feature'
        'wt-feature/src'                    = 'wt-feature'
        'plain/nested/deep'                 = 'deep'
    }
}

$verdict = 'KILLED'

switch ($Probe) {
    'repo-root' {
        # A working directory that already is the repository root keeps the
        # name it always had. This is the baseline-equivalence case, so it must
        # survive a mutant that ignores repositories entirely.
        $actual = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'solo-repo')
        $outer = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'outer-repo')
        if (($actual -ceq 'solo-repo') -and ($outer -ceq 'outer-repo')) { $verdict = 'SURVIVED' }
    }

    'nested-dir' {
        # The case this step exists for: a generic leaf deep inside a monorepo
        # must report the repository, not the folder.
        $web = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'solo-repo/apps/web')
        $api = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'solo-repo/packages/api')
        if (($web -ceq 'solo-repo') -and ($api -ceq 'solo-repo')) { $verdict = 'SURVIVED' }
    }

    'nearest' {
        # A repository checked out inside another one names itself. A resolver
        # that climbs past it, or stops one directory short, is killed here.
        $src = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'outer-repo/vendor/inner-repo/src')
        $root = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'outer-repo/vendor/inner-repo')
        if (($src -ceq 'inner-repo') -and ($root -ceq 'inner-repo')) { $verdict = 'SURVIVED' }
    }

    'worktree' {
        # A linked worktree marks its root with a file rather than a directory.
        # The subdirectory case is what makes this probe honest: at the
        # worktree root itself the leaf would give the same answer by accident.
        $root = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'wt-feature')
        $src = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'wt-feature/src')
        if (($root -ceq 'wt-feature') -and ($src -ceq 'wt-feature')) { $verdict = 'SURVIVED' }
    }

    'fallback' {
        # No repository, a directory that does not exist, and nothing at all.
        $plain = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'plain/nested/deep')
        $ghost = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'plain/ghost/gone')
        $inRepo = Resolve-ProjectLabel -WorkingDirectory (Join-Fixture 'solo-repo/apps/web/ghost')
        $blank = Resolve-ProjectLabel -WorkingDirectory '   '
        if (($plain -ceq 'deep') -and ($ghost -ceq 'gone') -and ($inRepo -ceq 'solo-repo') -and ($blank -ceq '')) {
            $verdict = 'SURVIVED'
        }
    }

    'leak' {
        # Whatever the input, the answer is a bare name. Separators, drive
        # specifiers, schemes and the fixture's own root must never survive
        # into a label.
        $inputs = @()
        foreach ($relative in (Get-FixtureExpectations).Keys) { $inputs += (Join-Fixture $relative) }
        $inputs += @(
            (Join-Fixture 'plain/ghost/gone'),
            'C:\',
            'D:\',
            'C:',
            '/',
            'https://example.invalid/owner/repo',
            (Join-Fixture 'solo-repo') + '\'
        )

        $clean = $true
        foreach ($item in $inputs) {
            $label = [string](Resolve-ProjectLabel -WorkingDirectory $item)
            if ($label.Length -gt 128) { $clean = $false }
            if ($label.Contains([char]'\') -or $label.Contains([char]'/')) { $clean = $false }
            if ($label.Contains(':')) { $clean = $false }
            if ($label -like '*http*') { $clean = $false }
            if ($label -like ('*' + $Fixture + '*')) { $clean = $false }
        }

        if ($clean) { $verdict = 'SURVIVED' }
    }

    'privacy' {
        # Shadowing the resolver in this scope replaces the one the adapter
        # calls, so the count below records whether resolution happened at all
        # rather than only what it returned.
        $script:ResolverCalls = 0
        function Resolve-ProjectLabel([string]$WorkingDirectory) {
            $script:ResolverCalls++
            return 'SENTINEL-LABEL'
        }

        $payload = New-LabelPayload (Join-Fixture 'solo-repo/apps/web')

        $suppressed = ConvertTo-AgentEvent -Payload $payload -EventState 'finished' -Locale 'en' -IncludeProjectLabel $false
        $callsWhileSuppressed = $script:ResolverCalls

        $script:ResolverCalls = 0
        $allowed = ConvertTo-AgentEvent -Payload $payload -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
        $callsWhileAllowed = $script:ResolverCalls

        $suppressedOk = ($callsWhileSuppressed -eq 0) -and (([string]$suppressed.projectLabel) -ceq 'Claude Code')
        $allowedOk = ($callsWhileAllowed -ge 1) -and (([string]$allowed.projectLabel) -ceq 'SENTINEL-LABEL')

        if ($suppressedOk -and $allowedOk) { $verdict = 'SURVIVED' }
    }

    'delivery' {
        # Project context is best effort, so a resolver that fails must cost the
        # label and nothing else. The whole chain runs here: normalize, render,
        # and hand the result to mobile delivery through a captured transport.
        $script:Sent = New-Object System.Collections.Generic.List[hashtable]
        function Invoke-RestMethod {
            param(
                [string]$Uri,
                [string]$Method,
                [hashtable]$Headers,
                [string]$Body,
                [string]$ContentType,
                [int]$TimeoutSec
            )
            $script:Sent.Add(@{ Uri = $Uri; Body = $Body; Title = [string]$Headers['Title'] })
        }

        $config = ([ordered]@{
                locale  = 'en'
                desktop = [ordered]@{ enabled = $false }
                mobile  = [ordered]@{ enabled = $true; provider = 'ntfy'; server = 'https://ntfy.invalid'; topic = 'probe' }
            } | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json)

        $delivered = $true
        try {
            $payload = New-LabelPayload (Join-Fixture 'solo-repo/apps/web')
            $agentEvent = ConvertTo-AgentEvent -Payload $payload -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
            $message = Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard'
            Send-NtfyNotification -Config $config -Message $message
        }
        catch {
            $delivered = $false
        }

        if ($delivered -and $script:Sent.Count -eq 1 -and ([string]$script:Sent[0].Title) -ceq 'Claude Code - FINISHED') {
            $verdict = 'SURVIVED'
        }
    }

    'account-boundary' {
        # A repository rooted at the account directory is not a project, and
        # its folder carries the account name. Pointing the account directory
        # at the fixture proves the boundary rather than the machine's layout.
        $accountHome = Join-Fixture 'account-home'
        $project = Join-Fixture 'account-home/projects/client-x'

        # Without the override the same directory does report the enclosing
        # repository, so the result below is the boundary at work rather than
        # an absent repository.
        $withoutBoundary = Resolve-ProjectLabel -WorkingDirectory $project

        $env:USERPROFILE = $accountHome
        $bounded = Resolve-ProjectLabel -WorkingDirectory $project
        $atAccountRoot = Resolve-ProjectLabel -WorkingDirectory $accountHome

        if (($withoutBoundary -ceq 'account-home') -and
            ($bounded -ceq 'client-x') -and
            ($atAccountRoot -ceq 'account-home')) {
            $verdict = 'SURVIVED'
        }
    }

    'toolless' {
        # Runs with an emptied PATH, so nothing can be launched by name. A
        # resolver that shelled out to a version control tool would degrade
        # here; one that only probes the filesystem does not notice.
        $env:PATH = ''
        $gitAvailable = $null -ne (Get-Command 'git' -ErrorAction SilentlyContinue)

        $ok = $true
        foreach ($entry in (Get-FixtureExpectations).GetEnumerator()) {
            $actual = [string](Resolve-ProjectLabel -WorkingDirectory (Join-Fixture $entry.Key))
            if ($actual -cne ([string]$entry.Value)) { $ok = $false }
        }

        # The control belongs in the probe: without it an environment that
        # still had the tool would make the result meaningless.
        if ($ok -and -not $gitAvailable) { $verdict = 'SURVIVED' }
    }
}

Write-Output "PROBE $Probe : $verdict"
exit 0
