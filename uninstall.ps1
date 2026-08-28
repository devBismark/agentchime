[CmdletBinding()]
param(
    [switch]$KeepConfig
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $HOME '.agentchime'
$BackupDir = Join-Path $InstallDir 'backups'
$NotifyPath = Join-Path $InstallDir 'notify.ps1'
$SettingsPath = Join-Path (Join-Path $HOME '.claude') 'settings.json'

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

if (Test-Path $SettingsPath) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Copy-Item $SettingsPath (Join-Path $BackupDir "settings-before-uninstall-$stamp.json") -Force

    $raw = Get-Content $SettingsPath -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
        $settings = $raw | ConvertFrom-Json
        if ($settings.PSObject.Properties['hooks']) {
            foreach ($eventProp in @($settings.hooks.PSObject.Properties)) {
                $newGroups = @()
                foreach ($group in @($eventProp.Value)) {
                    if ($null -eq $group -or -not $group.PSObject.Properties['hooks']) {
                        $newGroups += $group
                        continue
                    }

                    $kept = @()
                    foreach ($handler in @($group.hooks)) {
                        if (-not (Test-HandlerTargetsPath -Handler $handler -Path $NotifyPath)) {
                            $kept += $handler
                        }
                    }
                    if ($kept.Count -gt 0) {
                        $group.hooks = @($kept)
                        $newGroups += $group
                    }
                }
                $settings.hooks.($eventProp.Name) = @($newGroups)
            }
            $settings | ConvertTo-Json -Depth 100 | Set-Content -Path $SettingsPath -Encoding UTF8
        }
    }
}

if (Test-Path $InstallDir) {
    if ($KeepConfig) {
        Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -notin @('config.json', 'backups') } | Remove-Item -Recurse -Force
    }
    else {
        Remove-Item $InstallDir -Recurse -Force
    }
}

Write-Host 'AgentChime hooks removed from Claude Code.' -ForegroundColor Green
if ($KeepConfig) {
    Write-Host 'Configuration/backups were kept in ~/.agentchime.' -ForegroundColor Yellow
}
