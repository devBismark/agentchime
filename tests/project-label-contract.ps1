# Behavioral contract tests for provider-neutral project label resolution.
#
# notify.ps1 loads its functions only when dot-sourced, so every suite below
# drives the real resolver, adapter and renderer without sending a
# notification. Each suite prints a success-only token that the Unlazy gate
# ledger matches on.
#
# Every repository these suites look at is built here, under a disposable
# directory, and deleted again. None of them is the repository this file lives
# in, and no suite reads or writes anything in the maintainer's home.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('resolution', 'topology', 'fallback', 'label-privacy', 'label-detail', 'label-locales', 'leak', 'resilience', 'performance', 'mutation', 'contract')]
    [string]$Suite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path $PSScriptRoot -Parent
$NotifyPath = Join-Path $RepoRoot 'src\notify.ps1'
$ProbePath = Join-Path $PSScriptRoot 'label-probe.ps1'
$InstallPath = Join-Path $RepoRoot 'install.ps1'
$HomeProbePath = Join-Path $PSScriptRoot 'print-home.ps1'

# Loads the functions only. The state argument satisfies the mandatory
# parameter; the dot-source guard inside notify.ps1 suppresses the main flow.
. $NotifyPath 'finished'

foreach ($required in @('Resolve-ProjectLabel', 'Get-EnclosingRepositoryRoot', 'Get-DirectoryLeafName')) {
    if (-not (Get-Command -Name $required -CommandType Function -ErrorAction SilentlyContinue)) {
        throw "notify.ps1 did not expose $required when dot-sourced."
    }
}

$script:Failures = New-Object System.Collections.Generic.List[string]
$script:Assertions = 0

function Assert-That([bool]$Condition, [string]$Label) {
    $script:Assertions++
    if (-not $Condition) { $script:Failures.Add("FAIL $Label") }
}

function Assert-Equal([string]$Expected, [string]$Actual, [string]$Label) {
    $script:Assertions++
    if ($Expected -cne $Actual) {
        $script:Failures.Add("FAIL $Label | expected [$Expected] actual [$Actual]")
    }
}

function Complete-Suite([string]$Name, [int]$MinimumAssertions) {
    if ($script:Assertions -lt $MinimumAssertions) {
        $script:Failures.Add("FAIL $Name ran only $($script:Assertions) assertions, fewer than the $MinimumAssertions required; the suite is vacuous")
    }
    if ($script:Failures.Count -gt 0) {
        foreach ($f in $script:Failures) { Write-Host $f -ForegroundColor Red }
        Write-Host ('SUITE {0}: FAILED ({1} of {2} assertions)' -f $Name, $script:Failures.Count, $script:Assertions) -ForegroundColor Red
        exit 1
    }
    Write-Host ('SUITE {0}: PASS ({1} assertions)' -f $Name, $script:Assertions) -ForegroundColor Green
    $script:Failures = New-Object System.Collections.Generic.List[string]
    $script:Assertions = 0
}

# --------------------------------------------------------------------------
# Disposable repository fixture
# --------------------------------------------------------------------------

# Names that appear nowhere on disk except inside the fixture, so finding one
# in a label or a notification proves where it came from.
$script:RemoteOwner = 'ghost-owner-4f2a9c'
$script:RemoteProject = 'secret-remote-name-4f2a9c'

$script:FixtureRoot = ''
$script:FixtureMainGitDir = ''

# The directories the fixture offers and the label each one must produce.
# Written out here rather than derived from the resolver, so a change in
# behaviour has to be made here too.
$script:FixtureExpectations = [ordered]@{
    'solo-repo'                        = 'solo-repo'
    'solo-repo/apps/web'               = 'solo-repo'
    'solo-repo/packages/api'           = 'solo-repo'
    'solo-repo/src'                    = 'solo-repo'
    'outer-repo'                       = 'outer-repo'
    'outer-repo/vendor/inner-repo'     = 'inner-repo'
    'outer-repo/vendor/inner-repo/src' = 'inner-repo'
    'wt-feature'                       = 'wt-feature'
    'wt-feature/src'                   = 'wt-feature'
    'plain/nested/deep'                = 'deep'
}

# The generic leaf names the step exists to improve on. Each is created inside
# solo-repo, so the leaf alone would be uninformative.
$script:GenericLeaves = @('web', 'app', 'src', 'api', 'frontend', 'backend', 'site')

function Get-FixturePath([string]$Relative) {
    return (Join-Path $script:FixtureRoot ($Relative -replace '/', '\'))
}

function Invoke-Git {
    param([string]$Directory, [string[]]$GitArguments)

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $arguments = @('-C', $Directory, '-c', 'user.email=fixture@example.invalid', '-c', 'user.name=Fixture', '-c', 'init.defaultBranch=main', '-c', 'commit.gpgsign=false') + $GitArguments
        $output = & git.exe @arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }
    return [pscustomobject]@{ ExitCode = $code; Output = (($output | Out-String).Trim()) }
}

function New-FixtureRepository([string]$Relative) {
    $path = Get-FixturePath $Relative
    New-Item -ItemType Directory -Force -Path $path | Out-Null
    $init = Invoke-Git -Directory $path -GitArguments @('init', '--quiet')
    if ($init.ExitCode -ne 0) { throw "git init failed for ${Relative}: $($init.Output)" }
    Set-Content -Path (Join-Path $path 'readme.txt') -Value 'fixture' -Encoding UTF8
    Invoke-Git -Directory $path -GitArguments @('add', '--all') | Out-Null
    $commit = Invoke-Git -Directory $path -GitArguments @('commit', '--quiet', '-m', 'fixture')
    if ($commit.ExitCode -ne 0) { throw "git commit failed for ${Relative}: $($commit.Output)" }

    # A remote that names an owner and a project neither of which matches the
    # directory. Nothing may ever read it, and the leak suite proves that.
    Invoke-Git -Directory $path -GitArguments @('remote', 'add', 'origin', "https://$($script:RemoteOwner)@example.invalid/$($script:RemoteOwner)/$($script:RemoteProject).git") | Out-Null
    return $path
}

# Builds the whole fixture once per process and returns its root.
function Initialize-Fixture {
    if (-not [string]::IsNullOrWhiteSpace($script:FixtureRoot)) { return $script:FixtureRoot }

    if ($null -eq (Get-Command 'git.exe' -ErrorAction SilentlyContinue)) {
        throw 'git is required to build the repository fixture; these suites refuse to guess what git would have done'
    }

    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-label-' + [guid]::NewGuid().ToString('N'))
    if ($root -eq $RepoRoot) { throw 'refusing to run: the fixture resolved to this repository' }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $script:FixtureRoot = $root

    # The fixture must not sit inside somebody else's repository, or every
    # non-git expectation below would be measuring that repository instead.
    $enclosing = Get-EnclosingRepositoryRoot $root
    if (-not [string]::IsNullOrWhiteSpace($enclosing)) {
        throw "refusing to run: the fixture root is inside a repository at $enclosing"
    }

    New-FixtureRepository 'solo-repo' | Out-Null
    foreach ($leaf in $script:GenericLeaves) {
        New-Item -ItemType Directory -Force -Path (Get-FixturePath "solo-repo/apps/$leaf") | Out-Null
        New-Item -ItemType Directory -Force -Path (Get-FixturePath "solo-repo/$leaf") | Out-Null
    }
    New-Item -ItemType Directory -Force -Path (Get-FixturePath 'solo-repo/packages/api') | Out-Null

    New-FixtureRepository 'outer-repo' | Out-Null
    New-FixtureRepository 'outer-repo/vendor/inner-repo' | Out-Null
    New-Item -ItemType Directory -Force -Path (Get-FixturePath 'outer-repo/vendor/inner-repo/src') | Out-Null

    $worktree = Get-FixturePath 'wt-feature'
    $added = Invoke-Git -Directory (Get-FixturePath 'outer-repo') -GitArguments @('worktree', 'add', '--quiet', '-b', 'fixture-feature', $worktree)
    if ($added.ExitCode -ne 0) { throw "git worktree add failed: $($added.Output)" }
    New-Item -ItemType Directory -Force -Path (Get-FixturePath 'wt-feature/src') | Out-Null

    New-Item -ItemType Directory -Force -Path (Get-FixturePath 'plain/nested/deep') | Out-Null

    # A repository rooted at what the account-boundary probe will call the
    # account directory, with a real project underneath it.
    New-FixtureRepository 'account-home' | Out-Null
    New-Item -ItemType Directory -Force -Path (Get-FixturePath 'account-home/projects/client-x') | Out-Null

    # The worktree marker names the main checkout. Keep what it says so the
    # leak suite can prove that string never reaches a notification.
    $marker = Join-Path $worktree '.git'
    if (-not (Test-Path -LiteralPath $marker)) { throw 'the worktree fixture has no marker' }
    $script:FixtureMainGitDir = ((Get-Content -LiteralPath $marker -Raw).Trim() -replace '^gitdir:\s*', '')

    return $script:FixtureRoot
}

function Remove-Fixture {
    if ([string]::IsNullOrWhiteSpace($script:FixtureRoot)) { return }
    if (-not (Test-Path $script:FixtureRoot)) { return }
    # A worktree marks its files read-only in places, so clear the attribute
    # before deleting rather than leaving the fixture behind.
    Get-ChildItem -Path $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue |
        ForEach-Object { try { $_.Attributes = 'Normal' } catch {} }
    Remove-Item $script:FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# git's own answer for a directory, reduced to its last segment. This is the
# independent oracle: the expectations above are compared against what git
# actually reports rather than against the resolver's own opinion.
function Get-GitToplevelLeaf([string]$Directory) {
    $result = Invoke-Git -Directory $Directory -GitArguments @('rev-parse', '--show-toplevel')
    if ($result.ExitCode -ne 0) { return '' }
    return (Get-DirectoryLeafName $result.Output)
}

function New-LabelPayload([string]$WorkingDirectory) {
    return ([ordered]@{ cwd = $WorkingDirectory } | ConvertTo-Json -Compress | ConvertFrom-Json)
}

function Get-LabelFor([string]$WorkingDirectory, [bool]$SendProjectName = $true) {
    $agentEvent = ConvertTo-AgentEvent -Payload (New-LabelPayload $WorkingDirectory) -EventState 'finished' -Locale 'en' -IncludeProjectLabel $SendProjectName
    return ([string]$agentEvent.projectLabel)
}

# --------------------------------------------------------------------------
# Mutation harness
# --------------------------------------------------------------------------

$script:MutationSandbox = ''
function Get-MutationSandbox {
    if ([string]::IsNullOrWhiteSpace($script:MutationSandbox)) {
        $script:MutationSandbox = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-label-mutants-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $script:MutationSandbox | Out-Null
    }
    return $script:MutationSandbox
}

function New-MutantNotifier([string]$Find, [string]$Replace) {
    $source = Get-Content $NotifyPath -Raw
    if (-not $source.Contains($Find)) { return '' }
    $path = Join-Path (Get-MutationSandbox) ('mutant-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $source.Replace($Find, $Replace) | Set-Content -Path $path -Encoding UTF8
    return $path
}

# Runs one probe against a copy of the notifier and returns its verdict line.
function Invoke-LabelProbe {
    param(
        [string]$Probe,
        [string]$Find = '',
        [string]$Replace = ''
    )

    Initialize-Fixture | Out-Null

    $notifier = $NotifyPath
    if (-not [string]::IsNullOrWhiteSpace($Find)) {
        $notifier = New-MutantNotifier -Find $Find -Replace $Replace
        if ([string]::IsNullOrWhiteSpace($notifier)) { return "MUTATION-TARGET-MISSING [$Find]" }
    }

    # The probe is deliberately pointed at broken code, so its stderr must be
    # captured rather than promoted into a terminating error.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ProbePath -Notifier $notifier -Probe $Probe -Fixture $script:FixtureRoot 2>&1
    }
    finally {
        $ErrorActionPreference = $previous
    }

    return (($output | Out-String).Trim())
}

# The literal lines the mutants rewrite. Kept in one place so a refactor that
# moves them fails loudly as MUTATION-TARGET-MISSING instead of quietly
# turning every mutant into a no-op.
$script:MutationTargets = [ordered]@{
    RepositoryPreferred = '        $label = Get-DirectoryLeafName (Get-EnclosingRepositoryRoot $WorkingDirectory)'
    RootReturned        = '                return $current'
    MarkerAccepted      = '            if ([System.IO.Directory]::Exists($marker) -or [System.IO.File]::Exists($marker)) {'
    LeafReturned        = '        return (Get-DirectoryLeafName $WorkingDirectory)'
    DriveRejected       = "    if (`$leaf -match '^[A-Za-z]:`$') { return '' }"
    AccountBoundary     = "            if (`$current.TrimEnd([char]'\', [char]'/') -ieq `$accountRoot) { return '' }"
    PrivacyGuard        = '    if ($IncludeProjectLabel) {'
    AdapterCall         = '        $projectLabel = Get-ClaudeProjectLabel -Payload $Payload'
}

# --------------------------------------------------------------------------
# Static source inspection
# --------------------------------------------------------------------------

$script:NotifyAst = $null
function Get-NotifyAst {
    if ($null -eq $script:NotifyAst) {
        $tokens = $null
        $parseErrors = $null
        $script:NotifyAst = [System.Management.Automation.Language.Parser]::ParseFile($NotifyPath, [ref]$tokens, [ref]$parseErrors)
        if ($parseErrors.Count -gt 0) { throw 'src/notify.ps1 does not parse' }
    }
    return $script:NotifyAst
}

function Get-FunctionAst([string]$Name) {
    $found = (Get-NotifyAst).FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name
        }, $true)
    if ($found.Count -ne 1) { throw "expected exactly one function named $Name in notify.ps1" }
    return $found[0]
}

$script:ResolverFunctions = @('Resolve-ProjectLabel', 'Get-EnclosingRepositoryRoot', 'Get-DirectoryLeafName', 'Get-AccountRootDirectory')

# Everything the resolver is forbidden to do: launch anything, read a file,
# reach the network, or look at a remote.
$script:ForbiddenResolverPatterns = [ordered]@{
    'launches a process'      = 'Start-Process|Invoke-Expression|(?<![.\w-])git(\.exe)?\b|cmd\.exe|&\s*[''"]'
    'reads a file'            = 'Get-Content|ReadAllText|ReadAllLines|ReadAllBytes|OpenRead|StreamReader'
    'reaches the network'     = 'Invoke-RestMethod|Invoke-WebRequest|WebClient|HttpClient|https?:'
    'inspects a remote'       = 'remote|origin|owner|upstream'
    'reads project metadata'  = 'package\.json|pyproject|Cargo\.toml|\.csproj|composer\.json'
}

# Claude Code payload vocabulary. The resolver is reused by future adapters, so
# none of it may appear there.
$script:AgentVocabulary = @('cwd', 'transcript_path', 'session_id', 'prompt_id', 'hook_event_name', 'Payload', 'Claude')

function Find-AgentVocabulary([string]$Text) {
    $hits = @()
    foreach ($token in $script:AgentVocabulary) {
        if ([regex]::IsMatch($Text, "(?i)(?<![A-Za-z0-9_-])$([regex]::Escape($token))(?![A-Za-z0-9_])")) {
            $hits += $token
        }
    }
    return $hits
}

# --------------------------------------------------------------------------
# Suite: resolution
# --------------------------------------------------------------------------

function Invoke-ResolutionSuite {
    Initialize-Fixture | Out-Null

    # A. every fixture directory, measured against git's own answer rather than
    # against the table alone.
    foreach ($entry in $script:FixtureExpectations.GetEnumerator()) {
        $directory = Get-FixturePath $entry.Key
        $expected = [string]$entry.Value
        Assert-Equal $expected ([string](Resolve-ProjectLabel -WorkingDirectory $directory)) "A $($entry.Key) resolves"

        if ($entry.Key -ne 'plain/nested/deep') {
            Assert-Equal $expected (Get-GitToplevelLeaf $directory) "A git agrees about $($entry.Key)"
        }
    }

    # Control: git must actually disagree with the leaf somewhere, otherwise
    # the agreement above would be satisfied by doing nothing.
    Assert-Equal 'web' (Get-DirectoryLeafName (Get-FixturePath 'solo-repo/apps/web')) 'A the leaf of the nested directory really is generic'
    Assert-Equal '' (Get-GitToplevelLeaf (Get-FixturePath 'plain/nested/deep')) 'A git reports no repository outside one'

    # B. baseline equivalence. A working directory that already is the
    # repository root keeps exactly the label the previous version produced.
    foreach ($root in @('solo-repo', 'outer-repo')) {
        $directory = Get-FixturePath $root
        Assert-Equal (Get-DirectoryLeafName $directory) ([string](Resolve-ProjectLabel -WorkingDirectory $directory)) "B $root is unchanged from the leaf rule"
    }

    # C. the generic leaves this step exists for, each improved by the root.
    foreach ($leaf in $script:GenericLeaves) {
        foreach ($shape in @("solo-repo/$leaf", "solo-repo/apps/$leaf")) {
            Assert-Equal 'solo-repo' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath $shape))) "C the generic leaf '$leaf' at $shape reports the repository"
        }
    }

    # D. the label the adapter puts on the event is the resolved one, so the
    # improvement is not confined to a function nobody calls.
    Assert-Equal 'solo-repo' (Get-LabelFor (Get-FixturePath 'solo-repo/apps/web')) 'D the normalized event carries the resolved label'
    Assert-Equal 'inner-repo' (Get-LabelFor (Get-FixturePath 'outer-repo/vendor/inner-repo/src')) 'D the normalized event carries the nearest repository'

    # E. the resolver is provider neutral in name and in body.
    foreach ($name in $script:ResolverFunctions) {
        $hits = @(Find-AgentVocabulary (Get-FunctionAst $name).Extent.Text)
        Assert-Equal '' ($hits -join ',') "E $name is free of agent vocabulary"
    }

    # E control: the same detector must light up on the adapter that feeds it.
    $adapterHits = @(Find-AgentVocabulary (Get-FunctionAst 'Get-ClaudeProjectLabel').Extent.Text)
    Assert-That ($adapterHits -contains 'cwd') 'E control detects the adapter vocabulary'
    Assert-That ($adapterHits -contains 'Payload') 'E control detects the adapter payload parameter'

    # F. no new identification field appeared on the event.
    $agentEvent = ConvertTo-AgentEvent -Payload (New-LabelPayload (Get-FixturePath 'solo-repo/apps/web')) -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
    $names = @($agentEvent.PSObject.Properties.Name | Sort-Object)
    Assert-Equal 'durationMs,errorType,locale,projectLabel,provider,state' ($names -join ',') 'F the event field set is unchanged'

    Complete-Suite 'resolution' 45
}

# --------------------------------------------------------------------------
# Suite: topology
# --------------------------------------------------------------------------

function Invoke-TopologySuite {
    Initialize-Fixture | Out-Null

    # A. a repository inside another repository names itself, not its host.
    foreach ($inner in @('outer-repo/vendor/inner-repo', 'outer-repo/vendor/inner-repo/src')) {
        Assert-Equal 'inner-repo' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath $inner))) "A $inner reports the nearest repository"
    }
    Assert-Equal 'outer-repo' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath 'outer-repo/vendor'))) 'A a directory beside the inner repository still reports the outer one'

    # Non-vacuity: the two repositories really are nested, and git says so too.
    Assert-Equal 'inner-repo' (Get-GitToplevelLeaf (Get-FixturePath 'outer-repo/vendor/inner-repo/src')) 'A git agrees the inner repository wins'
    Assert-Equal 'outer-repo' (Get-GitToplevelLeaf (Get-FixturePath 'outer-repo/vendor')) 'A git agrees the outer repository owns the sibling directory'
    Assert-That (Test-Path -LiteralPath (Join-Path (Get-FixturePath 'outer-repo') '.git')) 'A the outer repository is marked'
    Assert-That (Test-Path -LiteralPath (Join-Path (Get-FixturePath 'outer-repo/vendor/inner-repo') '.git')) 'A the inner repository is marked'

    # B. a linked worktree names its own root. Its marker is a file, and the
    # main checkout it points at must not become the label.
    foreach ($shape in @('wt-feature', 'wt-feature/src')) {
        Assert-Equal 'wt-feature' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath $shape))) "B $shape names the worktree root"
        Assert-Equal 'wt-feature' (Get-GitToplevelLeaf (Get-FixturePath $shape)) "B git agrees about $shape"
    }

    $marker = Join-Path (Get-FixturePath 'wt-feature') '.git'
    Assert-That ([System.IO.File]::Exists($marker)) 'B the worktree marker is a file'
    Assert-That (-not [System.IO.Directory]::Exists($marker)) 'B the worktree marker is not a directory'
    Assert-That ($script:FixtureMainGitDir -like '*outer-repo*') 'B the worktree marker really does name the main checkout'
    Assert-That (([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath 'wt-feature/src'))) -notlike '*outer-repo*') 'B the main checkout does not leak into the worktree label'

    # C. a repository rooted at the account directory is not a project. Its
    # folder is named after the account, so claiming it would put a person's
    # name in a notification.
    Assert-Equal 'PROBE account-boundary : SURVIVED' (Invoke-LabelProbe -Probe 'account-boundary') 'C the account directory is never claimed as a repository'
    Assert-Equal 'PROBE account-boundary : KILLED' (Invoke-LabelProbe -Probe 'account-boundary' -Find $script:MutationTargets.AccountBoundary -Replace '            if ($false) { return '''' }') 'C control: without the boundary the account name does reach the label'

    # D. the enclosing-root search returns the directory git calls the toplevel,
    # not merely a directory that happens to end in the right name.
    foreach ($entry in $script:FixtureExpectations.GetEnumerator()) {
        if ($entry.Key -eq 'plain/nested/deep') { continue }
        $directory = Get-FixturePath $entry.Key
        $found = [string](Get-EnclosingRepositoryRoot $directory)
        Assert-Equal ([string]$entry.Value) (Get-DirectoryLeafName $found) "D the root found for $($entry.Key) is the right one"
        Assert-That (Test-Path -LiteralPath (Join-Path $found '.git')) "D the root found for $($entry.Key) really carries a marker"
    }

    Complete-Suite 'topology' 35
}

# --------------------------------------------------------------------------
# Suite: fallback
# --------------------------------------------------------------------------

function Invoke-FallbackSuite {
    Initialize-Fixture | Out-Null

    # A. no repository anywhere above: the leaf is still the best name there is.
    Assert-Equal 'deep' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath 'plain/nested/deep'))) 'A a directory outside any repository keeps its leaf'
    Assert-Equal 'plain' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath 'plain'))) 'A the parent outside any repository keeps its leaf'
    Assert-Equal '' ([string](Get-EnclosingRepositoryRoot (Get-FixturePath 'plain/nested/deep'))) 'A no repository is claimed outside one'

    # B. a directory that does not exist. The walk is probes, not reads, so it
    # neither raises nor invents a repository.
    Assert-Equal 'gone' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath 'plain/ghost/gone'))) 'B a missing directory outside a repository keeps its leaf'
    Assert-Equal 'solo-repo' ([string](Resolve-ProjectLabel -WorkingDirectory (Get-FixturePath 'solo-repo/apps/web/ghost'))) 'B a missing directory inside a repository still finds the root'

    # C. inputs no working directory should ever hold. None may raise, and none
    # may produce something that reads back as a path.
    $degenerate = [ordered]@{
        'empty'              = ''
        'whitespace'         = '   '
        'drive root'         = 'C:\'
        'other drive root'   = 'D:\'
        'drive specifier'    = 'C:'
        'separator only'     = '\'
        'forward separator'  = '/'
        'double separator'   = '\\'
    }
    foreach ($name in $degenerate.Keys) {
        Assert-Equal '' ([string](Resolve-ProjectLabel -WorkingDirectory $degenerate[$name])) "C the $name input resolves to nothing"
    }

    # D. characters Windows forbids in a path. The platform helpers raise on
    # these, so the resolver must not be built on them.
    foreach ($hostile in @('C:\a<b>c|d\leaf', 'C:\a"b\leaf', "C:\a`0b\leaf")) {
        $label = ''
        $raised = $false
        try { $label = [string](Resolve-ProjectLabel -WorkingDirectory $hostile) } catch { $raised = $true }
        Assert-That (-not $raised) "D a hostile path does not raise: $hostile"
        Assert-Equal 'leaf' $label "D a hostile path still yields its leaf: $hostile"
    }

    # E. an unreachable drive is a probe that fails, not an error.
    $raised = $false
    $label = ''
    try { $label = [string](Resolve-ProjectLabel -WorkingDirectory 'Q:\no-such-volume\project-x') } catch { $raised = $true }
    Assert-That (-not $raised) 'E an unreachable volume does not raise'
    Assert-Equal 'project-x' $label 'E an unreachable volume falls back to the leaf'

    # F. the neutral wording is the adapter's, and it is what an unusable
    # working directory produces on the event.
    foreach ($unusable in @('', '   ', 'C:\')) {
        Assert-Equal 'Claude Code' (Get-LabelFor $unusable) "F an unusable working directory degrades to the neutral label: '$unusable'"
    }
    Assert-Equal 'Claude Code' ([string](ConvertTo-AgentEvent -Payload $null -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true).projectLabel) 'F a missing payload degrades to the neutral label'

    # G. the search is bounded, so a pathological depth cannot become a
    # pathological cost.
    $deep = 'C:\' + ((1..400 | ForEach-Object { "seg$_" }) -join '\')
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $deepLabel = [string](Resolve-ProjectLabel -WorkingDirectory $deep)
    $watch.Stop()
    Assert-Equal 'seg400' $deepLabel 'G a pathologically deep path still yields its leaf'
    Assert-That ($watch.Elapsed.TotalMilliseconds -lt 1000) "G a pathologically deep path resolves promptly ($([math]::Round($watch.Elapsed.TotalMilliseconds)) ms)"

    Complete-Suite 'fallback' 27
}

# --------------------------------------------------------------------------
# Suite: label-privacy
# --------------------------------------------------------------------------

function Invoke-LabelPrivacySuite {
    Initialize-Fixture | Out-Null

    # A. with the preference off, nothing about the project reaches the event,
    # whatever the working directory would have resolved to.
    foreach ($entry in $script:FixtureExpectations.GetEnumerator()) {
        $directory = Get-FixturePath $entry.Key
        Assert-Equal 'Claude Code' (Get-LabelFor $directory $false) "A $($entry.Key) is suppressed"
        Assert-Equal ([string]$entry.Value) (Get-LabelFor $directory $true) "A $($entry.Key) is reported when allowed"
    }

    # B. resolution does not merely get discarded, it never happens. The probe
    # replaces the resolver with one that counts its own calls, so a notifier
    # that resolved first and dropped the answer later is visible here.
    Assert-Equal 'PROBE privacy : SURVIVED' (Invoke-LabelProbe -Probe 'privacy') 'B the resolver is never called while the label is suppressed'

    # B control: a guard that always resolves must be caught by that probe,
    # otherwise the clean result above would prove nothing.
    Assert-Equal 'PROBE privacy : KILLED' (Invoke-LabelProbe -Probe 'privacy' -Find $script:MutationTargets.PrivacyGuard -Replace '    if ($true) {') 'B control kills an adapter that resolves regardless of the preference'

    # C. the guard is in the seam, ahead of resolution, and reads the
    # preference rather than a detail level.
    $seam = (Get-FunctionAst 'ConvertTo-AgentEvent').Extent.Text
    Assert-That ($seam -match '\$projectLabel\s*=\s*''Claude Code''') 'C the seam starts from the neutral label'
    Assert-That ($seam -match 'if\s*\(\$IncludeProjectLabel\)') 'C the seam resolves only when the preference allows it'
    Assert-That (-not ($seam -match 'Detail')) 'C the seam does not consult a detail level'

    # C control: the same matcher must reject a guard that is not there.
    Assert-That (-not ($seam -match 'if\s*\(\$IncludeNothingAtAll\)')) 'C guard detector control rejects an absent guard'

    # D. nothing else in the notifier resolves a label behind the guard's back.
    $callers = @()
    foreach ($function in (Get-NotifyAst).FindAll({
                param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true)) {
        if ($script:ResolverFunctions -contains $function.Name) { continue }
        if ($function.Extent.Text -match 'Resolve-ProjectLabel|Get-EnclosingRepositoryRoot') { $callers += $function.Name }
    }
    Assert-Equal 'Get-ClaudeProjectLabel' ($callers -join ',') 'D exactly one function resolves a label'

    Complete-Suite 'label-privacy' 27
}

# --------------------------------------------------------------------------
# Suite: label-detail
# --------------------------------------------------------------------------

function Invoke-LabelDetailSuite {
    Initialize-Fixture | Out-Null

    $nested = Get-FixturePath 'solo-repo/apps/web'

    foreach ($locale in @('en', 'pt-BR')) {
        foreach ($state in @('finished', 'attention', 'error')) {
            foreach ($sendProjectName in @($true, $false)) {
                $agentEvent = ConvertTo-AgentEvent -Payload (New-LabelPayload $nested) -EventState $state -Locale $locale -IncludeProjectLabel $sendProjectName
                $label = "$locale/$state/sendProjectName=$sendProjectName"

                $standard = [string](Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard').Body
                $minimal = [string](Get-AgentMessage -AgentEvent $agentEvent -Detail 'minimal').Body

                # The minimal level hides a resolved label at every combination.
                Assert-That ($minimal -notlike '*solo-repo*') "minimal hides the resolved label for $label"
                Assert-That ($minimal -notlike '*web*') "minimal hides the working directory leaf for $label"

                if ($sendProjectName) {
                    # The standard level shows it, which is what makes the
                    # minimal result above meaningful.
                    Assert-That ($standard -like 'solo-repo - *') "standard shows the resolved label for $label"
                }
                else {
                    # Privacy still outranks detail: the most detailed level
                    # cannot reach back for a label the preference suppressed.
                    Assert-That ($standard -notlike '*solo-repo*') "standard cannot recover a suppressed label for $label"
                    Assert-That ($standard -notlike '*web*') "standard cannot recover a suppressed leaf for $label"
                }
            }
        }
    }

    # The precedence, stated once: privacy decides whether a label exists,
    # detail decides whether an existing one is shown, and resolution only ever
    # decides what an allowed label says.
    $allowed = ConvertTo-AgentEvent -Payload (New-LabelPayload $nested) -EventState 'finished' -Locale 'en' -IncludeProjectLabel $true
    $suppressed = ConvertTo-AgentEvent -Payload (New-LabelPayload $nested) -EventState 'finished' -Locale 'en' -IncludeProjectLabel $false
    Assert-Equal ([string](Get-AgentMessage -AgentEvent $allowed -Detail 'minimal').Body) ([string](Get-AgentMessage -AgentEvent $suppressed -Detail 'minimal').Body) 'minimal renders the same body whether or not a label was allowed'
    Assert-That (([string](Get-AgentMessage -AgentEvent $allowed -Detail 'standard').Body) -cne ([string](Get-AgentMessage -AgentEvent $suppressed -Detail 'standard').Body)) 'standard does distinguish the two, so the equality above is not vacuous'

    Complete-Suite 'label-detail' 44
}

# --------------------------------------------------------------------------
# Suite: label-locales
# --------------------------------------------------------------------------

function Invoke-LabelLocalesSuite {
    Initialize-Fixture | Out-Null

    $expectedBodies = [ordered]@{
        'en|finished'     = 'solo-repo - Claude finished the task.'
        'en|attention'    = 'solo-repo - Claude is waiting for your input.'
        'en|error'        = 'solo-repo - Claude stopped because of an error.'
        'pt-BR|finished'  = 'solo-repo - O Claude terminou o trabalho.'
        'pt-BR|attention' = 'solo-repo - O Claude esta esperando sua intervencao.'
        'pt-BR|error'     = 'solo-repo - O Claude interrompeu o trabalho.'
    }
    $expectedTitles = [ordered]@{
        'en|finished'     = 'Claude Code - FINISHED'
        'en|attention'    = 'Claude Code - ATTENTION'
        'en|error'        = 'Claude Code - ERROR'
        'pt-BR|finished'  = 'Claude Code - FINALIZADO'
        'pt-BR|attention' = 'Claude Code - ATENCAO'
        'pt-BR|error'     = 'Claude Code - ERRO'
    }

    $nested = Get-FixturePath 'solo-repo/apps/web'

    foreach ($locale in @('en', 'pt-BR')) {
        foreach ($state in @('finished', 'attention', 'error')) {
            $agentEvent = ConvertTo-AgentEvent -Payload (New-LabelPayload $nested) -EventState $state -Locale $locale -IncludeProjectLabel $true
            $message = Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard'
            Assert-Equal ([string]$expectedBodies["$locale|$state"]) ([string]$message.Body) "$locale/$state body carries the resolved label"
            Assert-Equal ([string]$expectedTitles["$locale|$state"]) ([string]$message.Title) "$locale/$state title is unchanged"
        }
    }

    # The error state still carries its category alongside the resolved label.
    $withError = ([ordered]@{ cwd = $nested; error = 'ToolExecutionFailure' } | ConvertTo-Json -Compress | ConvertFrom-Json)
    foreach ($locale in @('en', 'pt-BR')) {
        $agentEvent = ConvertTo-AgentEvent -Payload $withError -EventState 'error' -Locale $locale -IncludeProjectLabel $true
        $body = [string](Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard').Body
        Assert-That ($body -like 'solo-repo - *') "$locale error body starts with the resolved label"
        Assert-That ($body -like '*(ToolExecutionFailure)*') "$locale error body keeps the error category"
    }

    # An unknown locale still falls back to en, with the resolved label intact.
    foreach ($unknown in @('de', '', 'pt')) {
        $agentEvent = ConvertTo-AgentEvent -Payload (New-LabelPayload $nested) -EventState 'finished' -Locale $unknown -IncludeProjectLabel $true
        Assert-Equal 'solo-repo - Claude finished the task.' ([string](Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard').Body) "locale '$unknown' falls back to en with the resolved label"
    }

    Complete-Suite 'label-locales' 19
}

# --------------------------------------------------------------------------
# Suite: leak
# --------------------------------------------------------------------------

$script:CapturedNtfyCalls = New-Object System.Collections.Generic.List[hashtable]
function Invoke-RestMethod {
    param(
        [string]$Uri,
        [string]$Method,
        [hashtable]$Headers,
        [string]$Body,
        [string]$ContentType,
        [int]$TimeoutSec
    )
    $script:CapturedNtfyCalls.Add(@{ Uri = $Uri; Method = $Method; Headers = $Headers; Body = $Body; ContentType = $ContentType; TimeoutSec = $TimeoutSec })
}

function Invoke-LeakSuite {
    Initialize-Fixture | Out-Null

    # Everything that must never appear, each provably present in the fixture
    # so a clean result means the notifier declined to look rather than that
    # there was nothing to find.
    $forbidden = [ordered]@{
        fixtureRoot   = $script:FixtureRoot
        mainCheckout  = $script:FixtureMainGitDir
        remoteOwner   = $script:RemoteOwner
        remoteProject = $script:RemoteProject
    }

    function Find-Forbidden([string]$Text) {
        $hits = @()
        foreach ($name in $forbidden.Keys) {
            $needle = [string]$forbidden[$name]
            if (-not [string]::IsNullOrWhiteSpace($needle) -and $Text -like ('*' + $needle + '*')) { $hits += $name }
        }
        if ([regex]::IsMatch($Text, '[A-Za-z]:\\')) { $hits += 'windowsAbsolutePath' }
        if ([regex]::IsMatch($Text, 'https?://')) { $hits += 'url' }
        return ($hits | Sort-Object -Unique)
    }

    # Positive controls first, so a clean result below means something.
    foreach ($name in $forbidden.Keys) {
        Assert-That ((@(Find-Forbidden ('prefix ' + [string]$forbidden[$name] + ' suffix'))) -contains $name) "scanner control detects $name"
    }
    Assert-That ((@(Find-Forbidden 'see C:\Windows\notepad.exe')) -contains 'windowsAbsolutePath') 'scanner control detects an absolute path'
    Assert-That ((@(Find-Forbidden 'see https://example.invalid/x')) -contains 'url') 'scanner control detects a url'
    Assert-Equal '' ((@(Find-Forbidden 'solo-repo - Claude finished the task.')) -join ',') 'scanner control passes a clean message'

    # The remote really is configured, so 'the remote never appears' is a claim
    # about behaviour rather than about an empty fixture.
    $remote = Invoke-Git -Directory (Get-FixturePath 'solo-repo') -GitArguments @('remote', 'get-url', 'origin')
    Assert-Equal '0' ([string]$remote.ExitCode) 'the fixture repository has a remote'
    Assert-That ($remote.Output -like ('*' + $script:RemoteProject + '*')) 'the remote names a project the directory does not'
    Assert-That ($remote.Output -like ('*' + $script:RemoteOwner + '*')) 'the remote names an owner'

    foreach ($entry in $script:FixtureExpectations.GetEnumerator()) {
        $directory = Get-FixturePath $entry.Key
        foreach ($state in @('finished', 'attention', 'error')) {
            $agentEvent = ConvertTo-AgentEvent -Payload (New-LabelPayload $directory) -EventState $state -Locale 'en' -IncludeProjectLabel $true
            $label = "$($entry.Key)/$state"

            $eventText = (@($agentEvent.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '|')
            Assert-Equal '' ((@(Find-Forbidden $eventText)) -join ',') "the normalized event is clean for $label"

            $message = Get-AgentMessage -AgentEvent $agentEvent -Detail 'standard'
            $messageText = "$($message.Title)|$($message.Body)|$($message.Priority)|$($message.Tags)"
            Assert-Equal '' ((@(Find-Forbidden $messageText)) -join ',') "the rendered message is clean for $label"

            $script:CapturedNtfyCalls.Clear()
            $config = ([ordered]@{
                    locale  = 'en'
                    desktop = [ordered]@{ enabled = $false }
                    mobile  = [ordered]@{ enabled = $true; provider = 'ntfy'; server = 'https://ntfy.invalid'; topic = 'leak-topic' }
                } | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json)
            Send-NtfyNotification -Config $config -Message $message
            Assert-Equal '1' ([string]$script:CapturedNtfyCalls.Count) "one request was captured for $label"
            $call = $script:CapturedNtfyCalls[0]
            $requestText = "$($call.Body)|" + (@($call.Headers.Keys | Sort-Object | ForEach-Object { "$_=$($call.Headers[$_])" }) -join '|')
            Assert-Equal '' ((@(Find-Forbidden $requestText)) -join ',') "the outgoing request is clean for $label"
        }
    }

    # The label itself is a bare name whatever it is handed.
    Assert-Equal 'PROBE leak : SURVIVED' (Invoke-LabelProbe -Probe 'leak') 'the resolver never returns anything path shaped'

    Complete-Suite 'leak' 131
}

# --------------------------------------------------------------------------
# Suite: performance
# --------------------------------------------------------------------------

function Invoke-PerformanceSuite {
    Initialize-Fixture | Out-Null

    # A. the resolver's source does none of the expensive or revealing things.
    $resolverText = (@($script:ResolverFunctions | ForEach-Object { (Get-FunctionAst $_).Extent.Text }) -join "`n")
    foreach ($name in $script:ForbiddenResolverPatterns.Keys) {
        Assert-That (-not [regex]::IsMatch($resolverText, $script:ForbiddenResolverPatterns[$name])) "A the resolver never $name"
    }

    # A control: every detector must fire on text that really does the thing,
    # otherwise the clean results above would be meaningless.
    $controls = [ordered]@{
        'launches a process'     = '& git.exe rev-parse --show-toplevel'
        'reads a file'           = '$x = Get-Content $marker -Raw'
        'reaches the network'    = 'Invoke-RestMethod -Uri https://example.invalid'
        'inspects a remote'      = '$url = git remote get-url origin'
        'reads project metadata' = '$name = (Get-Content package.json | ConvertFrom-Json).name'
    }
    foreach ($name in $controls.Keys) {
        Assert-That ([regex]::IsMatch($controls[$name], $script:ForbiddenResolverPatterns[$name])) "A control: the '$name' detector fires on text that does"
    }

    # A second control: the same detectors find these behaviours where they do
    # legitimately live in this file.
    Assert-That ([regex]::IsMatch((Get-FunctionAst 'Send-NtfyNotification').Extent.Text, $script:ForbiddenResolverPatterns['reaches the network'])) 'A control: the network detector finds mobile delivery'
    Assert-That ([regex]::IsMatch((Get-FunctionAst 'Resolve-TurnDuration').Extent.Text, $script:ForbiddenResolverPatterns['reads a file'])) 'A control: the file detector finds the turn store'

    # B. resolution needs no tool on PATH. The probe empties PATH in a child
    # process, confirms nothing can be launched by name there, and resolves
    # every fixture directory anyway.
    Assert-Equal 'PROBE toolless : SURVIVED' (Invoke-LabelProbe -Probe 'toolless') 'B resolution succeeds with an emptied PATH'

    # C. the cost, measured here rather than asserted from a comment. The
    # worst case is a directory outside any repository, which walks all the way
    # to the volume root before giving up.
    $iterations = 200
    $worstCase = Get-FixturePath 'plain/nested/deep'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $iterations; $i++) { Resolve-ProjectLabel -WorkingDirectory $worstCase | Out-Null }
    $watch.Stop()
    $averageMs = $watch.Elapsed.TotalMilliseconds / $iterations
    Write-Host ('  worst-case resolution: {0} ms per call over {1} calls' -f ([math]::Round($averageMs, 3)), $iterations)
    Assert-That ($averageMs -lt 25) "C the worst case stays well inside a notification's budget ($([math]::Round($averageMs, 3)) ms)"

    $best = Get-FixturePath 'solo-repo/apps/web'
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $iterations; $i++) { Resolve-ProjectLabel -WorkingDirectory $best | Out-Null }
    $watch.Stop()
    $insideMs = $watch.Elapsed.TotalMilliseconds / $iterations
    Write-Host ('  inside-repository resolution: {0} ms per call over {1} calls' -f ([math]::Round($insideMs, 3)), $iterations)
    Assert-That ($insideMs -lt 25) "C resolving inside a repository is cheap ($([math]::Round($insideMs, 3)) ms)"

    # C control: the measurement is real, so a deliberately slow call must
    # exceed the same bound.
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Start-Sleep -Milliseconds 60
    $watch.Stop()
    Assert-That ($watch.Elapsed.TotalMilliseconds -gt 25) 'C control: the same clock does exceed the bound when something is slow'

    # D. the bound on the walk is a real constant, not a comment.
    Assert-That ($script:ProjectRootMaxDepth -ge 1 -and $script:ProjectRootMaxDepth -le 4096) 'D the search depth is bounded'
    Assert-That ((Get-FunctionAst 'Get-EnclosingRepositoryRoot').Extent.Text -match '\$depth\s*-lt\s*\$script:ProjectRootMaxDepth') 'D the loop honours that bound'

    Complete-Suite 'performance' 18
}

# --------------------------------------------------------------------------
# Suite: resilience
# --------------------------------------------------------------------------

function Invoke-ResilienceSuite {
    Initialize-Fixture | Out-Null

    # A. the whole chain, on the real notifier: normalize, render, deliver.
    Assert-Equal 'PROBE delivery : SURVIVED' (Invoke-LabelProbe -Probe 'delivery') 'A delivery works on the unmodified notifier'

    # B. a resolver that raises costs the label and nothing else. The
    # notification is still built and still handed to delivery.
    Assert-Equal 'PROBE delivery : SURVIVED' (Invoke-LabelProbe -Probe 'delivery' -Find $script:MutationTargets.RepositoryPreferred -Replace "        throw 'resolver exploded'") 'B a resolver that raises does not stop delivery'

    # B control: the probe must be able to see a failure, otherwise the two
    # results above would be indistinguishable from a probe that never checks.
    Assert-Equal 'PROBE delivery : KILLED' (Invoke-LabelProbe -Probe 'delivery' -Find $script:MutationTargets.AdapterCall -Replace "        `$projectLabel = & { throw 'unguarded failure' }") 'B control: an unguarded failure does stop delivery and is detected'

    # C. end to end, in a disposable home, with the installed hooks.
    $sandboxHome = Join-Path ([System.IO.Path]::GetTempPath()) ('agentchime-label-home-' + [guid]::NewGuid().ToString('N'))
    if ($sandboxHome -eq $HOME) { throw 'refusing to run: the sandbox resolved to the real home directory' }
    New-Item -ItemType Directory -Force -Path $sandboxHome | Out-Null

    $saved = @{ HOMEDRIVE = $env:HOMEDRIVE; HOMEPATH = $env:HOMEPATH; USERPROFILE = $env:USERPROFILE }
    try {
        $volume = [System.IO.Path]::GetPathRoot($sandboxHome).TrimEnd('\')
        $env:HOMEDRIVE = $volume
        $env:HOMEPATH = $sandboxHome.Substring($volume.Length)
        $env:USERPROFILE = $sandboxHome

        function Invoke-InSandbox {
            param([string]$Script, [string[]]$ScriptArguments = @(), [string]$StandardInput = '')
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $ScriptArguments
            $previous = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                if ([string]::IsNullOrEmpty($StandardInput)) { $output = & powershell.exe @arguments 2>&1 }
                else { $output = $StandardInput | & powershell.exe @arguments 2>&1 }
                $code = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $previous }
            return [pscustomobject]@{ ExitCode = $code; Output = (($output | Out-String).Trim()) }
        }

        $probe = Invoke-InSandbox -Script $HomeProbePath
        Assert-Equal ("HOME=" + $sandboxHome) $probe.Output 'C a child resolves HOME to the sandbox'

        $install = Invoke-InSandbox -Script $InstallPath
        Assert-Equal '0' ([string]$install.ExitCode) "C the install succeeds: $($install.Output)"

        $sandboxNotify = Join-Path (Join-Path $sandboxHome '.agentchime') 'notify.ps1'
        $sandboxConfig = Join-Path (Join-Path $sandboxHome '.agentchime') 'config.json'
        $sandboxLog = Join-Path (Join-Path $sandboxHome '.agentchime') 'agentchime.log'
        Assert-That (Test-Path $sandboxNotify) 'C the notifier is installed'

        # Both destinations off, so the run exercises everything up to delivery
        # without opening a balloon or reaching the network.
        $config = Get-Content $sandboxConfig -Raw | ConvertFrom-Json
        $config.desktop.enabled = $false
        $config.mobile.enabled = $false
        $config | ConvertTo-Json -Depth 10 | Set-Content -Path $sandboxConfig -Encoding UTF8

        $payload = ([ordered]@{
                cwd        = (Get-FixturePath 'solo-repo/apps/web')
                session_id = '11111111-2222-3333-4444-555555555555'
                prompt_id  = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'
            } | ConvertTo-Json -Compress)

        foreach ($state in @('turn-start', 'attention', 'finished')) {
            $run = Invoke-InSandbox -Script $sandboxNotify -ScriptArguments @($state) -StandardInput $payload
            Assert-Equal '0' ([string]$run.ExitCode) "C the $state hook exits cleanly: $($run.Output)"
        }
        Assert-That (-not (Test-Path $sandboxLog)) 'C no delivery error was logged'

        # D. the same run against a notifier whose resolver raises. Delivery
        # must be unaffected, which is what makes project context best effort.
        $broken = New-MutantNotifier -Find $script:MutationTargets.RepositoryPreferred -Replace "        throw 'resolver exploded'"
        Assert-That (-not [string]::IsNullOrWhiteSpace($broken)) 'D the broken notifier was produced'
        Copy-Item -Path $broken -Destination $sandboxNotify -Force

        foreach ($state in @('turn-start', 'attention', 'finished')) {
            $run = Invoke-InSandbox -Script $sandboxNotify -ScriptArguments @($state) -StandardInput $payload
            Assert-Equal '0' ([string]$run.ExitCode) "D the $state hook still exits cleanly with a broken resolver: $($run.Output)"
        }
        Assert-That (-not (Test-Path $sandboxLog)) 'D a broken resolver logged no delivery error'
    }
    finally {
        $env:HOMEDRIVE = $saved.HOMEDRIVE
        $env:HOMEPATH = $saved.HOMEPATH
        $env:USERPROFILE = $saved.USERPROFILE
        if (Test-Path $sandboxHome) { Remove-Item $sandboxHome -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Complete-Suite 'resilience' 15
}

# --------------------------------------------------------------------------
# Suite: mutation
# --------------------------------------------------------------------------

function Invoke-MutationSuite {
    Initialize-Fixture | Out-Null

    $probes = @('repo-root', 'nested-dir', 'nearest', 'worktree', 'fallback', 'leak')

    # A. every probe survives the real notifier. Without this a probe that
    # always reported KILLED would look like proof.
    foreach ($probe in $probes) {
        Assert-Equal "PROBE $probe : SURVIVED" (Invoke-LabelProbe -Probe $probe) "A the $probe probe survives the real notifier"
    }

    # B. each mutant, and exactly which probes must catch it. A probe listed as
    # SURVIVED is as much a part of the contract as one listed as KILLED: it
    # says the mutant did not change that behaviour, which is how the baseline
    # cases are pinned.
    $mutants = [ordered]@{
        'a resolver that ignores the repository' = @{
            Find    = $script:MutationTargets.RepositoryPreferred
            Replace = "        `$label = ''"
            Verdict = [ordered]@{ 'repo-root' = 'SURVIVED'; 'nested-dir' = 'KILLED'; 'nearest' = 'KILLED'; 'worktree' = 'KILLED'; 'fallback' = 'KILLED' }
        }
        'a walk that reports the parent of the repository' = @{
            Find    = $script:MutationTargets.RootReturned
            Replace = '                return ([string][System.IO.Path]::GetDirectoryName($current))'
            Verdict = [ordered]@{ 'repo-root' = 'KILLED'; 'nested-dir' = 'KILLED'; 'nearest' = 'KILLED'; 'worktree' = 'KILLED' }
        }
        'a walk that cannot see a worktree marker' = @{
            Find    = $script:MutationTargets.MarkerAccepted
            Replace = '            if ([System.IO.Directory]::Exists($marker)) {'
            Verdict = [ordered]@{ 'repo-root' = 'SURVIVED'; 'nested-dir' = 'SURVIVED'; 'nearest' = 'SURVIVED'; 'worktree' = 'KILLED' }
        }
        'a resolver that returns the working directory' = @{
            Find    = $script:MutationTargets.LeafReturned
            Replace = '        return $WorkingDirectory'
            Verdict = [ordered]@{ 'fallback' = 'KILLED'; 'leak' = 'KILLED'; 'nested-dir' = 'SURVIVED' }
        }
        'a leaf that keeps a drive specifier' = @{
            Find    = $script:MutationTargets.DriveRejected
            Replace = '    if ($false) { return '''' }'
            Verdict = [ordered]@{ 'leak' = 'KILLED'; 'nested-dir' = 'SURVIVED' }
        }
    }

    foreach ($name in $mutants.Keys) {
        $mutant = $mutants[$name]
        foreach ($probe in $mutant.Verdict.Keys) {
            $expected = "PROBE $probe : $($mutant.Verdict[$probe])"
            Assert-Equal $expected (Invoke-LabelProbe -Probe $probe -Find $mutant.Find -Replace $mutant.Replace) "B '$name' against the $probe probe"
        }
    }

    # C. every mutation target still exists, so a refactor cannot silently turn
    # the whole suite above into a set of no-ops.
    $source = Get-Content $NotifyPath -Raw
    foreach ($name in $script:MutationTargets.Keys) {
        Assert-That ($source.Contains([string]$script:MutationTargets[$name])) "C the $name mutation target is still present"
    }

    Complete-Suite 'mutation' 31
}

# --------------------------------------------------------------------------

try {
    switch ($Suite) {
        'resolution'    { Invoke-ResolutionSuite }
        'topology'      { Invoke-TopologySuite }
        'fallback'      { Invoke-FallbackSuite }
        'label-privacy' { Invoke-LabelPrivacySuite }
        'label-detail'  { Invoke-LabelDetailSuite }
        'label-locales' { Invoke-LabelLocalesSuite }
        'leak'          { Invoke-LeakSuite }
        'performance'   { Invoke-PerformanceSuite }
        'resilience'    { Invoke-ResilienceSuite }
        'mutation'      { Invoke-MutationSuite }
        'contract'      {
            Invoke-ResolutionSuite
            Invoke-TopologySuite
            Invoke-FallbackSuite
            Invoke-LabelPrivacySuite
            Invoke-LabelDetailSuite
            Invoke-LabelLocalesSuite
            Invoke-LeakSuite
            Invoke-PerformanceSuite
            Invoke-ResilienceSuite
            Invoke-MutationSuite
            Write-Host 'SUITE project-label contract: PASS' -ForegroundColor Green
        }
    }
}
finally {
    Remove-Fixture
    if (-not [string]::IsNullOrWhiteSpace($script:MutationSandbox) -and (Test-Path $script:MutationSandbox)) {
        Remove-Item $script:MutationSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# git runs as a child process, so say so explicitly.
exit 0
