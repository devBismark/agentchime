# Behavioral contract tests for elapsed turn duration.
#
# notify.ps1 loads its functions only when dot-sourced, so every suite below
# drives the real clock, turn store and renderer without sending a
# notification. The store is addressed through an explicit -StateDirectory, so
# no suite ever reads or writes a real installation. Each suite prints a
# success-only token that the Unlazy gate ledger matches on.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('semantics', 'correlation', 'concurrency', 'orphan', 'rendering', 'privacy', 'contract')]
    [string]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$NotifyPath = Join-Path $RepoRoot 'src\notify.ps1'
$ProbePath = Join-Path $PSScriptRoot 'mutation-probe.ps1'

# Loads the functions only. The state argument satisfies the mandatory
# parameter; the dot-source guard inside notify.ps1 suppresses the main flow.
. $NotifyPath 'finished'

foreach ($required in @('Measure-TurnDuration', 'Save-TurnStart', 'Resolve-TurnDuration', 'Remove-StaleTurnState', 'Format-TurnDuration', 'Get-OpaqueKey')) {
    if (-not (Get-Command -Name $required -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "notify.ps1 did not expose $required when dot-sourced."
    }
}

$script:SandboxRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $script:SandboxRoot | Out-Null

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Assertions = 0

function Assert-That([bool]$Condition, [string]$Label) {
    $script:Assertions++
    if (-not $Condition) { $script:Failures.Add("FAIL $Label") }
}

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Label) {
    $script:Assertions++
    if ($Expected -cne $Actual) {
        $script:Failures.Add("FAIL $Label | expected [$Expected] actual [$Actual]")
    }
}

function Complete-Suite([string]$Name, [int]$MinimumAssertions) {
    if ($script:Assertions -lt $MinimumAssertions) {
        $script:Failures.Add("FAIL $Name ran only $($script:Assertions) assertions, fewer than the $MinimumAssertions required; the suite is vacuous")
    }
    if ($script:Failures.Count -gt 0) {
        foreach ($f in $script:Failures) { Write-Host $f -ForegroundColor Red }
        Write-Host ('SUITE {0}: FAILED ({1} of {2} assertions)' -f $Name, $script:Failures.Count, $script:Assertions) -ForegroundColor Red
        exit 1
    }
    Write-Host ('SUITE {0}: PASS ({1} assertions)' -f $Name, $script:Assertions) -ForegroundColor Green
    $script:Failures = New-Object System.Collections.Generic.List[string]
    $script:Assertions = 0
}

# --------------------------------------------------------------------------
# Shared fixtures
# --------------------------------------------------------------------------

$script:Frequency = 10000000
$script:Anchor = '2026-01-01T00:00:00.0000000Z'

# A clock sample in exactly the shape a record read back from disk has, so the
# unit tests below exercise the same code path as the file-backed ones.
function New-Sample {
    param(
        [long]$Monotonic,
        [string]$Utc,
        [string]$ClockAnchor = $script:Anchor,
        [long]$SampleFrequency = $script:Frequency,
        [string]$PromptKey = ''
    )
    return ([ordered]@{
            schema      = 1
            promptKey   = $PromptKey
            utc         = $Utc
            monotonic   = $Monotonic
            frequency   = $SampleFrequency
            clockAnchor = $ClockAnchor
        } | ConvertTo-Json -Compress | ConvertFrom-Json)
}

function New-SandboxDirectory([string]$Name) {
    $path = Join-Path $script:SandboxRoot ($Name + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    return $path
}

# Writes a start record whose monotonic reading is exactly $AgoMs behind now, so
# a real Resolve-TurnDuration call has a known answer without a real wait.
function Write-BackdatedStart {
    param(
        [string]$Directory,
        [string]$SessionKey,
        [string]$PromptKey,
        [double]$AgoMs
    )

    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $now = Get-TurnClockSample
    $nowUtc = [datetime]::Parse([string]$now.utc, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)

    $record = [ordered]@{
        schema      = 1
        promptKey   = $PromptKey
        utc         = $nowUtc.AddMilliseconds(-$AgoMs).ToString('o')
        monotonic   = [long]([long]$now.monotonic - [long](($AgoMs / 1000.0) * [long]$now.frequency))
        frequency   = [long]$now.frequency
        clockAnchor = [string]$now.clockAnchor
    }

    $target = Join-Path $Directory ($SessionKey + '.json')
    ($record | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $target -Encoding UTF8
    return $target
}

# Runs one mutation probe against a copy of the notifier and returns its verdict.
function Invoke-MutationProbe {
    param(
        [string]$Probe,
        [string]$Find = '',
        [string]$Replace = ''
    )

    $notifier = $NotifyPath
    if (-not [string]::IsNullOrWhiteSpace($Find)) {
        $source = Get-Content $NotifyPath -Raw
        if (-not $source.Contains($Find)) { return "MUTATION-TARGET-MISSING [$Find]" }
        $notifier = Join-Path $script:SandboxRoot ('mutant-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $source.Replace($Find, $Replace) | Set-Content -Path $notifier -Encoding UTF8
    }

    # The probe is deliberately pointed at broken code, so its stderr must be
    # captured rather than promoted into a terminating error.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ProbePath -Notifier $notifier -Probe $Probe 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }

    return (($output | Out-String).Trim())
}

# --------------------------------------------------------------------------
# Suite: semantics
# --------------------------------------------------------------------------

function Invoke-SemanticsSuite {
    # A. an exact interval. 1122 seconds of monotonic ticks is 18m 42s.
    $start = New-Sample -Monotonic 10000000000 -Utc '2026-01-01T00:16:40.0000000Z'
    $end = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T00:35:22.0000000Z'
    Assert-Equal '1122000' ([string](Measure-TurnDuration -Start $start -End $end)) 'A a known interval measures exactly'

    # The monotonic clock wins over wall time. Here the two disagree by hours,
    # and the monotonic answer must be the one reported.
    $skewedEnd = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T09:00:00.0000000Z'
    Assert-Equal '1122000' ([string](Measure-TurnDuration -Start $start -End $skewedEnd)) 'A a moved wall clock does not change the measurement'

    # A wall clock that jumped backwards is equally ignored.
    $rewoundEnd = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T00:00:01.0000000Z'
    Assert-Equal '1122000' ([string](Measure-TurnDuration -Start $start -End $rewoundEnd)) 'A a rewound wall clock does not change the measurement'

    # B. a reboot rebases the performance counter, so the anchors disagree and
    # wall time becomes the only available basis.
    $rebootStart = New-Sample -Monotonic 900000000000 -Utc '2026-01-01T00:00:00.0000000Z' -ClockAnchor '2025-12-01T00:00:00.0000000Z'
    $rebootEnd = New-Sample -Monotonic 100000000 -Utc '2026-01-01T00:01:30.0000000Z' -ClockAnchor '2026-01-01T00:00:00.0000000Z'
    Assert-Equal '90000' ([string](Measure-TurnDuration -Start $rebootStart -End $rebootEnd)) 'B a rebooted counter falls back to wall time'

    # A counter running at a different rate is not comparable either.
    $otherFrequency = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T00:35:22.0000000Z' -SampleFrequency 3579545
    Assert-Equal '1122000' ([string](Measure-TurnDuration -Start $start -End $otherFrequency)) 'B a different counter frequency falls back to wall time'

    # A drift below the tolerance is still the same boot.
    $driftedEnd = New-Sample -Monotonic 21220000000 -Utc '2026-01-01T00:35:22.0000000Z' -ClockAnchor '2026-01-01T00:00:03.0000000Z'
    Assert-Equal '1122000' ([string](Measure-TurnDuration -Start $start -End $driftedEnd)) 'B anchor drift inside the tolerance keeps the monotonic reading'

    # C. refusals. Each of these must yield no duration rather than a guess.
    $backwards = Measure-TurnDuration -Start $end -End $start
    Assert-That ($null -eq $backwards) 'C an end before its start yields nothing'

    # 86400 seconds is 864000000000 ticks at ten million ticks per second.
    $overCap = New-Sample -Monotonic ([long]10000000000 + [long]864000010000) -Utc '2026-01-02T00:16:41.0000000Z'
    Assert-That ($null -eq (Measure-TurnDuration -Start $start -End $overCap)) 'C a duration beyond the plausible maximum yields nothing'

    # Exactly at the maximum is still reported; one millisecond past it is not.
    $atCap = New-Sample -Monotonic ([long]10000000000 + [long]864000000000) -Utc '2026-01-02T00:16:40.0000000Z'
    Assert-Equal '86400000' ([string](Measure-TurnDuration -Start $start -End $atCap)) 'C the maximum plausible duration is still reported'

    $badTimestamp = New-Sample -Monotonic 10000000000 -Utc 'not-a-timestamp' -ClockAnchor 'not-a-timestamp'
    Assert-That ($null -eq (Measure-TurnDuration -Start $badTimestamp -End $end)) 'C an unparsable timestamp yields nothing'
    Assert-That ($null -eq (Measure-TurnDuration -Start $start -End $badTimestamp)) 'C an unparsable end timestamp yields nothing'

    $incomplete = ([ordered]@{ schema = 1; promptKey = '' } | ConvertTo-Json -Compress | ConvertFrom-Json)
    Assert-That ($null -eq (Measure-TurnDuration -Start $incomplete -End $end)) 'C a record missing its clock fields yields nothing'

    $zeroFrequency = New-Sample -Monotonic 10000000000 -Utc '2026-01-01T00:16:40.0000000Z' -SampleFrequency 0
    Assert-Equal '1122000' ([string](Measure-TurnDuration -Start $zeroFrequency -End $end)) 'C a zero frequency falls back to wall time'

    # D. round trip through the store over a real, if short, wait.
    $directory = New-SandboxDirectory 'semantics'
    $sessionKey = Get-OpaqueKey 'session-a'
    $promptKey = Get-OpaqueKey 'prompt-a'

    Assert-That (Save-TurnStart -StateDirectory $directory -SessionKey $sessionKey -PromptKey $promptKey) 'D a start is recorded'
    Assert-Equal '1' ([string](@(Get-ChildItem -Path $directory -Filter '*.json' -File)).Count) 'D exactly one record exists'

    Start-Sleep -Milliseconds 1200
    $measured = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionKey -PromptKey $promptKey
    Assert-That ($null -ne $measured) 'D a real wait is measured'
    Assert-That ($null -ne $measured -and [long]$measured -ge 1100 -and [long]$measured -le 15000) "D the real wait is about 1200 ms, measured $measured"

    # E. a backdated record gives a known answer without a real wait.
    $backdatedDirectory = New-SandboxDirectory 'semantics-backdated'
    Write-BackdatedStart -Directory $backdatedDirectory -SessionKey $sessionKey -PromptKey $promptKey -AgoMs 1122000 | Out-Null
    $backdated = Resolve-TurnDuration -StateDirectory $backdatedDirectory -SessionKey $sessionKey -PromptKey $promptKey
    Assert-That ($null -ne $backdated) 'E a backdated start is measured'
    Assert-That ($null -ne $backdated -and [math]::Abs([long]$backdated - 1122000) -le 5000) "E the backdated start measures about 1122000 ms, measured $backdated"

    # F. a key that is not a digest cannot address a file at all.
    Assert-Equal '' (Get-TurnStatePath -StateDirectory $directory -SessionKey '..\..\escape') 'F a traversal key addresses nothing'
    Assert-Equal '' (Get-TurnStatePath -StateDirectory $directory -SessionKey '') 'F an empty key addresses nothing'
    Assert-That (-not (Save-TurnStart -StateDirectory $directory -SessionKey '' -PromptKey $promptKey)) 'F a session with no id records nothing'
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $directory -SessionKey '' -PromptKey $promptKey)) 'F a session with no id measures nothing'

    # G. mutation controls. A deliberately broken notifier must fail the same
    # oracles, and the unmodified notifier must pass them.
    Assert-Equal 'PROBE elapsed : SURVIVED' (Invoke-MutationProbe -Probe 'elapsed') 'G the unmodified notifier passes the elapsed probe'
    Assert-Equal 'PROBE backwards : SURVIVED' (Invoke-MutationProbe -Probe 'backwards') 'G the unmodified notifier passes the backwards probe'

    $wrongUnit = Invoke-MutationProbe -Probe 'elapsed' -Find '$endFrequency) * 1000.0' -Replace '$endFrequency) * 1.0'
    Assert-Equal 'PROBE elapsed : KILLED' $wrongUnit 'G a notifier that reports seconds as milliseconds is detected'

    $wallOnly = Invoke-MutationProbe -Probe 'elapsed' -Find 'if ($sameClock) {' -Replace 'if ($false) {'
    Assert-Equal 'PROBE elapsed : KILLED' $wallOnly 'G a notifier that ignores the monotonic clock is detected'

    $noBackwardsGuard = Invoke-MutationProbe -Probe 'backwards' -Find 'if ($elapsedMs -lt 0) { return $null }' -Replace 'if ($false) { return $null }'
    Assert-Equal 'PROBE backwards : KILLED' $noBackwardsGuard 'G a notifier that accepts a negative duration is detected'

    Complete-Suite 'semantics' 28
}

# --------------------------------------------------------------------------
# Suite: correlation
# --------------------------------------------------------------------------

function Invoke-CorrelationSuite {
    $directory = New-SandboxDirectory 'correlation'

    $sessionA = Get-OpaqueKey 'session-a'
    $sessionB = Get-OpaqueKey 'session-b'
    $promptOne = Get-OpaqueKey 'prompt-one'
    $promptTwo = Get-OpaqueKey 'prompt-two'

    # Keys are derived, stable and distinct.
    Assert-Equal $sessionA (Get-OpaqueKey 'session-a') 'the same id always derives the same key'
    Assert-That ($sessionA -cne $sessionB) 'different ids derive different keys'
    Assert-That ($sessionA -match '^[0-9a-f]{32}$') 'a key is a fixed-length hex digest'
    Assert-Equal '' (Get-OpaqueKey '') 'an absent id derives no key'

    # A. the matching pair measures.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey $promptOne -AgoMs 60000 | Out-Null
    $matched = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptOne
    Assert-That ($null -ne $matched -and [math]::Abs([long]$matched - 60000) -le 5000) "A a matching pair measures, measured $matched"

    # B. the wrong session finds nothing, and leaves the right session's record
    # untouched for its own end.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey $promptOne -AgoMs 60000 | Out-Null
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionB -PromptKey $promptOne)) 'B a different session measures nothing'
    Assert-That (Test-Path (Join-Path $directory ($sessionA + '.json'))) "B the other session's record survives"
    $stillThere = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptOne
    Assert-That ($null -ne $stillThere) 'B the right session still measures afterwards'

    # C. a start left by an earlier prompt is refused and consumed, so it cannot
    # attach itself to any later turn either.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey $promptOne -AgoMs 60000 | Out-Null
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptTwo)) 'C a stale prompt measures nothing'
    Assert-That (-not (Test-Path (Join-Path $directory ($sessionA + '.json')))) 'C the refused record is consumed'
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptOne)) 'C the refused record cannot be measured later'

    # D. no start at all yields nothing.
    $emptyDirectory = New-SandboxDirectory 'correlation-empty'
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $emptyDirectory -SessionKey $sessionA -PromptKey $promptOne)) 'D a turn with no recorded start measures nothing'
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory (Join-Path $emptyDirectory 'missing') -SessionKey $sessionA -PromptKey $promptOne)) 'D a missing state directory measures nothing'

    # E. when a build supplies no prompt id, the session key is the only
    # correlation available and the pair is still measured.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey '' -AgoMs 60000 | Out-Null
    $noPrompt = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey ''
    Assert-That ($null -ne $noPrompt) 'E a pair with no prompt id is still measured by session'
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey '' -AgoMs 60000 | Out-Null
    Assert-That ($null -ne (Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptOne)) 'E a start with no prompt id is measured against an end that has one'

    # F. a corrupt record is refused and consumed rather than half-read.
    $corruptPath = Join-Path $directory ($sessionA + '.json')
    Set-Content -Path $corruptPath -Value 'this is not json' -Encoding UTF8
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptOne)) 'F a corrupt record measures nothing'
    Assert-That (-not (Test-Path $corruptPath)) 'F a corrupt record is consumed'

    # G. mutation control. A notifier that drops the prompt check must be caught.
    Assert-Equal 'PROBE correlation : SURVIVED' (Invoke-MutationProbe -Probe 'correlation') 'G the unmodified notifier passes the correlation probe'
    $noCorrelation = Invoke-MutationProbe -Probe 'correlation' -Find '$recordedPromptKey -cne $PromptKey) {' -Replace '$false) {'
    Assert-Equal 'PROBE correlation : KILLED' $noCorrelation 'G a notifier that ignores the prompt id is detected'

    Complete-Suite 'correlation' 19
}

# --------------------------------------------------------------------------
# Suite: concurrency
# --------------------------------------------------------------------------

function Invoke-ConcurrencySuite {
    $directory = New-SandboxDirectory 'concurrency'

    $sessionA = Get-OpaqueKey 'concurrent-session-a'
    $sessionB = Get-OpaqueKey 'concurrent-session-b'
    $promptA = Get-OpaqueKey 'concurrent-prompt-a'
    $promptB = Get-OpaqueKey 'concurrent-prompt-b'

    # start A, start B, end A, end B. A ran for ten minutes, B for one.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey $promptA -AgoMs 600000 | Out-Null
    Write-BackdatedStart -Directory $directory -SessionKey $sessionB -PromptKey $promptB -AgoMs 60000 | Out-Null
    Assert-Equal '2' ([string](@(Get-ChildItem -Path $directory -Filter '*.json' -File)).Count) 'two sessions keep two records'

    $endA = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptA
    Assert-That ($null -ne $endA -and [math]::Abs([long]$endA - 600000) -le 5000) "session A reports its own ten minutes, measured $endA"
    Assert-That (Test-Path (Join-Path $directory ($sessionB + '.json'))) "ending A leaves B's record alone"

    $endB = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionB -PromptKey $promptB
    Assert-That ($null -ne $endB -and [math]::Abs([long]$endB - 60000) -le 5000) "session B reports its own minute, measured $endB"
    Assert-That ($null -ne $endA -and $null -ne $endB -and [long]$endA -gt [long]$endB) 'the two sessions did not report the same figure'
    Assert-Equal '0' ([string](@(Get-ChildItem -Path $directory -Filter '*.json' -File)).Count) 'both records are consumed'

    # Interleaved the other way: start A, start B, end B, end A.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey $promptA -AgoMs 600000 | Out-Null
    Write-BackdatedStart -Directory $directory -SessionKey $sessionB -PromptKey $promptB -AgoMs 60000 | Out-Null
    $reverseB = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionB -PromptKey $promptB
    $reverseA = Resolve-TurnDuration -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptA
    Assert-That ($null -ne $reverseB -and [math]::Abs([long]$reverseB - 60000) -le 5000) "B still reports its own minute when it ends first, measured $reverseB"
    Assert-That ($null -ne $reverseA -and [math]::Abs([long]$reverseA - 600000) -le 5000) "A still reports its own ten minutes when it ends last, measured $reverseA"

    # A second session starting does not disturb the first session's record.
    Write-BackdatedStart -Directory $directory -SessionKey $sessionA -PromptKey $promptA -AgoMs 600000 | Out-Null
    $beforeB = Get-Content (Join-Path $directory ($sessionA + '.json')) -Raw
    Save-TurnStart -StateDirectory $directory -SessionKey $sessionB -PromptKey $promptB | Out-Null
    $afterB = Get-Content (Join-Path $directory ($sessionA + '.json')) -Raw
    Assert-Equal $beforeB $afterB 'a second session starting does not rewrite the first record'

    # A new prompt in the same session replaces that session's own record.
    $beforeRestart = Get-Content (Join-Path $directory ($sessionA + '.json')) -Raw
    Save-TurnStart -StateDirectory $directory -SessionKey $sessionA -PromptKey $promptB | Out-Null
    $afterRestart = Get-Content (Join-Path $directory ($sessionA + '.json')) -Raw
    Assert-That ($beforeRestart -cne $afterRestart) 'a new prompt replaces the same session record'
    Assert-Equal '2' ([string](@(Get-ChildItem -Path $directory -Filter '*.json' -File)).Count) 'replacing a record does not create a second one'

    Complete-Suite 'concurrency' 11
}

# --------------------------------------------------------------------------
# Suite: orphan
# --------------------------------------------------------------------------

function Invoke-OrphanSuite {
    $directory = New-SandboxDirectory 'orphan'

    $fresh = Get-OpaqueKey 'orphan-fresh'
    $stale = Get-OpaqueKey 'orphan-stale'
    $prompt = Get-OpaqueKey 'orphan-prompt'

    Save-TurnStart -StateDirectory $directory -SessionKey $fresh -PromptKey $prompt | Out-Null
    Save-TurnStart -StateDirectory $directory -SessionKey $stale -PromptKey $prompt | Out-Null

    $stalePath = Join-Path $directory ($stale + '.json')
    $staleTemp = Join-Path $directory 'interrupted.tmp'
    Set-Content -Path $staleTemp -Value '{"schema":1}' -Encoding UTF8

    # Age the abandoned records past the longest turn the notifier will report.
    $old = [datetime]::UtcNow.AddHours(-25)
    (Get-Item $stalePath).LastWriteTimeUtc = $old
    (Get-Item $staleTemp).LastWriteTimeUtc = $old

    # Control first: the sweeper must leave everything alone while nothing is old.
    $freshOnly = New-SandboxDirectory 'orphan-fresh-only'
    Save-TurnStart -StateDirectory $freshOnly -SessionKey $fresh -PromptKey $prompt | Out-Null
    Assert-Equal '0' ([string](Remove-StaleTurnState -StateDirectory $freshOnly)) 'the sweeper removes nothing when nothing is stale'
    Assert-Equal '1' ([string](@(Get-ChildItem -Path $freshOnly -File)).Count) 'a fresh record survives a sweep'

    $removed = Remove-StaleTurnState -StateDirectory $directory
    Assert-Equal '2' ([string]$removed) 'the sweeper removes the stale record and the interrupted write'
    Assert-That (-not (Test-Path $stalePath)) 'the stale record is gone'
    Assert-That (-not (Test-Path $staleTemp)) 'the interrupted write is gone'
    Assert-That (Test-Path (Join-Path $directory ($fresh + '.json'))) 'the fresh record survives'

    # An unrelated file is not the sweeper's business.
    $unrelated = Join-Path $directory 'notes.txt'
    Set-Content -Path $unrelated -Value 'keep me' -Encoding UTF8
    (Get-Item $unrelated).LastWriteTimeUtc = $old
    Assert-Equal '0' ([string](Remove-StaleTurnState -StateDirectory $directory)) 'the sweeper ignores files it did not write'
    Assert-That (Test-Path $unrelated) 'an unrelated file survives'

    # A missing directory is not an error.
    Assert-Equal '0' ([string](Remove-StaleTurnState -StateDirectory (Join-Path $directory 'nowhere'))) 'sweeping a missing directory removes nothing'
    Assert-Equal '0' ([string](Remove-StaleTurnState -StateDirectory '')) 'sweeping no directory removes nothing'

    # A start is consumed exactly once, so a repeated end cannot report it twice.
    $twice = New-SandboxDirectory 'orphan-twice'
    Write-BackdatedStart -Directory $twice -SessionKey $fresh -PromptKey $prompt -AgoMs 60000 | Out-Null
    $first = Resolve-TurnDuration -StateDirectory $twice -SessionKey $fresh -PromptKey $prompt
    $second = Resolve-TurnDuration -StateDirectory $twice -SessionKey $fresh -PromptKey $prompt
    Assert-That ($null -ne $first) 'the first end measures'
    Assert-That ($null -eq $second) 'a repeated end measures nothing'

    # An abandoned start that survives to the next turn is still refused,
    # because the age rule and the reporting cap are the same figure.
    $abandoned = New-SandboxDirectory 'orphan-abandoned'
    Write-BackdatedStart -Directory $abandoned -SessionKey $fresh -PromptKey '' -AgoMs 90000000 | Out-Null
    Assert-That ($null -eq (Resolve-TurnDuration -StateDirectory $abandoned -SessionKey $fresh -PromptKey '')) 'a start older than the cap measures nothing'

    # Explicit removal, used when the feature is switched off.
    $switchedOff = New-SandboxDirectory 'orphan-switched-off'
    Save-TurnStart -StateDirectory $switchedOff -SessionKey $fresh -PromptKey $prompt | Out-Null
    Assert-That (Remove-TurnState -StateDirectory $switchedOff -SessionKey $fresh) 'an existing record can be removed explicitly'
    Assert-That (-not (Remove-TurnState -StateDirectory $switchedOff -SessionKey $fresh)) 'removing an absent record reports nothing removed'

    Complete-Suite 'orphan' 15
}

# --------------------------------------------------------------------------
# Suite: rendering
# --------------------------------------------------------------------------

function Invoke-RenderingSuite {
    # Formatting is truncating, so a rendered figure never overstates.
    $expected = [ordered]@{
        '0'         = @{ en = '0s'; pt = '0s' }
        '999'       = @{ en = '0s'; pt = '0s' }
        '1000'      = @{ en = '1s'; pt = '1s' }
        '42999'     = @{ en = '42s'; pt = '42s' }
        '60000'     = @{ en = '1m 0s'; pt = '1min 0s' }
        '1122000'   = @{ en = '18m 42s'; pt = '18min 42s' }
        '3599999'   = @{ en = '59m 59s'; pt = '59min 59s' }
        '3600000'   = @{ en = '1h 0m'; pt = '1h 0min' }
        '7512000'   = @{ en = '2h 5m'; pt = '2h 5min' }
        '86400000'  = @{ en = '24h 0m'; pt = '24h 0min' }
    }

    foreach ($key in $expected.Keys) {
        $ms = [long]$key
        Assert-Equal ([string]$expected[$key].en) (Format-TurnDuration -DurationMs $ms -Locale 'en') "en formats $key"
        Assert-Equal ([string]$expected[$key].pt) (Format-TurnDuration -DurationMs $ms -Locale 'pt-BR') "pt-BR formats $key"
    }

    # An unknown locale falls back to the English units, as every other string does.
    foreach ($unknown in @('de', '', 'pt', 'en-US')) {
        Assert-Equal '18m 42s' (Format-TurnDuration -DurationMs 1122000 -Locale $unknown) "locale '$unknown' falls back to en units"
    }

    # Nothing measured renders nothing at all.
    Assert-Equal '' (Format-TurnDuration -DurationMs $null -Locale 'en') 'no measurement renders nothing'
    Assert-Equal '' (Format-TurnDuration -DurationMs -1 -Locale 'en') 'a negative measurement renders nothing'
    Assert-Equal '' (Format-TurnDuration -DurationMs 'nonsense' -Locale 'en') 'an unusable measurement renders nothing'

    # The message. Titles, priority and tags are the v0.1 contract and must not
    # move; only the body gains the elapsed figure.
    $payload = ([ordered]@{ cwd = 'C:\dev\my-project'; error = 'ToolExecutionFailure' } | ConvertTo-Json -Compress | ConvertFrom-Json)

    foreach ($state in @('finished', 'attention', 'error')) {
        foreach ($locale in @('en', 'pt-BR')) {
            foreach ($send in @($true, $false)) {
                $plainEvent = ConvertTo-AgentEvent -Payload $payload -EventState $state -Locale $locale -IncludeProjectLabel $send
                $timedEvent = ConvertTo-AgentEvent -Payload $payload -EventState $state -Locale $locale -IncludeProjectLabel $send -DurationMs 1122000
                $plain = Get-AgentMessage -AgentEvent $plainEvent
                $timed = Get-AgentMessage -AgentEvent $timedEvent
                $label = "$state/$locale/sendProjectName=$send"

                Assert-Equal ([string]$plain.Title) ([string]$timed.Title) "title is unchanged for $label"
                Assert-Equal ([string]$plain.Priority) ([string]$timed.Priority) "priority is unchanged for $label"
                Assert-Equal ([string]$plain.Tags) ([string]$timed.Tags) "tags are unchanged for $label"

                $unit = if ($locale -eq 'pt-BR') { '18min 42s' } else { '18m 42s' }
                Assert-Equal ([string]$plain.Body + " ($unit)") ([string]$timed.Body) "body gains exactly the elapsed figure for $label"

                # The project label still governs whether the folder name appears.
                if ($send) {
                    Assert-That (([string]$timed.Body).StartsWith('my-project - ')) "the project label survives for $label"
                }
                else {
                    Assert-That (([string]$timed.Body).StartsWith('Claude Code - ')) "the neutral label survives for $label"
                }
            }
        }
    }

    Complete-Suite 'rendering' 87
}

# --------------------------------------------------------------------------
# Suite: privacy
# --------------------------------------------------------------------------

$script:SecretCatalog = [ordered]@{
    prompt          = 'refactor the billing module for acme'
    sourceCode      = 'function Invoke-Billing { $total = 42 }'
    apiKey          = 'sk-ant-api03-DO-NOT-LEAK-0123456789'
    assistantOutput = 'Here is the patch you asked for.'
    transcriptPath  = 'C:\Users\bisma\.claude\projects\demo\transcript.jsonl'
    sessionId       = '11111111-2222-3333-4444-555555555555'
    promptId        = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    absolutePath    = 'D:\Programacao\Projetos\IDISTOPIC LAB\agentchime'
    arbitrarySecret = 'ARBITRARY-SECRET-TOKEN-9f8e7d6c5b4a'
}

function New-SensitivePayload {
    return ([ordered]@{
            cwd              = $script:SecretCatalog.absolutePath
            error            = 'ToolExecutionFailure'
            session_id       = $script:SecretCatalog.sessionId
            prompt_id        = $script:SecretCatalog.promptId
            transcript_path  = $script:SecretCatalog.transcriptPath
            prompt           = $script:SecretCatalog.prompt
            source_code      = $script:SecretCatalog.sourceCode
            api_key          = $script:SecretCatalog.apiKey
            assistant_output = $script:SecretCatalog.assistantOutput
            secret_token     = $script:SecretCatalog.arbitrarySecret
        } | ConvertTo-Json -Compress | ConvertFrom-Json)
}

function Find-Secrets([string]$Text) {
    $hits = @()
    foreach ($name in $script:SecretCatalog.Keys) {
        if ($Text -like ('*' + [string]$script:SecretCatalog[$name] + '*')) { $hits += $name }
    }
    if ([regex]::IsMatch($Text, '[A-Za-z]:\\')) { $hits += 'windowsAbsolutePath' }
    return ($hits | Sort-Object -Unique)
}

# Shadows the cmdlet for the whole test script so the ntfy request can be
# inspected without any network access.
$script:CapturedNtfyCalls = New-Object System.Collections.Generic.List[hashtable]
function Invoke-RestMethod {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [string]$Body,
        [string]$ContentType,
        [int]$TimeoutSec
    )
    $script:CapturedNtfyCalls.Add(@{
            Uri         = $Uri
            Method      = $Method
            Headers     = $Headers
            Body        = $Body
            ContentType = $ContentType
            TimeoutSec  = $TimeoutSec
        })
}

function Invoke-PrivacySuite {
    # Positive control first: prove the scanner detects every category it claims
    # to guard, so a clean result below means something.
    foreach ($name in $script:SecretCatalog.Keys) {
        $poisoned = 'prefix ' + [string]$script:SecretCatalog[$name] + ' suffix'
        Assert-That ((@(Find-Secrets $poisoned)) -contains $name) "scanner control detects $name"
    }
    Assert-That ((@(Find-Secrets 'see C:\Windows\notepad.exe')) -contains 'windowsAbsolutePath') 'scanner control detects a windows absolute path'
    Assert-Equal '' ((@(Find-Secrets 'my-project - Claude finished the task. (18m 42s)')) -join ',') 'scanner control passes a clean timed message'

    $payload = New-SensitivePayload
    $identity = Get-ClaudeTurnIdentity -Payload $payload

    # The keys the store is given carry nothing back to the ids they came from.
    Assert-Equal '' ((@(Find-Secrets ([string]$identity.SessionKey))) -join ',') 'the session key reveals no secret'
    Assert-Equal '' ((@(Find-Secrets ([string]$identity.PromptKey))) -join ',') 'the prompt key reveals no secret'
    Assert-That (([string]$identity.SessionKey) -notlike ('*' + $script:SecretCatalog.sessionId + '*')) 'the session key is not the session id'
    Assert-That (([string]$identity.PromptKey) -notlike ('*' + $script:SecretCatalog.promptId + '*')) 'the prompt key is not the prompt id'

    # What actually lands on disk.
    $directory = New-SandboxDirectory 'privacy'
    Save-TurnStart -StateDirectory $directory -SessionKey $identity.SessionKey -PromptKey $identity.PromptKey | Out-Null

    $files = @(Get-ChildItem -Path $directory -File)
    Assert-Equal '1' ([string]$files.Count) 'the start wrote exactly one file'
    Assert-Equal '' ((@(Find-Secrets ([string]$files[0].Name))) -join ',') 'the file name reveals no secret'

    $onDisk = Get-Content $files[0].FullName -Raw
    Assert-Equal '' ((@(Find-Secrets $onDisk)) -join ',') 'the state file content reveals no secret'
    Assert-That ($onDisk -notmatch '(?i)prompt"\s*:\s*"refactor') 'the state file holds no prompt text'

    # Control: the same scanner must light up on a record that did leak, so the
    # clean result above is not an artefact of scanning the wrong thing.
    $leaked = $onDisk.Replace('"promptKey":"' + [string]$identity.PromptKey + '"', '"promptKey":"' + $script:SecretCatalog.promptId + '"')
    Assert-That ((@(Find-Secrets $leaked)) -contains 'promptId') 'disk scanner control detects a leaked prompt id'

    # The normalized event, the rendered message and the ntfy request.
    $duration = Resolve-TurnDuration -StateDirectory $directory -SessionKey $identity.SessionKey -PromptKey $identity.PromptKey

    foreach ($state in @('finished', 'error')) {
        foreach ($locale in @('en', 'pt-BR')) {
            foreach ($send in @($true, $false)) {
                $label = "$state/$locale/sendProjectName=$send"
                $agentEvent = ConvertTo-AgentEvent -Payload $payload -EventState $state -Locale $locale -IncludeProjectLabel $send -DurationMs $duration

                $eventText = (@($agentEvent.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|')
                Assert-Equal '' ((@(Find-Secrets $eventText)) -join ',') "the normalized event is clean for $label"
                Assert-That ($eventText -notmatch '(?i)sessionkey|promptkey') "the normalized event carries no turn key for $label"

                $message = Get-AgentMessage -AgentEvent $agentEvent
                $messageText = "$($message.Title)|$($message.Body)|$($message.Priority)|$($message.Tags)"
                Assert-Equal '' ((@(Find-Secrets $messageText)) -join ',') "the rendered message is clean for $label"

                $script:CapturedNtfyCalls.Clear()
                $config = [pscustomobject]@{
                    locale  = $locale
                    desktop = [pscustomobject]@{ enabled = $true }
                    mobile  = [pscustomobject]@{ enabled = $true; provider = 'ntfy'; server = 'https://ntfy.sh'; topic = 'privacy-topic' }
                }
                Send-NtfyNotification -Config $config -Message $message
                Assert-Equal '1' ([string]$script:CapturedNtfyCalls.Count) "one ntfy request was captured for $label"
                $call = $script:CapturedNtfyCalls[0]
                $requestText = "$($call.Uri)|$($call.Body)|$($call.ContentType)|" + (@($call.Headers.Keys | Sort-Object | ForEach-Object { "$_=$($call.Headers[$_])" }) -join '|')
                Assert-Equal '' ((@(Find-Secrets $requestText)) -join ',') "the ntfy request is clean for $label"
                Assert-Equal 'Priority,Tags,Title' ((@($call.Headers.Keys | Sort-Object)) -join ',') "the ntfy headers are unchanged for $label"
            }
        }
    }

    Complete-Suite 'privacy' 68
}

# --------------------------------------------------------------------------

try {
    switch ($Suite) {
        'semantics'   { Invoke-SemanticsSuite }
        'correlation' { Invoke-CorrelationSuite }
        'concurrency' { Invoke-ConcurrencySuite }
        'orphan'      { Invoke-OrphanSuite }
        'rendering'   { Invoke-RenderingSuite }
        'privacy'     { Invoke-PrivacySuite }
        'contract'    {
            Invoke-SemanticsSuite
            Invoke-CorrelationSuite
            Invoke-ConcurrencySuite
            Invoke-OrphanSuite
            Invoke-RenderingSuite
            Invoke-PrivacySuite
            Write-Host 'SUITE duration-contract: PASS' -ForegroundColor Green
        }
    }

    # The mutation probes run as child processes, so say so explicitly.
    exit 0
}
finally {
    if (Test-Path $script:SandboxRoot) {
        Remove-Item $script:SandboxRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
