[CmdletBinding()]
param(
    [string] $CodexHome,
    [switch] $SkipDependencies
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
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
        & $candidate.Executable @prefixArguments -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>$null | Out-Null
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

function Install-WingetPackage {
    param([Parameter(Mandatory = $true)][string] $PackageId)

    $winget = Get-Command 'winget.exe' -ErrorAction SilentlyContinue
    if ($null -eq $winget) {
        throw "A dependency is missing and winget is unavailable. Install Microsoft App Installer, then retry. Missing package: $PackageId"
    }

    Write-Host "Installing $PackageId with winget ..."
    & $winget.Source install --id $PackageId -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $PackageId (exit code $LASTEXITCODE)."
    }
}

function Test-PythonModule {
    param(
        [Parameter(Mandatory = $true)] $Python,
        [Parameter(Mandatory = $true)][string] $Module
    )

    $prefixArguments = @($Python.PrefixArguments)
    & $Python.Executable @prefixArguments -c "import $Module" 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-RootNotifyBlock {
    param([string[]] $Lines)

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        $line = $Lines[$index]
        if ($line -match '^\s*\[.+\]\s*(?:#.*)?$') {
            break
        }
        if ($line -notmatch '^\s*notify\s*=') {
            continue
        }

        $balance = 0
        $opened = $false
        for ($end = $index; $end -lt $Lines.Count; $end++) {
            foreach ($character in $Lines[$end].ToCharArray()) {
                if ($character -eq '[') {
                    $balance++
                    $opened = $true
                }
                elseif ($character -eq ']') {
                    $balance--
                }
            }
            if ($opened -and $balance -le 0) {
                return [pscustomobject] @{
                    Start = $index
                    End = $end
                    Lines = @($Lines[$index..$end])
                }
            }
        }

        throw 'The notify array in config.toml is not closed. The config was not changed.'
    }

    return $null
}

function ConvertTo-TomlBasicString {
    param([Parameter(Mandatory = $true)][string] $Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Set-RootNotify {
    param(
        [string[]] $Lines,
        [Parameter(Mandatory = $true)][string] $NotifyLine
    )

    $existing = Get-RootNotifyBlock -Lines $Lines
    $result = New-Object 'System.Collections.Generic.List[string]'

    if ($null -ne $existing) {
        for ($index = 0; $index -lt $Lines.Count; $index++) {
            if ($index -eq $existing.Start) {
                $result.Add($NotifyLine)
            }
            if ($index -lt $existing.Start -or $index -gt $existing.End) {
                $result.Add($Lines[$index])
            }
        }
        return [pscustomobject] @{ Lines = @($result); Previous = @($existing.Lines) }
    }

    $insertAt = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[.+\]\s*(?:#.*)?$') {
            $insertAt = $index
            break
        }
    }

    for ($index = 0; $index -le $Lines.Count; $index++) {
        if ($index -eq $insertAt) {
            $result.Add($NotifyLine)
            $result.Add('')
        }
        if ($index -lt $Lines.Count) {
            $result.Add($Lines[$index])
        }
    }
    return [pscustomobject] @{ Lines = @($result); Previous = @() }
}

if ([string]::IsNullOrWhiteSpace($CodexHome)) {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        $CodexHome = $env:CODEX_HOME
    }
    else {
        $CodexHome = Join-Path $HOME '.codex'
    }
}

$CodexHome = [System.IO.Path]::GetFullPath($CodexHome)
$sourceHooks = Join-Path $PSScriptRoot 'hooks'
$requirementsPath = Join-Path $PSScriptRoot 'requirements.txt'
$runtimeDirectory = Join-Path $CodexHome 'hooks\codex-audio-notification'
$configPath = Join-Path $CodexHome 'config.toml'
$runtimeScript = Join-Path $runtimeDirectory 'turn-complete-voice.ps1'
$requiredFiles = @(
    'turn-complete-voice.ps1',
    'generate-thread-title-audio.py',
    'task-completion-voice.json',
    'codex-task-complete-hsiaoyu.mp3',
    'claude-task-complete-hsiaoyu.mp3'
)

foreach ($file in $requiredFiles) {
    $sourceFile = Join-Path $sourceHooks $file
    if (-not (Test-Path -LiteralPath $sourceFile)) {
        throw "The installation package is incomplete. Missing: $sourceFile"
    }
}

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $sourceHooks 'turn-complete-voice.ps1'),
    [ref] $null,
    [ref] $parseErrors
) | Out-Null
if ($parseErrors.Count -gt 0) {
    throw "The notification script failed syntax validation: $($parseErrors[0].Message)"
}
Get-Content -Raw -LiteralPath (Join-Path $sourceHooks 'task-completion-voice.json') | ConvertFrom-Json | Out-Null

$python = Resolve-PythonRuntime
if ($null -eq $python) {
    if ($SkipDependencies) {
        throw 'Python 3.10+ was not found. -SkipDependencies does not install missing dependencies.'
    }
    Install-WingetPackage -PackageId 'Python.Python.3.13'
    $python = Resolve-PythonRuntime
}
if ($null -eq $python) {
    throw 'Python was installed but is not visible in this session. Open a new PowerShell window and retry.'
}

if (-not (Test-PythonModule -Python $python -Module 'edge_tts')) {
    if ($SkipDependencies) {
        throw 'edge-tts is missing. -SkipDependencies does not install missing dependencies.'
    }
    Write-Host 'Installing the edge-tts Python dependency ...'
    $pythonPrefix = @($python.PrefixArguments)
    & $python.Executable @pythonPrefix -m pip install --disable-pip-version-check --user -r $requirementsPath
    if ($LASTEXITCODE -ne 0) {
        # --user is intentionally preferred for system Python, but virtual
        # environments reject it. Retry in the active environment in that case.
        & $python.Executable @pythonPrefix -m pip install --disable-pip-version-check -r $requirementsPath
    }
    if ($LASTEXITCODE -ne 0 -or -not (Test-PythonModule -Python $python -Module 'edge_tts')) {
        throw 'edge-tts installation failed.'
    }
}

$ffmpegPath = Resolve-MediaTool -Name 'ffmpeg'
$ffplayPath = Resolve-MediaTool -Name 'ffplay'
if ([string]::IsNullOrWhiteSpace($ffmpegPath) -or [string]::IsNullOrWhiteSpace($ffplayPath)) {
    if ($SkipDependencies) {
        throw 'ffmpeg/ffplay were not found. -SkipDependencies does not install missing dependencies.'
    }
    Install-WingetPackage -PackageId 'Gyan.FFmpeg'
    $ffmpegPath = Resolve-MediaTool -Name 'ffmpeg'
    $ffplayPath = Resolve-MediaTool -Name 'ffplay'
}
if ([string]::IsNullOrWhiteSpace($ffmpegPath) -or [string]::IsNullOrWhiteSpace($ffplayPath)) {
    throw 'FFmpeg was installed but ffmpeg.exe or ffplay.exe is still unavailable. Open a new PowerShell window and retry.'
}

$pythonPrefix = @($python.PrefixArguments)
& $python.Executable @pythonPrefix (Join-Path $sourceHooks 'generate-thread-title-audio.py') --help 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'The Python helper source failed its self-check. The Codex config has not been changed.'
}

New-Item -ItemType Directory -Force -Path $CodexHome | Out-Null
New-Item -ItemType Directory -Force -Path $runtimeDirectory | Out-Null
foreach ($file in $requiredFiles) {
    Copy-Item -LiteralPath (Join-Path $sourceHooks $file) -Destination (Join-Path $runtimeDirectory $file) -Force
}

$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellPath)) {
    throw "Windows PowerShell was not found: $powershellPath"
}
$notifyArguments = @(
    $powershellPath,
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $runtimeScript
)
$notifyLine = 'notify = [ ' + (($notifyArguments | ForEach-Object { ConvertTo-TomlBasicString $_ }) -join ', ') + ' ]'

$configLines = @()
if (Test-Path -LiteralPath $configPath) {
    $configLines = @([System.IO.File]::ReadAllLines($configPath))
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupPath = "$configPath.codex-audio-notification.$timestamp.bak"
    Copy-Item -LiteralPath $configPath -Destination $backupPath
    Write-Host "Backed up the Codex config: $backupPath"
}

$updatedConfig = Set-RootNotify -Lines $configLines -NotifyLine $notifyLine
$previousNotifyLines = @($updatedConfig.Previous)
$existingStatePath = Join-Path $runtimeDirectory '.install-state.json'
if (Test-Path -LiteralPath $existingStatePath) {
    try {
        $existingState = Get-Content -Raw -LiteralPath $existingStatePath | ConvertFrom-Json
        $replacedNotifyText = $previousNotifyLines -join [Environment]::NewLine
        if ($replacedNotifyText -eq [string] $existingState.installedNotifyLine) {
            # Reinstall/upgrade: keep the notify that existed before the first install,
            # rather than treating this tool's own notify as the restore target.
            $previousNotifyLines = @($existingState.previousNotifyLines)
        }
    }
    catch {
        throw 'The existing install state is invalid. Installation stopped to avoid overwriting the original notify value.'
    }
}
$state = [ordered] @{
    installedNotifyLine = $notifyLine
    previousNotifyLines = $previousNotifyLines
}
Write-Utf8NoBom -Path (Join-Path $runtimeDirectory '.install-state.json') -Content ($state | ConvertTo-Json -Depth 4)

$configContent = (@($updatedConfig.Lines) -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
$temporaryConfig = "$configPath.codex-audio-notification.tmp"
Write-Utf8NoBom -Path $temporaryConfig -Content $configContent
Move-Item -LiteralPath $temporaryConfig -Destination $configPath -Force

# Minimal post-install self-check. It intentionally does not play audio.
$installedParseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $runtimeScript,
    [ref] $null,
    [ref] $installedParseErrors
) | Out-Null
if ($installedParseErrors.Count -gt 0) {
    throw "The installed PowerShell script failed validation: $($installedParseErrors[0].Message)"
}

& $python.Executable @pythonPrefix (Join-Path $runtimeDirectory 'generate-thread-title-audio.py') --help 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'The installed Python helper failed its self-check.'
}

$installedConfig = [System.IO.File]::ReadAllText($configPath)
if (-not $installedConfig.Contains($notifyLine)) {
    throw 'config.toml self-check failed: notify was not written correctly.'
}

Write-Host ''
Write-Host 'Codex Audio Notification installed successfully.' -ForegroundColor Green
Write-Host "Runtime directory: $runtimeDirectory"
Write-Host 'Defaults: Codex voice, 15-second debounce, quiet from 23:00 to 08:00.'
Write-Host 'Restart Codex Desktop/CLI so the new notify setting is loaded consistently.'
