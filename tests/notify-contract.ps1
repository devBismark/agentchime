# Behavioral contract tests for src/notify.ps1.
#
# notify.ps1 loads its functions only when dot-sourced, so every suite below
# drives the real adapter, renderer and delivery code without sending a
# notification. Each suite prints a success-only token that the Unlazy gate
# ledger matches on.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('normalize', 'baseline', 'detail', 'locales', 'privacy', 'desktop', 'ntfy', 'scope', 'clean', 'ci', 'contract')]
    [string]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$NotifyPath = Join-Path $RepoRoot 'src\notify.ps1'
$FixturePath = Join-Path $PSScriptRoot 'fixtures\baseline-messages.json'

# The commit the 72-case message snapshot was captured from, before the
# normalization refactor. It still describes the messages exactly, which is the
# point: elapsed time must be additive, not a rewrite.
$FixtureCommit = '1d63f8fba1ddfab204d8d19436b8c872b0b0d812'

# The commit this step started from. Scope is measured against it.
$StepBaselineCommit = '2f5c15adf8aa97b87939baa21797a947fbd8ec98'

# The probe used by the detail suite's mutation controls.
$ProbePath = Join-Path $PSScriptRoot 'mutation-probe.ps1'

# Loads the functions only. The state argument satisfies the mandatory
# parameter; the dot-source guard inside notify.ps1 suppresses the main flow.
. $NotifyPath 'finished'

if (-not (Get-Command -Name 'ConvertTo-AgentEvent' -CommandType Function -ErrorAction SilentlyContinue)) {
    throw 'notify.ps1 did not expose ConvertTo-AgentEvent when dot-sourced.'
}

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

# Same six payload shapes the baseline snapshot was captured from. They are
# round-tripped through JSON so the tests see exactly the object shape stdin
# would produce.
function New-ClaudePayload([string]$Name) {
    $table = switch ($Name) {
        'full' {
            [ordered]@{
                cwd              = 'D:\Programacao\Projetos\IDISTOPIC LAB\agentchime'
                error            = 'ToolExecutionFailure'
                session_id       = '11111111-2222-3333-4444-555555555555'
                transcript_path  = 'C:\Users\bisma\.claude\projects\x\t.jsonl'
                prompt           = 'refactor the billing module'
                api_key          = 'sk-ant-SECRET'
                assistant_output = 'here is the code'
            }
        }
        'no-error'    { [ordered]@{ cwd = 'C:\dev\my-project' } }
        'null'        { $null }
        'empty-cwd'   { [ordered]@{ cwd = '   ' } }
        'blank-error' { [ordered]@{ cwd = 'C:\dev\my-project'; error = '   ' } }
        'unrelated'   { [ordered]@{ foo = 'bar' } }
        default       { throw "unknown payload fixture: $Name" }
    }

    if ($null -eq $table) { return $null }
    return ($table | ConvertTo-Json -Compress | ConvertFrom-Json)
}

function Get-RenderedMessage([object]$Payload, [string]$State, [string]$Locale, [bool]$SendProjectName, [object]$DurationMs = $null) {
    $agentEvent = ConvertTo-AgentEvent -Payload $Payload -EventState $State -Locale $Locale -IncludeProjectLabel $SendProjectName -DurationMs $DurationMs
    return (Get-AgentMessage -AgentEvent $agentEvent)
}

$script:NotifyAst = $null
function Get-NotifyAst {
    if ($null -eq $script:NotifyAst) {
        $tokens = $null
        $parseErrors = $null
        $script:NotifyAst = [System.Management.Automation.Language.Parser]::ParseFile($NotifyPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'src/notify.ps1 does not parse' }
    }
    return $script:NotifyAst
}

function Get-FunctionAst([string]$Name) {
    $ast = Get-NotifyAst
    $found = $ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if ($found.Count -ne 1) { throw "expected exactly one function named $Name in notify.ps1" }
    return $found[0]
}

# Claude Code payload vocabulary. Nothing below the adapter seam may mention it.
$script:ClaudeVocabulary = @(
    'cwd',
    'transcript_path',
    'session_id',
    'prompt_id',
    'hook_event_name',
    'stop_hook_active',
    'Payload',
    'HookInput',
    'ClaudeHookPayload',
    'ClaudePayloadValue',
    'ClaudeProjectLabel',
    'ClaudeTurnIdentity'
)

# Every function that must stay provider-neutral: rendering, delivery, and the
# whole turn-duration store, which is handed opaque keys rather than ids.
$script:DownstreamFunctions = @(
    'Get-AgentMessage',
    'Resolve-DetailLevel',
    'Get-DesktopStyle',
    'Send-WindowsNotification',
    'Send-NtfyNotification',
    'Format-TurnDuration',
    'Get-OpaqueKey',
    'Get-TurnClockSample',
    'ConvertFrom-TurnTimestamp',
    'Measure-TurnDuration',
    'Get-TurnStatePath',
    'Save-TurnStart',
    'Remove-TurnState',
    'Resolve-TurnDuration',
    'Remove-StaleTurnState'
)

# Returns which Claude-specific identifiers a block of script text mentions.
function Find-ClaudeVocabulary([string]$Text) {
    $hits = @()
    foreach ($token in $script:ClaudeVocabulary) {
        if ([regex]::IsMatch($Text, "(?i)(?<![A-Za-z0-9_-])$([regex]::Escape($token))(?![A-Za-z0-9_])")) {
            $hits += $token
        }
    }
    return $hits
}

# Returns $true when a function body reads the named variable.
function Test-ReferencesVariable([object]$FunctionAst, [string]$VariableName) {
    $found = $FunctionAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.VariableExpressionAst] -and
            $node.VariablePath.UserPath -eq $VariableName
        }, $true)
    return ($found.Count -gt 0)
}

# --------------------------------------------------------------------------
# Suite: normalize
# --------------------------------------------------------------------------

function Invoke-NormalizeSuite {
    $expectedFields = @('durationMs', 'errorType', 'locale', 'projectLabel', 'provider', 'state')

    # A. finished
    $a = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'full') -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
    Assert-Equal 'claude-code' ([string]$a.provider) 'A finished provider'
    Assert-Equal 'finished' ([string]$a.state) 'A finished state'
    Assert-Equal 'agentchime' ([string]$a.projectLabel) 'A finished projectLabel is the cwd leaf'
    Assert-Equal 'en' ([string]$a.locale) 'A finished locale'

    # B. attention
    $b = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'no-error') -EventState 'attention' -Locale 'pt-BR' -IncludeProjectLabel $true
    Assert-Equal 'attention' ([string]$b.state) 'B attention state'
    Assert-Equal 'my-project' ([string]$b.projectLabel) 'B attention projectLabel'
    Assert-Equal '' ([string]$b.errorType) 'B attention has no errorType'
    Assert-Equal 'pt-BR' ([string]$b.locale) 'B attention locale'

    # C. error
    $c = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'full') -EventState 'error' -Locale 'en' -IncludeProjectLabel $true
    Assert-Equal 'error' ([string]$c.state) 'C error state'
    Assert-Equal 'ToolExecutionFailure' ([string]$c.errorType) 'C error errorType'

    # D. missing or incomplete payloads degrade to the neutral label.
    foreach ($case in @('null', 'empty-cwd', 'unrelated')) {
        $d = ConvertTo-AgentEvent -Payload (New-ClaudePayload $case) -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
        Assert-Equal 'Claude Code' ([string]$d.projectLabel) "D $case degrades projectLabel"
        Assert-Equal '' ([string]$d.errorType) "D $case degrades errorType"
        Assert-Equal 'claude-code' ([string]$d.provider) "D $case keeps provider"
    }
    $dBlank = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'blank-error') -EventState 'error' -Locale 'en' -IncludeProjectLabel $true
    Assert-Equal '' ([string]$dBlank.errorType) 'D whitespace errorType normalizes to empty'

    # Privacy switch is honoured at the seam, so the real name never enters the event.
    $dPrivate = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'full') -EventState 'finished' -Locale 'en' -IncludeProjectLabel $false
    Assert-Equal 'Claude Code' ([string]$dPrivate.projectLabel) 'D privacy off keeps neutral projectLabel'

    # E. the event carries exactly the fields the notifier renders, nothing else.
    foreach ($case in @('full', 'no-error', 'null', 'unrelated')) {
        $e = ConvertTo-AgentEvent -Payload (New-ClaudePayload $case) -EventState 'error' -Locale 'en' -IncludeProjectLabel $true
        $names = @($e.PSObject.Properties.Name | Sort-Object)
        Assert-Equal ($expectedFields -join ',') ($names -join ',') "E $case event field set"
    }

    # F. no downstream function mentions the Claude payload vocabulary.
    foreach ($name in $script:DownstreamFunctions) {
        $hits = @(Find-ClaudeVocabulary (Get-FunctionAst $name).Extent.Text)
        Assert-Equal '' ($hits -join ',') "F $name is free of Claude payload vocabulary"
    }

    # F control. The same detector must light up on the adapter, otherwise the
    # clean result above would be meaningless.
    $adapterHits = @(Find-ClaudeVocabulary (Get-FunctionAst 'ConvertTo-AgentEvent').Extent.Text)
    Assert-That ($adapterHits -contains 'Payload') 'F control detects Payload inside the adapter'
    $labelHits = @(Find-ClaudeVocabulary (Get-FunctionAst 'Get-ClaudeProjectLabel').Extent.Text)
    Assert-That ($labelHits -contains 'cwd') 'F control detects cwd inside the adapter'
    $identityHits = @(Find-ClaudeVocabulary (Get-FunctionAst 'Get-ClaudeTurnIdentity').Extent.Text)
    Assert-That ($identityHits -contains 'session_id') 'F control detects session_id inside the adapter'
    Assert-That ($identityHits -contains 'prompt_id') 'F control detects prompt_id inside the adapter'

    # G. durationMs is optional, vendor neutral, and null without evidence.
    foreach ($case in @('full', 'no-error', 'null', 'unrelated')) {
        $g = ConvertTo-AgentEvent -Payload (New-ClaudePayload $case) -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
        Assert-That ($null -eq $g.durationMs) "G $case has no duration when none was measured"
    }

    # The payload cannot supply one: only the caller can, and only within the
    # plausible range.
    $gPayload = ([ordered]@{ cwd = 'C:\dev\my-project'; duration_ms = 999; durationMs = 999 } | ConvertTo-Json -Compress | ConvertFrom-Json)
    $gFromPayload = ConvertTo-AgentEvent -Payload $gPayload -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
    Assert-That ($null -eq $gFromPayload.durationMs) 'G a duration in the payload is ignored'

    $gMeasured = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'full') -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true -DurationMs 61000
    Assert-Equal '61000' ([string]$gMeasured.durationMs) 'G a measured duration is carried through'

    $gZero = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'full') -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true -DurationMs 0
    Assert-Equal '0' ([string]$gZero.durationMs) 'G zero is a measurement, not an absence'

    foreach ($rejected in @(-1, 86400001, 'not-a-number')) {
        $gBad = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'full') -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true -DurationMs $rejected
        Assert-That ($null -eq $gBad.durationMs) "G implausible duration '$rejected' is dropped"
    }

    Complete-Suite 'normalize' 50
}

# --------------------------------------------------------------------------
# Suite: baseline
# --------------------------------------------------------------------------

# Returns the field names whose values differ. Empty means byte-identical.
function Compare-Message([object]$Expected, [hashtable]$Actual) {
    $diffs = @()
    foreach ($field in @('Title', 'Body', 'Priority', 'Tags')) {
        if (([string]$Expected.$field) -cne ([string]$Actual.$field)) { $diffs += $field }
    }
    return $diffs
}

function Invoke-BaselineSuite {
    if (-not (Test-Path $FixturePath)) { throw "missing baseline fixture: $FixturePath" }
    $fixture = Get-Content $FixturePath -Raw | ConvertFrom-Json

    Assert-Equal $FixtureCommit ([string]$fixture.baselineCommit) 'fixture records the pre-refactor commit'

    $cases = @($fixture.cases.PSObject.Properties)
    Assert-Equal '72' ([string]$cases.Count) 'baseline covers the full 72 case matrix'

    foreach ($case in $cases) {
        $parts = ([string]$case.Name) -split '\|'
        if ($parts.Count -ne 4) { throw "malformed baseline key: $($case.Name)" }
        $payload = New-ClaudePayload $parts[0]
        $locale = $parts[1]
        $send = [bool]::Parse((($parts[2]) -replace '^sendProjectName=', ''))
        $state = $parts[3]

        $actual = Get-RenderedMessage -Payload $payload -State $state -Locale $locale -SendProjectName $send
        $diffs = @(Compare-Message -Expected $case.Value -Actual $actual)
        Assert-Equal '' ($diffs -join ',') "baseline $($case.Name)"
    }

    # Comparator controls. The comparator must accept an identical message and
    # reject a mutated one, otherwise every check above would pass vacuously.
    $sample = $cases[0].Value
    $identical = @{ Title = [string]$sample.Title; Body = [string]$sample.Body; Priority = [string]$sample.Priority; Tags = [string]$sample.Tags }
    Assert-Equal '' ((@(Compare-Message -Expected $sample -Actual $identical)) -join ',') 'comparator control accepts an identical message'

    foreach ($field in @('Title', 'Body', 'Priority', 'Tags')) {
        $mutated = @{ Title = [string]$sample.Title; Body = [string]$sample.Body; Priority = [string]$sample.Priority; Tags = [string]$sample.Tags }
        $mutated[$field] = ([string]$mutated[$field]) + '-MUTATED'
        Assert-Equal $field ((@(Compare-Message -Expected $sample -Actual $mutated)) -join ',') "comparator control rejects a mutated $field"
    }

    # Equivalence control. Rendering the same case with a measured duration must
    # differ from its baseline in the body alone. Without this, the 72 identical
    # results above could equally mean the feature was never implemented.
    foreach ($state in @('finished', 'attention', 'error')) {
        foreach ($locale in @('en', 'pt-BR')) {
            $plain = Get-RenderedMessage -Payload (New-ClaudePayload 'full') -State $state -Locale $locale -SendProjectName $true
            $timed = Get-RenderedMessage -Payload (New-ClaudePayload 'full') -State $state -Locale $locale -SendProjectName $true -DurationMs 1122000
            $timedDiffs = @(Compare-Message -Expected ([pscustomobject]$plain) -Actual $timed)
            Assert-Equal 'Body' ($timedDiffs -join ',') "a measured duration changes only the body for $state/$locale"
        }
    }

    Complete-Suite 'baseline' 85
}

# --------------------------------------------------------------------------
# Suite: detail
# --------------------------------------------------------------------------

# The exact body every state, locale and level must produce for one event that
# carries all three pieces of context. Written out in full rather than built
# from the renderer, so a change to the wording has to be made here too.
$script:DetailBodies = [ordered]@{
    'standard|en|finished'     = 'my-project - Claude finished the task. (18m 42s)'
    'standard|en|attention'    = 'my-project - Claude is waiting for your input. (18m 42s)'
    'standard|en|error'        = 'my-project - Claude stopped because of an error (ToolExecutionFailure). (18m 42s)'
    'standard|pt-BR|finished'  = 'my-project - O Claude terminou o trabalho. (18min 42s)'
    'standard|pt-BR|attention' = 'my-project - O Claude esta esperando sua intervencao. (18min 42s)'
    'standard|pt-BR|error'     = 'my-project - O Claude interrompeu o trabalho (ToolExecutionFailure). (18min 42s)'
    'minimal|en|finished'      = 'Claude finished the task.'
    'minimal|en|attention'     = 'Claude is waiting for your input.'
    'minimal|en|error'         = 'Claude stopped because of an error.'
    'minimal|pt-BR|finished'   = 'O Claude terminou o trabalho.'
    'minimal|pt-BR|attention'  = 'O Claude esta esperando sua intervencao.'
    'minimal|pt-BR|error'      = 'O Claude interrompeu o trabalho.'
}

$script:DetailSandbox = ''
function Get-DetailSandbox {
    if ([string]::IsNullOrWhiteSpace($script:DetailSandbox)) {
        $script:DetailSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-detail-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:DetailSandbox | Out-Null
    }
    return $script:DetailSandbox
}

# Runs one probe against a copy of the notifier with a single literal
# substitution applied, and returns its verdict line.
function Invoke-DetailMutationProbe {
    param(
        [string]$Probe,
        [string]$Find = '',
        [string]$Replace = ''
    )

    $notifier = $NotifyPath
    if (-not [string]::IsNullOrWhiteSpace($Find)) {
        $source = Get-Content $NotifyPath -Raw
        if (-not $source.Contains($Find)) { return "MUTATION-TARGET-MISSING [$Find]" }
        $notifier = Join-Path (Get-DetailSandbox) ('mutant-' + [guid]::NewGuid().ToString('N') + '.ps1')
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

# One event carrying every piece of context the notifier can render.
function New-DetailEvent {
    param(
        [string]$State,
        [string]$Locale,
        [bool]$SendProjectName = $true,
        [bool]$SendDuration = $true
    )
    $payload = ([ordered]@{ cwd = 'C:\dev\my-project'; error = 'ToolExecutionFailure' } | ConvertTo-Json -Compress | ConvertFrom-Json)
    $duration = if ($SendDuration) { 1122000 } else { $null }
    return (ConvertTo-AgentEvent -Payload $payload -EventState $State -Locale $Locale -IncludeProjectLabel $SendProjectName -DurationMs $duration)
}

# A configuration in the shape ConvertFrom-Json actually produces, so the
# preference reader is exercised against real property types rather than a
# hand-built object.
function New-DetailConfig([object]$Value, [bool]$Include = $true) {
    $table = [ordered]@{ version = '0.1.0'; locale = 'en' }
    if ($Include) { $table['detailLevel'] = $Value }
    $table['desktop'] = [ordered]@{ enabled = $true }
    return ($table | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json)
}

function Invoke-DetailSuite {
    try {
        # A. resolution. Every recognised spelling, and everything else
        # degrading to the level that reproduces the v0.1 message.
        # Pairs rather than a hashtable: PowerShell hash keys are case
        # insensitive, and the casing is part of what is under test.
        $resolution = @(
            @('minimal', 'minimal'),
            @('MINIMAL', 'minimal'),
            @('Minimal', 'minimal'),
            @('  minimal', 'minimal'),
            @('minimal  ', 'minimal'),
            @('standard', 'standard'),
            @('STANDARD', 'standard'),
            @(' standard', 'standard'),
            @('detailed', 'standard'),
            @('verbose', 'standard'),
            @('min', 'standard'),
            @('minimal!', 'standard'),
            @('full', 'standard'),
            @('', 'standard'),
            @('   ', 'standard')
        )
        foreach ($pair in $resolution) {
            Assert-Equal ([string]$pair[1]) (Resolve-DetailLevel $pair[0]) "A '$($pair[0])' resolves"
        }

        # Anything that is not a string carries no instruction at all.
        $nonStrings = [ordered]@{
            'null'    = $null
            'number'  = 42
            'boolean' = $true
            'array'   = @('minimal')
            'object'  = ([pscustomobject]@{ level = 'minimal' })
        }
        foreach ($kind in $nonStrings.Keys) {
            Assert-Equal 'standard' (Resolve-DetailLevel $nonStrings[$kind]) "A a $kind value resolves to standard"
        }

        # B. the configuration contract, read from real JSON shapes.
        Assert-Equal 'standard' (Get-DetailLevelPreference -Config (New-DetailConfig -Value $null -Include $false)) 'B a config with no detailLevel key is standard'
        Assert-Equal 'minimal' (Get-DetailLevelPreference -Config (New-DetailConfig -Value 'minimal')) 'B a config asking for minimal gets minimal'
        Assert-Equal 'standard' (Get-DetailLevelPreference -Config (New-DetailConfig -Value 'standard')) 'B a config asking for standard gets standard'
        foreach ($bad in @('detailed', 'verbose', '', '   ', 42, $true)) {
            Assert-Equal 'standard' (Get-DetailLevelPreference -Config (New-DetailConfig -Value $bad)) "B an invalid stored value '$bad' degrades to standard"
        }
        Assert-Equal 'standard' (Get-DetailLevelPreference -Config $null) 'B an unreadable config degrades to standard'

        # C. the rendered body at each level, for every state and locale.
        foreach ($level in @('standard', 'minimal')) {
            foreach ($locale in @('en', 'pt-BR')) {
                foreach ($state in @('finished', 'attention', 'error')) {
                    $agentEvent = New-DetailEvent -State $state -Locale $locale
                    $message = Get-AgentMessage -AgentEvent $agentEvent -Detail $level
                    Assert-Equal ([string]$script:DetailBodies["$level|$locale|$state"]) ([string]$message.Body) "C $level/$locale/$state body"
                }
            }
        }

        # D. the level never moves the title, the priority or the tags. A
        # minimal notification still says which state it is reporting.
        foreach ($locale in @('en', 'pt-BR')) {
            foreach ($state in @('finished', 'attention', 'error')) {
                $agentEvent = New-DetailEvent -State $state -Locale $locale
                $standard = Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard'
                $minimal = Get-AgentMessage -AgentEvent $agentEvent -Detail 'minimal'
                $diffs = @(Compare-Message -Expected ([pscustomobject]$standard) -Actual $minimal)
                Assert-Equal 'Body' ($diffs -join ',') "D only the body differs between levels for $locale/$state"
            }
        }

        # E. the default. Omitting the argument, passing standard, and passing
        # anything unrecognised must all render the same message, because that
        # is what an install written before this key existed will do.
        foreach ($locale in @('en', 'pt-BR')) {
            foreach ($state in @('finished', 'attention', 'error')) {
                $agentEvent = New-DetailEvent -State $state -Locale $locale
                $omitted = Get-AgentMessage -AgentEvent $agentEvent
                foreach ($supplied in @('standard', 'detailed', '', 'nonsense')) {
                    $actual = Get-AgentMessage -AgentEvent $agentEvent -Detail $supplied
                    $diffs = @(Compare-Message -Expected ([pscustomobject]$omitted) -Actual $actual)
                    Assert-Equal '' ($diffs -join ',') "E '$supplied' renders the default message for $locale/$state"
                }
            }
        }

        # F. privacy outranks detail, across the whole matrix.
        foreach ($level in @('standard', 'minimal')) {
            foreach ($locale in @('en', 'pt-BR')) {
                foreach ($state in @('finished', 'attention', 'error')) {
                    foreach ($sendProject in @($true, $false)) {
                        foreach ($sendDuration in @($true, $false)) {
                            $label = "$level/$locale/$state/project=$sendProject/duration=$sendDuration"
                            $agentEvent = New-DetailEvent -State $state -Locale $locale -SendProjectName $sendProject -SendDuration $sendDuration
                            $body = [string](Get-AgentMessage -AgentEvent $agentEvent -Detail $level).Body
                            $elapsed = if ($locale -eq 'pt-BR') { '18min 42s' } else { '18m 42s' }

                            # A suppressed project name never appears, whatever
                            # the level asks for.
                            if (-not $sendProject) {
                                Assert-That ($body -notlike '*my-project*') "F the project name stays suppressed for $label"
                            }

                            # A suppressed measurement never appears either.
                            if (-not $sendDuration) {
                                Assert-That ($body -notlike ('*' + $elapsed + '*')) "F the elapsed time stays suppressed for $label"
                            }

                            # The minimal level drops all three regardless of
                            # what privacy allowed.
                            if ($level -eq 'minimal') {
                                Assert-That ($body -notlike '*my-project*') "F minimal carries no project name for $label"
                                Assert-That ($body -notlike ('*' + $elapsed + '*')) "F minimal carries no elapsed time for $label"
                                Assert-That ($body -notlike '*ToolExecutionFailure*') "F minimal carries no error type for $label"
                            }

                            # Non-vacuity: with everything allowed, the standard
                            # level must actually be showing all of it.
                            if ($level -eq 'standard' -and $sendProject -and $sendDuration) {
                                Assert-That ($body -like '*my-project*') "F standard shows the project name for $label"
                                Assert-That ($body -like ('*' + $elapsed + '*')) "F standard shows the elapsed time for $label"
                                if ($state -eq 'error') {
                                    Assert-That ($body -like '*ToolExecutionFailure*') "F standard shows the error type for $label"
                                }
                            }
                        }
                    }
                }
            }
        }

        # G. mutation controls. The oracles above must be able to fail, so run
        # the probes against deliberately broken copies of the notifier.
        Assert-Equal 'PROBE detail : SURVIVED' (Invoke-DetailMutationProbe -Probe 'detail') 'G the detail probe survives the real notifier'
        Assert-Equal 'PROBE detail-privacy : SURVIVED' (Invoke-DetailMutationProbe -Probe 'detail-privacy') 'G the privacy probe survives the real notifier'

        # The find strings escape their dollar signs, so each one is the literal
        # line as it appears in the notifier rather than an interpolation.
        $mutants = [ordered]@{
            'a level that is never applied'     = @{ Probe = 'detail'; Find = "    if (`$level -eq 'minimal') {"; Replace = "    if (`$false) {" }
            'a level that is always minimal'    = @{ Probe = 'detail'; Find = "    `$level = Resolve-DetailLevel `$Detail"; Replace = "    `$level = 'minimal'" }
            'a level that keeps the error type' = @{ Probe = 'detail'; Find = "        `$errorType = ''"; Replace = "        `$errorType = `$errorType" }
            'a renderer that invents a label'   = @{ Probe = 'detail-privacy'; Find = "    `$project = [string]`$AgentEvent.projectLabel"; Replace = "    `$project = 'my-project'" }
            'a renderer that invents a time'    = @{ Probe = 'detail-privacy'; Find = "    `$durationMs = `$AgentEvent.durationMs"; Replace = "    `$durationMs = 1122000" }
        }
        foreach ($name in $mutants.Keys) {
            $mutant = $mutants[$name]
            $verdict = Invoke-DetailMutationProbe -Probe $mutant.Probe -Find $mutant.Find -Replace $mutant.Replace
            Assert-Equal ('PROBE ' + $mutant.Probe + ' : KILLED') $verdict "G the probe kills $name"
        }

        # H. the preference is actually wired into the one place that sends a
        # notification, rather than only being renderable from a test.
        $mainText = (Get-FunctionAst 'Invoke-AgentChimeNotification').Extent.Text
        Assert-That ($mainText -match '\$detailLevel\s*=\s*Get-DetailLevelPreference\s+-Config\s+\$config') 'H the notifier reads the configured level'
        Assert-That ($mainText -match 'Get-AgentMessage\s+-AgentEvent\s+\$agentEvent\s+-Detail\s+\$detailLevel') 'H the notifier renders with the configured level'

        # H control: the same matcher must reject a call that is not there.
        Assert-That (-not ($mainText -match 'Get-AgentMessage\s+-AgentEvent\s+\$agentEvent\s+-Detail\s+\$notAThing')) 'H wiring detector control rejects a call that is absent'
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($script:DetailSandbox) -and (Test-Path $script:DetailSandbox)) {
            Remove-Item $script:DetailSandbox -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Complete-Suite 'detail' 190
}

# --------------------------------------------------------------------------
# Suite: locales
# --------------------------------------------------------------------------

function Invoke-LocalesSuite {
    $payload = New-ClaudePayload 'full'

    $ptTitles = @{ finished = 'Claude Code - FINALIZADO'; attention = 'Claude Code - ATENCAO'; error = 'Claude Code - ERRO' }
    $enTitles = @{ finished = 'Claude Code - FINISHED'; attention = 'Claude Code - ATTENTION'; error = 'Claude Code - ERROR' }

    foreach ($state in @('finished', 'attention', 'error')) {
        $en = Get-RenderedMessage -Payload $payload -State $state -Locale 'en' -SendProjectName $true
        $pt = Get-RenderedMessage -Payload $payload -State $state -Locale 'pt-BR' -SendProjectName $true

        Assert-Equal $enTitles[$state] ([string]$en.Title) "en title for $state"
        Assert-Equal $ptTitles[$state] ([string]$pt.Title) "pt-BR title for $state"

        # Non-vacuous: the two locales must actually differ in title and body.
        $diffs = @(Compare-Message -Expected ([pscustomobject]$en) -Actual $pt)
        Assert-Equal 'Title,Body' ($diffs -join ',') "en and pt-BR differ in title and body for $state"

        # Priority and tags are locale independent.
        Assert-Equal ([string]$en.Priority) ([string]$pt.Priority) "priority is locale independent for $state"
        Assert-Equal ([string]$en.Tags) ([string]$pt.Tags) "tags are locale independent for $state"

        # Unknown and empty locales fall back to en.
        foreach ($unknown in @('de', '', 'pt', 'en-US')) {
            $fallback = Get-RenderedMessage -Payload $payload -State $state -Locale $unknown -SendProjectName $true
            $fallbackDiffs = @(Compare-Message -Expected ([pscustomobject]$en) -Actual $fallback)
            Assert-Equal '' ($fallbackDiffs -join ',') "locale '$unknown' falls back to en for $state"
        }
    }

    Complete-Suite 'locales' 27
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
    absolutePath    = 'D:\Programacao\Projetos\IDISTOPIC LAB\agentchime'
    arbitrarySecret = 'ARBITRARY-SECRET-TOKEN-9f8e7d6c5b4a'
}

function New-SensitivePayload {
    return ([ordered]@{
            cwd              = $script:SecretCatalog.absolutePath
            error            = 'ToolExecutionFailure'
            session_id       = $script:SecretCatalog.sessionId
            transcript_path  = $script:SecretCatalog.transcriptPath
            prompt           = $script:SecretCatalog.prompt
            source_code      = $script:SecretCatalog.sourceCode
            api_key          = $script:SecretCatalog.apiKey
            assistant_output = $script:SecretCatalog.assistantOutput
            secret_token     = $script:SecretCatalog.arbitrarySecret
        } | ConvertTo-Json -Compress | ConvertFrom-Json)
}

# Returns the names of every secret category present in the text, plus
# 'windowsAbsolutePath' when any drive-rooted path appears.
function Find-Secrets([string]$Text) {
    $hits = @()
    foreach ($name in $script:SecretCatalog.Keys) {
        if ($Text -like ('*' + [string]$script:SecretCatalog[$name] + '*')) { $hits += $name }
    }
    if ([regex]::IsMatch($Text, '[A-Za-z]:\\')) { $hits += 'windowsAbsolutePath' }
    return ($hits | Sort-Object -Unique)
}

function Invoke-PrivacySuite {
    $payload = New-SensitivePayload

    # Positive control first: prove the scanner detects every category it claims
    # to guard, so a clean result below means something.
    foreach ($name in $script:SecretCatalog.Keys) {
        $poisoned = 'prefix ' + [string]$script:SecretCatalog[$name] + ' suffix'
        Assert-That ((@(Find-Secrets $poisoned)) -contains $name) "scanner control detects $name"
    }
    Assert-That ((@(Find-Secrets 'see C:\Windows\notepad.exe')) -contains 'windowsAbsolutePath') 'scanner control detects a windows absolute path'
    Assert-Equal '' ((@(Find-Secrets 'agentchime - Claude finished the task.')) -join ',') 'scanner control passes a clean message'

    $ntfyCalls = New-Object System.Collections.Generic.List[hashtable]
    $script:CapturedNtfyCalls = $ntfyCalls

    foreach ($state in @('finished', 'attention', 'error')) {
        foreach ($locale in @('en', 'pt-BR')) {
            foreach ($send in @($true, $false)) {
                $agentEvent = ConvertTo-AgentEvent -Payload $payload -EventState $state -Locale $locale -IncludeProjectLabel $send
                $label = "$state/$locale/sendProjectName=$send"

                # The normalized event itself.
                $eventText = (@($agentEvent.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|')
                Assert-Equal '' ((@(Find-Secrets $eventText)) -join ',') "normalized event is clean for $label"

                # The rendered message, which is exactly what the desktop balloon shows.
                $message = Get-AgentMessage -AgentEvent $agentEvent
                $messageText = "$($message.Title)|$($message.Body)|$($message.Priority)|$($message.Tags)"
                Assert-Equal '' ((@(Find-Secrets $messageText)) -join ',') "rendered message is clean for $label"

                # The ntfy request, captured through the shadowed Invoke-RestMethod.
                $ntfyCalls.Clear()
                $config = New-MobileConfig -Enabled $true -Topic 'privacy-topic'
                Send-NtfyNotification -Config $config -Message $message
                Assert-Equal '1' ([string]$ntfyCalls.Count) "ntfy request captured for $label"
                $call = $ntfyCalls[0]
                $requestText = "$($call.Uri)|$($call.Body)|$($call.ContentType)|" + (@($call.Headers.Keys | Sort-Object | ForEach-Object { "$_=$($call.Headers[$_])" }) -join '|')
                Assert-Equal '' ((@(Find-Secrets $requestText)) -join ',') "ntfy request is clean for $label"
            }
        }
    }

    Complete-Suite 'privacy' 57
}

# --------------------------------------------------------------------------
# Suite: desktop
# --------------------------------------------------------------------------

function Invoke-DesktopSuite {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $expected = @{
        finished  = @{ Sound = 'Asterisk'; BalloonIcon = 'Info'; SystemIcon = 'Information' }
        attention = @{ Sound = 'Exclamation'; BalloonIcon = 'Warning'; SystemIcon = 'Warning' }
        error     = @{ Sound = 'Hand'; BalloonIcon = 'Error'; SystemIcon = 'Error' }
    }

    foreach ($state in @('finished', 'attention', 'error')) {
        $agentEvent = ConvertTo-AgentEvent -Payload (New-ClaudePayload 'no-error') -EventState $state -Locale 'en' -IncludeProjectLabel $true
        $style = Get-DesktopStyle -AgentEvent $agentEvent

        Assert-Equal ([string]$expected[$state].Sound) ([string]$style.Sound) "$state maps to its sound"
        Assert-Equal ([string]$expected[$state].BalloonIcon) ([string]$style.BalloonIcon) "$state maps to its balloon icon"
        Assert-Equal ([string]$expected[$state].SystemIcon) ([string]$style.SystemIcon) "$state maps to its system icon"

        # The names must resolve to real framework members, not just match strings.
        $soundName = [string]$style.Sound
        $iconName = [string]$style.SystemIcon
        $sound = [System.Media.SystemSounds]::$soundName
        $icon = [System.Drawing.SystemIcons]::$iconName
        $balloon = [System.Windows.Forms.ToolTipIcon]([string]$style.BalloonIcon)
        Assert-That ($null -ne $sound) "$state sound resolves to a SystemSound"
        Assert-That ($null -ne $icon) "$state icon resolves to a SystemIcon"
        Assert-Equal ([string]$expected[$state].BalloonIcon) ([string]$balloon) "$state balloon icon resolves to the enum value"
    }

    # Decoupling: desktop delivery reads the normalized event, not the script parameter.
    $sendFn = Get-FunctionAst 'Send-WindowsNotification'
    Assert-That (-not (Test-ReferencesVariable -FunctionAst $sendFn -VariableName 'State')) 'desktop delivery does not read the script State parameter'
    Assert-That (Test-ReferencesVariable -FunctionAst $sendFn -VariableName 'AgentEvent') 'desktop delivery reads the normalized event'

    # Control: the same detector must find State in the composition root, which
    # is the one place still allowed to read it.
    $mainFn = Get-FunctionAst 'Invoke-AgentChimeNotification'
    Assert-That (Test-ReferencesVariable -FunctionAst $mainFn -VariableName 'State') 'coupling detector control finds State in the composition root'

    # The balloon still carries the rendered title and body.
    $sendText = $sendFn.Extent.Text
    Assert-That ($sendText -match '\$notify\.BalloonTipTitle\s*=\s*\[string\]\$Message\.Title') 'balloon title comes from the rendered message'
    Assert-That ($sendText -match '\$notify\.BalloonTipText\s*=\s*\[string\]\$Message\.Body') 'balloon body comes from the rendered message'
    Assert-That ($sendText -match 'ShowBalloonTip\(6000\)') 'balloon timeout is unchanged'

    Complete-Suite 'desktop' 24
}

# --------------------------------------------------------------------------
# Suite: ntfy
# --------------------------------------------------------------------------

function New-MobileConfig {
    param(
        [bool]$Enabled = $true,
        [string]$Provider = 'ntfy',
        [string]$Server = 'https://ntfy.sh',
        [string]$Topic = 'agentchime-test'
    )
    return [pscustomobject]@{
        locale  = 'en'
        desktop = [pscustomobject]@{ enabled = $true }
        mobile  = [pscustomobject]@{ enabled = $Enabled; provider = $Provider; server = $Server; topic = $Topic }
    }
}

# Shadows the cmdlet for the whole test script so Send-NtfyNotification can be
# driven without any network access.
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

function Invoke-NtfySuite {
    $message = @{ Title = 'Claude Code - ERROR'; Body = 'my-project - Claude stopped because of an error (ToolExecutionFailure).'; Priority = 'high'; Tags = 'x,robot_face' }

    # Enabled path.
    $script:CapturedNtfyCalls.Clear()
    Send-NtfyNotification -Config (New-MobileConfig -Server 'https://ntfy.sh/' -Topic '  my topic  ') -Message $message
    Assert-Equal '1' ([string]$script:CapturedNtfyCalls.Count) 'enabled mobile sends exactly one request'

    $call = $script:CapturedNtfyCalls[0]
    Assert-Equal 'https://ntfy.sh/my%20topic' ([string]$call.Uri) 'uri is server slash escaped topic'
    Assert-Equal 'Post' ([string]$call.Method) 'method is Post'
    Assert-Equal ([string]$message.Body) ([string]$call.Body) 'body is the rendered message body'
    Assert-Equal 'text/plain; charset=utf-8' ([string]$call.ContentType) 'content type is unchanged'
    Assert-Equal '10' ([string]$call.TimeoutSec) 'timeout is unchanged'

    # No new field: the header set is exactly the three v0.1 headers.
    $headerNames = @($call.Headers.Keys | Sort-Object)
    Assert-Equal 'Priority,Tags,Title' ($headerNames -join ',') 'ntfy headers are exactly Title, Priority and Tags'
    Assert-Equal ([string]$message.Title) ([string]$call.Headers['Title']) 'Title header'
    Assert-Equal ([string]$message.Priority) ([string]$call.Headers['Priority']) 'Priority header'
    Assert-Equal ([string]$message.Tags) ([string]$call.Headers['Tags']) 'Tags header'

    # Guarded paths send nothing. The capture above proves these are not vacuous.
    $guards = [ordered]@{
        'mobile disabled'    = (New-MobileConfig -Enabled $false)
        'provider not ntfy'  = (New-MobileConfig -Provider 'pushover')
        'empty topic'        = (New-MobileConfig -Topic '   ')
        'empty server'       = (New-MobileConfig -Server '   ')
    }
    foreach ($guardName in $guards.Keys) {
        $script:CapturedNtfyCalls.Clear()
        Send-NtfyNotification -Config $guards[$guardName] -Message $message
        Assert-Equal '0' ([string]$script:CapturedNtfyCalls.Count) "guard '$guardName' sends nothing"
    }

    # The delivery function reads only the rendered message, never an event field.
    $ntfyFn = Get-FunctionAst 'Send-NtfyNotification'
    Assert-That (-not (Test-ReferencesVariable -FunctionAst $ntfyFn -VariableName 'AgentEvent')) 'ntfy delivery does not read the normalized event directly'
    Assert-That (Test-ReferencesVariable -FunctionAst $ntfyFn -VariableName 'Message') 'ntfy delivery reads the rendered message'

    Complete-Suite 'ntfy' 16
}

# --------------------------------------------------------------------------
# Suite: scope
# --------------------------------------------------------------------------

function Invoke-ScopeSuite {
    Push-Location $RepoRoot
    try {
        $changed = @(& git diff --name-only $StepBaselineCommit -- . | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $untracked = @(& git ls-files --others --exclude-standard | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $touched = @($changed + $untracked | Sort-Object -Unique)

        # Non-vacuous: this step must actually have changed the notifier and
        # registered the start marker.
        Assert-That ($touched -contains 'src/notify.ps1') 'this step touched src/notify.ps1'
        Assert-That ($touched -contains 'install.ps1') 'this step touched install.ps1'
        Assert-That ($touched.Count -ge 4) 'this step touched the notifier, the installer and their tests'

        $allowed = '^(src/notify\.ps1|install\.ps1|bootstrap\.ps1|agentchime\.ps1|config\.example\.json|CHANGELOG\.md|README\.md|tests/.*|docs/.*|\.github/workflows/powershell\.yml)$'
        foreach ($path in $touched) {
            Assert-That ($path -match $allowed) "touched path stays in scope: $path"
        }

        # Control: the same filter must reject a path this step has no business
        # writing, otherwise every result above would pass vacuously.
        Assert-That (-not ('uninstall.ps1' -match $allowed)) 'scope filter control rejects an out-of-scope path'
        Assert-That (-not ('VERSION' -match $allowed)) 'scope filter control rejects the version file'

        # Frozen files must be byte-identical to the commit this step started from.
        $frozen = @('VERSION', 'uninstall.ps1', 'LICENSE', 'RELEASE_NOTES_v0.1.0.md', 'scripts/package-release.ps1')
        foreach ($file in $frozen) {
            $diff = @(& git diff --name-only $StepBaselineCommit -- $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            Assert-Equal '' ($diff -join ',') "frozen file unchanged: $file"
        }

        Assert-Equal '0.1.0' ((Get-Content (Join-Path $RepoRoot 'VERSION') -Raw).Trim()) 'VERSION is untouched'

        # The features this step is explicitly not allowed to start. Each is
        # searched for as a working-tree identifier, not as prose.
        $excluded = [ordered]@{
            'notification history' = 'notificationHistory|notification-history|Add-NotificationHistory'
            'mobile auth'          = 'Authorization\s*=|ntfyToken|accessToken'
            'a command line tool'  = 'function\s+Invoke-AgentChimeCli|agentchime-cli'
            'codex support'        = 'ConvertTo-CodexEvent|Get-CodexPayloadValue|provider\s*=\s*.codex'
            'smarter project labels' = 'Get-SmartProjectLabel|Get-GitProjectLabel|projectLabelStrategy'
        }
        $sources = @('src/notify.ps1', 'install.ps1', 'agentchime.ps1', 'uninstall.ps1', 'bootstrap.ps1')
        $sourceText = (@($sources | ForEach-Object { Get-Content (Join-Path $RepoRoot $_) -Raw }) -join "`n")
        foreach ($feature in $excluded.Keys) {
            Assert-That (-not [regex]::IsMatch($sourceText, $excluded[$feature])) "out-of-scope feature absent: $feature"
        }

        # Control: the same detector must find something that is present.
        Assert-That ([regex]::IsMatch($sourceText, 'Resolve-TurnDuration')) 'exclusion detector control finds a symbol that is present'
    }
    finally {
        Pop-Location
    }

    Complete-Suite 'scope' 25
}

# --------------------------------------------------------------------------
# Suite: clean
# --------------------------------------------------------------------------

function Invoke-CleanSuite {
    Push-Location $RepoRoot
    try {
        $status = @(& git status --porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-Equal '' ($status -join '; ') 'the working tree has no modified, staged or untracked files'

        $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
        Assert-Equal 'main' $branch 'work is on main'

        $ahead = @(& git rev-list --count "origin/main..HEAD")
        Assert-Equal '0' (($ahead -join '').Trim()) 'HEAD is pushed to origin/main'

        # Control: git status must be able to report something, so prove the
        # parser sees a deliberately created file before it is removed again.
        $probe = Join-Path $RepoRoot 'scope-probe.tmp'
        Set-Content -Path $probe -Value 'probe' -Encoding UTF8
        $dirty = @(& git status --porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Remove-Item -Path $probe -Force
        Assert-That ($dirty.Count -eq 1) 'cleanliness control detects a deliberately dirty tree'

        $restored = @(& git status --porcelain | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        Assert-Equal '' ($restored -join '; ') 'the control file was removed again'
    }
    finally {
        Pop-Location
    }

    Complete-Suite 'clean' 5
}

# --------------------------------------------------------------------------
# Suite: ci
# --------------------------------------------------------------------------

function Invoke-CiSuite {
    Push-Location $RepoRoot
    try {
        $sha = (& git rev-parse HEAD).Trim()
        Assert-That ($sha.Length -eq 40) 'resolved a HEAD commit'

        $raw = & gh run list --limit 30 --json headSha,conclusion,status,workflowName
        if ($LASTEXITCODE -ne 0) { throw "gh run list failed: $raw" }

        # Windows PowerShell hands a JSON array to the pipeline as one object
        # instead of enumerating it, so unroll it explicitly rather than
        # wrapping it in @(), which would leave a single nested array behind.
        $parsed = ($raw -join "`n") | ConvertFrom-Json
        $runs = New-Object System.Collections.Generic.List[object]
        foreach ($item in $parsed) { $runs.Add($item) }
        Assert-That ($runs.Count -ge 1) 'gh returned at least one workflow run'

        $mine = @($runs | Where-Object { [string]$_.headSha -eq $sha })
        Assert-That ($mine.Count -ge 1) "remote CI has a run for $sha"
        foreach ($run in $mine) {
            Assert-Equal 'completed' ([string]$run.status) "run '$($run.workflowName)' completed"
            Assert-Equal 'success' ([string]$run.conclusion) "run '$($run.workflowName)' concluded success"
        }

        # Control: the same filter must find nothing for a commit that cannot
        # exist, otherwise the match above would prove nothing.
        $absent = @($runs | Where-Object { [string]$_.headSha -eq ('0' * 40) })
        Assert-Equal '0' ([string]$absent.Count) 'control finds no run for a commit that does not exist'
    }
    finally {
        Pop-Location
    }

    Complete-Suite 'ci' 6
}

# --------------------------------------------------------------------------

switch ($Suite) {
    'normalize' { Invoke-NormalizeSuite }
    'baseline'  { Invoke-BaselineSuite }
    'detail'    { Invoke-DetailSuite }
    'locales'   { Invoke-LocalesSuite }
    'privacy'   { Invoke-PrivacySuite }
    'desktop'   { Invoke-DesktopSuite }
    'ntfy'      { Invoke-NtfySuite }
    'scope'     { Invoke-ScopeSuite }
    'clean'     { Invoke-CleanSuite }
    'ci'        { Invoke-CiSuite }
    'contract'  {
        Invoke-NormalizeSuite
        Invoke-BaselineSuite
        Invoke-DetailSuite
        Invoke-LocalesSuite
        Invoke-PrivacySuite
        Invoke-DesktopSuite
        Invoke-NtfySuite
        Write-Host 'SUITE contract: PASS' -ForegroundColor Green
    }
}

# git and gh run as child processes, so say so explicitly.
exit 0
