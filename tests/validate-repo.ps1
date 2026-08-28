Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$expectedVersion = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$failed = $false

Write-Host "Validating AgentChime repository v$expectedVersion" -ForegroundColor Cyan

Get-ChildItem -Path $root -Recurse -Filter *.ps1 -File | Where-Object {
    $_.FullName -notmatch '[\\/]\.git[\\/]'
} | ForEach-Object {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "[FAIL] syntax: $($_.FullName)" -ForegroundColor Red
        $errors | ForEach-Object { Write-Host "       $($_.Message)" -ForegroundColor Red }
    }
    else {
        Write-Host "[OK] syntax: $($_.Name)" -ForegroundColor Green
    }
}

$versionFiles = @(
    (Join-Path $root 'install.ps1'),
    (Join-Path $root 'agentchime.ps1'),
    (Join-Path $root 'README.md'),
    (Join-Path $root 'config.example.json'),
    (Join-Path $root 'CHANGELOG.md')
)

foreach ($file in $versionFiles) {
    $text = Get-Content $file -Raw
    if ($text -notmatch [regex]::Escape($expectedVersion)) {
        $failed = $true
        Write-Host "[FAIL] version $expectedVersion missing from $file" -ForegroundColor Red
    }
    else {
        Write-Host "[OK] version: $(Split-Path $file -Leaf)" -ForegroundColor Green
    }
}

$config = Get-Content (Join-Path $root 'config.example.json') -Raw | ConvertFrom-Json
if ([string]$config.version -ne $expectedVersion) {
    $failed = $true
    Write-Host '[FAIL] config.example.json version mismatch' -ForegroundColor Red
}
else {
    Write-Host '[OK] config.example.json parses' -ForegroundColor Green
}

$required = @('bootstrap.ps1', 'install.ps1', 'agentchime.ps1', 'uninstall.ps1', 'src\notify.ps1', 'scripts\init-repo.ps1', 'scripts\publish-github.ps1', 'LICENSE', 'SECURITY.md')
foreach ($relative in $required) {
    $path = Join-Path $root $relative
    if (-not (Test-Path $path)) {
        $failed = $true
        Write-Host "[FAIL] missing: $relative" -ForegroundColor Red
    }
    else {
        Write-Host "[OK] exists: $relative" -ForegroundColor Green
    }
}

if ($failed) {
    Write-Host 'Repository validation: FAIL' -ForegroundColor Red
    exit 1
}

Write-Host 'Repository validation: PASS' -ForegroundColor Green
