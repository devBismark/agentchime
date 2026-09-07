# Runs one duration expectation against an arbitrary copy of the notifier.
#
# tests/duration-contract.ps1 uses this to prove its own oracles can fail: it
# writes a deliberately broken copy of src/notify.ps1 and expects the probe to
# report KILLED. Running the probe against the unmodified notifier must report
# SURVIVED, otherwise a probe that always reported KILLED would look like proof.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Notifier,

    [Parameter(Mandatory = $true)]
    [ValidateSet('elapsed', 'backwards', 'correlation', 'detail', 'detail-privacy')]
    [string]$Probe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Loads the functions only; the dot-source guard suppresses the main flow.
. $Notifier 'finished'

$Frequency = 10000000
$Anchor = '2026-01-01T00:00:00.0000000Z'

function New-Sample([long]$Monotonic, [string]$Utc, [string]$ClockAnchor = $Anchor, [long]$SampleFrequency = $Frequency) {
    return ([ordered]@{
            schema      = 1
            promptKey   = ''
            utc         = $Utc
            monotonic   = $Monotonic
            frequency   = $SampleFrequency
            clockAnchor = $ClockAnchor
        } | ConvertTo-Json -Compress | ConvertFrom-Json)
}

$verdict = 'KILLED'

switch ($Probe) {
    'elapsed' {
        # 1122 seconds of monotonic ticks must be reported as 1122000 ms. The
        # wall clock deliberately disagrees, so a notifier that reads it instead
        # produces a different number rather than the same one by luck.
        $start = New-Sample -Monotonic 10000000000 -Utc '2026-01-01T00:16:40.0000000Z'
        $end = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T09:00:00.0000000Z'
        $actual = Measure-TurnDuration -Start $start -End $end
        if ($null -ne $actual -and [long]$actual -eq 1122000) { $verdict = 'SURVIVED' }
    }

    'backwards' {
        # An end that precedes its start is not a duration at all.
        $start = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T00:35:22.0000000Z'
        $end = New-Sample -Monotonic 10000000000 -Utc '2026-01-01T00:16:40.0000000Z'
        $actual = Measure-TurnDuration -Start $start -End $end
        if ($null -eq $actual) { $verdict = 'SURVIVED' }
    }

    'correlation' {
        # A start recorded for a different prompt must not be measured against.
        $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-probe-' + [guid]::NewGuid().ToString('N'))
        try {
            $sessionKey = Get-OpaqueKey 'session-under-test'
            $recorded = Get-OpaqueKey 'prompt-one'
            $current = Get-OpaqueKey 'prompt-two'
            Save-TurnStart -StateDirectory $directory -SessionKey $sessionKey -PromptKey $recorded | Out-Null
            $actual = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionKey -PromptKey $current
            if ($null -eq $actual) { $verdict = 'SURVIVED' }
        }
        finally {
            if (Test-Path $directory) { Remove-Item $directory -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    'detail' {
        # The minimal level must actually drop all three pieces of context
        # while the standard level keeps them. A notifier that ignores the
        # level renders the same body twice and is killed here.
        $agentEvent = [pscustomobject]@{
            provider     = 'claude-code'
            state        = 'error'
            projectLabel = 'my-project'
            errorType    = 'ToolExecutionFailure'
            locale       = 'en'
            durationMs   = 1122000
        }
        $standard = Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard'
        $minimal = Get-AgentMessage -AgentEvent $agentEvent -Detail 'minimal'

        $standardOk = ([string]$standard.Body) -ceq 'my-project - Claude stopped because of an error (ToolExecutionFailure). (18m 42s)'
        $minimalOk = ([string]$minimal.Body) -ceq 'Claude stopped because of an error.'
        $titlesOk = ([string]$standard.Title) -ceq ([string]$minimal.Title)

        if ($standardOk -and $minimalOk -and $titlesOk) { $verdict = 'SURVIVED' }
    }

    'detail-privacy' {
        # Privacy outranks detail. An event whose label and measurement were
        # already suppressed must render the same body at the most detailed
        # level as it does at the least detailed one. A notifier that lets a
        # level reach back for suppressed context is killed here.
        $suppressed = [pscustomobject]@{
            provider     = 'claude-code'
            state        = 'finished'
            projectLabel = 'Claude Code'
            errorType    = ''
            locale       = 'en'
            durationMs   = $null
        }
        $standard = Get-AgentMessage -AgentEvent $suppressed -Detail 'standard'

        $leaked = @('my-project', '18m 42s', 'ToolExecutionFailure')
        $clean = $true
        foreach ($fragment in $leaked) {
            if (([string]$standard.Body) -like ('*' + $fragment + '*')) { $clean = $false }
        }

        if ($clean -and (([string]$standard.Body) -ceq 'Claude Code - Claude finished the task.')) { $verdict = 'SURVIVED' }
    }
}

Write-Output "PROBE $Probe : $verdict"
exit 0
