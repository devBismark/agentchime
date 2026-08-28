[CmdletBinding()]
param(
    [string]$OutputDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $root 'dist'
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$staging = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-package-' + [guid]::NewGuid().ToString('N'))
$zipPath = Join-Path $OutputDir "agentchime-v$version.zip"
$hashPath = Join-Path $OutputDir "agentchime-v$version.sha256"

try {
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    Get-ChildItem -Path $root -Force | Where-Object {
        $_.Name -notin @('.git', 'dist')
    } | ForEach-Object {
        Copy-Item $_.FullName -Destination $staging -Recurse -Force
    }

    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal

    $hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $(Split-Path $zipPath -Leaf)" | Set-Content -Path $hashPath -Encoding ASCII

    Write-Host "Created: $zipPath" -ForegroundColor Green
    Write-Host "SHA256 : $hash" -ForegroundColor Cyan
}
finally {
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue }
}
