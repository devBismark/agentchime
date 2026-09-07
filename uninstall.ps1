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

function Test-HandlerTargetsPath([object]$Handler, [string]$Path) {
    $key = Get-NormalizedPathKey $Path
    if ([string]::IsNullOrWhiteSpace($key)) { return $false }
    return (@(Get-HandlerScriptPaths -Handler $Handler) -contains $key)
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
