param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('turn-start', 'finished', 'attention', 'error')]
    [string]$State
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $HOME '.agentchime'
$ConfigPath = Join-Path $InstallDir 'config.json'
$TurnStateDir = Join-Path $InstallDir 'turns'

# The longest turn this notifier will believe. Anything above it is discarded
# rather than rendered. It is also the age at which orphan state is swept, so a
# record the sweeper would have deleted can never still be reported.
$script:TurnMaxDurationMs = 86400000

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

# Claude Code names a turn with two ids. session_id names the session and is
# present on every hook; prompt_id correlates one submitted prompt with every
# event until the next prompt, so a start and its own end carry the same value.
# Both are reduced to opaque keys here, which is why the turn store below never
# holds an identifier that could be read back.
function Get-ClaudeTurnIdentity([object]$Payload) {
    return [pscustomobject]@{
        SessionKey = Get-OpaqueKey (Get-ClaudePayloadValue -Payload $Payload -Name 'session_id')
        PromptKey  = Get-OpaqueKey (Get-ClaudePayloadValue -Payload $Payload -Name 'prompt_id')
    }
}

# The seam. A Claude Code payload goes in, a vendor-neutral AgentEvent comes
# out carrying only the fields the notifier actually renders. Anything else the
# payload happens to contain stops here.
function ConvertTo-AgentEvent {
    param(
        [object]$Payload,
        [string]$EventState,
        [string]$Locale,
        [bool]$IncludeProjectLabel,
        [object]$DurationMs = $null
    )

    $projectLabel = 'Claude Code'
    if ($IncludeProjectLabel) {
        $projectLabel = Get-ClaudeProjectLabel -Payload $Payload
    }

    $errorType = Get-ClaudePayloadValue -Payload $Payload -Name 'error'
    if ([string]::IsNullOrWhiteSpace($errorType)) { $errorType = '' }

    # durationMs stays null unless a measurement survived every plausibility
    # rule, so an absent value means "not measured" rather than "measured zero".
    $duration = $null
    try {
        if ($null -ne $DurationMs) {
            $value = [long]$DurationMs
            if ($value -ge 0 -and $value -le $script:TurnMaxDurationMs) { $duration = $value }
        }
    }
    catch {}

    return [pscustomobject]@{
        provider     = 'claude-code'
        state        = $EventState
        projectLabel = $projectLabel
        errorType    = $errorType
        locale       = $Locale
        durationMs   = $duration
    }
}

# ---------------------------------------------------------------------------
# Turn duration store
#
# Provider-neutral from here down. The store is handed opaque keys, never an
# agent identifier, and it keeps one small record per session under
# ~/.agentchime/turns. No prompt, output, transcript or absolute path is ever
# written to it.
# ---------------------------------------------------------------------------

# A one-way key. Two calls with the same input agree, which is all correlation
# needs, and nothing on disk can be turned back into the id it came from.
function Get-OpaqueKey([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value))
    }
    finally {
        $sha.Dispose()
    }

    return ((-join ($bytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 32))
}

# Elapsed time wants a clock nobody can move. QueryPerformanceCounter, which
# Stopwatch exposes, is monotonic but only comparable within one boot, so each
# sample also records the UTC instant at which that counter would have read
# zero. Two samples whose anchors agree were taken on the same boot, and only
# then is the monotonic difference meaningful.
function Get-TurnClockSample {
    $frequency = [System.Diagnostics.Stopwatch]::Frequency
    $monotonic = [System.Diagnostics.Stopwatch]::GetTimestamp()
    $utc = [datetime]::UtcNow
    $uptimeTicks = [long](($monotonic / $frequency) * [timespan]::TicksPerSecond)

    return [pscustomobject]@{
        schema      = 1
        utc         = $utc.ToString('o')
        monotonic   = [long]$monotonic
        frequency   = [long]$frequency
        clockAnchor = $utc.AddTicks(-$uptimeTicks).ToString('o')
    }
}

function ConvertFrom-TurnTimestamp([string]$Value) {
    return [datetime]::Parse(
        $Value,
        [cultureinfo]::InvariantCulture,
        [System.Globalization.DateTimeStyles]::RoundtripKind)
}

# Returns elapsed milliseconds, or $null when the two samples cannot be
# compared honestly. A malformed record, a backwards result and an implausibly
# long one are refusals rather than guesses.
function Measure-TurnDuration([object]$Start, [object]$End) {
    $elapsedMs = $null

    try {
        $startAnchor = ConvertFrom-TurnTimestamp ([string]$Start.clockAnchor)
        $endAnchor = ConvertFrom-TurnTimestamp ([string]$End.clockAnchor)
        $startFrequency = [long]$Start.frequency
        $endFrequency = [long]$End.frequency

        $sameClock = ($startFrequency -gt 0) -and
            ($startFrequency -eq $endFrequency) -and
            ([math]::Abs(($endAnchor - $startAnchor).TotalSeconds) -le 5)

        if ($sameClock) {
            $elapsedMs = (([long]$End.monotonic - [long]$Start.monotonic) / $endFrequency) * 1000.0
        }
        else {
            # A different boot, or a rebased performance counter. Wall time is
            # the only remaining basis, and it is checked below.
            $startUtc = ConvertFrom-TurnTimestamp ([string]$Start.utc)
            $endUtc = ConvertFrom-TurnTimestamp ([string]$End.utc)
            $elapsedMs = ($endUtc - $startUtc).TotalMilliseconds
        }
    }
    catch {
        return $null
    }

    if ($null -eq $elapsedMs) { return $null }
    if ([double]::IsNaN($elapsedMs) -or [double]::IsInfinity($elapsedMs)) { return $null }
    if ($elapsedMs -lt 0) { return $null }
    if ($elapsedMs -gt $script:TurnMaxDurationMs) { return $null }

    return [long][math]::Round($elapsedMs)
}

function Get-TurnStatePath([string]$StateDirectory, [string]$SessionKey) {
    if ([string]::IsNullOrWhiteSpace($StateDirectory)) { return '' }
    if ([string]::IsNullOrWhiteSpace($SessionKey)) { return '' }

    # The key is a fixed-length hex digest, so it can never spell a traversal
    # segment or a separator no matter what the agent sent.
    if ($SessionKey -notmatch '^[0-9a-f]{32}$') { return '' }

    return (Join-Path $StateDirectory ($SessionKey + '.json'))
}

# One file per session, so two sessions running at once never share a record.
# The record is written beside its target and moved into place, so a reader
# cannot observe a half-written start.
function Save-TurnStart {
    param(
        [string]$StateDirectory,
        [string]$SessionKey,
        [string]$PromptKey
    )

    $target = Get-TurnStatePath -StateDirectory $StateDirectory -SessionKey $SessionKey
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }

    try {
        New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null

        $sample = Get-TurnClockSample
        $record = [ordered]@{
            schema      = [int]$sample.schema
            promptKey   = [string]$PromptKey
            utc         = [string]$sample.utc
            monotonic   = [long]$sample.monotonic
            frequency   = [long]$sample.frequency
            clockAnchor = [string]$sample.clockAnchor
        }

        $temp = "$target.$PID.tmp"
        ($record | ConvertTo-Json -Depth 5 -Compress) | Set-Content -Path $temp -Encoding UTF8
        Move-Item -Path $temp -Destination $target -Force
        return $true
    }
    catch {
        return $false
    }
}

function Remove-TurnState {
    param(
        [string]$StateDirectory,
        [string]$SessionKey
    )

    $target = Get-TurnStatePath -StateDirectory $StateDirectory -SessionKey $SessionKey
    if ([string]::IsNullOrWhiteSpace($target)) { return $false }
    if (-not (Test-Path $target)) { return $false }

    try {
        Remove-Item -Path $target -Force
        return $true
    }
    catch {
        return $false
    }
}

# Reads this session's start, consumes it, and reports the elapsed time only
# when the record provably belongs to the turn that is ending.
function Resolve-TurnDuration {
    param(
        [string]$StateDirectory,
        [string]$SessionKey,
        [string]$PromptKey
    )

    $target = Get-TurnStatePath -StateDirectory $StateDirectory -SessionKey $SessionKey
    if ([string]::IsNullOrWhiteSpace($target)) { return $null }
    if (-not (Test-Path $target)) { return $null }

    $start = $null
    try {
        $start = Get-Content -Path $target -Raw | ConvertFrom-Json
    }
    catch {
        $start = $null
    }

    # Consume the record whatever it turned out to be. A start this turn could
    # not claim must not survive to attach itself to a later one.
    try { Remove-Item -Path $target -Force } catch {}

    if ($null -eq $start) { return $null }

    # When both ends carry a prompt key they must agree. A disagreement means
    # the stored start belongs to an earlier prompt, and measuring across it
    # would invent a duration rather than report one. When either side has no
    # prompt key the session key is the only correlation available, so the pair
    # is accepted and the plausibility rules carry the weight instead.
    $recordedPromptKey = ''
    try { $recordedPromptKey = [string]$start.promptKey } catch { return $null }

    if (-not [string]::IsNullOrWhiteSpace($recordedPromptKey) -and
        -not [string]::IsNullOrWhiteSpace($PromptKey) -and
        $recordedPromptKey -cne $PromptKey) {
        return $null
    }

    return (Measure-TurnDuration -Start $start -End (Get-TurnClockSample))
}

# A session that crashes, or one whose end hook never ran, leaves a start
# behind. Nothing older than the longest turn we would report can still be
# useful, so age it out on the one event that fires exactly once per turn.
function Remove-StaleTurnState {
    param([string]$StateDirectory)

    if ([string]::IsNullOrWhiteSpace($StateDirectory)) { return 0 }
    if (-not (Test-Path $StateDirectory)) { return 0 }

    $cutoff = [datetime]::UtcNow.AddMilliseconds(-$script:TurnMaxDurationMs)
    $removed = 0

    try {
        # A .tmp file is an interrupted write. It is never read, so it ages out
        # on the same rule rather than accumulating.
        foreach ($file in @(Get-ChildItem -Path $StateDirectory -File -Force -ErrorAction SilentlyContinue)) {
            if ($file.Extension -ne '.json' -and $file.Extension -ne '.tmp') { continue }
            if ($file.LastWriteTimeUtc -lt $cutoff) {
                Remove-Item -Path $file.FullName -Force -ErrorAction SilentlyContinue
                $removed++
            }
        }
    }
    catch {}

    return $removed
}

# ---------------------------------------------------------------------------
# Rendering and delivery
#
# Provider-neutral. These functions read the AgentEvent only.
# ---------------------------------------------------------------------------

# Truncates rather than rounds, so a rendered figure is never longer than the
# time that actually elapsed. Hours drop the seconds, which are noise at that
# scale.
function Format-TurnDuration([object]$DurationMs, [string]$Locale) {
    if ($null -eq $DurationMs) { return '' }

    $total = 0
    try { $total = [long]$DurationMs } catch { return '' }
    if ($total -lt 0) { return '' }

    $seconds = [long][math]::Floor($total / 1000.0)
    $hours = [long][math]::Floor($seconds / 3600)
    $minutes = [long][math]::Floor(($seconds % 3600) / 60)
    $rest = [long]($seconds % 60)

    $minuteUnit = if ($Locale -eq 'pt-BR') { 'min' } else { 'm' }

    if ($hours -gt 0) { return ('{0}h {1}{2}' -f $hours, $minutes, $minuteUnit) }
    if ($minutes -gt 0) { return ('{0}{1} {2}s' -f $minutes, $minuteUnit, $rest) }
    return ('{0}s' -f $rest)
}

function Get-AgentMessage([object]$AgentEvent) {
    $project = [string]$AgentEvent.projectLabel
    $errorType = [string]$AgentEvent.errorType
    $suffix = if ([string]::IsNullOrWhiteSpace($errorType)) { '' } else { " ($errorType)" }

    # Elapsed time is appended to the body only. Titles, priority and tags are
    # the v0.1 contract and stay exactly as they were.
    $elapsed = Format-TurnDuration -DurationMs $AgentEvent.durationMs -Locale ([string]$AgentEvent.locale)
    $tail = if ([string]::IsNullOrWhiteSpace($elapsed)) { '' } else { " ($elapsed)" }

    if ([string]$AgentEvent.locale -eq 'pt-BR') {
        switch ([string]$AgentEvent.state) {
            'finished' {
                return @{ Title = 'Claude Code - FINALIZADO'; Body = "$project - O Claude terminou o trabalho.$tail"; Priority = 'default'; Tags = 'white_check_mark,robot_face' }
            }
            'attention' {
                return @{ Title = 'Claude Code - ATENCAO'; Body = "$project - O Claude esta esperando sua intervencao.$tail"; Priority = 'high'; Tags = 'warning,robot_face' }
            }
            'error' {
                return @{ Title = 'Claude Code - ERRO'; Body = "$project - O Claude interrompeu o trabalho$suffix.$tail"; Priority = 'high'; Tags = 'x,robot_face' }
            }
        }
    }

    switch ([string]$AgentEvent.state) {
        'finished' {
            return @{ Title = 'Claude Code - FINISHED'; Body = "$project - Claude finished the task.$tail"; Priority = 'default'; Tags = 'white_check_mark,robot_face' }
        }
        'attention' {
            return @{ Title = 'Claude Code - ATTENTION'; Body = "$project - Claude is waiting for your input.$tail"; Priority = 'high'; Tags = 'warning,robot_face' }
        }
        'error' {
            return @{ Title = 'Claude Code - ERROR'; Body = "$project - Claude stopped because of an error$suffix.$tail"; Priority = 'high'; Tags = 'x,robot_face' }
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

# A config written before this feature existed has no sendDuration key. Elapsed
# time is on by default, so an upgraded install reports it without a reinstall,
# and an explicit false is always honoured.
function Get-DurationPreference([object]$Config) {
    try {
        if ($Config.PSObject.Properties['privacy'] -and $Config.privacy.PSObject.Properties['sendDuration']) {
            return [bool]$Config.privacy.sendDuration
        }
    }
    catch {}
    return $true
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

    $sendDuration = Get-DurationPreference -Config $config
    $identity = Get-ClaudeTurnIdentity -Payload $payload

    # The start marker records local state and notifies nobody. It is also the
    # one event that fires exactly once per turn, which makes it the right place
    # to sweep state left behind by sessions that never ended.
    if ($State -eq 'turn-start') {
        Remove-StaleTurnState -StateDirectory $TurnStateDir | Out-Null
        if ($sendDuration) {
            Save-TurnStart -StateDirectory $TurnStateDir -SessionKey $identity.SessionKey -PromptKey $identity.PromptKey | Out-Null
        }
        else {
            # Turning the feature off leaves nothing behind to be reported later.
            Remove-TurnState -StateDirectory $TurnStateDir -SessionKey $identity.SessionKey | Out-Null
        }
        exit 0
    }

    # Only a terminal state ends a turn. 'attention' fires while the same turn is
    # still running, so it must neither report a duration nor consume the start.
    $durationMs = $null
    if ($sendDuration -and ($State -eq 'finished' -or $State -eq 'error')) {
        $durationMs = Resolve-TurnDuration -StateDirectory $TurnStateDir -SessionKey $identity.SessionKey -PromptKey $identity.PromptKey
    }

    $agentEvent = ConvertTo-AgentEvent -Payload $payload -EventState $State -Locale $locale -IncludeProjectLabel $sendProjectName -DurationMs $durationMs

    # The payload has been reduced to the normalized event; drop it, and the
    # turn keys with it, so nothing downstream can reach back into agent data.
    $payload = $null
    $identity = $null

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
