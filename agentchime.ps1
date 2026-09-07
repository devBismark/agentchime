[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'doctor', 'test', 'mobile')]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [ValidateSet('finished', 'attention', 'error')]
    [string]$State = 'finished'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$AgentChimeVersion = '0.1.0'
$InstallDir = Join-Path $HOME '.agentchime'
$ConfigPath = Join-Path $InstallDir 'config.json'
$NotifyPath = Join-Path $InstallDir 'notify.ps1'
$SettingsPath = Join-Path (Join-Path $HOME '.claude') 'settings.json'

function Read-Config {
    if (-not (Test-Path $ConfigPath)) { return $null }
    try { return (Get-Content $ConfigPath -Raw | ConvertFrom-Json) } catch { return $null }
}

# Hook handlers can spell the same file with either Windows separator, wrapped
# in quotes, or with a trailing separator. Compare on a normalized key so one
# file is recognised in every spelling.
function Get-NormalizedPathKey([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $value = $Path.Trim().Trim('"').Trim("'").Replace('/', '\')
    if ($value.Length -gt 3) { $value = $value.TrimEnd('\') }
    return $value.ToLowerInvariant()
}

# Every .ps1 file a handler points at, taken from its command line and from its
# args separately. The lookahead stops "notify.ps1" from matching inside a
# longer name such as "notify.ps1.bak", which belongs to somebody else.
function Get-HandlerScriptPaths([object]$Handler) {
    $paths = @()
    if ($null -eq $Handler) { return $paths }
    try {
        if ($Handler.PSObject.Properties['command']) {
            $text = ([string]$Handler.command).Replace('/', '\').ToLowerInvariant()
            foreach ($match in [regex]::Matches($text, '(?:[a-z]:\\|\\\\)[^"'',;]*?\.ps1(?![a-z0-9._-])')) {
                $paths += (Get-NormalizedPathKey $match.Value)
            }
        }
        if ($Handler.PSObject.Properties['args']) {
            foreach ($arg in @($Handler.args)) {
                $key = Get-NormalizedPathKey ([string]$arg)
                if ($key.EndsWith('.ps1')) { $paths += $key }
            }
        }
    }
    catch {}
    return $paths
}

# 'healthy' only when every script the handler names is our notifier. A handler
# that also names another script is reported rather than counted: one of its
# fields is a leftover, and a leftover can still be what actually runs.
function Get-AgentChimeHandlerState([object]$Handler, [string]$Path) {
    $key = Get-NormalizedPathKey $Path
    $paths = @(Get-HandlerScriptPaths -Handler $Handler)
    if ($paths.Count -eq 0) { return 'none' }
    if ($paths -notcontains $key) { return 'none' }
    if (@($paths | Where-Object { $_ -ne $key }).Count -gt 0) { return 'ambiguous' }
    return 'healthy'
}

function Measure-AgentChimeHandlers([object]$Settings, [string]$EventName) {
    $healthy = 0
    $ambiguous = 0
    if ($Settings.PSObject.Properties['hooks'] -and $Settings.hooks.PSObject.Properties[$EventName]) {
        foreach ($group in @($Settings.hooks.$EventName)) {
            if ($null -eq $group -or -not $group.PSObject.Properties['hooks']) { continue }
            foreach ($handler in @($group.hooks)) {
                switch (Get-AgentChimeHandlerState -Handler $handler -Path $NotifyPath) {
                    'healthy' { $healthy++ }
                    'ambiguous' { $ambiguous++ }
                }
            }
        }
    }
    return [pscustomobject]@{ Healthy = $healthy; Ambiguous = $ambiguous }
}

switch ($Command) {
    'status' {
        $config = Read-Config
        Write-Host "AgentChime v$AgentChimeVersion status" -ForegroundColor Cyan
        Write-Host ('Installed : ' + (Test-Path $NotifyPath))
        Write-Host ('Claude settings found : ' + (Test-Path $SettingsPath))
        if ($null -ne $config) {
            if ($config.PSObject.Properties['version']) { Write-Host ('Config version : ' + $config.version) }

            # The effective level, not the stored spelling. A config with no
            # detailLevel key, or one that spells it wrongly, renders standard
            # notifications, so that is what status has to report.
            $detail = 'standard'
            if ($config.PSObject.Properties['detailLevel'] -and
                ([string]$config.detailLevel).Trim().ToLowerInvariant() -eq 'minimal') {
                $detail = 'minimal'
            }
            Write-Host ('Detail  : ' + $detail)

            Write-Host ('Desktop : ' + $(if ($config.desktop.enabled) { 'ON' } else { 'OFF' }))
            Write-Host ('Mobile  : ' + $(if ($config.mobile.enabled) { 'ON' } else { 'OFF' }))
            if ($config.mobile.enabled) {
                Write-Host ('Provider: ' + $config.mobile.provider)
                Write-Host ('Server  : ' + $config.mobile.server)
                Write-Host ('Topic   : ' + $config.mobile.topic)
            }
        }
        exit 0
    }

    'test' {
        if (-not (Test-Path $NotifyPath)) { throw 'AgentChime is not installed.' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $NotifyPath $State
        exit $LASTEXITCODE
    }

    'mobile' {
        $config = Read-Config
        if ($null -eq $config -or -not $config.mobile.enabled) {
            Write-Host 'Mobile notifications are disabled.' -ForegroundColor Yellow
            exit 1
        }
        Write-Host ('Server: ' + $config.mobile.server)
        Write-Host ('Topic : ' + $config.mobile.topic) -ForegroundColor Yellow
        exit 0
    }

    'doctor' {
        $ok = $true
        Write-Host 'AgentChime doctor' -ForegroundColor Cyan

        if (Test-Path $NotifyPath) { Write-Host '[OK] notify.ps1 installed' -ForegroundColor Green }
        else { Write-Host '[FAIL] notify.ps1 missing' -ForegroundColor Red; $ok = $false }

        $config = Read-Config
        if ($null -ne $config) {
            Write-Host '[OK] config.json readable' -ForegroundColor Green
            if ($config.PSObject.Properties['version'] -and [string]$config.version -ne $AgentChimeVersion) {
                Write-Host ("[WARN] config version is $($config.version); helper version is $AgentChimeVersion") -ForegroundColor Yellow
            }
        }
        else { Write-Host '[FAIL] config.json missing or invalid' -ForegroundColor Red; $ok = $false }

        if (Test-Path $SettingsPath) {
            try {
                $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json
                $expectedEvents = @('UserPromptSubmit', 'Stop', 'StopFailure', 'Notification')
                $missingEvents = @()
                $duplicateEvents = @()
                $ambiguousEvents = @()

                foreach ($eventName in $expectedEvents) {
                    $counts = Measure-AgentChimeHandlers -Settings $settings -EventName $eventName
                    if ($counts.Ambiguous -gt 0) { $ambiguousEvents += "$eventName ($($counts.Ambiguous))" }
                    if ($counts.Healthy -eq 0 -and $counts.Ambiguous -eq 0) { $missingEvents += $eventName }
                    elseif ($counts.Healthy -gt 1) { $duplicateEvents += "$eventName ($($counts.Healthy))" }
                }

                if ($missingEvents.Count -eq 0 -and $duplicateEvents.Count -eq 0 -and $ambiguousEvents.Count -eq 0) {
                    Write-Host '[OK] Claude hooks reference AgentChime exactly once (UserPromptSubmit, Stop, StopFailure, Notification)' -ForegroundColor Green
                }
                else {
                    if ($missingEvents.Count -gt 0) {
                        Write-Host ('[FAIL] Missing AgentChime hooks: ' + ($missingEvents -join ', ')) -ForegroundColor Red
                        $ok = $false
                    }
                    if ($duplicateEvents.Count -gt 0) {
                        Write-Host ('[FAIL] Duplicate AgentChime hooks: ' + ($duplicateEvents -join ', ')) -ForegroundColor Red
                        Write-Host '       Re-run install.ps1 to repair idempotently.' -ForegroundColor Yellow
                        $ok = $false
                    }
                    if ($ambiguousEvents.Count -gt 0) {
                        Write-Host ('[FAIL] Ambiguous AgentChime hooks: ' + ($ambiguousEvents -join ', ')) -ForegroundColor Red
                        Write-Host '       These handlers name more than one notifier script, so the' -ForegroundColor Yellow
                        Write-Host '       leftover one may be what actually runs.' -ForegroundColor Yellow
                        Write-Host '       Re-run install.ps1 to repair idempotently.' -ForegroundColor Yellow
                        $ok = $false
                    }
                }
            }
            catch { Write-Host '[FAIL] Claude settings.json is invalid JSON' -ForegroundColor Red; $ok = $false }
        }
        else { Write-Host '[FAIL] Claude settings.json not found' -ForegroundColor Red; $ok = $false }

        if ($null -ne $config -and $config.mobile.enabled) {
            try {
                $server = ([string]$config.mobile.server).TrimEnd('/')
                $health = Invoke-RestMethod -Uri "$server/v1/health" -Method Get -TimeoutSec 10
                if (-not $health.healthy) { throw 'ntfy health endpoint reported unhealthy' }
                Write-Host '[OK] ntfy server healthy' -ForegroundColor Green
            }
            catch { Write-Host ('[FAIL] ntfy server unreachable: ' + $_.Exception.Message) -ForegroundColor Red; $ok = $false }
        }

        if ($ok) { Write-Host 'Doctor result: PASS' -ForegroundColor Green; exit 0 }
        Write-Host 'Doctor result: FAIL' -ForegroundColor Red
        exit 1
    }
}
