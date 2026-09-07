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

    # The archive is built from a working copy, so exclude everything that
    # belongs to this machine rather than to the release: version control, build
    # output, editor and tool state, logs, and any configuration a maintainer
    # may have left in the folder. An unknown dotted directory is excluded on
    # purpose; a release file that needs one has to be named here explicitly.
    $keepDotted = @('.github', '.gitignore')
    $excluded = @('.git', 'dist', 'node_modules', 'config.json')

    Get-ChildItem -Path $root -Force | Where-Object {
        $_.Name -notin $excluded -and
        $_.Extension -ne '.log' -and
        -not ($_.Name.StartsWith('.') -and $_.Name -notin $keepDotted)
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
