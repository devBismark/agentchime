param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('finished', 'attention', 'error')]
    [string]$State
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $HOME '.agentchime'
$ConfigPath = Join-Path $InstallDir 'config.json'

function Get-HookInput {
    try {
        if ([Console]::IsInputRedirected) {
            $raw = [Console]::In.ReadToEnd()
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                return ($raw | ConvertFrom-Json)
            }
        }
    }
    catch {
        # Hook input is optional for manual tests.
    }
    return $null
}

function Get-ProjectName([object]$HookInput) {
    try {
        if ($null -ne $HookInput -and $HookInput.PSObject.Properties['cwd']) {
            $cwd = [string]$HookInput.cwd
            if (-not [string]::IsNullOrWhiteSpace($cwd)) {
                $leaf = Split-Path -Path $cwd -Leaf
                if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                    return $leaf
                }
            }
        }
    }
    catch {}
    return 'Claude Code'
}

function Get-MessageSet([string]$Locale, [string]$CurrentState, [string]$Project, [object]$HookInput) {
    $errorType = $null
    try {
        if ($null -ne $HookInput -and $HookInput.PSObject.Properties['error']) {
            $errorType = [string]$HookInput.error
        }
    }
    catch {}

    if ($Locale -eq 'pt-BR') {
        switch ($CurrentState) {
            'finished' {
                return @{ Title = 'Claude Code - FINALIZADO'; Body = "$Project - O Claude terminou o trabalho."; Priority = 'default'; Tags = 'white_check_mark,robot_face' }
            }
            'attention' {
                return @{ Title = 'Claude Code - ATENCAO'; Body = "$Project - O Claude esta esperando sua intervencao."; Priority = 'high'; Tags = 'warning,robot_face' }
            }
            'error' {
                $suffix = if ([string]::IsNullOrWhiteSpace($errorType)) { '' } else { " ($errorType)" }
                return @{ Title = 'Claude Code - ERRO'; Body = "$Project - O Claude interrompeu o trabalho$suffix."; Priority = 'high'; Tags = 'x,robot_face' }
            }
        }
    }

    switch ($CurrentState) {
        'finished' {
            return @{ Title = 'Claude Code - FINISHED'; Body = "$Project - Claude finished the task."; Priority = 'default'; Tags = 'white_check_mark,robot_face' }
        }
        'attention' {
            return @{ Title = 'Claude Code - ATTENTION'; Body = "$Project - Claude is waiting for your input."; Priority = 'high'; Tags = 'warning,robot_face' }
        }
        'error' {
            $suffix = if ([string]::IsNullOrWhiteSpace($errorType)) { '' } else { " ($errorType)" }
            return @{ Title = 'Claude Code - ERROR'; Body = "$Project - Claude stopped because of an error$suffix."; Priority = 'high'; Tags = 'x,robot_face' }
        }
    }
}

function Send-WindowsNotification([hashtable]$Message) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    switch ($State) {
        'finished' {
            [System.Media.SystemSounds]::Asterisk.Play()
            $balloonIcon = [System.Windows.Forms.ToolTipIcon]::Info
            $systemIcon = [System.Drawing.SystemIcons]::Information
        }
        'attention' {
            [System.Media.SystemSounds]::Exclamation.Play()
            $balloonIcon = [System.Windows.Forms.ToolTipIcon]::Warning
            $systemIcon = [System.Drawing.SystemIcons]::Warning
        }
        'error' {
            [System.Media.SystemSounds]::Hand.Play()
            $balloonIcon = [System.Windows.Forms.ToolTipIcon]::Error
            $systemIcon = [System.Drawing.SystemIcons]::Error
        }
    }

    $notify = New-Object System.Windows.Forms.NotifyIcon
    try {
        $notify.Icon = $systemIcon
        $notify.BalloonTipIcon = $balloonIcon
        $notify.BalloonTipTitle = [string]$Message.Title
        $notify.BalloonTipText = [string]$Message.Body
        $notify.Visible = $true
        $notify.ShowBalloonTip(6000)
        Start-Sleep -Seconds 7
    }
    finally {
        $notify.Dispose()
    }
}

function Send-NtfyNotification([object]$Config, [hashtable]$Message) {
    if (-not $Config.mobile.enabled) { return }
    if ($Config.mobile.provider -ne 'ntfy') { return }

    $server = ([string]$Config.mobile.server).TrimEnd('/')
    $topic = [uri]::EscapeDataString(([string]$Config.mobile.topic).Trim())
    if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($topic)) { return }

    $uri = "$server/$topic"
    $headers = @{
        Title = [string]$Message.Title
        Priority = [string]$Message.Priority
        Tags = [string]$Message.Tags
    }

    Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ([string]$Message.Body) -ContentType 'text/plain; charset=utf-8' -TimeoutSec 10 | Out-Null
}

$hookInput = Get-HookInput
$project = Get-ProjectName -HookInput $hookInput

$config = [pscustomobject]@{
    locale = 'en'
    desktop = [pscustomobject]@{ enabled = $true }
    mobile = [pscustomobject]@{ enabled = $false; provider = 'ntfy'; server = 'https://ntfy.sh'; topic = '' }
}

if (Test-Path $ConfigPath) {
    try {
        $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    }
    catch {
        # Keep safe defaults if config is malformed.
    }
}

$locale = if ($config.PSObject.Properties['locale']) { [string]$config.locale } else { 'en' }

$sendProjectName = $true
try {
    if ($config.PSObject.Properties['privacy'] -and $config.privacy.PSObject.Properties['sendProjectName']) {
        $sendProjectName = [bool]$config.privacy.sendProjectName
    }
}
catch {}
if (-not $sendProjectName) { $project = 'Claude Code' }

$message = Get-MessageSet -Locale $locale -CurrentState $State -Project $project -HookInput $hookInput

$errors = New-Object System.Collections.Generic.List[string]

# Send mobile first so the phone is not delayed by the desktop balloon lifetime.
try {
    Send-NtfyNotification -Config $config -Message $message
}
catch {
    $errors.Add("Mobile notification failed: $($_.Exception.Message)")
}

try {
    if ($config.desktop.enabled) {
        Send-WindowsNotification -Message $message
    }
}
catch {
    $errors.Add("Desktop notification failed: $($_.Exception.Message)")
}

if ($errors.Count -gt 0) {
    $logPath = Join-Path $InstallDir 'agentchime.log'
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    foreach ($item in $errors) {
        Add-Content -Path $logPath -Value "[$timestamp] $item" -Encoding UTF8
    }
    exit 1
}

exit 0
