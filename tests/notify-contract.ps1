# Behavioral contract tests for src/notify.ps1.
#
# notify.ps1 loads its functions only when dot-sourced, so every suite below
# drives the real adapter, renderer and delivery code without sending a
# notification. Each suite prints a success-only token that the Unlazy gate
# ledger matches on.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('normalize', 'baseline', 'locales', 'privacy', 'desktop', 'ntfy', 'scope', 'ci', 'contract')]
    [string]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$NotifyPath = Join-Path $RepoRoot 'src\notify.ps1'
$FixturePath = Join-Path $PSScriptRoot 'fixtures\baseline-messages.json'
$BaselineCommit = '1d63f8fba1ddfab204d8d19436b8c872b0b0d812'

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

function Get-RenderedMessage([object]$Payload, [string]$State, [string]$Locale, [bool]$SendProjectName) {
    $agentEvent = ConvertTo-AgentEvent -Payload $Payload -EventState $State -Locale $Locale -IncludeProjectLabel $SendProjectName
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
    'hook_event_name',
    'stop_hook_active',
    'Payload',
    'HookInput',
    'ClaudeHookPayload',
    'ClaudePayloadValue',
    'ClaudeProjectLabel'
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
    $expectedFields = @('errorType', 'locale', 'projectLabel', 'provider', 'state')

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
    $downstream = @('Get-AgentMessage', 'Get-DesktopStyle', 'Send-WindowsNotification', 'Send-NtfyNotification')
    foreach ($name in $downstream) {
        $hits = @(Find-ClaudeVocabulary (Get-FunctionAst $name).Extent.Text)
        Assert-Equal '' ($hits -join ',') "F $name is free of Claude payload vocabulary"
    }

    # F control. The same detector must light up on the adapter, otherwise the
    # clean result above would be meaningless.
    $adapterHits = @(Find-ClaudeVocabulary (Get-FunctionAst 'ConvertTo-AgentEvent').Extent.Text)
    Assert-That ($adapterHits -contains 'Payload') 'F control detects Payload inside the adapter'
    $labelHits = @(Find-ClaudeVocabulary (Get-FunctionAst 'Get-ClaudeProjectLabel').Extent.Text)
    Assert-That ($labelHits -contains 'cwd') 'F control detects cwd inside the adapter'

    Complete-Suite 'normalize' 30
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

    Assert-Equal $BaselineCommit ([string]$fixture.baselineCommit) 'fixture records the pre-refactor commit'

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

    Complete-Suite 'baseline' 78
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
        $changed = @(& git diff --name-only $BaselineCommit -- . | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $untracked = @(& git ls-files --others --exclude-standard | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $touched = @($changed + $untracked | Sort-Object -Unique)

        # Non-vacuous: this step must actually have changed the notifier.
        Assert-That ($touched -contains 'src/notify.ps1') 'the refactor touched src/notify.ps1'
        Assert-That ($touched.Count -ge 2) 'the refactor touched the notifier and its tests'

        $allowed = '^(src/notify\.ps1|tests/.*|\.github/workflows/powershell\.yml)$'
        foreach ($path in $touched) {
            Assert-That ($path -match $allowed) "touched path stays in scope: $path"
        }

        # Frozen files must be byte-identical to the pre-refactor commit.
        $frozen = @('VERSION', 'install.ps1', 'bootstrap.ps1', 'uninstall.ps1', 'agentchime.ps1', 'config.example.json', 'RELEASE_NOTES_v0.1.0.md', 'CHANGELOG.md')
        foreach ($file in $frozen) {
            $diff = @(& git diff --name-only $BaselineCommit -- $file | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            Assert-Equal '' ($diff -join ',') "frozen file unchanged: $file"
        }

        Assert-Equal '0.1.0' ((Get-Content (Join-Path $RepoRoot 'VERSION') -Raw).Trim()) 'VERSION is untouched'
    }
    finally {
        Pop-Location
    }

    Complete-Suite 'scope' 12
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
    'locales'   { Invoke-LocalesSuite }
    'privacy'   { Invoke-PrivacySuite }
    'desktop'   { Invoke-DesktopSuite }
    'ntfy'      { Invoke-NtfySuite }
    'scope'     { Invoke-ScopeSuite }
    'ci'        { Invoke-CiSuite }
    'contract'  {
        Invoke-NormalizeSuite
        Invoke-BaselineSuite
        Invoke-LocalesSuite
        Invoke-PrivacySuite
        Invoke-DesktopSuite
        Invoke-NtfySuite
        Write-Host 'SUITE contract: PASS' -ForegroundColor Green
    }
}
