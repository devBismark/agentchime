[CmdletBinding()]
param(
    [string]$Owner = '',
    [string]$RepoName = 'agentchime',
    [switch]$DraftRelease
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$tag = "v$version"
$description = 'Stop watching your terminal. Windows + mobile notifications when Claude Code finishes, needs attention, or fails.'
$releaseNotes = Join-Path $root "RELEASE_NOTES_v$version.md"
$distDir = Join-Path $root 'dist'
$zip = Join-Path $distDir "agentchime-v$version.zip"
$hash = Join-Path $distDir "agentchime-v$version.sha256"

function Require-Command([string]$Name) {
    if ($null -eq (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found on PATH."
    }
}

Require-Command -Name 'git'
Require-Command -Name 'gh'

Push-Location $root
try {
    & gh auth status | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI is not authenticated. Run: gh auth login'
    }

    if ([string]::IsNullOrWhiteSpace($Owner)) {
        $Owner = (& gh api user --jq '.login').Trim()
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($Owner)) {
            throw 'Could not determine the authenticated GitHub username.'
        }
    }

    $fullRepo = "$Owner/$RepoName"

    Write-Host "Validating AgentChime v$version..." -ForegroundColor Cyan
    & (Join-Path $root 'tests\validate-repo.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Repository validation failed.' }

    $status = (& git status --porcelain)
    if (-not [string]::IsNullOrWhiteSpace(($status -join "`n"))) {
        throw 'Git working tree is not clean. Commit or stash changes before publishing.'
    }

    $branch = (& git branch --show-current).Trim()
    if ($branch -ne 'main') {
        throw "Publish from branch 'main'. Current branch: $branch"
    }

    Write-Host 'Packaging release artifacts...' -ForegroundColor Cyan
    & (Join-Path $root 'scripts\package-release.ps1') -OutputDir $distDir
    if ($LASTEXITCODE -ne 0) { throw 'Release packaging failed.' }

    if (-not (Test-Path $releaseNotes)) { throw "Missing release notes: $releaseNotes" }
    if (-not (Test-Path $zip)) { throw "Missing release ZIP: $zip" }
    if (-not (Test-Path $hash)) { throw "Missing SHA256 file: $hash" }

    & gh repo view $fullRepo --json nameWithOwner 2>$null | Out-Null
    $repoExists = ($LASTEXITCODE -eq 0)

    if (-not $repoExists) {
        Write-Host "Creating public repository $fullRepo..." -ForegroundColor Cyan
        & gh repo create $fullRepo --public --source $root --remote origin --push --description $description
        if ($LASTEXITCODE -ne 0) { throw 'GitHub repository creation failed.' }
    }
    else {
        Write-Host "Repository $fullRepo already exists; pushing main..." -ForegroundColor Yellow
        $origin = (& git remote get-url origin 2>$null)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($origin -join ''))) {
            & git remote add origin "https://github.com/$fullRepo.git"
        }
        & git push -u origin main
        if ($LASTEXITCODE -ne 0) { throw 'Push to GitHub failed.' }
    }

    $topics = @(
        'claude-code',
        'anthropic',
        'ai-agents',
        'coding-agents',
        'powershell',
        'windows',
        'developer-tools',
        'notifications',
        'ntfy',
        'open-source'
    )

    foreach ($topic in $topics) {
        & gh repo edit $fullRepo --add-topic $topic | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Could not add repository topic: $topic" }
    }

    & gh repo edit $fullRepo --enable-issues --enable-wiki=false --delete-branch-on-merge | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not apply repository settings.' }

    & gh release view $tag --repo $fullRepo 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        throw "Release $tag already exists on $fullRepo. Refusing to create a duplicate release."
    }

    if (-not (& git tag --list $tag)) {
        & git tag -a $tag -m "AgentChime $tag - Stop watching your terminal"
        if ($LASTEXITCODE -ne 0) { throw 'Could not create git tag.' }
    }

    & git push origin $tag
    if ($LASTEXITCODE -ne 0) { throw 'Could not push release tag.' }

    $releaseArgs = @(
        'release', 'create', $tag,
        $zip, $hash,
        '--repo', $fullRepo,
        '--title', "AgentChime $tag - Stop watching your terminal",
        '--notes-file', $releaseNotes,
        '--verify-tag'
    )
    if ($DraftRelease) { $releaseArgs += '--draft' }

    Write-Host "Creating GitHub release $tag..." -ForegroundColor Cyan
    & gh @releaseArgs
    if ($LASTEXITCODE -ne 0) { throw 'GitHub release creation failed.' }

    Write-Host ''
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host ' AGENTCHIME PUBLISHED' -ForegroundColor Green
    Write-Host '==============================================' -ForegroundColor Cyan
    Write-Host "Repository : https://github.com/$fullRepo"
    Write-Host "Release    : https://github.com/$fullRepo/releases/tag/$tag"
    Write-Host ''
}
finally {
    Pop-Location
}
