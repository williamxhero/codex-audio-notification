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

# Preserve the completion notification that Codex Desktop configured previously.
# Codex supplies a JSON payload; a person running this script directly does not.
if ($null -ne $NotificationArguments -and $NotificationArguments.Count -gt 0) {
    try {
        Invoke-CodexTurnEndedNotifier -Arguments $NotificationArguments
    }
    catch {
        # A desktop notification failure must not prevent the voice decision.
    }
}

try {
    $notificationPayload = $null
    foreach ($argument in $NotificationArguments) {
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

    $threadId = $null
    if ($null -ne $notificationPayload) {
        $threadId = $notificationPayload.'thread-id'
        if ([string]::IsNullOrWhiteSpace($threadId)) {
            $threadId = $notificationPayload.thread_id
        }
        if ([string]::IsNullOrWhiteSpace($threadId)) {
            $threadId = $notificationPayload.threadId
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
                $configuredAudioFile = [string] $profileProperty.Value.prefixAudio
                if (-not [string]::IsNullOrWhiteSpace($configuredAudioFile)) {
                    $audioFile = [System.IO.Path]::GetFileName($configuredAudioFile)
                }
            }
        }
        catch {
            # Invalid configuration falls back to the Codex completion defaults.
        }
    }

    $python = Resolve-PythonRuntime
    if (-not [string]::IsNullOrWhiteSpace($threadId)) {
        # Fail closed when a thread cannot be classified. This avoids announcing
        # subagents if Python or the Codex thread database becomes unavailable.
        if ($null -eq $python -or
            -not (Test-Path -LiteralPath $generatorPath) -or
            -not (Test-Path -LiteralPath $databasePath)) {
            exit 0
        }

        $pythonPrefix = @($python.PrefixArguments)
        $settleSecondsText = $settleSeconds.ToString([System.Globalization.CultureInfo]::InvariantCulture)
        $notificationDecision = & $python.Executable @pythonPrefix $generatorPath `
            --thread-id $threadId `
            --database $databasePath `
            --decision-only `
            --pending-dir $pendingPath `
            --settle-seconds $settleSecondsText 2>$null

        $notificationDecision = [string] $notificationDecision
        if ([string]::IsNullOrWhiteSpace($notificationDecision) -or
            $notificationDecision -in @('silence-spawned', 'silence-followup', 'silence-superseded')) {
            exit 0
        }
    }

    # Re-check quiet hours after the settling delay.
    if (Test-QuietHour -Hour (Get-Date).Hour -Start $quietStart -End $quietEnd) {
        exit 0
    }

    $ffplayPath = Resolve-MediaTool -Name 'ffplay'
    $ffmpegPath = Resolve-MediaTool -Name 'ffmpeg'
    if (-not [string]::IsNullOrWhiteSpace($ffmpegPath)) {
        $ffmpegDirectory = Split-Path -Parent $ffmpegPath
        if (($env:PATH -split ';') -notcontains $ffmpegDirectory) {
            $env:PATH = "$ffmpegDirectory;$env:PATH"
        }
    }

    $audioPath = Join-Path $PSScriptRoot $audioFile
    if ((Test-Path -LiteralPath $audioPath) -and -not [string]::IsNullOrWhiteSpace($ffplayPath)) {
        & $ffplayPath -nodisp -autoexit -loglevel quiet -volume 100 $audioPath 2>$null | Out-Null
    }

    if (-not [string]::IsNullOrWhiteSpace($threadId) -and $null -ne $python) {
        $pythonPrefix = @($python.PrefixArguments)
        $titleAudioPath = & $python.Executable @pythonPrefix $generatorPath `
            --thread-id $threadId `
            --database $databasePath `
            --cache-dir $cachePath 2>$null

        $titleAudioPath = [string] $titleAudioPath
        if (-not [string]::IsNullOrWhiteSpace($titleAudioPath) -and
            (Test-Path -LiteralPath $titleAudioPath) -and
            -not [string]::IsNullOrWhiteSpace($ffplayPath)) {
            & $ffplayPath -nodisp -autoexit -loglevel quiet -volume 100 $titleAudioPath 2>$null | Out-Null
        }
    }
}
catch {
    # Notifications must never interrupt or fail a completed Codex turn.
}

exit 0
