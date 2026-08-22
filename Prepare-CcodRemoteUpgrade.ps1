[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InstallRoot
)

$ErrorActionPreference = 'Stop'

function Get-CcodUpgradeCanonicalPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        throw 'CCOD_UPGRADE_ROOT_INVALID'
    }
    return [IO.Path]::GetFullPath($Path).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
}

function Get-CcodVerifiedSupervisor {
    param([Parameter(Mandatory)][string]$Root)

    $activePath = Join-Path $Root 'active.json'
    $statusPath = Join-Path $Root 'state\status.json'
    if (-not [IO.File]::Exists($activePath) -or -not [IO.File]::Exists($statusPath)) { return $null }

    try {
        $active = Get-Content -LiteralPath $activePath -Raw | ConvertFrom-Json -ErrorAction Stop
        $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $active -or $active.activeRuntime -isnot [string] -or $active.activeRuntime -notmatch '^[A-Za-z0-9._-]{1,96}$' -or
            $null -eq $status.session -or $status.session.supervisorPid -isnot [int] -or $status.session.supervisorPid -lt 1 -or
            $status.session.supervisorCreationTimeUtc -isnot [string] -or $status.session.sessionId -isnot [string]) { return $null }
        $sessionId = 0
        if (-not [int]::TryParse($status.session.sessionId, [ref]$sessionId) -or $sessionId -lt 0) { return $null }
        $expectedSupervisor = [IO.Path]::GetFullPath((Join-Path $Root ("runtime\{0}\src\persistence\Supervisor.ps1" -f $active.activeRuntime)))
        if (-not [IO.File]::Exists($expectedSupervisor)) { return $null }
        $process = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f [int]$status.session.supervisorPid) -ErrorAction Stop
        if ($null -eq $process -or [string]::IsNullOrWhiteSpace([string]$process.CommandLine)) { return $null }
        $commandLine = [string]$process.CommandLine
        if ($commandLine -notmatch [regex]::Escape($expectedSupervisor) -or $commandLine -notmatch '(?i)(?:^|\s)-ReadyToken\s+[0-9a-f]{64}(?=\s|$)') { return $null }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        try {
            if ($null -eq $identity -or $null -eq $identity.User) {
                return $null
            }
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
            if ($null -eq $owner -or [int]$owner.ReturnValue -ne 0 -or [string]$owner.Sid -cne $identity.User.Value) { return $null }
            return [pscustomobject][ordered]@{
                Pid = [int]$status.session.supervisorPid
                CreationTimeUtc = [string]$status.session.supervisorCreationTimeUtc
                SessionId = $sessionId
                UserSid = [string]$identity.User.Value
            }
        } finally {
            if ($null -ne $identity) { $identity.Dispose() }
        }
    } catch {
        return $null
    }
}

function Test-CcodUpgradeProcessIdentity {
    param([Parameter(Mandatory)]$Identity)
    $process = Get-Process -Id $Identity.Pid -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    try {
        return $process.SessionId -eq $Identity.SessionId -and
            $process.StartTime.ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture) -ceq $Identity.CreationTimeUtc
    } finally {
        $process.Dispose()
    }
}

$root = Get-CcodUpgradeCanonicalPath $InstallRoot
$identity = Get-CcodVerifiedSupervisor $root
if ($null -eq $identity) { exit 0 }

$eventName = "Local\CodexControlOtherDevices.Shutdown.$($identity.UserSid).$($identity.SessionId)"
$event = $null
try {
    $rights = [Security.AccessControl.EventWaitHandleRights]::Modify -bor [Security.AccessControl.EventWaitHandleRights]::Synchronize
    $event = [Threading.EventWaitHandle]::OpenExisting($eventName, $rights)
    [void]$event.Set()
} catch {
    throw 'CCOD_UPGRADE_SHUTDOWN_SIGNAL_FAILED'
} finally {
    if ($null -ne $event) { $event.Dispose() }
}

$deadline = [DateTime]::UtcNow.AddSeconds(10)
while ([DateTime]::UtcNow -lt $deadline -and (Test-CcodUpgradeProcessIdentity $identity)) {
    Start-Sleep -Milliseconds 200
}
if (Test-CcodUpgradeProcessIdentity $identity) {
    Stop-Process -Id $identity.Pid -Force -ErrorAction Stop
    $killDeadline = [DateTime]::UtcNow.AddSeconds(5)
    while ([DateTime]::UtcNow -lt $killDeadline -and (Test-CcodUpgradeProcessIdentity $identity)) {
        Start-Sleep -Milliseconds 200
    }
}
if (Test-CcodUpgradeProcessIdentity $identity) { throw 'CCOD_UPGRADE_SUPERVISOR_STOP_FAILED' }
exit 0
