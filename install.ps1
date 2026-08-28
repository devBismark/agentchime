[CmdletBinding()]
param(
    [switch]$EnableMobile,
    [switch]$DisableMobile,
    [string]$NtfyTopic = '',
    [string]$NtfyServer = '',
    [ValidateSet('', 'en', 'pt-BR')]
    [string]$Locale = '',
    [switch]$MigratePrototype,
    [switch]$MigrateTaskChime
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentChimeVersion = '0.1.0'

if ($env:OS -ne 'Windows_NT') {
    throw 'AgentChime v0.1 currently supports Windows only.'
}

if ($EnableMobile -and $DisableMobile) {
    throw 'Use either -EnableMobile or -DisableMobile, not both.'
}

$RepoDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($RepoDir)) {
    throw 'Run install.ps1 from a cloned/downloaded AgentChime repository.'
}

$SourceNotify = Join-Path $RepoDir 'src\notify.ps1'
if (-not (Test-Path $SourceNotify)) {
    throw "Missing source file: $SourceNotify"
}

# Current AgentChime paths.
$InstallDir = Join-Path $HOME '.agentchime'
$BackupDir = Join-Path $InstallDir 'backups'
$NotifyPath = Join-Path $InstallDir 'notify.ps1'
$ConfigPath = Join-Path $InstallDir 'config.json'
$SettingsPath = Join-Path (Join-Path $HOME '.claude') 'settings.json'

# Pre-publication TaskChime brand paths. These are read for safe automatic migration.
$TaskChimeDir = Join-Path $HOME '.taskchime'
$TaskChimeConfigPath = Join-Path $TaskChimeDir 'config.json'
$TaskChimeNotifyPath = Join-Path $TaskChimeDir 'notify.ps1'

# Earliest prototype paths, used only when -MigratePrototype is requested.
$PrototypeConfigPath = Join-Path (Join-Path $HOME '.claude') 'taskchime.json'
$PrototypeNotifyPath = Join-Path (Join-Path (Join-Path $HOME '.claude') 'hooks') 'notify.ps1'

function Load-JsonFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return ($raw | ConvertFrom-Json)
}

function Load-Settings {
    $settings = Load-JsonFile -Path $SettingsPath
    if ($null -eq $settings) { return [pscustomobject]@{} }
    return $settings
}

function Ensure-Property([object]$Object, [string]$Name, [object]$Value) {
    if (-not $Object.PSObject.Properties[$Name]) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Test-HandlerTargetsPath([object]$Handler, [string]$Path) {
    if ($null -eq $Handler) { return $false }
    try {
        if ($Handler.PSObject.Properties['args']) {
            foreach ($arg in @($Handler.args)) {
                if ([string]::Equals([string]$arg, $Path, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return $true
                }
            }
        }
        if ($Handler.PSObject.Properties['command']) {
            if (([string]$Handler.command).IndexOf($Path, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                return $true
            }
        }
    }
    catch {}
    return $false
}

function Remove-HandlersForPath([object]$Settings, [string]$Path) {
    if (-not $Settings.PSObject.Properties['hooks']) { return }

    foreach ($eventProp in @($Settings.hooks.PSObject.Properties)) {
        $groups = @($eventProp.Value)
        $newGroups = @()

        foreach ($group in $groups) {
            if ($null -eq $group -or -not $group.PSObject.Properties['hooks']) {
                # Preserve unknown/non-standard hook groups rather than deleting them.
                $newGroups += $group
                continue
            }

            $kept = @()
            foreach ($handler in @($group.hooks)) {
                if (-not (Test-HandlerTargetsPath -Handler $handler -Path $Path)) {
                    $kept += $handler
                }
            }
            if ($kept.Count -gt 0) {
                $group.hooks = @($kept)
                $newGroups += $group
            }
        }

        $Settings.hooks.($eventProp.Name) = @($newGroups)
    }
}

function New-AgentChimeHandler([string]$State) {
    return [pscustomobject]@{
        type = 'command'
        command = 'powershell.exe'
        args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $NotifyPath, $State)
        async = $true
    }
}

function Add-Hook([object]$Settings, [string]$Event, [string]$State, [string]$Matcher = '') {
    Ensure-Property -Object $Settings -Name 'hooks' -Value ([pscustomobject]@{})

    $handler = New-AgentChimeHandler -State $State
    if ([string]::IsNullOrWhiteSpace($Matcher)) {
        $group = [pscustomobject]@{ hooks = @($handler) }
    }
    else {
        $group = [pscustomobject]@{ matcher = $Matcher; hooks = @($handler) }
    }

    if (-not $Settings.hooks.PSObject.Properties[$Event]) {
        $Settings.hooks | Add-Member -MemberType NoteProperty -Name $Event -Value @($group)
    }
    else {
        $Settings.hooks.$Event = @(@($Settings.hooks.$Event) + $group)
    }
}

# Prefer an existing AgentChime config. The pre-publication TaskChime config is
# read only when -MigrateTaskChime is explicitly requested, avoiding collisions
# with unrelated software that may use the same historical name.
$existingConfig = $null
$taskChimeConfig = $null
$migratingTaskChime = $false

try { $existingConfig = Load-JsonFile -Path $ConfigPath } catch {}
if ($MigrateTaskChime -and $null -eq $existingConfig) {
    try { $taskChimeConfig = Load-JsonFile -Path $TaskChimeConfigPath } catch {}
    if ($null -ne $taskChimeConfig) { $migratingTaskChime = $true }
}

$sourceConfig = if ($null -ne $existingConfig) { $existingConfig } else { $taskChimeConfig }

$effectiveLocale = if (-not [string]::IsNullOrWhiteSpace($Locale)) {
    $Locale
}
elseif ($null -ne $sourceConfig -and $sourceConfig.PSObject.Properties['locale']) {
    [string]$sourceConfig.locale
}
else {
    'en'
}

$mobileEnabled = if ($EnableMobile) {
    $true
}
elseif ($DisableMobile) {
    $false
}
elseif ($null -ne $sourceConfig -and $sourceConfig.PSObject.Properties['mobile']) {
    [bool]$sourceConfig.mobile.enabled
}
else {
    $false
}

$effectiveServer = if (-not [string]::IsNullOrWhiteSpace($NtfyServer)) {
    $NtfyServer
}
elseif ($null -ne $sourceConfig -and $sourceConfig.PSObject.Properties['mobile'] -and $sourceConfig.mobile.PSObject.Properties['server']) {
    [string]$sourceConfig.mobile.server
}
else {
    'https://ntfy.sh'
}

$topic = if (-not [string]::IsNullOrWhiteSpace($NtfyTopic)) {
    $NtfyTopic
}
elseif ($null -ne $sourceConfig -and $sourceConfig.PSObject.Properties['mobile'] -and $sourceConfig.mobile.PSObject.Properties['topic']) {
    [string]$sourceConfig.mobile.topic
}
else {
    ''
}

$sendProjectName = $true
if ($null -ne $sourceConfig -and $sourceConfig.PSObject.Properties['privacy'] -and $sourceConfig.privacy.PSObject.Properties['sendProjectName']) {
    $sendProjectName = [bool]$sourceConfig.privacy.sendProjectName
}

# Optional migration from the earliest prototype built before the repository existed.
$prototypeConfig = $null
if ($MigratePrototype -and $null -eq $sourceConfig -and (Test-Path $PrototypeConfigPath)) {
    try { $prototypeConfig = Load-JsonFile -Path $PrototypeConfigPath } catch {}

    if ($null -ne $prototypeConfig) {
        if ([string]::IsNullOrWhiteSpace($topic) -and $prototypeConfig.PSObject.Properties['topic']) {
            $topic = [string]$prototypeConfig.topic
        }
        if ([string]::IsNullOrWhiteSpace($NtfyServer) -and $prototypeConfig.PSObject.Properties['server']) {
            $effectiveServer = [string]$prototypeConfig.server
        }
        if (-not $EnableMobile -and -not $DisableMobile -and $prototypeConfig.PSObject.Properties['mobileEnabled']) {
            $mobileEnabled = [bool]$prototypeConfig.mobileEnabled
        }
    }
}

if ($mobileEnabled -and [string]::IsNullOrWhiteSpace($topic)) {
    $topic = 'agentchime-' + ([guid]::NewGuid().ToString('N'))
}

New-Item -ItemType Directory -Force -Path $InstallDir, $BackupDir | Out-Null
Copy-Item -Path $SourceNotify -Destination $NotifyPath -Force

$settings = Load-Settings
Ensure-Property -Object $settings -Name 'hooks' -Value ([pscustomobject]@{})

if (Test-Path $SettingsPath) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Copy-Item $SettingsPath (Join-Path $BackupDir "settings-$stamp.json") -Force
}

# Idempotency: remove prior AgentChime handlers before registering exactly one per event.
Remove-HandlersForPath -Settings $settings -Path $NotifyPath

# Safe pre-publication brand migration. Remove only handlers that point at TaskChime's old notify path.
if ($MigrateTaskChime) {
    Remove-HandlersForPath -Settings $settings -Path $TaskChimeNotifyPath
}

if ($MigratePrototype) {
    Remove-HandlersForPath -Settings $settings -Path $PrototypeNotifyPath
}

Add-Hook -Settings $settings -Event 'Stop' -State 'finished'
Add-Hook -Settings $settings -Event 'StopFailure' -State 'error'
Add-Hook -Settings $settings -Event 'Notification' -State 'attention' -Matcher '^(permission_prompt|agent_needs_input|elicitation_dialog)$'

$settingsDir = Split-Path $SettingsPath -Parent
New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
$settings | ConvertTo-Json -Depth 100 | Set-Content -Path $SettingsPath -Encoding UTF8

$config = [ordered]@{
    version = $AgentChimeVersion
    locale = $effectiveLocale
    desktop = [ordered]@{
        enabled = $true
    }
    mobile = [ordered]@{
        enabled = $mobileEnabled
        provider = 'ntfy'
        server = $effectiveServer.TrimEnd('/')
        topic = $topic
    }
    privacy = [ordered]@{
        sendProjectName = $sendProjectName
        sendPrompt = $false
        sendCode = $false
        sendAssistantOutput = $false
    }
}
$config | ConvertTo-Json -Depth 10 | Set-Content -Path $ConfigPath -Encoding UTF8

Write-Host ''
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host " AGENTCHIME v$AgentChimeVersion INSTALLED" -ForegroundColor Green
Write-Host '==============================================' -ForegroundColor Cyan
Write-Host ''

if ($migratingTaskChime) {
    Write-Host 'Migrated existing TaskChime configuration automatically.' -ForegroundColor Cyan
    Write-Host 'The old ~/.taskchime folder was kept as a fallback and was not deleted.' -ForegroundColor DarkGray
    Write-Host ''
}

Write-Host 'Desktop notifications : ON' -ForegroundColor Green
if ($mobileEnabled) {
    Write-Host 'Mobile notifications  : ON (ntfy)' -ForegroundColor Green
    Write-Host "ntfy server           : $($config.mobile.server)"
    Write-Host "ntfy topic            : $($config.mobile.topic)" -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'If this topic was migrated from TaskChime, your existing phone subscription should keep working.' -ForegroundColor Yellow
    Write-Host 'Otherwise, subscribe to that exact topic in the ntfy mobile app.' -ForegroundColor Yellow
}
else {
    Write-Host 'Mobile notifications  : OFF' -ForegroundColor DarkGray
    Write-Host 'Re-run with -EnableMobile to turn them on.' -ForegroundColor DarkGray
}
Write-Host ''
Write-Host 'Recommended checks:' -ForegroundColor Cyan
Write-Host '& "$HOME\.agentchime\notify.ps1" finished'
Write-Host '.\agentchime.ps1 doctor'
Write-Host ''
Write-Host 'Restart/new-open Claude Code, then use /hooks to verify the registered hooks.' -ForegroundColor Cyan
