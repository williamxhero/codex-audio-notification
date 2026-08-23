[CmdletBinding()]
param(
    [string] $CodexHome
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string] $Path, [string] $Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-RootNotifyBlock {
    param([string[]] $Lines)

    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[.+\]\s*(?:#.*)?$') {
            break
        }
        if ($Lines[$index] -notmatch '^\s*notify\s*=') {
            continue
        }

        $balance = 0
        $opened = $false
        for ($end = $index; $end -lt $Lines.Count; $end++) {
            foreach ($character in $Lines[$end].ToCharArray()) {
                if ($character -eq '[') { $balance++; $opened = $true }
                elseif ($character -eq ']') { $balance-- }
            }
            if ($opened -and $balance -le 0) {
                return [pscustomobject] @{ Start = $index; End = $end; Lines = @($Lines[$index..$end]) }
            }
        }
        throw 'The notify array in config.toml is not closed. The config was not changed.'
    }
    return $null
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
$hooksDirectory = [System.IO.Path]::GetFullPath((Join-Path $CodexHome 'hooks'))
$runtimeDirectory = [System.IO.Path]::GetFullPath((Join-Path $hooksDirectory 'codex-audio-notification'))
$expectedPrefix = $hooksDirectory.TrimEnd('\') + '\'
if (-not $runtimeDirectory.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase) -or
    (Split-Path -Leaf $runtimeDirectory) -ne 'codex-audio-notification') {
    throw "Refusing to delete an unexpected directory: $runtimeDirectory"
}

$configPath = Join-Path $CodexHome 'config.toml'
$statePath = Join-Path $runtimeDirectory '.install-state.json'
if ((Test-Path -LiteralPath $configPath) -and -not (Test-Path -LiteralPath $statePath)) {
    $currentWithoutState = Get-RootNotifyBlock -Lines @([System.IO.File]::ReadAllLines($configPath))
    $currentWithoutStateText = if ($null -eq $currentWithoutState) { '' } else { @($currentWithoutState.Lines) -join [Environment]::NewLine }
    if ($currentWithoutStateText -match 'codex-audio-notification') {
        throw 'The install state is missing, so the original notify cannot be restored safely. No runtime files were deleted.'
    }
}
if ((Test-Path -LiteralPath $configPath) -and (Test-Path -LiteralPath $statePath)) {
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
    $lines = @([System.IO.File]::ReadAllLines($configPath))
    $current = Get-RootNotifyBlock -Lines $lines
    $currentText = if ($null -eq $current) { '' } else { @($current.Lines) -join [Environment]::NewLine }
    $installedLine = [string] $state.installedNotifyLine

    if ($currentText -eq $installedLine) {
        $result = New-Object 'System.Collections.Generic.List[string]'
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($index -eq $current.Start) {
                foreach ($previousLine in @($state.previousNotifyLines)) {
                    $result.Add([string] $previousLine)
                }
            }
            if ($index -lt $current.Start -or $index -gt $current.End) {
                $result.Add($lines[$index])
            }
        }

        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backupPath = "$configPath.codex-audio-notification-uninstall.$timestamp.bak"
        Copy-Item -LiteralPath $configPath -Destination $backupPath
        $content = (@($result) -join [Environment]::NewLine).TrimEnd() + [Environment]::NewLine
        Write-Utf8NoBom -Path $configPath -Content $content
        Write-Host "Restored the pre-install notify value and backed up the current config: $backupPath"
    }
    elseif ($currentText -match 'codex-audio-notification') {
        throw 'notify still points to this tool but was edited manually. Uninstall stopped to avoid damaging config.toml.'
    }
    else {
        Write-Warning 'notify was changed by the user or another tool, so the current value was preserved.'
    }
}

if (Test-Path -LiteralPath $runtimeDirectory) {
    Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force
}

Write-Host 'Codex Audio Notification uninstalled successfully.' -ForegroundColor Green
