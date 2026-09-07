# Install, reinstall and uninstall contract, run entirely inside a disposable
# HOME.
#
# Windows PowerShell resolves $HOME once at engine start, so every step below
# launches a child powershell with HOMEDRIVE, HOMEPATH and USERPROFILE pointed
# at a temporary directory. The child then reads and writes its own
# .agentchime and .claude folders and never touches a real installation.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('lifecycle')]
    [string]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent

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
}

# --------------------------------------------------------------------------
# Disposable HOME
# --------------------------------------------------------------------------

$script:SandboxHome = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-home-' + [guid]::NewGuid().ToString('N'))
$script:RealHome = $HOME

if ($script:SandboxHome -eq $script:RealHome) { throw 'refusing to run: the sandbox resolved to the real home directory' }

New-Item -ItemType Directory -Force -Path $script:SandboxHome | Out-Null

$script:SavedEnvironment = @{
    HOMEDRIVE   = $env:HOMEDRIVE
    HOMEPATH    = $env:HOMEPATH
    USERPROFILE = $env:USERPROFILE
}

# Child processes inherit these, and a child powershell builds $HOME from them.
function Enter-SandboxEnvironment {
    $root = [System.IO.Path]::GetPathRoot($script:SandboxHome).TrimEnd('\')
    $env:HOMEDRIVE = $root
    $env:HOMEPATH = $script:SandboxHome.Substring($root.Length)
    $env:USERPROFILE = $script:SandboxHome
}

function Exit-SandboxEnvironment {
    $env:HOMEDRIVE = $script:SavedEnvironment.HOMEDRIVE
    $env:HOMEPATH = $script:SavedEnvironment.HOMEPATH
    $env:USERPROFILE = $script:SavedEnvironment.USERPROFILE
}

# Runs one script in the sandbox home and returns its output and exit code.
function Invoke-InSandbox {
    param(
        [string]$Script,
        [string[]]$ScriptArguments = @(),
        [string]$StandardInput = ''
    )

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ScriptArguments

    # Windows PowerShell wraps a native command's stderr in error records, and
    # this suite deliberately runs steps that are meant to fail. Capture the
    # stream instead of letting it terminate the suite.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ([string]::IsNullOrEmpty($StandardInput)) {
            $output = & powershell.exe @arguments 2>&1
        }
        else {
            $output = $StandardInput | & powershell.exe @arguments 2>&1
        }
    }
    finally {
        $ErrorActionPreference = $previous
    }

    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = (($output | Out-String).Trim())
    }
}

$script:SandboxAgentChime = Join-Path $script:SandboxHome '.agentchime'
$script:SandboxConfig = Join-Path $script:SandboxAgentChime 'config.json'
$script:SandboxNotify = Join-Path $script:SandboxAgentChime 'notify.ps1'
$script:SandboxTurns = Join-Path $script:SandboxAgentChime 'turns'
$script:SandboxSettings = Join-Path (Join-Path $script:SandboxHome '.claude') 'settings.json'

function Read-SandboxJson([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

# Counts handlers on one event whose arguments name the sandbox notifier.
function Measure-SandboxHandlers([object]$Settings, [string]$EventName) {
    $count = 0
    $states = @()
    if ($null -eq $Settings) { return [pscustomobject]@{ Count = 0; States = @() } }
    if (-not $Settings.PSObject.Properties['hooks']) { return [pscustomobject]@{ Count = 0; States = @() } }
    if (-not $Settings.hooks.PSObject.Properties[$EventName]) { return [pscustomobject]@{ Count = 0; States = @() } }

    foreach ($group in @($Settings.hooks.$EventName)) {
        if ($null -eq $group -or -not $group.PSObject.Properties['hooks']) { continue }
        foreach ($handler in @($group.hooks)) {
            if (-not $handler.PSObject.Properties['args']) { continue }
            $args = @($handler.args | ForEach-Object { [string]$_ })
            if ($args -contains $script:SandboxNotify) {
                $count++
                $states += $args[$args.Count - 1]
            }
        }
    }

    return [pscustomobject]@{ Count = $count; States = $states }
}

function Get-PrivacyFlag([object]$Config, [string]$Name) {
    if ($null -eq $Config) { return 'missing' }
    if (-not $Config.PSObject.Properties['privacy']) { return 'missing' }
    if (-not $Config.privacy.PSObject.Properties[$Name]) { return 'missing' }
    return ([string][bool]$Config.privacy.$Name)
}

# Reads a top-level configuration value, distinguishing an absent key from a
# stored empty one.
function Get-ConfigValue([object]$Config, [string]$Name) {
    if ($null -eq $Config) { return 'missing' }
    if (-not $Config.PSObject.Properties[$Name]) { return 'missing' }
    return ([string]$Config.$Name)
}

function Set-SandboxConfigValue([scriptblock]$Mutate) {
    $config = Read-SandboxJson $script:SandboxConfig
    & $Mutate $config
    $config | ConvertTo-Json -Depth 10 | Set-Content -Path $script:SandboxConfig -Encoding UTF8
}

# --------------------------------------------------------------------------
# Suite: lifecycle
# --------------------------------------------------------------------------

function Invoke-LifecycleSuite {
    $install = Join-Path $RepoRoot 'install.ps1'
    $uninstall = Join-Path $RepoRoot 'uninstall.ps1'
    $doctor = Join-Path $RepoRoot 'agentchime.ps1'

    # A. the sandbox really is somewhere else.
    $probe = Invoke-InSandbox -Script (Join-Path $PSScriptRoot 'print-home.ps1')
    Assert-Equal '0' ([string]$probe.ExitCode) 'A the home probe ran'
    Assert-Equal ("HOME=" + $script:SandboxHome) $probe.Output 'A a child resolves HOME to the sandbox'
    Assert-That ($script:RealHome -ne $script:SandboxHome) 'A the real home is untouched by this suite'

    # B. a fresh install.
    $fresh = Invoke-InSandbox -Script $install
    Assert-Equal '0' ([string]$fresh.ExitCode) "B a fresh install succeeds: $($fresh.Output)"
    Assert-That (Test-Path $script:SandboxNotify) 'B the notifier is installed'
    Assert-That (Test-Path $script:SandboxConfig) 'B a configuration is written'
    Assert-That (Test-Path $script:SandboxSettings) 'B Claude settings are written'

    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'True' (Get-PrivacyFlag $config 'sendDuration') 'B elapsed turn time is on by default'
    Assert-Equal 'True' (Get-PrivacyFlag $config 'sendProjectName') 'B the project-name preference is unchanged'
    Assert-Equal 'standard' (Get-ConfigValue $config 'detailLevel') 'B the notification detail level defaults to standard'

    $settings = Read-SandboxJson $script:SandboxSettings
    $expectedStates = [ordered]@{
        UserPromptSubmit = 'turn-start'
        Stop             = 'finished'
        StopFailure      = 'error'
        Notification     = 'attention'
    }
    foreach ($eventName in $expectedStates.Keys) {
        $handlers = Measure-SandboxHandlers -Settings $settings -EventName $eventName
        Assert-Equal '1' ([string]$handlers.Count) "B $eventName has exactly one AgentChime handler"
        Assert-Equal ([string]$expectedStates[$eventName]) (@($handlers.States) -join ',') "B $eventName runs the $($expectedStates[$eventName]) state"
    }

    # Control: the same inspector must find nothing on an event nobody registered.
    Assert-Equal '0' ([string](Measure-SandboxHandlers -Settings $settings -EventName 'PreToolUse').Count) 'B handler inspector control finds no handler on an unused event'

    # C. the installed hooks really do record and consume a turn.
    # Desktop delivery is switched off first so the end hook does not open a
    # balloon and wait for it.
    Set-SandboxConfigValue { param($c) $c.desktop.enabled = $false }

    $sessionId = '11111111-2222-3333-4444-555555555555'
    $promptId = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
    $startPayload = ([ordered]@{ session_id = $sessionId; prompt_id = $promptId; cwd = 'C:\dev\my-project' } | ConvertTo-Json -Compress)

    $started = Invoke-InSandbox -Script $script:SandboxNotify -ScriptArguments @('turn-start') -StandardInput $startPayload
    Assert-Equal '0' ([string]$started.ExitCode) "C the start hook exits cleanly: $($started.Output)"
    Assert-That (Test-Path $script:SandboxTurns) 'C the start hook created the turn state directory'
    $records = @(Get-ChildItem -Path $script:SandboxTurns -Filter '*.json' -File)
    Assert-Equal '1' ([string]$records.Count) 'C the start hook recorded exactly one turn'
    Assert-That (($records[0].Name) -notlike ('*' + $sessionId + '*')) 'C the record is not named after the session id'
    Assert-That ((Get-Content $records[0].FullName -Raw) -notlike ('*' + $promptId + '*')) 'C the record does not contain the prompt id'

    $ended = Invoke-InSandbox -Script $script:SandboxNotify -ScriptArguments @('finished') -StandardInput $startPayload
    Assert-Equal '0' ([string]$ended.ExitCode) "C the end hook exits cleanly: $($ended.Output)"
    Assert-Equal '0' ([string](@(Get-ChildItem -Path $script:SandboxTurns -Filter '*.json' -File)).Count) 'C the end hook consumed the recorded turn'

    # An attention notification arrives mid-turn and must leave the start alone.
    Invoke-InSandbox -Script $script:SandboxNotify -ScriptArguments @('turn-start') -StandardInput $startPayload | Out-Null
    $attention = Invoke-InSandbox -Script $script:SandboxNotify -ScriptArguments @('attention') -StandardInput $startPayload
    Assert-Equal '0' ([string]$attention.ExitCode) "C the attention hook exits cleanly: $($attention.Output)"
    Assert-Equal '1' ([string](@(Get-ChildItem -Path $script:SandboxTurns -Filter '*.json' -File)).Count) 'C an attention notification does not consume the turn'
    Invoke-InSandbox -Script $script:SandboxNotify -ScriptArguments @('finished') -StandardInput $startPayload | Out-Null

    # D. a reinstall preserves every existing preference.
    Set-SandboxConfigValue {
        param($c)
        $c.locale = 'pt-BR'
        $c.desktop.enabled = $true
        $c.mobile.enabled = $true
        $c.mobile.topic = 'preserved-topic-abc123'
        $c.mobile.server = 'https://ntfy.example.test'
        $c.privacy.sendProjectName = $false
        $c.privacy.sendDuration = $false
    }

    $reinstall = Invoke-InSandbox -Script $install
    Assert-Equal '0' ([string]$reinstall.ExitCode) "D a reinstall succeeds: $($reinstall.Output)"

    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'pt-BR' ([string]$config.locale) 'D the locale survives a reinstall'
    Assert-Equal 'True' ([string][bool]$config.mobile.enabled) 'D the mobile switch survives a reinstall'
    Assert-Equal 'preserved-topic-abc123' ([string]$config.mobile.topic) 'D the ntfy topic survives a reinstall'
    Assert-Equal 'https://ntfy.example.test' ([string]$config.mobile.server) 'D the ntfy server survives a reinstall'
    Assert-Equal 'False' (Get-PrivacyFlag $config 'sendProjectName') 'D the project-name preference survives a reinstall'
    Assert-Equal 'False' (Get-PrivacyFlag $config 'sendDuration') 'D the elapsed-time preference survives a reinstall'

    # E. the switches move the preference, and move nothing else.
    $enabled = Invoke-InSandbox -Script $install -ScriptArguments @('-EnableDuration')
    Assert-Equal '0' ([string]$enabled.ExitCode) "E -EnableDuration succeeds: $($enabled.Output)"
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'True' (Get-PrivacyFlag $config 'sendDuration') 'E -EnableDuration turns elapsed time on'
    Assert-Equal 'preserved-topic-abc123' ([string]$config.mobile.topic) 'E -EnableDuration leaves the topic alone'

    $disabled = Invoke-InSandbox -Script $install -ScriptArguments @('-DisableDuration')
    Assert-Equal '0' ([string]$disabled.ExitCode) "E -DisableDuration succeeds: $($disabled.Output)"
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'False' (Get-PrivacyFlag $config 'sendDuration') 'E -DisableDuration turns elapsed time off'
    Assert-Equal 'pt-BR' ([string]$config.locale) 'E -DisableDuration leaves the locale alone'

    $both = Invoke-InSandbox -Script $install -ScriptArguments @('-EnableDuration', '-DisableDuration')
    Assert-That ($both.ExitCode -ne 0) 'E contradicting switches are refused'

    # L. the notification detail level. It is a rendering preference, so the
    # installer only has to store it, preserve it, repair an unusable one and
    # refuse a level nobody defined.
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'standard' (Get-ConfigValue $config 'detailLevel') 'L the stored level is still the default here'

    Set-SandboxConfigValue { param($c) $c.detailLevel = 'minimal' }
    $kept = Invoke-InSandbox -Script $install
    Assert-Equal '0' ([string]$kept.ExitCode) "L a reinstall succeeds: $($kept.Output)"
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'minimal' (Get-ConfigValue $config 'detailLevel') 'L the detail level survives a reinstall'
    Assert-Equal 'pt-BR' ([string]$config.locale) 'L the reinstall left the locale alone'
    Assert-Equal 'preserved-topic-abc123' ([string]$config.mobile.topic) 'L the reinstall left the ntfy topic alone'

    # The switch moves the level, and moves nothing else.
    $standardRun = Invoke-InSandbox -Script $install -ScriptArguments @('-DetailLevel', 'standard')
    Assert-Equal '0' ([string]$standardRun.ExitCode) "L -DetailLevel standard succeeds: $($standardRun.Output)"
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'standard' (Get-ConfigValue $config 'detailLevel') 'L -DetailLevel standard stores the standard level'
    Assert-Equal 'False' (Get-PrivacyFlag $config 'sendDuration') 'L -DetailLevel standard leaves the privacy flags alone'

    $minimalRun = Invoke-InSandbox -Script $install -ScriptArguments @('-DetailLevel', 'minimal')
    Assert-Equal '0' ([string]$minimalRun.ExitCode) "L -DetailLevel minimal succeeds: $($minimalRun.Output)"
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'minimal' (Get-ConfigValue $config 'detailLevel') 'L -DetailLevel minimal stores the minimal level'
    Assert-That ($minimalRun.Output -like '*MINIMAL*') 'L the installer reports the level it stored'

    # A level nobody defined is refused at the switch rather than written.
    $bogus = Invoke-InSandbox -Script $install -ScriptArguments @('-DetailLevel', 'detailed')
    Assert-That ($bogus.ExitCode -ne 0) 'L an unrecognised level is refused'
    Assert-Equal 'minimal' (Get-ConfigValue (Read-SandboxJson $script:SandboxConfig) 'detailLevel') 'L a refused install changed nothing'

    # An upgrade from a configuration written before the key existed.
    Set-SandboxConfigValue { param($c) $c.PSObject.Properties.Remove('detailLevel') }
    Assert-Equal 'missing' (Get-ConfigValue (Read-SandboxJson $script:SandboxConfig) 'detailLevel') 'L the key really was removed'

    $upgraded = Invoke-InSandbox -Script $install
    Assert-Equal '0' ([string]$upgraded.ExitCode) "L an upgrade install succeeds: $($upgraded.Output)"
    $config = Read-SandboxJson $script:SandboxConfig
    Assert-Equal 'standard' (Get-ConfigValue $config 'detailLevel') 'L an upgrade adds the standard level'
    Assert-Equal 'False' (Get-PrivacyFlag $config 'sendProjectName') 'L an upgrade preserved the project-name preference'
    Assert-Equal 'pt-BR' ([string]$config.locale) 'L an upgrade preserved the locale'

    # A stored value nobody recognises is repaired rather than carried forward.
    Set-SandboxConfigValue { param($c) $c.detailLevel = 'verbose' }
    $repaired = Invoke-InSandbox -Script $install
    Assert-Equal '0' ([string]$repaired.ExitCode) "L a repair install succeeds: $($repaired.Output)"
    Assert-Equal 'standard' (Get-ConfigValue (Read-SandboxJson $script:SandboxConfig) 'detailLevel') 'L an unrecognised stored level is repaired to standard'

    # A recognised level spelled differently still means the same level. The
    # notifier reads it case-insensitively, so a reinstall must not quietly
    # restore the default instead.
    Set-SandboxConfigValue { param($c) $c.detailLevel = 'MINIMAL' }
    $cased = Invoke-InSandbox -Script $install
    Assert-Equal '0' ([string]$cased.ExitCode) "L a cased-level reinstall succeeds: $($cased.Output)"
    Assert-Equal 'minimal' (Get-ConfigValue (Read-SandboxJson $script:SandboxConfig) 'detailLevel') 'L a recognised level keeps its meaning whatever its casing'

    # The notifier itself must survive every stored level, including one a hand
    # edit introduced between installs. An unusable value degrades; it never
    # costs the user the notification.
    Set-SandboxConfigValue { param($c) $c.desktop.enabled = $false; $c.mobile.enabled = $false }
    foreach ($stored in @('minimal', 'standard', 'detailed', '')) {
        Set-SandboxConfigValue ({ param($c) $c.detailLevel = $stored }.GetNewClosure())
        $run = Invoke-InSandbox -Script $script:SandboxNotify -ScriptArguments @('finished') -StandardInput $startPayload
        Assert-Equal '0' ([string]$run.ExitCode) "L the notifier runs with a stored level of '$stored': $($run.Output)"
    }

    # F. several installs later there is still exactly one handler per event.
    $settings = Read-SandboxJson $script:SandboxSettings
    foreach ($eventName in $expectedStates.Keys) {
        Assert-Equal '1' ([string](Measure-SandboxHandlers -Settings $settings -EventName $eventName).Count) "F $eventName still has exactly one handler after repeated installs"
    }

    # G. a hook belonging to somebody else is never touched.
    $foreign = [pscustomobject]@{
        type    = 'command'
        command = 'powershell.exe'
        args    = @('-File', 'C:\other\tool.ps1', 'finished')
    }
    $settings = Read-SandboxJson $script:SandboxSettings
    $settings.hooks.Stop = @(@($settings.hooks.Stop) + [pscustomobject]@{ hooks = @($foreign) })
    $settings | ConvertTo-Json -Depth 100 | Set-Content -Path $script:SandboxSettings -Encoding UTF8

    Invoke-InSandbox -Script $install | Out-Null
    $settings = Read-SandboxJson $script:SandboxSettings
    Assert-That (((Get-Content $script:SandboxSettings -Raw)) -like '*other*tool.ps1*') 'G a foreign hook survives a reinstall'
    Assert-Equal '1' ([string](Measure-SandboxHandlers -Settings $settings -EventName 'Stop').Count) 'G the reinstall still leaves one AgentChime Stop handler'

    # H. uninstall keeping the configuration.
    New-Item -ItemType Directory -Force -Path $script:SandboxTurns | Out-Null
    $leftover = Join-Path $script:SandboxTurns '0123456789abcdef0123456789abcdef.json'
    Set-Content -Path $leftover -Value '{"schema":1}' -Encoding UTF8
    Assert-That (Test-Path $leftover) 'H a leftover turn record exists before uninstall'

    $keep = Invoke-InSandbox -Script $uninstall -ScriptArguments @('-KeepConfig')
    Assert-Equal '0' ([string]$keep.ExitCode) "H uninstall -KeepConfig succeeds: $($keep.Output)"
    Assert-That (Test-Path $script:SandboxConfig) 'H the configuration is kept'
    Assert-That (-not (Test-Path $script:SandboxNotify)) 'H the notifier is removed'
    Assert-That (-not (Test-Path $script:SandboxTurns)) 'H turn state is removed even when the configuration is kept'

    $settings = Read-SandboxJson $script:SandboxSettings
    foreach ($eventName in $expectedStates.Keys) {
        Assert-Equal '0' ([string](Measure-SandboxHandlers -Settings $settings -EventName $eventName).Count) "H $eventName no longer runs AgentChime"
    }
    Assert-That (((Get-Content $script:SandboxSettings -Raw)) -like '*other*tool.ps1*') 'H the foreign hook survives an uninstall'

    # I. a full uninstall removes everything AgentChime owns.
    Invoke-InSandbox -Script $install | Out-Null
    New-Item -ItemType Directory -Force -Path $script:SandboxTurns | Out-Null
    Set-Content -Path $leftover -Value '{"schema":1}' -Encoding UTF8

    $full = Invoke-InSandbox -Script $uninstall
    Assert-Equal '0' ([string]$full.ExitCode) "I a full uninstall succeeds: $($full.Output)"
    Assert-That (-not (Test-Path $script:SandboxAgentChime)) 'I the whole installation directory is removed'

    # J. doctor recognises the start hook, and misses it when it is gone.
    Invoke-InSandbox -Script $install | Out-Null
    Set-SandboxConfigValue { param($c) $c.mobile.enabled = $false }

    $healthy = Invoke-InSandbox -Script $doctor -ScriptArguments @('doctor')
    Assert-Equal '0' ([string]$healthy.ExitCode) "J doctor passes on a complete install: $($healthy.Output)"
    Assert-That ($healthy.Output -like '*UserPromptSubmit*') 'J doctor names the start hook'

    # Control: remove only the start hook and doctor must fail for that reason.
    $settings = Read-SandboxJson $script:SandboxSettings
    $settings.hooks.PSObject.Properties.Remove('UserPromptSubmit')
    $settings | ConvertTo-Json -Depth 100 | Set-Content -Path $script:SandboxSettings -Encoding UTF8

    $degraded = Invoke-InSandbox -Script $doctor -ScriptArguments @('doctor')
    Assert-That ($degraded.ExitCode -ne 0) 'J doctor fails when the start hook is missing'
    Assert-That ($degraded.Output -like '*Missing AgentChime hooks: UserPromptSubmit*') 'J doctor names the missing start hook'

    # K. the real home was never written to.
    Assert-That ($script:RealHome -ne $script:SandboxHome) 'K the sandbox and the real home stayed different'

    Complete-Suite 'lifecycle' 91
}

# --------------------------------------------------------------------------

try {
    Enter-SandboxEnvironment
    switch ($Suite) {
        'lifecycle' { Invoke-LifecycleSuite }
    }

    # Child processes leave their own status behind, so say so explicitly.
    exit 0
}
finally {
    Exit-SandboxEnvironment
    if (Test-Path $script:SandboxHome) {
        Remove-Item $script:SandboxHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}
