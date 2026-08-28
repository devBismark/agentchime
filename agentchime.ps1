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

function Count-AgentChimeHandlers([object]$Settings, [string]$EventName) {
    $count = 0
    if (-not $Settings.PSObject.Properties['hooks']) { return 0 }
    if (-not $Settings.hooks.PSObject.Properties[$EventName]) { return 0 }

    foreach ($group in @($Settings.hooks.$EventName)) {
        if ($null -eq $group -or -not $group.PSObject.Properties['hooks']) { continue }
        foreach ($handler in @($group.hooks)) {
            if (Test-HandlerTargetsPath -Handler $handler -Path $NotifyPath) {
                $count++
            }
        }
    }
    return $count
}

switch ($Command) {
    'status' {
        $config = Read-Config
        Write-Host "AgentChime v$AgentChimeVersion status" -ForegroundColor Cyan
        Write-Host ('Installed : ' + (Test-Path $NotifyPath))
        Write-Host ('Claude settings found : ' + (Test-Path $SettingsPath))
        if ($null -ne $config) {
            if ($config.PSObject.Properties['version']) { Write-Host ('Config version : ' + $config.version) }
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
                $expectedEvents = @('Stop', 'StopFailure', 'Notification')
                $missingEvents = @()
                $duplicateEvents = @()

                foreach ($eventName in $expectedEvents) {
                    $count = Count-AgentChimeHandlers -Settings $settings -EventName $eventName
                    if ($count -eq 0) { $missingEvents += $eventName }
                    elseif ($count -gt 1) { $duplicateEvents += "$eventName ($count)" }
                }

                if ($missingEvents.Count -eq 0 -and $duplicateEvents.Count -eq 0) {
                    Write-Host '[OK] Claude hooks reference AgentChime exactly once (Stop, StopFailure, Notification)' -ForegroundColor Green
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
