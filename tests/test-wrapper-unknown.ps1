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
$mainThreadId = '01a02df9-f1e0-7e81-8039-7eb930470220'
$mutedThreadId = '01a02df9-f1e0-7e81-8039-7eb930470221'
$spawnedThreadId = '01a02df9-f1e0-7e81-8039-7eb930470222'
$unknownThreadId = '01a02df9-f1e0-7e81-8039-7eb930470223'
$mainTitle = 'Audible integration title'
$mutedTitle = 'Muted 🔇 integration title'

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

    $voiceConfigPath = Join-Path $runtimeDirectory 'task-completion-voice.json'
    $voiceConfig = Get-Content -Raw -LiteralPath $voiceConfigPath | ConvertFrom-Json
    $voiceConfig.settleSeconds = 0
    $voiceConfig.quietHours.start = 0
    $voiceConfig.quietHours.end = 0
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($voiceConfigPath, ($voiceConfig | ConvertTo-Json -Depth 8), $utf8NoBom)

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
connection.executemany(
    """
    INSERT INTO threads (id, name, thread_source, rollout_path, source)
    VALUES (?, ?, ?, NULL, '{}')
    """,
    [
        (sys.argv[2], sys.argv[3], "user"),
        (sys.argv[4], "Muted \U0001F507 integration title", "user"),
        (sys.argv[5], "Spawned integration title", "subagent"),
    ],
)
connection.commit()
connection.close()
'@
    $schema | & python - $databasePath $mainThreadId $mainTitle $mutedThreadId $spawnedThreadId
    if ($LASTEXITCODE -ne 0) {
        throw 'Failed to create the isolated Codex database.'
    }

    $cacheDirectory = Join-Path $runtimeDirectory 'voice-cache'
    New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null
    $settingsVersion = 'hsiaoyu-rate-6-pitch-22-volume-4db-v1'
    $cacheMaterial = $mainThreadId + [char] 0 + $mainTitle + [char] 0 + $settingsVersion
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($cacheMaterial))
    }
    finally {
        $sha256.Dispose()
    }
    $cacheHash = (-join ($hashBytes | ForEach-Object { $_.ToString('x2') })).Substring(0, 24)
    [System.IO.File]::WriteAllBytes((Join-Path $cacheDirectory "thread-title-$cacheHash.mp3"), [byte[]] @(1))

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

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wrapperPath = Join-Path $runtimeDirectory 'turn-complete-voice.ps1'
    $auditPath = Join-Path $runtimeDirectory 'logs\notification-audit.jsonl'

    function Invoke-WrapperCase {
        param(
            [string] $ThreadId,
            [string] $TurnId
        )

        $payload = [ordered] @{
            type = 'agent-turn-complete'
            'thread-id' = $ThreadId
            'turn-id' = $TurnId
            cwd = 'D:\WILL\STOCK\MarketHub2'
        } | ConvertTo-Json -Compress
        $escapedPayload = $payload.Replace('"', '\"')

        & $windowsPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $wrapperPath $escapedPayload
        if ($LASTEXITCODE -ne 0) {
            throw "Wrapper exited with code $LASTEXITCODE for $TurnId."
        }
    }

    function Get-AuditRecord {
        param([string] $TurnId)

        if (-not (Test-Path -LiteralPath $auditPath)) {
            throw 'Wrapper did not write an audit record.'
        }
        $record = @(Get-Content -LiteralPath $auditPath | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.turnId -eq $TurnId })
        if ($record.Count -ne 1) {
            $allRecords = Get-Content -LiteralPath $auditPath -Raw
            throw "Expected one audit record for $TurnId, found $($record.Count). Records: $allRecords"
        }
        return $record[0]
    }

    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Invoke-WrapperCase -ThreadId $mutedThreadId -TurnId 'captured-muted-turn'
    if (Test-Path -LiteralPath $markerPath) {
        throw 'Muted thread reached ffplay.'
    }
    $mutedRecord = Get-AuditRecord -TurnId 'captured-muted-turn'
    if ($mutedRecord.decision -ne 'silence-muted' -or
        $mutedRecord.reason -ne 'title-muted' -or
        $mutedRecord.threadId -ne $mutedThreadId -or
        $mutedRecord.prefixPlayed -ne $false -or
        $mutedRecord.titlePlayed -ne $false) {
        throw "Unexpected muted audit record: $($mutedRecord | ConvertTo-Json -Compress)"
    }
    $mutedAuditJson = $mutedRecord | ConvertTo-Json -Compress
    if ($mutedAuditJson.Contains($mutedTitle) -or $mutedAuditJson.Contains('integration title')) {
        throw 'Muted audit record exposed the title text.'
    }

    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Invoke-WrapperCase -ThreadId $unknownThreadId -TurnId 'captured-unknown-turn'
    if (Test-Path -LiteralPath $markerPath) {
        throw 'Unknown thread reached ffplay.'
    }
    $unknownRecord = Get-AuditRecord -TurnId 'captured-unknown-turn'
    if ($unknownRecord.decision -ne 'silence-unknown' -or
        $unknownRecord.reason -ne 'thread-not-registered' -or
        $unknownRecord.threadId -ne $unknownThreadId -or
        $unknownRecord.eventType -ne 'agent-turn-complete' -or
        $unknownRecord.cwd -ne 'D:\WILL\STOCK\MarketHub2' -or
        $unknownRecord.prefixPlayed -ne $false -or
        $unknownRecord.titlePlayed -ne $false) {
        throw "Unexpected unknown audit record: $($unknownRecord | ConvertTo-Json -Compress)"
    }

    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Invoke-WrapperCase -ThreadId $spawnedThreadId -TurnId 'captured-spawned-turn'
    if (Test-Path -LiteralPath $markerPath) {
        throw 'Spawned thread reached ffplay.'
    }
    $spawnedRecord = Get-AuditRecord -TurnId 'captured-spawned-turn'
    if ($spawnedRecord.decision -ne 'silence-spawned' -or
        $spawnedRecord.reason -ne 'spawned-thread' -or
        $spawnedRecord.prefixPlayed -ne $false -or
        $spawnedRecord.titlePlayed -ne $false) {
        throw "Unexpected spawned audit record: $($spawnedRecord | ConvertTo-Json -Compress)"
    }

    Remove-Item -LiteralPath $markerPath -Force -ErrorAction SilentlyContinue
    Invoke-WrapperCase -ThreadId $mainThreadId -TurnId 'captured-main-turn'
    $ffplayCalls = if (Test-Path -LiteralPath $markerPath) { @(Get-Content -LiteralPath $markerPath) } else { @() }
    if ($ffplayCalls.Count -ne 2) {
        throw "Expected main thread to call fake ffplay twice, found $($ffplayCalls.Count)."
    }
    $mainRecord = Get-AuditRecord -TurnId 'captured-main-turn'
    if ($mainRecord.decision -ne 'play' -or
        $mainRecord.reason -ne 'completed-thread' -or
        $mainRecord.prefixPlayed -ne $true -or
        $mainRecord.titlePlayed -ne $true) {
        throw "Unexpected main audit record: $($mainRecord | ConvertTo-Json -Compress)"
    }

    'WRAPPER_DECISIONS_FAKE_FFPLAY_OK'
}
finally {
    $env:PATH = $originalPath
    $env:CODEX_AUDIO_SKIP_DESKTOP_NOTIFIER = $originalSkipNotifier
    $env:CODEX_AUDIO_TEST_FFPLAY_MARKER = $originalMarker
    if (Test-Path -LiteralPath $temporaryRoot) {
        [System.IO.Directory]::Delete($temporaryRoot, $true)
    }
}
