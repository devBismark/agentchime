# Behavioral contract for Claude hook handler matching.
#
# install.ps1, uninstall.ps1 and agentchime.ps1 each decide, from a settings
# file somebody else may have edited, which handlers are AgentChime's. Getting
# that wrong either deletes a third-party hook or leaves a stale notifier
# running, so the decision is pinned here rather than left to the installer's
# end-to-end behaviour alone.
#
# agentchime.ps1 dispatches on a parameter and exits, so it cannot be
# dot-sourced the way src/notify.ps1 can. The named functions are lifted out of
# its syntax tree instead. No suite reads or writes a real installation.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('normalization', 'matching', 'state', 'removal', 'mutation', 'contract')]
    [string]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$CliPath = Join-Path $RepoRoot 'agentchime.ps1'
$InstallPath = Join-Path $RepoRoot 'install.ps1'
$UninstallPath = Join-Path $RepoRoot 'uninstall.ps1'
$ProbePath = Join-Path $PSScriptRoot 'handler-probe.ps1'

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Assertions = 0
$script:Sandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-handler-' + [guid]::NewGuid().ToString('N'))

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

function Get-FunctionText([string]$Path, [string]$Name) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot parse $Path" }
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($fn.Name -eq $Name) { return ($fn.Extent.Text -replace "`r", '') }
    }
    throw "$Path does not define $Name"
}

function Import-ScriptFunctions([string]$Path, [string[]]$Names) {
    $parts = @()
    foreach ($name in $Names) { $parts += (Get-FunctionText -Path $Path -Name $name) }
    return [scriptblock]::Create(($parts -join "`n`n"))
}

# The three entry points each carry their own copy of the two shared helpers.
# A copy that drifts would let the installer and the doctor disagree about who
# owns a handler, so identity is asserted before either copy is trusted.
$script:SharedHelpers = @('Get-NormalizedPathKey', 'Get-HandlerScriptPaths')

. (Import-ScriptFunctions -Path $CliPath -Names @('Get-NormalizedPathKey', 'Get-HandlerScriptPaths', 'Get-AgentChimeHandlerState', 'Measure-AgentChimeHandlers'))
. (Import-ScriptFunctions -Path $InstallPath -Names @('Test-HandlerTargetsPath', 'Remove-HandlersForPath'))

$NotifyPath = 'C:\Users\probe\.agentchime\notify.ps1'
$ForeignPath = 'C:\Tools\other-tool.ps1'

# Real handlers and settings reach the code as JSON, so build them the same way.
function New-Handler([string]$Command, [string[]]$Arguments) {
    $map = [ordered]@{ type = 'command'; command = $Command }
    if ($null -ne $Arguments) { $map['args'] = $Arguments }
    return ($map | ConvertTo-Json -Compress | ConvertFrom-Json)
}

function ConvertTo-JsonShape([object]$Value) {
    return ($Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
}

function New-OurHandler([string]$Spelling, [string]$State) {
    return (New-Handler 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Spelling, $State))
}

# --------------------------------------------------------------------------

function Invoke-NormalizationSuite {
    Assert-Equal 'c:\users\probe\.agentchime\notify.ps1' (Get-NormalizedPathKey 'C:/Users/probe/.agentchime/notify.ps1') 'forward slashes fold to backslashes'
    Assert-Equal 'c:\users\probe\.agentchime\notify.ps1' (Get-NormalizedPathKey 'C:\Users/probe\.agentchime/notify.ps1') 'mixed separators fold to backslashes'
    Assert-Equal 'c:\users\probe' (Get-NormalizedPathKey 'C:\Users\probe\') 'a trailing backslash is trimmed'
    Assert-Equal 'c:\users\probe' (Get-NormalizedPathKey 'C:/Users/probe/') 'a trailing forward slash is trimmed'
    Assert-Equal 'c:\' (Get-NormalizedPathKey 'C:\') 'a drive root keeps its separator'
    Assert-Equal 'c:\users\probe\.agentchime\notify.ps1' (Get-NormalizedPathKey '"C:\Users\probe\.agentchime\notify.ps1"') 'surrounding double quotes are stripped'
    Assert-Equal 'c:\users\probe\.agentchime\notify.ps1' (Get-NormalizedPathKey "'C:\Users\probe\.agentchime\notify.ps1'") 'surrounding single quotes are stripped'
    Assert-Equal 'c:\users\probe\.agentchime\notify.ps1' (Get-NormalizedPathKey "   C:\Users\probe\.agentchime\notify.ps1  ") 'surrounding whitespace is trimmed'
    Assert-Equal 'c:\users\probe\.agentchime\notify.ps1' (Get-NormalizedPathKey 'C:\USERS\PROBE\.AGENTCHIME\NOTIFY.PS1') 'case is folded'
    Assert-Equal '\\server\share\notify.ps1' (Get-NormalizedPathKey '\\server\share\notify.ps1') 'a UNC path keeps both leading separators'
    Assert-Equal '' (Get-NormalizedPathKey '') 'an empty path has no key'
    Assert-Equal '' (Get-NormalizedPathKey "   ") 'a whitespace path has no key'
    Assert-Equal '' (Get-NormalizedPathKey $null) 'a null path has no key'

    # The invariant this function exists for.
    Assert-Equal (Get-NormalizedPathKey 'C:\Users\probe\.agentchime\notify.ps1') (Get-NormalizedPathKey '"C:/Users/probe/.agentchime/notify.ps1"') 'every spelling of one file yields one key'

    # Control: the same comparison must separate two genuinely different files,
    # otherwise the equality above would prove nothing.
    Assert-That ((Get-NormalizedPathKey $NotifyPath) -ne (Get-NormalizedPathKey $ForeignPath)) 'control: two different files yield different keys'
    Assert-That ((Get-NormalizedPathKey 'C:\a\notify.ps1') -ne (Get-NormalizedPathKey 'C:\a\notify.ps1.bak')) 'control: a backup sibling is a different key'

    # The three entry points must agree on what a handler path means.
    foreach ($name in $script:SharedHelpers) {
        $fromCli = Get-FunctionText -Path $CliPath -Name $name
        Assert-Equal $fromCli (Get-FunctionText -Path $InstallPath -Name $name) "install.ps1 carries the same $name"
        Assert-Equal $fromCli (Get-FunctionText -Path $UninstallPath -Name $name) "uninstall.ps1 carries the same $name"
    }

    # Control: the comparison must be able to see a difference at all.
    Assert-That ((Get-FunctionText -Path $CliPath -Name 'Get-NormalizedPathKey') -ne (Get-FunctionText -Path $CliPath -Name 'Get-HandlerScriptPaths')) 'control: the text comparison separates two different functions'

    Complete-Suite 'normalization' 20
}

# --------------------------------------------------------------------------

function Invoke-MatchingSuite {
    $key = Get-NormalizedPathKey $NotifyPath

    $viaArgs = @(Get-HandlerScriptPaths -Handler (New-OurHandler $NotifyPath 'finished'))
    Assert-Equal $key ($viaArgs -join ',') 'a -File argument is reported'

    $viaCommand = @(Get-HandlerScriptPaths -Handler (New-Handler ('powershell.exe -NoProfile -File ' + $NotifyPath + ' finished') $null))
    Assert-Equal $key ($viaCommand -join ',') 'a path inside the command line is reported'

    $viaSlashes = @(Get-HandlerScriptPaths -Handler (New-Handler 'powershell.exe -NoProfile -File C:/Users/probe/.agentchime/notify.ps1 finished' $null))
    Assert-Equal $key ($viaSlashes -join ',') 'a forward-slash command line is reported under the same key'

    $viaQuotes = @(Get-HandlerScriptPaths -Handler (New-Handler ('powershell.exe -NoProfile -File "' + $NotifyPath + '" finished') $null))
    Assert-Equal $key ($viaQuotes -join ',') 'a quoted command line is reported under the same key'

    $viaUnc = @(Get-HandlerScriptPaths -Handler (New-Handler 'powershell.exe -File \\server\share\notify.ps1' $null))
    Assert-Equal '\\server\share\notify.ps1' ($viaUnc -join ',') 'a UNC command line is reported'

    $viaBak = @(Get-HandlerScriptPaths -Handler (New-Handler ('powershell.exe -File ' + $NotifyPath + '.bak') $null))
    Assert-That ($viaBak -notcontains $key) 'a backup sibling is never reported as the notifier'

    $viaLonger = @(Get-HandlerScriptPaths -Handler (New-Handler 'powershell.exe -File C:\Users\probe\.agentchime\mynotify.ps1' $null))
    Assert-That ($viaLonger -notcontains $key) 'a longer basename is not reported as the notifier'

    $viaBoth = @(Get-HandlerScriptPaths -Handler (New-Handler ('powershell.exe -File ' + $ForeignPath) @('-File', $NotifyPath)))
    Assert-Equal '2' ([string]$viaBoth.Count) 'a handler naming two scripts reports both'
    Assert-That ($viaBoth -contains $key) 'the notifier among two scripts is reported'
    Assert-That ($viaBoth -contains (Get-NormalizedPathKey $ForeignPath)) 'the foreign script among two is reported'

    $viaNone = @(Get-HandlerScriptPaths -Handler (New-Handler 'echo hello' @('-NoProfile', 'finished')))
    Assert-Equal '' ($viaNone -join ',') 'a handler that names no script reports nothing'

    $viaNull = @(Get-HandlerScriptPaths -Handler $null)
    Assert-Equal '' ($viaNull -join ',') 'a null handler reports nothing'

    $viaBare = @(Get-HandlerScriptPaths -Handler (New-Handler 'powershell.exe -File notify.ps1' $null))
    Assert-That ($viaBare -notcontains $key) 'an unanchored command-line name is not read as the installed notifier'

    Complete-Suite 'matching' 13
}

# --------------------------------------------------------------------------

function Invoke-StateSuite {
    Assert-Equal 'healthy' (Get-AgentChimeHandlerState -Handler (New-OurHandler $NotifyPath 'finished') -Path $NotifyPath) 'our own handler is healthy'
    Assert-Equal 'healthy' (Get-AgentChimeHandlerState -Handler (New-OurHandler 'C:/Users/probe/.agentchime/notify.ps1' 'finished') -Path $NotifyPath) 'a forward-slash spelling is healthy'
    Assert-Equal 'healthy' (Get-AgentChimeHandlerState -Handler (New-OurHandler '"C:\Users\probe\.agentchime\notify.ps1"' 'finished') -Path $NotifyPath) 'a quoted spelling is healthy'
    Assert-Equal 'healthy' (Get-AgentChimeHandlerState -Handler (New-OurHandler 'C:\USERS\PROBE\.AGENTCHIME\NOTIFY.PS1' 'finished') -Path $NotifyPath) 'a differently cased spelling is healthy'
    Assert-Equal 'healthy' (Get-AgentChimeHandlerState -Handler (New-Handler ('powershell.exe -NoProfile -File ' + $NotifyPath + ' finished') $null) -Path $NotifyPath) 'a command-line spelling is healthy'

    Assert-Equal 'none' (Get-AgentChimeHandlerState -Handler (New-OurHandler $ForeignPath 'finished') -Path $NotifyPath) 'a foreign handler is not ours'
    Assert-Equal 'none' (Get-AgentChimeHandlerState -Handler (New-Handler ('powershell.exe -File ' + $NotifyPath + '.bak') $null) -Path $NotifyPath) 'a backup sibling is not ours'
    Assert-Equal 'none' (Get-AgentChimeHandlerState -Handler (New-Handler 'echo hello' $null) -Path $NotifyPath) 'a handler naming no script is not ours'
    Assert-Equal 'none' (Get-AgentChimeHandlerState -Handler $null -Path $NotifyPath) 'a null handler is not ours'

    Assert-Equal 'ambiguous' (Get-AgentChimeHandlerState -Handler (New-Handler ('powershell.exe -File ' + $ForeignPath) @('-File', $NotifyPath)) -Path $NotifyPath) 'a handler naming a leftover script as well is ambiguous'
    Assert-Equal 'ambiguous' (Get-AgentChimeHandlerState -Handler (New-Handler ('powershell.exe -File ' + $NotifyPath) @('-File', $ForeignPath)) -Path $NotifyPath) 'ambiguity is reported whichever field carries the leftover'

    $single = ConvertTo-JsonShape ([ordered]@{ hooks = [ordered]@{ Stop = @(@{ hooks = @((New-OurHandler $NotifyPath 'finished')) }) } })
    $counts = Measure-AgentChimeHandlers -Settings $single -EventName 'Stop'
    Assert-Equal '1' ([string]$counts.Healthy) 'one installed handler counts once'
    Assert-Equal '0' ([string]$counts.Ambiguous) 'one installed handler is not ambiguous'

    $duplicated = ConvertTo-JsonShape ([ordered]@{ hooks = [ordered]@{ Stop = @(
        @{ hooks = @((New-OurHandler $NotifyPath 'finished')) },
        @{ hooks = @((New-OurHandler 'C:/Users/probe/.agentchime/notify.ps1' 'finished')) }
    ) } })
    $counts = Measure-AgentChimeHandlers -Settings $duplicated -EventName 'Stop'
    Assert-Equal '2' ([string]$counts.Healthy) 'the same file spelled two ways is counted as a duplicate'

    $mixed = ConvertTo-JsonShape ([ordered]@{ hooks = [ordered]@{ Stop = @(@{ hooks = @(
        (New-OurHandler $NotifyPath 'finished'),
        (New-Handler ('powershell.exe -File ' + $ForeignPath) @('-File', $NotifyPath)),
        (New-OurHandler $ForeignPath 'finished')
    ) }) } })
    $counts = Measure-AgentChimeHandlers -Settings $mixed -EventName 'Stop'
    Assert-Equal '1' ([string]$counts.Healthy) 'an ambiguous handler is not counted as healthy'
    Assert-Equal '1' ([string]$counts.Ambiguous) 'an ambiguous handler is counted as ambiguous'

    $counts = Measure-AgentChimeHandlers -Settings $mixed -EventName 'PreToolUse'
    Assert-Equal '0' ([string]$counts.Healthy) 'control: an event we never install on counts nothing'
    Assert-Equal '0' ([string]$counts.Ambiguous) 'control: an event we never install on has no ambiguity'

    $hookless = ConvertTo-JsonShape ([ordered]@{ hooks = [ordered]@{ Stop = @(@{ matcher = 'something' }) } })
    $counts = Measure-AgentChimeHandlers -Settings $hookless -EventName 'Stop'
    Assert-Equal '0' ([string]$counts.Healthy) 'a group with no hooks list is skipped rather than crashing'

    $noHooks = ConvertTo-JsonShape ([ordered]@{ other = 'value' })
    $counts = Measure-AgentChimeHandlers -Settings $noHooks -EventName 'Stop'
    Assert-Equal '0' ([string]$counts.Healthy) 'settings with no hooks section count nothing'

    Complete-Suite 'state' 20
}

# --------------------------------------------------------------------------

function Invoke-RemovalSuite {
    Assert-That (Test-HandlerTargetsPath -Handler (New-OurHandler $NotifyPath 'finished') -Path $NotifyPath) 'a backslash spelling is targeted for removal'
    Assert-That (Test-HandlerTargetsPath -Handler (New-OurHandler 'C:/Users/probe/.agentchime/notify.ps1' 'finished') -Path $NotifyPath) 'a forward-slash spelling is targeted for removal'
    Assert-That (-not (Test-HandlerTargetsPath -Handler (New-OurHandler $ForeignPath 'finished') -Path $NotifyPath)) 'a foreign handler is never targeted for removal'
    Assert-That (-not (Test-HandlerTargetsPath -Handler (New-Handler ('powershell.exe -File ' + $NotifyPath + '.bak') $null) -Path $NotifyPath)) 'a backup sibling is never targeted for removal'
    Assert-That (-not (Test-HandlerTargetsPath -Handler (New-OurHandler $NotifyPath 'finished') -Path '')) 'an empty path targets nothing, so a bad call cannot delete every hook'
    Assert-That (-not (Test-HandlerTargetsPath -Handler (New-OurHandler $NotifyPath 'finished') -Path '   ')) 'a whitespace path targets nothing'

    # Deliberate asymmetry: the doctor reports an ambiguous handler so a person
    # can look at it, while a reinstall removes it and writes a clean one.
    Assert-Equal 'ambiguous' (Get-AgentChimeHandlerState -Handler (New-Handler ('powershell.exe -File ' + $ForeignPath) @('-File', $NotifyPath)) -Path $NotifyPath) 'the doctor reports an ambiguous handler'
    Assert-That (Test-HandlerTargetsPath -Handler (New-Handler ('powershell.exe -File ' + $ForeignPath) @('-File', $NotifyPath)) -Path $NotifyPath) 'a reinstall removes an ambiguous handler instead of leaving it behind'

    $settings = ConvertTo-JsonShape ([ordered]@{
        hooks = [ordered]@{
            Stop         = @(@{ hooks = @((New-OurHandler $NotifyPath 'finished'), (New-OurHandler $ForeignPath 'finished')) })
            Notification = @(@{ hooks = @((New-OurHandler 'C:/Users/probe/.agentchime/notify.ps1' 'attention')) })
            PreToolUse   = @(@{ matcher = 'Bash'; hooks = @((New-OurHandler $ForeignPath 'finished')) })
            SessionStart = @(@{ matcher = 'startup' })
        }
    })

    Assert-Equal '1' ([string](Measure-AgentChimeHandlers -Settings $settings -EventName 'Stop').Healthy) 'control: our Stop handler exists before removal'
    Assert-Equal '1' ([string](Measure-AgentChimeHandlers -Settings $settings -EventName 'Notification').Healthy) 'control: our Notification handler exists before removal'

    Remove-HandlersForPath -Settings $settings -Path $NotifyPath

    Assert-Equal '0' ([string](Measure-AgentChimeHandlers -Settings $settings -EventName 'Stop').Healthy) 'our Stop handler is removed'
    Assert-Equal '0' ([string](Measure-AgentChimeHandlers -Settings $settings -EventName 'Notification').Healthy) 'a forward-slash handler is removed too'
    Assert-Equal '1' ([string](@($settings.hooks.Stop[0].hooks)).Count) 'the foreign handler sharing our group survives'
    Assert-Equal '0' ([string](@($settings.hooks.Notification)).Count) 'a group left empty is dropped rather than kept as a husk'
    Assert-Equal '1' ([string](@($settings.hooks.PreToolUse)).Count) 'an unrelated third-party event is untouched'
    Assert-Equal 'Bash' ([string]$settings.hooks.PreToolUse[0].matcher) 'the third-party matcher is preserved'
    Assert-Equal '1' ([string](@($settings.hooks.SessionStart)).Count) 'a group with no hooks list is preserved rather than deleted'
    Assert-That ((@($settings.hooks.Stop[0].hooks))[0].args -contains $ForeignPath) 'the surviving handler is the foreign one'
    Assert-Equal '4' ([string](@($settings.hooks.PSObject.Properties)).Count) 'no hook event is deleted from the settings file'

    $before = $settings | ConvertTo-Json -Depth 20
    Remove-HandlersForPath -Settings $settings -Path $NotifyPath
    Assert-Equal $before ($settings | ConvertTo-Json -Depth 20) 'a second removal changes nothing'

    Complete-Suite 'removal' 20
}

# --------------------------------------------------------------------------

# Each mutation breaks exactly one rule in a throwaway copy of agentchime.ps1.
# The probe must survive the real file and die on the copy; without both halves
# a probe that always reported KILLED would look like proof.
function Invoke-MutationSuite {
    New-Item -ItemType Directory -Force -Path $script:Sandbox | Out-Null
    $pristine = Get-Content $CliPath -Raw

    $mutations = [ordered]@{
        'separator' = @(
            "`$value = `$Path.Trim().Trim('`"').Trim(`"'`").Replace('/', '\')",
            "`$value = `$Path.Trim().Trim('`"').Trim(`"'`")"
        )
        'suffix'    = @(
            '\.ps1(?![a-z0-9._-])',
            '\.ps1'
        )
        'ambiguous' = @(
            "if (@(`$paths | Where-Object { `$_ -ne `$key }).Count -gt 0) { return 'ambiguous' }",
            "if (`$false) { return 'ambiguous' }"
        )
        'foreign'   = @(
            "if (`$paths -notcontains `$key) { return 'none' }",
            "if (`$false) { return 'none' }"
        )
    }

    foreach ($probe in $mutations.Keys) {
        $find = $mutations[$probe][0]
        $replace = $mutations[$probe][1]

        $survived = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ProbePath -Source $CliPath -Probe $probe
        Assert-Equal ('PROBE {0}: SURVIVED' -f $probe) (($survived | Out-String).Trim()) "the $probe expectation holds against the real file"

        Assert-That ($pristine.Contains($find)) "the $probe mutation has something to change"
        $mutated = $pristine.Replace($find, $replace)
        Assert-That ($mutated -ne $pristine) "the $probe mutation actually changed the copy"

        $copy = Join-Path $script:Sandbox ("agentchime-$probe.ps1")
        Set-Content -Path $copy -Value $mutated -Encoding UTF8

        $killed = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ProbePath -Source $copy -Probe $probe
        Assert-Equal ('PROBE {0}: KILLED' -f $probe) (($killed | Out-String).Trim()) "the $probe expectation fails once the rule is broken"
    }

    Complete-Suite 'mutation' 16
}

# --------------------------------------------------------------------------

try {
    switch ($Suite) {
        'normalization' { Invoke-NormalizationSuite }
        'matching'      { Invoke-MatchingSuite }
        'state'         { Invoke-StateSuite }
        'removal'       { Invoke-RemovalSuite }
        'mutation'      { Invoke-MutationSuite }
        'contract'      {
            Invoke-NormalizationSuite
            Invoke-MatchingSuite
            Invoke-StateSuite
            Invoke-RemovalSuite
            Invoke-MutationSuite
            Write-Host 'SUITE handler-contract: PASS' -ForegroundColor Green
        }
    }

    # The mutation probes run as child processes, so say so explicitly.
    exit 0
}
finally {
    if (Test-Path $script:Sandbox) {
        Remove-Item $script:Sandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}
