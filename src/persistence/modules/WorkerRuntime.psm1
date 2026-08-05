Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'PersistenceIO.psm1') -Force

function Throw-CcodWorkerRuntimeError {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Message,
        $Target
    )

    throw [Management.Automation.ErrorRecord]::new(
        [InvalidOperationException]::new($Message),
        $Id,
        [Management.Automation.ErrorCategory]::InvalidData,
        $Target
    )
}

function Get-CcodWorkerLeafState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker leaf path must be absolute' $Path
    }
    $exists = [IO.File]::Exists($Path)
    $isReparse = $false
    if ($exists) {
        try {
            $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
            $isReparse = (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        } catch {
            $isReparse = $true
        }
    }
    return [pscustomobject][ordered]@{
        Exists = [bool]$exists
        IsReparse = [bool]$isReparse
    }
}

function Write-CcodWorkerRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Request
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker request path must be absolute' $Path
    }
    Write-CcodAtomicJson -Path $Path -Value $Request
}

function Start-CcodWorkerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Controller', 'StaticProbe')][string]$Kind,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$RequestPath,
        [Parameter(Mandatory)][string]$ResultPath,
        [AllowNull()][string]$StderrPath,
        [Parameter(Mandatory)][string]$PowerShellPath
    )

    foreach ($path in @($ScriptPath, $RequestPath, $ResultPath)) {
        if (-not [IO.Path]::IsPathRooted($path)) {
            Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker paths must be absolute' $path
        }
    }
    if (-not [IO.File]::Exists($ScriptPath)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SCRIPT_MISSING' 'Worker script does not exist' $ScriptPath
    }
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + [string]$ScriptPath + '" -RequestPath "' + [string]$RequestPath + '" -ResultPath "' + [string]$ResultPath + '"'
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = [string]$PowerShellPath
    $startInfo.Arguments = $arguments
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.CreateNoWindow = $true
    $startInfo.UseShellExecute = $false
    try {
        $process = [Diagnostics.Process]::Start($startInfo)
    } catch {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'The supervisor worker could not be launched' $ScriptPath
    }
    if ($null -eq $process) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_START_FAILED' 'The supervisor worker returned no process handle' $ScriptPath
    }
    return [pscustomobject][ordered]@{
        ProcessId = [int]$process.Id
        CreationTimeUtc = $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        Handle = $process
    }
}

function Get-CcodWorkerPoll {
    [CmdletBinding()]
    param($Slot)

    if ($null -eq $Slot -or $Slot.ProcessId -isnot [int] -or $Slot.ProcessId -lt 1) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SLOT_INVALID' 'Worker slot is invalid' $Slot
    }
    $completed = $false
    $exitCode = $null
    $probe = Get-Process -Id $Slot.ProcessId -ErrorAction SilentlyContinue
    if ($null -ne $probe) {
        try {
            $probe.Refresh()
            if ($probe.HasExited) {
                $completed = $true
                $exitCode = [int]$probe.ExitCode
            }
        } finally {
            $probe.Dispose()
        }
    } else {
        $completed = $true
        $exitCode = [int]0
    }
    $stdoutText = ''
    if ($completed -and [IO.File]::Exists($Slot.ResultPath)) {
        try {
            $stdoutText = [IO.File]::ReadAllText($Slot.ResultPath, [Text.UTF8Encoding]::new($false)).Trim()
        } catch {
            $stdoutText = ''
        }
    }
    $stdoutBytes = 0
    if (-not [string]::IsNullOrEmpty($stdoutText)) {
        $stdoutBytes = [Text.Encoding]::UTF8.GetByteCount($stdoutText)
    }
    $stderrBytes = 0
    if (-not [string]::IsNullOrWhiteSpace([string]$Slot.StderrPath) -and [IO.File]::Exists($Slot.StderrPath)) {
        try {
            $stderrBytes = [int](Get-Item -LiteralPath $Slot.StderrPath -Force -ErrorAction Stop).Length
        } catch {
            $stderrBytes = 0
        }
    }
    return [pscustomobject][ordered]@{
        Completed = [bool]$completed
        ExitCode = $exitCode
        StdoutText = [string]$stdoutText
        StdoutByteCount = [int]$stdoutBytes
        StdoutOverflow = $stdoutBytes -gt 1048576
        StderrByteCount = [int]$stderrBytes
        StderrOverflow = $stderrBytes -gt 65536
    }
}

function Read-CcodWorkerResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.File]::Exists($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_RESULT_MISSING' 'Worker result file is missing' $Path
    }
    return Read-CcodStrictJson -Path $Path -ExpectedSchema 1 -Kind 'worker result'
}

function Wait-CcodWorkerExit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Slot,
        [Parameter(Mandatory)][ValidateRange(1, 600000)][int]$TimeoutMilliseconds
    )

    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $probe = Get-Process -Id $Slot.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $probe) { return $true }
        $probe.Dispose()
        if ($clock.ElapsedMilliseconds -ge [long]$TimeoutMilliseconds) { return $false }
        Start-Sleep -Milliseconds 100
    } while ($true)
}

function Get-CcodWorkerIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Pid)

    $probe = Get-Process -Id $Pid -ErrorAction SilentlyContinue
    if ($null -eq $probe) { return $null }
    try {
        return [pscustomobject][ordered]@{
            Pid = [int]$probe.Id
            CreationTimeUtc = $probe.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
    } finally {
        $probe.Dispose()
    }
}

function Stop-CcodWorkerProcess {
    [CmdletBinding()]
    param($Slot)

    if ($null -eq $Slot -or $Slot.ProcessId -isnot [int] -or $Slot.ProcessId -lt 1) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_SLOT_INVALID' 'Worker slot is invalid' $Slot
    }
    try {
        Stop-Process -Id $Slot.ProcessId -Force -ErrorAction Stop
    } catch {
        return $false
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $probe = Get-Process -Id $Slot.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $probe) { return $true }
        $probe.Dispose()
        if ($clock.ElapsedMilliseconds -ge 5000) { return $false }
        Start-Sleep -Milliseconds 100
    } while ($true)
}

function Close-CcodWorkerHandle {
    [CmdletBinding()]
    param($Slot)

    if ($null -ne $Slot -and $null -ne $Slot.Handle) {
        try { $Slot.Handle.Dispose() } catch { }
    }
}

function Remove-CcodWorkerFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Path]::IsPathRooted($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_PATH_INVALID' 'Worker file path must be absolute' $Path
    }
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        if (-not [IO.File]::Exists($Path)) { return }
        try {
            [IO.File]::Delete($Path)
            return
        } catch [IO.IOException] {
            if ($attempt -ge 19) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}

function Open-CcodLogDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    if (-not [IO.Directory]::Exists($Path)) {
        Throw-CcodWorkerRuntimeError 'CCOD_WORKER_LOG_MISSING' 'Log directory does not exist' $Path
    }
    Start-Process explorer.exe -ArgumentList ([string]$Path) -ErrorAction SilentlyContinue
}

function Get-CcodChatGptProcessIds {
    [CmdletBinding()]
    param()

    return ,[int[]]@(Get-Process -Name ChatGPT -ErrorAction SilentlyContinue | ForEach-Object {
        try { [int]$_.Id } finally { $_.Dispose() }
    })
}

Export-ModuleMember -Function @(
    'Get-CcodWorkerLeafState',
    'Write-CcodWorkerRequest',
    'Start-CcodWorkerProcess',
    'Get-CcodWorkerPoll',
    'Read-CcodWorkerResult',
    'Wait-CcodWorkerExit',
    'Get-CcodWorkerIdentity',
    'Stop-CcodWorkerProcess',
    'Close-CcodWorkerHandle',
    'Remove-CcodWorkerFile',
    'Open-CcodLogDirectory',
    'Get-CcodChatGptProcessIds'
)
