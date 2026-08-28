[CmdletBinding()]
param(
    [switch]$EnableMobile,
    [switch]$DisableMobile,
    [string]$NtfyTopic = '',
    [string]$NtfyServer = '',
    [ValidateSet('', 'en', 'pt-BR')]
    [string]$Locale = '',
    [switch]$MigratePrototype,
    [switch]$MigrateTaskChime,
    [string]$Ref = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -ne 'Windows_NT') {
    throw 'AgentChime v0.1 currently supports Windows only.'
}

$Repository = 'devBismark/agentchime'
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $tempRoot 'agentchime.zip'
$extractPath = Join-Path $tempRoot 'repo'

New-Item -ItemType Directory -Force -Path $tempRoot, $extractPath | Out-Null

try {
    if ($Ref -match '^v\d') {
        $archiveUrl = "https://github.com/$Repository/archive/refs/tags/$Ref.zip"
    }
    else {
        $archiveUrl = "https://github.com/$Repository/archive/refs/heads/$Ref.zip"
    }

    Write-Host "Downloading AgentChime $Ref..." -ForegroundColor Cyan
    Invoke-WebRequest -UseBasicParsing -Uri $archiveUrl -OutFile $zipPath
    Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

    $repoDir = Get-ChildItem -Path $extractPath -Directory | Select-Object -First 1
    if ($null -eq $repoDir) { throw 'Downloaded archive did not contain a repository directory.' }

    $installer = Join-Path $repoDir.FullName 'install.ps1'
    if (-not (Test-Path $installer)) { throw 'Downloaded archive is missing install.ps1.' }

    $installArgs = @{}
    if ($EnableMobile) { $installArgs.EnableMobile = $true }
    if ($DisableMobile) { $installArgs.DisableMobile = $true }
    if (-not [string]::IsNullOrWhiteSpace($NtfyTopic)) { $installArgs.NtfyTopic = $NtfyTopic }
    if (-not [string]::IsNullOrWhiteSpace($NtfyServer)) { $installArgs.NtfyServer = $NtfyServer }
    if (-not [string]::IsNullOrWhiteSpace($Locale)) { $installArgs.Locale = $Locale }
    if ($MigratePrototype) { $installArgs.MigratePrototype = $true }
    if ($MigrateTaskChime) { $installArgs.MigrateTaskChime = $true }

    & $installer @installArgs
}
finally {
    if (Test-Path $tempRoot) {
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
