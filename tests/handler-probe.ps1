# Runs one handler-matching expectation against an arbitrary copy of the CLI.
#
# tests/handler-contract.ps1 uses this to prove its own oracles can fail: it
# writes a deliberately broken copy of agentchime.ps1 and expects the probe to
# report KILLED. Running the same probe against the unmodified file must report
# SURVIVED, otherwise a probe that always reported KILLED would look like proof.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [ValidateSet('separator', 'suffix', 'ambiguous', 'foreign')]
    [string]$Probe
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# agentchime.ps1 dispatches on a parameter and exits, so it cannot be
# dot-sourced the way src/notify.ps1 can. Lift the named functions out of its
# syntax tree instead and define those, and only those, here.
function Import-ScriptFunctions([string]$Path, [string[]]$Names) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) { throw "Cannot parse $Path" }

    $found = @{}
    foreach ($fn in $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($Names -contains $fn.Name) { $found[$fn.Name] = $fn.Extent.Text }
    }
    foreach ($name in $Names) {
        if (-not $found.ContainsKey($name)) { throw "$Path does not define $name" }
    }
    return [scriptblock]::Create((($Names | ForEach-Object { $found[$_] }) -join "`n`n"))
}

. (Import-ScriptFunctions -Path $Source -Names @('Get-NormalizedPathKey', 'Get-HandlerScriptPaths', 'Get-AgentChimeHandlerState'))

$NotifyPath = 'C:\Users\probe\.agentchime\notify.ps1'

# Real handlers reach the code as JSON, so build them the same way.
function New-Handler([string]$Command, [string[]]$Arguments) {
    $map = [ordered]@{ type = 'command'; command = $Command }
    if ($null -ne $Arguments) { $map['args'] = $Arguments }
    return ($map | ConvertTo-Json -Compress | ConvertFrom-Json)
}

$verdict = 'KILLED'

switch ($Probe) {
    'separator' {
        # The installer writes a backslash path; a hand-edited settings file may
        # spell the same file with forward slashes. Both are the same handler.
        $handler = New-Handler 'powershell.exe' @('-NoProfile', '-File', 'C:/Users/probe/.agentchime/notify.ps1', 'finished')
        if ((Get-AgentChimeHandlerState -Handler $handler -Path $NotifyPath) -eq 'healthy') { $verdict = 'SURVIVED' }
    }
    'suffix' {
        # notify.ps1.bak belongs to somebody else and must not be claimed.
        $handler = New-Handler 'powershell.exe -NoProfile -File C:\Users\probe\.agentchime\notify.ps1.bak finished' $null
        if ((Get-AgentChimeHandlerState -Handler $handler -Path $NotifyPath) -eq 'none') { $verdict = 'SURVIVED' }
    }
    'ambiguous' {
        # A handler that also names a leftover script is not healthy: the
        # leftover can still be what actually runs.
        $handler = New-Handler 'powershell.exe -NoProfile -File C:\Users\probe\.claude\hooks\notify.ps1' @('-File', 'C:\Users\probe\.agentchime\notify.ps1', 'finished')
        if ((Get-AgentChimeHandlerState -Handler $handler -Path $NotifyPath) -eq 'ambiguous') { $verdict = 'SURVIVED' }
    }
    'foreign' {
        # Somebody else's hook is not ours in any spelling.
        $handler = New-Handler 'powershell.exe' @('-NoProfile', '-File', 'C:\Tools\other-tool.ps1')
        if ((Get-AgentChimeHandlerState -Handler $handler -Path $NotifyPath) -eq 'none') { $verdict = 'SURVIVED' }
    }
}

Write-Host ('PROBE {0}: {1}' -f $Probe, $verdict)
exit 0
