param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('finished', 'attention', 'error')]
    [string]$State
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $HOME '.agentchime'
$ConfigPath = Join-Path $InstallDir 'config.json'

# ---------------------------------------------------------------------------
# Claude Code adapter
#
# Everything that knows how a Claude Code hook payload is spelled lives in this
# region. Past this boundary the notifier only ever sees a normalized
# AgentEvent, so another agent can be supported later by adding one more
# adapter instead of by editing rendering or delivery.
# ---------------------------------------------------------------------------

# Claude Code delivers its hook payload as one JSON document on stdin.
function Read-ClaudeHookPayload {
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

function Get-ClaudePayloadValue([object]$Payload, [string]$Name) {
    try {
        if ($null -ne $Payload -and $Payload.PSObject.Properties[$Name]) {
            return [string]$Payload.$Name
        }
    }
    catch {}
    return ''
}

# The working directory is the only field a project label is taken from, and
# only its leaf is kept, so no absolute path can leave the adapter.
function Get-ClaudeProjectLabel([object]$Payload) {
    try {
        $cwd = Get-ClaudePayloadValue -Payload $Payload -Name 'cwd'
        if (-not [string]::IsNullOrWhiteSpace($cwd)) {
            $leaf = Split-Path -Path $cwd -Leaf
            if (-not [string]::IsNullOrWhiteSpace($leaf)) {
                return $leaf
            }
        }
    }
    catch {}
    return 'Claude Code'
}

# The seam. A Claude Code payload goes in, a vendor-neutral AgentEvent comes
# out carrying only the fields the notifier actually renders. Anything else the
# payload happens to contain stops here.
function ConvertTo-AgentEvent {
    param(
        [object]$Payload,
        [string]$EventState,
        [string]$Locale,
        [bool]$IncludeProjectLabel
    )

    $projectLabel = 'Claude Code'
    if ($IncludeProjectLabel) {
        $projectLabel = Get-ClaudeProjectLabel -Payload $Payload
    }

    $errorType = Get-ClaudePayloadValue -Payload $Payload -Name 'error'
    if ([string]::IsNullOrWhiteSpace($errorType)) { $errorType = '' }

    return [pscustomobject]@{
        provider     = 'claude-code'
        state        = $EventState
        projectLabel = $projectLabel
        errorType    = $errorType
        locale       = $Locale
    }
}

# ---------------------------------------------------------------------------
# Rendering and delivery
#
# Provider-neutral from here down. These functions read the AgentEvent only.
# ---------------------------------------------------------------------------

function Get-AgentMessage([object]$AgentEvent) {
    $project = [string]$AgentEvent.projectLabel
    $errorType = [string]$AgentEvent.errorType
    $suffix = if ([string]::IsNullOrWhiteSpace($errorType)) { '' } else { " ($errorType)" }

    if ([string]$AgentEvent.locale -eq 'pt-BR') {
        switch ([string]$AgentEvent.state) {
            'finished' {
                return @{ Title = 'Claude Code - FINALIZADO'; Body = "$project - O Claude terminou o trabalho."; Priority = 'default'; Tags = 'white_check_mark,robot_face' }
            }
            'attention' {
                return @{ Title = 'Claude Code - ATENCAO'; Body = "$project - O Claude esta esperando sua intervencao."; Priority = 'high'; Tags = 'warning,robot_face' }
            }
            'error' {
                return @{ Title = 'Claude Code - ERRO'; Body = "$project - O Claude interrompeu o trabalho$suffix."; Priority = 'high'; Tags = 'x,robot_face' }
            }
        }
    }

    switch ([string]$AgentEvent.state) {
        'finished' {
            return @{ Title = 'Claude Code - FINISHED'; Body = "$project - Claude finished the task."; Priority = 'default'; Tags = 'white_check_mark,robot_face' }
        }
        'attention' {
            return @{ Title = 'Claude Code - ATTENTION'; Body = "$project - Claude is waiting for your input."; Priority = 'high'; Tags = 'warning,robot_face' }
        }
        'error' {
            return @{ Title = 'Claude Code - ERROR'; Body = "$project - Claude stopped because of an error$suffix."; Priority = 'high'; Tags = 'x,robot_face' }
        }
    }
}

# Sound and icon names rather than live .NET objects, so the mapping stays
# readable and can be verified without a desktop session.
function Get-DesktopStyle([object]$AgentEvent) {
    switch ([string]$AgentEvent.state) {
        'finished' {
            return @{ Sound = 'Asterisk'; BalloonIcon = 'Info'; SystemIcon = 'Information' }
        }
        'attention' {
            return @{ Sound = 'Exclamation'; BalloonIcon = 'Warning'; SystemIcon = 'Warning' }
        }
        'error' {
            return @{ Sound = 'Hand'; BalloonIcon = 'Error'; SystemIcon = 'Error' }
        }
    }
}

function Send-WindowsNotification([object]$AgentEvent, [hashtable]$Message) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $style = Get-DesktopStyle -AgentEvent $AgentEvent
    $soundName = [string]$style.Sound
    $systemIconName = [string]$style.SystemIcon

    $sound = [System.Media.SystemSounds]::$soundName
    $sound.Play()

    $notify = New-Object System.Windows.Forms.NotifyIcon
    try {
        $notify.Icon = [System.Drawing.SystemIcons]::$systemIconName
        $notify.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]([string]$style.BalloonIcon)
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

function Get-AgentChimeConfig {
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

    return $config
}

function Invoke-AgentChimeNotification {
    $payload = Read-ClaudeHookPayload
    $config = Get-AgentChimeConfig

    $locale = if ($config.PSObject.Properties['locale']) { [string]$config.locale } else { 'en' }

    $sendProjectName = $true
    try {
        if ($config.PSObject.Properties['privacy'] -and $config.privacy.PSObject.Properties['sendProjectName']) {
            $sendProjectName = [bool]$config.privacy.sendProjectName
        }
    }
    catch {}

    $agentEvent = ConvertTo-AgentEvent -Payload $payload -EventState $State -Locale $locale -IncludeProjectLabel $sendProjectName

    # The payload has been reduced to the normalized event; drop it so nothing
    # downstream can reach back into raw agent data.
    $payload = $null

    $message = Get-AgentMessage -AgentEvent $agentEvent

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
            Send-WindowsNotification -AgentEvent $agentEvent -Message $message
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
}

# Dot-sourcing loads the functions only, so the contract tests can drive the
# adapter and the renderer without sending a notification.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-AgentChimeNotification
}
