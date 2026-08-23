[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$temporaryRoot = Join-Path $env:TEMP ('codex-audio-wrapper-test-' + [guid]::NewGuid().ToString('N'))
$runtimeDirectory = Join-Path $temporaryRoot 'hooks\codex-audio-notification'
$fakeDirectory = Join-Path $temporaryRoot 'fake-bin'
$markerPath = Join-Path $temporaryRoot 'ffplay-called.txt'
$originalPath = $env:PATH
$originalSkipNotifier = $env:CODEX_AUDIO_SKIP_DESKTOP_NOTIFIER
$originalMarker = $env:CODEX_AUDIO_TEST_FFPLAY_MARKER

try {
    New-Item -ItemType Directory -Path $runtimeDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $fakeDirectory -Force | Out-Null

    foreach ($file in @(
        'turn-complete-voice.ps1',
        'generate-thread-title-audio.py',
        'notification_audit.py',
        'task-completion-voice.json',
        'codex-task-complete-hsiaoyu.mp3',
        'claude-task-complete-hsiaoyu.mp3'
    )) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot "hooks\$file") -Destination (Join-Path $runtimeDirectory $file)
    }

    $databasePath = Join-Path $temporaryRoot 'state_5.sqlite'
    $schema = @'
import sqlite3
import sys
connection = sqlite3.connect(sys.argv[1])
connection.executescript("""
CREATE TABLE threads (
    id TEXT PRIMARY KEY,
    name TEXT,
    thread_source TEXT,
    rollout_path TEXT,
    source TEXT
);
CREATE TABLE thread_spawn_edges (child_thread_id TEXT);
""")
connection.close()
'@
    & python -c $schema $databasePath
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the isolated Codex database.'
    }

    $fakeFfplayPath = Join-Path $fakeDirectory 'ffplay.exe'
    $fakeSource = @'
using System;
using System.IO;

public static class Program
{
    public static int Main(string[] args)
    {
        string marker = Environment.GetEnvironmentVariable("CODEX_AUDIO_TEST_FFPLAY_MARKER");
        if (!String.IsNullOrWhiteSpace(marker))
        {
            File.AppendAllText(marker, "called" + Environment.NewLine);
        }
        return 0;
    }
}
'@
    $fakeSourcePath = Join-Path $fakeDirectory 'fake-ffplay.cs'
    [System.IO.File]::WriteAllText($fakeSourcePath, $fakeSource)
    $compilerPath = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compilerPath)) {
        throw "C# compiler not found: $compilerPath"
    }
    & $compilerPath /nologo /target:exe "/out:$fakeFfplayPath" $fakeSourcePath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fakeFfplayPath)) {
        throw 'Failed to compile the fake ffplay executable.'
    }

    $env:PATH = "$fakeDirectory;$originalPath"
    $env:CODEX_AUDIO_SKIP_DESKTOP_NOTIFIER = '1'
    $env:CODEX_AUDIO_TEST_FFPLAY_MARKER = $markerPath

    $payload = [ordered] @{
        type = 'agent-turn-complete'
        'thread-id' = '01a02df9-f1e0-7e81-8039-7eb93047022b'
        'turn-id' = 'captured-unknown-turn'
        cwd = 'D:\WILL\STOCK\MarketHub2'
    } | ConvertTo-Json -Compress

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $runtimeDirectory 'turn-complete-voice.ps1') $payload
    if ($LASTEXITCODE -ne 0) {
        throw "Wrapper exited with code $LASTEXITCODE."
    }
    if (Test-Path -LiteralPath $markerPath) {
        throw 'Unknown thread reached ffplay.'
    }

    $auditPath = Join-Path $runtimeDirectory 'logs\notification-audit.jsonl'
    if (-not (Test-Path -LiteralPath $auditPath)) {
        throw 'Wrapper did not write an audit record.'
    }
    $records = @(Get-Content -LiteralPath $auditPath | ForEach-Object { $_ | ConvertFrom-Json })
    $record = $records[-1]
    if ($record.decision -ne 'silence-unknown' -or
        $record.reason -ne 'thread-not-registered' -or
        $record.threadId -ne '01a02df9-f1e0-7e81-8039-7eb93047022b' -or
        $record.eventType -ne 'agent-turn-complete' -or
        $record.cwd -ne 'D:\WILL\STOCK\MarketHub2' -or
        $record.prefixPlayed -ne $false -or
        $record.titlePlayed -ne $false) {
        throw "Unexpected audit record: $($record | ConvertTo-Json -Compress)"
    }

    'WRAPPER_UNKNOWN_SILENT_OK'
}
finally {
    $env:PATH = $originalPath
    $env:CODEX_AUDIO_SKIP_DESKTOP_NOTIFIER = $originalSkipNotifier
    $env:CODEX_AUDIO_TEST_FFPLAY_MARKER = $originalMarker
    if (Test-Path -LiteralPath $temporaryRoot) {
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
}
