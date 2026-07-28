[CmdletBinding()]
param(
    [switch]$BackupDeviceKeyStore,
    [switch]$DoNotRestart
)

$ErrorActionPreference = 'Stop'
$package = Get-AppxPackage OpenAI.Codex -ErrorAction Stop
$codexExecutable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
$storePath = $null

if ($BackupDeviceKeyStore) {
    $codexHome = if ([string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        Join-Path $env:USERPROFILE '.codex'
    } else {
        if (-not [System.IO.Path]::IsPathRooted($env:CODEX_HOME)) {
            throw 'CODEX_HOME must be an absolute path before the key store can be backed up safely.'
        }
        [System.IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    $storePath = Join-Path $codexHome 'remote-control-device-keys.windows.json'
}

$backupPath = $null
$operationFailure = $null
try {
    $running = @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $codexExecutable } catch { $false }
    })
    if ($running.Count -gt 0) {
        $running | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }

    if ($BackupDeviceKeyStore -and (Test-Path -LiteralPath $storePath -PathType Leaf)) {
        $candidateBackupPath = "$storePath.backup.$(Get-Date -Format 'yyyyMMdd-HHmmss')"
        Move-Item -LiteralPath $storePath -Destination $candidateBackupPath
        $backupPath = $candidateBackupPath
    }
} catch {
    $operationFailure = $_.Exception
}

$restartFailure = $null
if (-not $DoNotRestart) {
    try {
        Start-Process -FilePath $codexExecutable | Out-Null
    } catch {
        $restartFailure = $_.Exception
    }
}

if ($operationFailure) {
    if ($restartFailure) {
        throw "Rollback failed and Codex could not be restarted. Rollback error: $($operationFailure.Message) Restart error: $($restartFailure.Message)"
    }
    $recovery = if ($DoNotRestart) { 'Codex was left closed as requested.' } else { 'Codex was restarted normally.' }
    throw "Rollback failed. $recovery $($operationFailure.Message)"
}
if ($restartFailure) {
    throw "The runtime fix was stopped, but Codex could not be restarted normally. $($restartFailure.Message)"
}

Write-Host ''
Write-Host 'The runtime fix is no longer active.' -ForegroundColor Green
if ($backupPath) {
    Write-Host "The encrypted device-key store was moved to: $backupPath"
    Write-Host 'This does not revoke server-side authorization; revoke the device in Codex first.' -ForegroundColor Yellow
}
if ($DoNotRestart) {
    Write-Host 'Codex Desktop was left closed.'
} else {
    Write-Host 'Codex Desktop was restarted normally.'
}
Write-Host ''
