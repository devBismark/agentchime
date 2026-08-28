[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "Required command 'git' was not found on PATH."
}

Push-Location $root
try {
    if (-not (Test-Path (Join-Path $root '.git'))) {
        & git init -b main
        if ($LASTEXITCODE -ne 0) { throw 'git init failed.' }
    }

    $branch = (& git branch --show-current).Trim()
    if ([string]::IsNullOrWhiteSpace($branch)) {
        & git checkout -b main
        if ($LASTEXITCODE -ne 0) { throw 'Could not create main branch.' }
    }
    elseif ($branch -ne 'main') {
        throw "Expected branch 'main', found '$branch'. Rename it before publishing."
    }

    & git add .
    if ($LASTEXITCODE -ne 0) { throw 'git add failed.' }

    & git diff --cached --quiet
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'Repository already initialized; no staged changes to commit.' -ForegroundColor Yellow
        exit 0
    }

    $name = (& git config user.name).Trim()
    $email = (& git config user.email).Trim()
    if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($email)) {
        throw 'Git user.name/user.email is not configured. Configure your Git identity, then run this script again.'
    }

    & git commit -m 'feat: initial AgentChime v0.1.0'
    if ($LASTEXITCODE -ne 0) { throw 'git commit failed.' }

    Write-Host 'AgentChime repository initialized on main.' -ForegroundColor Green
}
finally {
    Pop-Location
}
