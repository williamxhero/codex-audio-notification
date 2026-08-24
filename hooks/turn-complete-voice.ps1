[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $NotificationArguments
)

$ErrorActionPreference = 'SilentlyContinue'

function Invoke-CodexTurnEndedNotifier {
    param([string[]] $Arguments)

    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        return
    }

    $notifierPattern = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\runtimes\cua_node\*\bin\node_modules\@oai\sky\bin\windows\codex-computer-use.exe'
    $notifier = Get-Item -Path $notifierPattern -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if ($null -ne $notifier) {
        & $notifier.FullName 'turn-ended' @Arguments | Out-Null
    }
}

function Resolve-PythonRuntime {
    $candidates = @()
    $pythonCommand = Get-Command 'python.exe' -ErrorAction SilentlyContinue
    if ($null -ne $pythonCommand) {
        $candidates += [pscustomobject] @{ Executable = $pythonCommand.Source; PrefixArguments = @() }
    }

    $launcherCommand = Get-Command 'py.exe' -ErrorAction SilentlyContinue
    if ($null -ne $launcherCommand) {
        $candidates += [pscustomobject] @{ Executable = $launcherCommand.Source; PrefixArguments = @('-3') }
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        Get-Item -Path (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python*\python.exe') -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                $candidates += [pscustomobject] @{ Executable = $_.FullName; PrefixArguments = @() }
            }
    }

    foreach ($candidate in $candidates) {
        $prefixArguments = @($candidate.PrefixArguments)
        & $candidate.Executable @prefixArguments -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    return $null
}

function Resolve-MediaTool {
    param([Parameter(Mandatory = $true)][string] $Name)

    $command = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
    if ($null -ne $command) {
        return $command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $wingetLink = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$Name.exe"
        if (Test-Path -LiteralPath $wingetLink) {
            return $wingetLink
        }

        $packageRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'
        $packageTool = Get-ChildItem -LiteralPath $packageRoot -Filter "$Name.exe" -File -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -ne $packageTool) {
            return $packageTool.FullName
        }
    }

    return $null
}

function Test-QuietHour {
    param(
        [int] $Hour,
        [int] $Start,
        [int] $End
    )

    if ($Start -eq $End) {
        return $false
    }
    if ($Start -lt $End) {
        return ($Hour -ge $Start -and $Hour -lt $End)
    }
    return ($Hour -ge $Start -or $Hour -lt $End)
}

function Get-NotificationProperty {
    param(
        $Payload,
        [string[]] $Names
    )

    if ($null -eq $Payload) {
        return $null
    }
    foreach ($name in $Names) {
        $property = $Payload.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [string] $property.Value
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }
    return $null
}

function Write-NotificationAudit {
    param(
        $Python,
        [string] $AuditHelperPath,
        [string] $LogDirectory,
        [string] $EventType,
        [string] $ThreadId,
        [string] $TurnId,
        [string] $WorkingDirectory,
        [string] $Source,
        [string] $Profile,
        [string] $Decision,
        [string] $Reason,
        [bool] $PrefixPlayed,
        [bool] $TitlePlayed,
        [string] $ErrorStage,
        [string] $ErrorType
    )

    try {
        if ($null -eq $Python -or -not (Test-Path -LiteralPath $AuditHelperPath)) {
            return
        }

        $auditArguments = @(
            $AuditHelperPath,
            '--log-directory', $LogDirectory,
            '--source', $Source,
            '--profile', $Profile,
            '--decision', $Decision,
            '--reason', $Reason
        )
        foreach ($pair in @(
            @('--event-type', $EventType),
            @('--thread-id', $ThreadId),
            @('--turn-id', $TurnId),
            @('--cwd', $WorkingDirectory),
            @('--error-stage', $ErrorStage),
            @('--error-type', $ErrorType)
        )) {
            if (-not [string]::IsNullOrWhiteSpace([string] $pair[1])) {
                $auditArguments += @([string] $pair[0], [string] $pair[1])
            }
        }
        if ($PrefixPlayed) {
            $auditArguments += '--prefix-played'
        }
        if ($TitlePlayed) {
            $auditArguments += '--title-played'
        }

        $invokeArguments = @($Python.PrefixArguments) + $auditArguments
        & $Python.Executable @invokeArguments 2>$null | Out-Null
    }
    catch {
        # Audit failures must not affect Codex or notification decisions.
    }
}

function Complete-NotificationAudit {
    param(
        [Parameter(Mandatory = $true)][string] $Decision,
        [Parameter(Mandatory = $true)][string] $Reason
    )

    Write-NotificationAudit `
        -Python $script:auditPython `
        -AuditHelperPath $script:auditHelperPath `
        -LogDirectory $script:auditLogDirectory `
        -EventType $script:auditEventType `
        -ThreadId $script:auditThreadId `
        -TurnId $script:auditTurnId `
        -WorkingDirectory $script:auditCwd `
        -Source $script:auditSource `
        -Profile $script:auditProfile `
        -Decision $Decision `
        -Reason $Reason `
        -PrefixPlayed $script:auditPrefixPlayed `
        -TitlePlayed $script:auditTitlePlayed `
        -ErrorStage $script:auditErrorStage `
        -ErrorType $script:auditErrorType
}

$script:auditPython = $null
$script:auditHelperPath = Join-Path $PSScriptRoot 'notification_audit.py'
$script:auditLogDirectory = Join-Path $PSScriptRoot 'logs'
$script:auditEventType = $null
$script:auditThreadId = $null
$script:auditTurnId = $null
$script:auditCwd = $null
$script:auditSource = if ($null -ne $NotificationArguments -and $NotificationArguments.Count -gt 0) { 'payload' } else { 'manual' }
$script:auditProfile = 'codex'
$script:auditPrefixPlayed = $false
$script:auditTitlePlayed = $false
$script:auditErrorStage = $null
$script:auditErrorType = $null
$currentStage = 'payload-parse'

try {
    $notificationPayload = $null
    foreach ($argument in @($NotificationArguments)) {
        try {
            $candidatePayload = $argument | ConvertFrom-Json
            if ($null -ne $candidatePayload) {
                $notificationPayload = $candidatePayload
                break
            }
        }
        catch {
            continue
        }
    }

    $script:auditEventType = Get-NotificationProperty -Payload $notificationPayload -Names @('type', 'event-type', 'event_type')
    $script:auditThreadId = Get-NotificationProperty -Payload $notificationPayload -Names @('thread-id', 'thread_id', 'threadId')
    $script:auditTurnId = Get-NotificationProperty -Payload $notificationPayload -Names @('turn-id', 'turn_id', 'turnId')
    $script:auditCwd = Get-NotificationProperty -Payload $notificationPayload -Names @('cwd')

    $currentStage = 'desktop-notifier'
    if ($script:auditSource -eq 'payload' -and $env:CODEX_AUDIO_SKIP_DESKTOP_NOTIFIER -ne '1') {
        try {
            Invoke-CodexTurnEndedNotifier -Arguments $NotificationArguments
        }
        catch {
            $script:auditErrorStage = $currentStage
            $script:auditErrorType = $_.Exception.GetType().Name
        }
    }

    $codexHome = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $generatorPath = Join-Path $PSScriptRoot 'generate-thread-title-audio.py'
    $databasePath = Join-Path $codexHome 'state_5.sqlite'
    $cachePath = Join-Path $PSScriptRoot 'voice-cache'
    $pendingPath = Join-Path $PSScriptRoot 'pending-notifications'
    $audioFile = 'codex-task-complete-hsiaoyu.mp3'
    $settleSeconds = 15.0
    $quietStart = 23
    $quietEnd = 8
    $voiceConfigPath = Join-Path $PSScriptRoot 'task-completion-voice.json'

    $currentStage = 'config-load'
    if (Test-Path -LiteralPath $voiceConfigPath) {
        try {
            $voiceConfig = Get-Content -Raw -LiteralPath $voiceConfigPath | ConvertFrom-Json
            if ($null -ne $voiceConfig.settleSeconds) {
                $settleSeconds = [Math]::Max(0.0, [Math]::Min(300.0, [double] $voiceConfig.settleSeconds))
            }
            if ($null -ne $voiceConfig.quietHours) {
                $quietStart = [Math]::Max(0, [Math]::Min(23, [int] $voiceConfig.quietHours.start))
                $quietEnd = [Math]::Max(0, [Math]::Min(23, [int] $voiceConfig.quietHours.end))
            }

            $activeProfile = [string] $voiceConfig.activeProfile
            $profileProperty = $voiceConfig.profiles.PSObject.Properties[$activeProfile]
            if ($null -ne $profileProperty) {
                $script:auditProfile = $activeProfile
                $configuredAudioFile = [string] $profileProperty.Value.prefixAudio
                if (-not [string]::IsNullOrWhiteSpace($configuredAudioFile)) {
                    $audioFile = [System.IO.Path]::GetFileName($configuredAudioFile)
                }
            }
        }
        catch {
            $script:auditErrorStage = $currentStage
            $script:auditErrorType = $_.Exception.GetType().Name
        }
    }

    $currentStage = 'python-resolve'
    $script:auditPython = Resolve-PythonRuntime

    if ($script:auditSource -eq 'payload' -and [string]::IsNullOrWhiteSpace($script:auditThreadId)) {
        Complete-NotificationAudit -Decision 'silence-unknown' -Reason 'payload-missing-thread-id'
        exit 0
    }

    if (-not [string]::IsNullOrWhiteSpace($script:auditThreadId)) {
        $currentStage = 'thread-classification'
        if ($null -eq $script:auditPython -or
            -not (Test-Path -LiteralPath $generatorPath) -or
            -not (Test-Path -LiteralPath $databasePath)) {
            $script:auditErrorStage = $currentStage
            $script:auditErrorType = 'ClassifierUnavailable'
            Complete-NotificationAudit -Decision 'silence-error' -Reason 'classifier-unavailable'
            exit 0
        }

        $pythonPrefix = @($script:auditPython.PrefixArguments)
        $settleSecondsText = $settleSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $notificationDecision = & $script:auditPython.Executable @pythonPrefix $generatorPath `
            --thread-id $script:auditThreadId `
            --database $databasePath `
            --decision-only `
            --pending-dir $pendingPath `
            --settle-seconds $settleSecondsText 2>$null

        $notificationDecision = [string] $notificationDecision
        switch ($notificationDecision) {
            'silence-muted' {
                Complete-NotificationAudit -Decision $notificationDecision -Reason 'title-muted'
                exit 0
            }
            'silence-unknown' {
                Complete-NotificationAudit -Decision $notificationDecision -Reason 'thread-not-registered'
                exit 0
            }
            'silence-spawned' {
                Complete-NotificationAudit -Decision $notificationDecision -Reason 'spawned-thread'
                exit 0
            }
            'silence-followup' {
                Complete-NotificationAudit -Decision $notificationDecision -Reason 'followup-active'
                exit 0
            }
            'silence-superseded' {
                Complete-NotificationAudit -Decision $notificationDecision -Reason 'newer-turn'
                exit 0
            }
            'play' {
                break
            }
            default {
                $script:auditErrorStage = $currentStage
                $script:auditErrorType = 'UnexpectedClassifierResult'
                Complete-NotificationAudit -Decision 'silence-error' -Reason 'classifier-failed'
                exit 0
            }
        }
    }

    $currentStage = 'quiet-hours'
    if (Test-QuietHour -Hour (Get-Date).Hour -Start $quietStart -End $quietEnd) {
        Complete-NotificationAudit -Decision 'silence-quiet-hours' -Reason 'quiet-hours'
        exit 0
    }

    $currentStage = 'media-resolve'
    $ffplayPath = Resolve-MediaTool -Name 'ffplay'
    $ffmpegPath = Resolve-MediaTool -Name 'ffmpeg'
    if (-not [string]::IsNullOrWhiteSpace($ffmpegPath)) {
        $ffmpegDirectory = Split-Path -Parent $ffmpegPath
        if (($env:PATH -split ';') -notcontains $ffmpegDirectory) {
            $env:PATH = "$ffmpegDirectory;$env:PATH"
        }
    }

    $currentStage = 'prefix-playback'
    $audioPath = Join-Path $PSScriptRoot $audioFile
    if ((Test-Path -LiteralPath $audioPath) -and -not [string]::IsNullOrWhiteSpace($ffplayPath)) {
        & $ffplayPath -nodisp -autoexit -loglevel quiet -volume 100 $audioPath 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $script:auditPrefixPlayed = $true
        }
        else {
            $script:auditErrorStage = $currentStage
            $script:auditErrorType = "NativeExitCode$LASTEXITCODE"
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($script:auditThreadId) -and $null -ne $script:auditPython) {
        $currentStage = 'title-generation'
        $pythonPrefix = @($script:auditPython.PrefixArguments)
        $titleAudioPath = & $script:auditPython.Executable @pythonPrefix $generatorPath `
            --thread-id $script:auditThreadId `
            --database $databasePath `
            --cache-dir $cachePath 2>$null

        $titleAudioPath = [string] $titleAudioPath
        if (-not [string]::IsNullOrWhiteSpace($titleAudioPath) -and
            (Test-Path -LiteralPath $titleAudioPath) -and
            -not [string]::IsNullOrWhiteSpace($ffplayPath)) {
            $currentStage = 'title-playback'
            & $ffplayPath -nodisp -autoexit -loglevel quiet -volume 100 $titleAudioPath 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $script:auditTitlePlayed = $true
            }
            else {
                $script:auditErrorStage = $currentStage
                $script:auditErrorType = "NativeExitCode$LASTEXITCODE"
            }
        }
    }

    if ($script:auditPrefixPlayed -or $script:auditTitlePlayed) {
        $playReason = if ($script:auditSource -eq 'manual') { 'manual-preview' } else { 'completed-thread' }
        Complete-NotificationAudit -Decision 'play' -Reason $playReason
    }
    else {
        if ([string]::IsNullOrWhiteSpace($script:auditErrorStage)) {
            $script:auditErrorStage = 'playback'
            $script:auditErrorType = 'AudioUnavailable'
        }
        Complete-NotificationAudit -Decision 'silence-error' -Reason 'playback-unavailable'
    }
}
catch {
    $script:auditErrorStage = $currentStage
    $script:auditErrorType = $_.Exception.GetType().Name
    if ($script:auditPrefixPlayed -or $script:auditTitlePlayed) {
        Complete-NotificationAudit -Decision 'play' -Reason 'error-after-playback'
    }
    else {
        Complete-NotificationAudit -Decision 'silence-error' -Reason 'caught-exception'
    }
}

exit 0
