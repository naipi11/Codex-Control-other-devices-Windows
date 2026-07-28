[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$RendererDebugPort = 0,

    [ValidateRange(0, 65535)]
    [int]$MainInspectorPort = 0,

    [ValidateRange(10, 120)]
    [int]$TimeoutSeconds = 30
)

$ErrorActionPreference = 'Stop'
$projectRoot = $PSScriptRoot
$preflightScript = Join-Path $projectRoot 'Test-CodexControlOtherDevices.ps1'
$runtimeDirectory = Join-Path $projectRoot 'src\runtime'
$runtimeOrchestrator = Join-Path $runtimeDirectory 'orchestrator.js'
$mainPayload = Join-Path $runtimeDirectory 'main-payload.js'
$rendererPayload = Join-Path $runtimeDirectory 'renderer-payload.js'
$cdpTransport = Join-Path $runtimeDirectory 'lib\cdp.js'
$powershellExecutable = (Get-Command powershell.exe -ErrorAction Stop).Source

function Get-AvailableLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Assert-LoopbackPortAvailable([int]$Port, [string]$Label) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try {
        $listener.Start()
    } catch {
        throw "$Label port $Port is already in use. Choose another port or leave it at 0 for automatic selection."
    } finally {
        try { $listener.Stop() } catch {}
    }
}

function Get-CodexProcesses([string]$Executable) {
    @(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | Where-Object {
        try { $_.Path -eq $Executable } catch { $false }
    })
}

foreach ($requiredFile in @($preflightScript, $runtimeOrchestrator, $mainPayload, $rendererPayload, $cdpTransport)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required project file not found: $requiredFile"
    }
}

$preflightText = & $powershellExecutable -NoProfile -ExecutionPolicy Bypass -File $preflightScript -Json 2>&1
$preflightExitCode = $LASTEXITCODE
if ($preflightExitCode -ne 0) {
    try {
        $failedPreflight = ($preflightText -join "`n") | ConvertFrom-Json
        throw "Compatibility check failed: $($failedPreflight.Reasons -join '; ')"
    } catch [System.Management.Automation.RuntimeException] {
        throw
    } catch {
        throw "Compatibility check failed: $($preflightText -join ' ')"
    }
}
$preflight = ($preflightText -join "`n") | ConvertFrom-Json

$codexExecutable = [string]$preflight.ExecutablePath
$nodeExecutable = [string]$preflight.NodePath
$timeoutMilliseconds = $TimeoutSeconds * 1000

if ($RendererDebugPort -eq 0) { $RendererDebugPort = Get-AvailableLoopbackPort }
Assert-LoopbackPortAvailable $RendererDebugPort 'Renderer debugging'

if ($MainInspectorPort -eq 0) {
    do { $MainInspectorPort = Get-AvailableLoopbackPort } while ($MainInspectorPort -eq $RendererDebugPort)
}
if ($MainInspectorPort -eq $RendererDebugPort) {
    throw 'Renderer debugging and main-process Inspector ports must be different.'
}
Assert-LoopbackPortAvailable $MainInspectorPort 'Main-process inspector'

$logDirectory = Join-Path $env:TEMP 'CodexControlOtherDevices'
New-Item -ItemType Directory -Force -Path $logDirectory | Out-Null
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$logFile = Join-Path $logDirectory "runtime-$timestamp.log"
$sessionFile = Join-Path $logDirectory 'last-session.json'

@(
    "[$(Get-Date -Format o)] Starting Codex Control other devices runtime fix."
    "PackageVersion=$($preflight.PackageVersion)"
    "RendererDebugEndpoint=127.0.0.1:$RendererDebugPort"
    "MainInspectorEndpoint=127.0.0.1:$MainInspectorPort"
) | Set-Content -LiteralPath $logFile -Encoding utf8

$recoveryAuthorized = $false
try {
    # From this point onward, any failure may have interrupted the user's Codex
    # session, so the catch block is authorized to restore a normal launch.
    $recoveryAuthorized = $true
    $running = Get-CodexProcesses $codexExecutable
    if ($running.Count -gt 0) {
        Add-Content -LiteralPath $logFile -Encoding utf8 -Value "Stopping $($running.Count) Codex Desktop process(es)."
        $running | Stop-Process -Force
    }

    $exitDeadline = (Get-Date).AddSeconds(15)
    while ((Get-CodexProcesses $codexExecutable).Count -gt 0 -and (Get-Date) -lt $exitDeadline) {
        Start-Sleep -Milliseconds 250
    }
    if ((Get-CodexProcesses $codexExecutable).Count -gt 0) {
        throw 'Codex Desktop did not exit within 15 seconds.'
    }

    $appProcess = Start-Process -FilePath $codexExecutable -PassThru -ArgumentList @(
        '--remote-debugging-address=127.0.0.1'
        "--remote-debugging-port=$RendererDebugPort"
        "--inspect=127.0.0.1:$MainInspectorPort"
    )
    Add-Content -LiteralPath $logFile -Encoding utf8 -Value "Started Codex PID=$($appProcess.Id)."

    $bridgeOutput = & $nodeExecutable $runtimeOrchestrator `
        --renderer-port "$RendererDebugPort" `
        --main-port "$MainInspectorPort" `
        --timeout-ms "$timeoutMilliseconds" `
        --main-payload $mainPayload 2>&1
    $bridgeExitCode = $LASTEXITCODE
    Add-Content -LiteralPath $logFile -Encoding utf8 -Value @(
        '[clean-room runtime bridge]'
        ($bridgeOutput -join "`n")
    )
    if ($bridgeExitCode -ne 0) {
        throw "Runtime bridge failed: $($bridgeOutput -join ' ')"
    }
    $bridgeStatus = ($bridgeOutput -join "`n") | ConvertFrom-Json
    if ($bridgeStatus.ok -ne $true) {
        throw 'Runtime bridge did not report success.'
    }
    if ($bridgeStatus.main.inspectorPortClosed.confirmed -ne $true) {
        throw 'Main-process bridge did not verify that the Inspector closed.'
    }
    if ($bridgeStatus.renderer.newDocumentScriptInstalled -ne $true -or
        $bridgeStatus.renderer.probe.proof -ne $true) {
        throw 'Renderer bridge did not prove both current and future-document coverage.'
    }

    [ordered]@{
        StartedAt = (Get-Date -Format o)
        PackageVersion = [string]$preflight.PackageVersion
        ProcessId = $appProcess.Id
        RendererDebugAddress = "127.0.0.1:$RendererDebugPort"
        MainInspectorAddress = "127.0.0.1:$MainInspectorPort"
        MainInspectorClosed = $true
        RendererProbePassed = $true
        CleanRoomRuntime = $true
        LogFile = $logFile
    } | ConvertTo-Json | Set-Content -LiteralPath $sessionFile -Encoding utf8

    Add-Content -LiteralPath $logFile -Encoding utf8 -Value "[$(Get-Date -Format o)] Runtime fix installed successfully."
    Write-Host ''
    Write-Host 'Codex Control other devices is enabled for this app session.' -ForegroundColor Green
    Write-Host 'Open Settings > Connections > Control other devices.'
    Write-Host "Diagnostics: $logFile"
    Write-Host 'Launch Codex normally to disable the runtime fix.'
    Write-Host ''
} catch {
    $failureMessage = $_.Exception.Message
    Add-Content -LiteralPath $logFile -Encoding utf8 -Value "[$(Get-Date -Format o)] FAILURE: $failureMessage"
    if ($recoveryAuthorized) {
        try {
            Get-CodexProcesses $codexExecutable | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 500
            Start-Process -FilePath $codexExecutable | Out-Null
            Add-Content -LiteralPath $logFile -Encoding utf8 -Value 'Special launch stopped or failed; Codex restarted normally.'
        } catch {
            $recoveryFailure = $_.Exception.Message
            Add-Content -LiteralPath $logFile -Encoding utf8 -Value "Normal-launch recovery also failed: $recoveryFailure"
            throw "Runtime fix failed, and Codex could not be restarted normally. See $logFile. Original failure: $failureMessage Recovery failure: $recoveryFailure"
        }
    }
    throw "Runtime fix failed and Codex was returned to a normal launch. See $logFile. $failureMessage"
}
