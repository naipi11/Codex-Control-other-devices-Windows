Set-StrictMode -Version Latest

$script:CcodProcessSnapshotFields = @(
    'Pid',
    'CreationTimeUtc',
    'SessionId',
    'UserSid',
    'Path',
    'PackageFamilyName',
    'CommandLine',
    'ParentPid',
    'IsTopLevel',
    'Mode',
    'RendererPort',
    'MainPort'
)
$script:CcodNativeTypeName = 'Ccod.Persistence.Native.ProcessIdentityV1'

function Initialize-CcodProcessNativeApi {
    if ($null -ne ($script:CcodNativeTypeName -as [type])) { return }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
using System.Text;

namespace Ccod.Persistence.Native {
    public sealed class ProcessIdentityResult {
        public int Pid { get; set; }
        public string CreationTimeUtc { get; set; }
        public int SessionId { get; set; }
        public string UserSid { get; set; }
        public string Path { get; set; }
        public string PackageFamilyName { get; set; }
    }

    public static class ProcessIdentityV1 {
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint TOKEN_QUERY = 0x0008;
        private const int TokenUser = 1;
        private const int ERROR_INSUFFICIENT_BUFFER = 122;
        private const int APPMODEL_ERROR_NO_PACKAGE = 15700;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME { public uint Low; public uint High; }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ProcessIdToSessionId(uint processId, out uint sessionId);

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool QueryFullProcessImageName(IntPtr process, int flags, StringBuilder path, ref int size);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool OpenProcessToken(IntPtr process, uint desiredAccess, out IntPtr token);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern bool GetTokenInformation(IntPtr token, int informationClass, IntPtr information, int informationLength, out int returnLength);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetPackageFamilyName(IntPtr process, ref uint length, StringBuilder familyName);

        private static void ThrowLastError() { throw new Win32Exception(Marshal.GetLastWin32Error()); }

        private static string ReadUserSid(IntPtr process) {
            IntPtr token;
            if (!OpenProcessToken(process, TOKEN_QUERY, out token)) ThrowLastError();
            try {
                int required;
                GetTokenInformation(token, TokenUser, IntPtr.Zero, 0, out required);
                if (required <= 0 || Marshal.GetLastWin32Error() != ERROR_INSUFFICIENT_BUFFER) ThrowLastError();
                IntPtr buffer = Marshal.AllocHGlobal(required);
                try {
                    if (!GetTokenInformation(token, TokenUser, buffer, required, out required)) ThrowLastError();
                    IntPtr sid = Marshal.ReadIntPtr(buffer);
                    return new SecurityIdentifier(sid).Value;
                } finally { Marshal.FreeHGlobal(buffer); }
            } finally { CloseHandle(token); }
        }

        private static string ReadFamily(IntPtr process) {
            uint length = 0;
            int result = GetPackageFamilyName(process, ref length, null);
            if (result == APPMODEL_ERROR_NO_PACKAGE) return null;
            if (result != ERROR_INSUFFICIENT_BUFFER) throw new Win32Exception(result);
            StringBuilder family = new StringBuilder((int)length);
            result = GetPackageFamilyName(process, ref length, family);
            if (result == APPMODEL_ERROR_NO_PACKAGE) return null;
            if (result != 0) throw new Win32Exception(result);
            return family.ToString();
        }

        public static ProcessIdentityResult Query(int processId) {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
            if (process == IntPtr.Zero) ThrowLastError();
            try {
                FILETIME creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) ThrowLastError();
                long fileTime = ((long)creation.High << 32) | creation.Low;
                uint sessionId;
                if (!ProcessIdToSessionId((uint)processId, out sessionId)) ThrowLastError();
                int capacity = 32768;
                StringBuilder path = new StringBuilder(capacity);
                if (!QueryFullProcessImageName(process, 0, path, ref capacity)) ThrowLastError();
                return new ProcessIdentityResult {
                    Pid = processId,
                    CreationTimeUtc = DateTime.FromFileTimeUtc(fileTime).ToString("o"),
                    SessionId = (int)sessionId,
                    UserSid = ReadUserSid(process),
                    Path = path.ToString(),
                    PackageFamilyName = ReadFamily(process)
                };
            } finally { CloseHandle(process); }
        }
    }

    public sealed class ProcessStopResult {
        public string Outcome { get; set; }
        public bool StoppedByController { get; set; }
        public int Pid { get; set; }
        public string CreationTimeUtc { get; set; }
    }

    public static class ProcessStopV1 {
        private const uint PROCESS_TERMINATE = 0x0001;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private const uint WAIT_FAILED = 0xFFFFFFFF;

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME { public uint Low; public uint High; }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, bool inheritHandle, int processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out FILETIME creation, out FILETIME exit, out FILETIME kernel, out FILETIME user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        private static ProcessStopResult Result(string outcome, bool stopped, int pid, string creation) {
            return new ProcessStopResult { Outcome = outcome, StoppedByController = stopped, Pid = pid, CreationTimeUtc = creation };
        }

        private static ProcessStopResult ErrorResult(int error, int pid, string creation) {
            if (error == 5) return Result("AccessDenied", false, pid, creation);
            if (error == 6 || error == 87 || error == 1168) return Result("ExitedBeforeStop", false, pid, creation);
            return Result("TimedOut", false, pid, creation);
        }

        public static ProcessStopResult StopVerified(int processId, string expectedCreationTimeUtc, int timeoutMilliseconds) {
            IntPtr process = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, processId);
            if (process == IntPtr.Zero) return ErrorResult(Marshal.GetLastWin32Error(), processId, expectedCreationTimeUtc);
            try {
                FILETIME creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) {
                    return ErrorResult(Marshal.GetLastWin32Error(), processId, expectedCreationTimeUtc);
                }
                long fileTime = ((long)creation.High << 32) | creation.Low;
                string actualCreation = DateTime.FromFileTimeUtc(fileTime).ToString("o");
                DateTime expected;
                if (!DateTime.TryParse(expectedCreationTimeUtc, null, System.Globalization.DateTimeStyles.RoundtripKind, out expected) ||
                    expected.ToUniversalTime().ToFileTimeUtc() != fileTime) {
                    return Result("IdentityChanged", false, processId, actualCreation);
                }
                uint priorWait = WaitForSingleObject(process, 0);
                if (priorWait == WAIT_OBJECT_0) return Result("ExitedBeforeStop", false, processId, actualCreation);
                if (priorWait == WAIT_FAILED) return ErrorResult(Marshal.GetLastWin32Error(), processId, actualCreation);
                if (!TerminateProcess(process, 1)) return ErrorResult(Marshal.GetLastWin32Error(), processId, actualCreation);
                uint wait = WaitForSingleObject(process, (uint)timeoutMilliseconds);
                if (wait == WAIT_OBJECT_0) return Result("StoppedByController", true, processId, actualCreation);
                if (wait == WAIT_FAILED) return ErrorResult(Marshal.GetLastWin32Error(), processId, actualCreation);
                return Result("TimedOut", false, processId, actualCreation);
            } finally { CloseHandle(process); }
        }
    }
}
'@
}

function Get-CcodDefaultNativeProcess {
    param([int]$ProcessId)

    Initialize-CcodProcessNativeApi
    try {
        return [Ccod.Persistence.Native.ProcessIdentityV1]::Query($ProcessId)
    } catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -in @(6, 87, 1168)) { return $null }
        throw
    }
}

function Get-CcodProcessAdapters {
    param([hashtable]$Adapters)

    $resolved = @{
        GetPackageIdentity = {
            if ($null -eq (Get-Command Get-CcodPackageIdentity -ErrorAction SilentlyContinue)) {
                Import-Module (Join-Path $PSScriptRoot 'CompatibilityProbe.psm1') -Force
            }
            Get-CcodPackageIdentity
        }
        GetCurrentSessionId = { [Diagnostics.Process]::GetCurrentProcess().SessionId }
        GetCurrentUserSid = { [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
        GetNativeProcess = { param($ProcessId) Get-CcodDefaultNativeProcess -ProcessId $ProcessId }
        GetCimProcess = {
            param($ProcessId)
            Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$ProcessId)" -ErrorAction Stop
        }
        ProbeSpecial = { param($ProcessId, $RendererPort, $MainPort) [pscustomobject]@{ Valid = $false; RendererUrl = $null } }
        GetProcess = { param($ProcessId, $StatusEvidence) Get-CcodProcessSnapshot -ProcessId $ProcessId -StatusEvidence $StatusEvidence }
        ListProcessIds = { @((Get-Process -Name 'ChatGPT' -ErrorAction SilentlyContinue).Id) }
        StopProcess = {
            param($Snapshot, $TimeoutMilliseconds)
            Initialize-CcodProcessNativeApi
            [Ccod.Persistence.Native.ProcessStopV1]::StopVerified(
                [int]$Snapshot.Pid,
                [string]$Snapshot.CreationTimeUtc,
                [int]$TimeoutMilliseconds
            )
        }
        ReserveLoopbackPort = {
            param($Address)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse([string]$Address), 0)
            try {
                $listener.Start()
                return [int]$listener.LocalEndpoint.Port
            } finally { $listener.Stop() }
        }
        TestLoopbackPortAvailable = {
            param($Port, $Address)
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Parse([string]$Address), [int]$Port)
            try {
                $listener.Start()
                return $true
            } catch [Net.Sockets.SocketException] {
                return $false
            } finally { $listener.Stop() }
        }
        ProbeLoopbackPort = {
            param($Port)
            $client = [Net.Sockets.TcpClient]::new([Net.Sockets.AddressFamily]::InterNetwork)
            try {
                $client.Connect('127.0.0.1', [int]$Port)
                return 'Open'
            } catch [Net.Sockets.SocketException] {
                if ($_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::ConnectionRefused) { return 'Refused' }
                return 'Error'
            } finally { $client.Dispose() }
        }
        GetUtcNow = { [DateTimeOffset]::UtcNow }
        Delay = { param($Milliseconds) Start-Sleep -Milliseconds ([int]$Milliseconds) }
        StartProcess = {
            param($FilePath, $Arguments, $WindowStyle)
            $parameters = @{
                FilePath = [string]$FilePath
                ArgumentList = @($Arguments)
                PassThru = $true
                ErrorAction = 'Stop'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$WindowStyle)) { $parameters.WindowStyle = [string]$WindowStyle }
            Start-Process @parameters
        }
    }
    if ($null -ne $Adapters) {
        foreach ($name in $Adapters.Keys) { $resolved[$name] = $Adapters[$name] }
    }
    return $resolved
}

function Test-CcodOrdinalIgnoreCase {
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    return [string]::Equals($Left, $Right, [StringComparison]::OrdinalIgnoreCase)
}

function Get-CcodStatusEvidence {
    param($StatusEvidence)

    if ($null -eq $StatusEvidence) { return $null }
    if ($null -ne $StatusEvidence.PSObject.Properties['session'] -and $null -ne $StatusEvidence.session -and
        $null -ne $StatusEvidence.session.PSObject.Properties['codex']) {
        return $StatusEvidence.session.codex
    }
    return $StatusEvidence
}

function Get-CcodCommandPort {
    param([string]$CommandLine, [string]$Pattern)

    $matches = [regex]::Matches($CommandLine, $Pattern, [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if ($matches.Count -ne 1) { return $null }
    $port = 0
    if (-not [int]::TryParse($matches[0].Groups['port'].Value, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { return $null }
    return $port
}

function Get-CcodProcessSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 2147483647)][int]$ProcessId,
        $StatusEvidence,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $package = & $adapter.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or -not $package.Found) { return $null }
    foreach ($name in @('FullName', 'FamilyName', 'Version', 'ExecutablePath')) {
        if ($null -eq $package.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$package.$name)) { return $null }
    }

    $before = & $adapter.GetNativeProcess $ProcessId
    if ($null -eq $before) { return $null }
    $cim = & $adapter.GetCimProcess $ProcessId
    if ($null -eq $cim) { return $null }
    $after = & $adapter.GetNativeProcess $ProcessId
    if ($null -eq $after -or $before.Pid -ne $after.Pid -or $before.CreationTimeUtc -cne $after.CreationTimeUtc) { return $null }

    $commandLine = [string]$cim.CommandLine
    $hasTypeArgument = $commandLine -match '(?:^|\s)--type(?:=|\s|$)'
    $isTopLevel = -not $hasTypeArgument
    $currentSessionId = & $adapter.GetCurrentSessionId
    $currentUserSid = & $adapter.GetCurrentUserSid
    $eligibleRoot = $isTopLevel -and
        $before.SessionId -eq $currentSessionId -and
        $before.UserSid -ceq $currentUserSid -and
        [IO.Path]::GetFileName([string]$before.Path) -ieq 'ChatGPT.exe' -and
        (Test-CcodOrdinalIgnoreCase $before.Path $package.ExecutablePath) -and
        $before.PackageFamilyName -ceq $package.FamilyName

    $rendererPort = Get-CcodCommandPort -CommandLine $commandLine -Pattern '(?:^|\s)--remote-debugging-port=(?<port>\d{1,5})(?=\s|$)'
    $mainPort = Get-CcodCommandPort -CommandLine $commandLine -Pattern '(?:^|\s)--inspect=127\.0\.0\.1:(?<port>\d{1,5})(?=\s|$)'
    $hasLoopbackAddress = [regex]::Matches($commandLine, '(?:^|\s)--remote-debugging-address=127\.0\.0\.1(?=\s|$)').Count -eq 1
    $hasAnyDebugArgument = $commandLine -match '(?:^|\s)--(?:remote-debugging-address|remote-debugging-port|inspect)(?:=|\s|$)'
    $mode = 'Unrelated'
    if ($eligibleRoot -and -not $hasAnyDebugArgument) {
        $mode = 'Ordinary'
    } elseif ($eligibleRoot -and $hasLoopbackAddress -and $null -ne $rendererPort -and $null -ne $mainPort -and $rendererPort -ne $mainPort) {
        $status = Get-CcodStatusEvidence -StatusEvidence $StatusEvidence
        if ($null -ne $status) {
            $requiredStatus = @('pid', 'creationTimeUtc', 'packageFullName', 'packageVersion', 'rendererPort', 'mainPort')
            $statusComplete = $true
            foreach ($name in $requiredStatus) {
                if ($null -eq $status.PSObject.Properties[$name]) { $statusComplete = $false; break }
            }
            if ($statusComplete -and
                $status.pid -eq $ProcessId -and
                $status.creationTimeUtc -ceq $before.CreationTimeUtc -and
                $status.packageFullName -ceq $package.FullName -and
                $status.packageVersion -ceq $package.Version -and
                $status.rendererPort -eq $rendererPort -and
                $status.mainPort -eq $mainPort) {
                $probe = & $adapter.ProbeSpecial $ProcessId $rendererPort $mainPort
                if ($null -ne $probe -and $probe.Valid -eq $true -and $probe.RendererUrl -ceq 'app://-/index.html') {
                    $mode = 'Special'
                }
            }
        }
    }

    return [pscustomobject][ordered]@{
        Pid = [int]$before.Pid
        CreationTimeUtc = [string]$before.CreationTimeUtc
        SessionId = [int]$before.SessionId
        UserSid = [string]$before.UserSid
        Path = [string]$before.Path
        PackageFamilyName = [string]$before.PackageFamilyName
        CommandLine = $commandLine
        ParentPid = if ($null -eq $cim.ParentProcessId) { $null } else { [int]$cim.ParentProcessId }
        IsTopLevel = [bool]$isTopLevel
        Mode = $mode
        RendererPort = if ($null -eq $rendererPort) { $null } else { [int]$rendererPort }
        MainPort = if ($null -eq $mainPort) { $null } else { [int]$mainPort }
    }
}

function Test-CcodProcessMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual
    )

    foreach ($field in $script:CcodProcessSnapshotFields) {
        $expectedProperty = $Expected.PSObject.Properties[$field]
        $actualProperty = $Actual.PSObject.Properties[$field]
        if ($null -eq $expectedProperty -or $null -eq $actualProperty) { return $false }
        if (-not [object]::Equals($expectedProperty.Value, $actualProperty.Value)) { return $false }
    }
    return $true
}

function New-CcodStopResult {
    param(
        [Parameter(Mandatory)][ValidateSet('StoppedByController', 'ExitedBeforeStop', 'IdentityChanged', 'AccessDenied', 'TimedOut')][string]$Outcome,
        $Snapshot
    )

    return [pscustomobject][ordered]@{
        Outcome = $Outcome
        StoppedByController = $Outcome -ceq 'StoppedByController'
        Snapshot = $Snapshot
    }
}

function Stop-CcodProcessIfMatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Expected,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actual = & $adapter.GetProcess ([int]$Expected.Pid)
    if ($null -eq $actual) { return New-CcodStopResult -Outcome 'ExitedBeforeStop' -Snapshot $null }
    if (-not (Test-CcodProcessMatch -Expected $Expected -Actual $actual)) {
        return New-CcodStopResult -Outcome 'IdentityChanged' -Snapshot $actual
    }

    try {
        $receipt = & $adapter.StopProcess $actual $TimeoutMilliseconds
    } catch [UnauthorizedAccessException] {
        return New-CcodStopResult -Outcome 'AccessDenied' -Snapshot $actual
    } catch [ComponentModel.Win32Exception] {
        if ($_.Exception.NativeErrorCode -eq 5) { return New-CcodStopResult -Outcome 'AccessDenied' -Snapshot $actual }
        return New-CcodStopResult -Outcome 'TimedOut' -Snapshot $actual
    }

    if ($null -eq $receipt -or $null -eq $receipt.PSObject.Properties['Outcome']) {
        return New-CcodStopResult -Outcome 'TimedOut' -Snapshot $actual
    }
    switch -CaseSensitive ([string]$receipt.Outcome) {
        'StoppedByController' {
            if ($null -ne $receipt.PSObject.Properties['StoppedByController'] -and [object]::Equals($receipt.StoppedByController, $true) -and
                $null -ne $receipt.PSObject.Properties['Pid'] -and [object]::Equals($receipt.Pid, $actual.Pid) -and
                $null -ne $receipt.PSObject.Properties['CreationTimeUtc'] -and [object]::Equals($receipt.CreationTimeUtc, $actual.CreationTimeUtc)) {
                return New-CcodStopResult -Outcome 'StoppedByController' -Snapshot $actual
            }
            return New-CcodStopResult -Outcome 'TimedOut' -Snapshot $actual
        }
        'ExitedBeforeStop' { return New-CcodStopResult -Outcome 'ExitedBeforeStop' -Snapshot $actual }
        'IdentityChanged' { return New-CcodStopResult -Outcome 'IdentityChanged' -Snapshot $actual }
        'AccessDenied' { return New-CcodStopResult -Outcome 'AccessDenied' -Snapshot $actual }
        'TimedOut' { return New-CcodStopResult -Outcome 'TimedOut' -Snapshot $actual }
        default { return New-CcodStopResult -Outcome 'TimedOut' -Snapshot $actual }
    }
}

function ConvertTo-CcodDateTimeOffset {
    param([AllowNull()][string]$Value)

    $parsed = [DateTimeOffset]::MinValue
    if ([string]::IsNullOrWhiteSpace($Value) -or
        -not [DateTimeOffset]::TryParseExact($Value, 'o', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
        return $null
    }
    return $parsed.ToUniversalTime()
}

function Test-CcodSameProcessOwnerAndPackage {
    param($Root, $Candidate)

    return $Candidate.SessionId -eq $Root.SessionId -and
        $Candidate.UserSid -ceq $Root.UserSid -and
        (Test-CcodOrdinalIgnoreCase $Candidate.Path $Root.Path) -and
        $Candidate.PackageFamilyName -ceq $Root.PackageFamilyName
}

function Get-CcodVerifiedProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Root,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $actualRoot = & $adapter.GetProcess ([int]$Root.Pid) $null
    if ($null -eq $actualRoot -or -not (Test-CcodProcessMatch -Expected $Root -Actual $actualRoot)) { return @() }
    $rootTime = ConvertTo-CcodDateTimeOffset -Value $actualRoot.CreationTimeUtc
    if ($null -eq $rootTime) { return @() }

    $verifiedByPid = @{}
    $verifiedByPid[[int]$actualRoot.Pid] = $actualRoot
    foreach ($processId in @(& $adapter.ListProcessIds | Select-Object -Unique)) {
        if ($null -eq $processId -or [int]$processId -eq [int]$actualRoot.Pid) { continue }
        $candidate = & $adapter.GetProcess ([int]$processId) $null
        if ($null -eq $candidate -or -not (Test-CcodSameProcessOwnerAndPackage -Root $actualRoot -Candidate $candidate)) { continue }
        $candidateTime = ConvertTo-CcodDateTimeOffset -Value $candidate.CreationTimeUtc
        if ($null -eq $candidateTime -or $candidateTime -lt $rootTime) { continue }
        $verifiedByPid[[int]$candidate.Pid] = $candidate
    }

    $included = @([int]$actualRoot.Pid)
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($entry in $verifiedByPid.GetEnumerator()) {
            $pidValue = [int]$entry.Key
            if ($included -contains $pidValue) { continue }
            $parentProperty = $entry.Value.PSObject.Properties['ParentPid']
            if ($null -eq $parentProperty -or $null -eq $parentProperty.Value) { continue }
            if ($included -contains [int]$parentProperty.Value) {
                $included += $pidValue
                $changed = $true
            }
        }
    }

    return @($included | Sort-Object | ForEach-Object { $verifiedByPid[[int]$_] })
}

function Find-CcodTransactionProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$RendererPort,
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$MainPort,
        [Parameter(Mandatory)][string]$TransactionTimeUtc,
        $StatusEvidence,
        [hashtable]$Adapters
    )

    if ($RendererPort -eq $MainPort) { return $null }
    $transactionTime = ConvertTo-CcodDateTimeOffset -Value $TransactionTimeUtc
    if ($null -eq $transactionTime) { return $null }
    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $package = & $adapter.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or -not $package.Found) { return $null }
    foreach ($name in @('FamilyName', 'ExecutablePath')) {
        if ($null -eq $package.PSObject.Properties[$name] -or [string]::IsNullOrWhiteSpace([string]$package.$name)) { return $null }
    }
    $currentSessionId = & $adapter.GetCurrentSessionId
    $currentUserSid = & $adapter.GetCurrentUserSid
    $candidates = @()
    foreach ($processId in @(& $adapter.ListProcessIds | Select-Object -Unique)) {
        if ($null -eq $processId) { continue }
        $snapshot = & $adapter.GetProcess ([int]$processId) $StatusEvidence
        if ($null -eq $snapshot -or $snapshot.Mode -cne 'Special' -or -not $snapshot.IsTopLevel) { continue }
        if ($snapshot.SessionId -ne $currentSessionId -or $snapshot.UserSid -cne $currentUserSid) { continue }
        if (-not (Test-CcodOrdinalIgnoreCase $snapshot.Path $package.ExecutablePath) -or $snapshot.PackageFamilyName -cne $package.FamilyName) { continue }
        if ($snapshot.RendererPort -ne $RendererPort -or $snapshot.MainPort -ne $MainPort) { continue }
        $creation = ConvertTo-CcodDateTimeOffset -Value $snapshot.CreationTimeUtc
        if ($null -eq $creation -or $creation -lt $transactionTime) { continue }
        $candidates += $snapshot
    }
    if ($candidates.Count -ne 1) { return $null }
    return $candidates[0]
}

function Get-CcodAvailableLoopbackPort {
    [CmdletBinding()]
    param(
        [AllowNull()][int[]]$ExcludedPorts = @(),
        [ValidateRange(1, 128)][int]$MaximumAttempts = 32,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    for ($attempt = 0; $attempt -lt $MaximumAttempts; $attempt++) {
        $port = & $adapter.ReserveLoopbackPort '127.0.0.1'
        if ($port -isnot [int] -or $port -lt 1 -or $port -gt 65535) { continue }
        if (@($ExcludedPorts) -contains [int]$port) { continue }
        return [int]$port
    }
    throw 'Could not reserve a distinct IPv4 loopback port.'
}

function Wait-CcodPortClosed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 65535)][int]$Port,
        [ValidateRange(1, 60000)][int]$TimeoutMilliseconds = 5000,
        [ValidateRange(1, 1000)][int]$PollMilliseconds = 50,
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    $deadline = (& $adapter.GetUtcNow).AddMilliseconds($TimeoutMilliseconds)
    while ($true) {
        $probe = [string](& $adapter.ProbeLoopbackPort $Port)
        if ($probe -ceq 'Refused') { return $true }
        if ($probe -cne 'Open') { return $false }
        if ((& $adapter.GetUtcNow) -ge $deadline) { return $false }
        & $adapter.Delay $PollMilliseconds
    }
}

function New-CcodStartResult {
    param(
        [Parameter(Mandatory)][ValidateSet('Started', 'Adopted', 'PortUnavailable', 'Failed')][string]$Outcome,
        $Snapshot,
        $Process
    )

    [pscustomobject][ordered]@{
        Outcome = $Outcome
        Snapshot = $Snapshot
        Process = $Process
    }
}

function Start-CcodProcess {
    [CmdletBinding(DefaultParameterSetName = 'Codex')]
    param(
        [Parameter(ParameterSetName = 'Codex')][ValidateSet('Ordinary', 'Special')][string]$Mode = 'Ordinary',
        [Parameter(ParameterSetName = 'Codex')][ValidateRange(1, 65535)][Nullable[int]]$RendererPort,
        [Parameter(ParameterSetName = 'Codex')][ValidateRange(1, 65535)][Nullable[int]]$MainPort,
        [Parameter(Mandatory, ParameterSetName = 'Helper')][switch]$BackgroundHelper,
        [Parameter(Mandatory, ParameterSetName = 'Helper')][string]$HelperPath,
        [Parameter(ParameterSetName = 'Helper')][AllowEmptyCollection()][string[]]$HelperArguments = @(),
        [hashtable]$Adapters
    )

    $adapter = Get-CcodProcessAdapters -Adapters $Adapters
    if ($PSCmdlet.ParameterSetName -ceq 'Helper') {
        if (-not [IO.Path]::IsPathRooted($HelperPath)) { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null }
        $process = & $adapter.StartProcess $HelperPath @($HelperArguments) 'Hidden'
        if ($null -eq $process) { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null }
        return New-CcodStartResult -Outcome 'Started' -Snapshot $null -Process $process
    }

    $package = & $adapter.GetPackageIdentity
    if ($null -eq $package -or $null -eq $package.PSObject.Properties['Found'] -or -not $package.Found -or
        $null -eq $package.PSObject.Properties['FamilyName'] -or $null -eq $package.PSObject.Properties['ExecutablePath'] -or
        [string]::IsNullOrWhiteSpace([string]$package.FamilyName) -or [string]::IsNullOrWhiteSpace([string]$package.ExecutablePath)) {
        return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null
    }

    if ($Mode -ceq 'Ordinary') {
        $currentSessionId = & $adapter.GetCurrentSessionId
        $currentUserSid = & $adapter.GetCurrentUserSid
        $ordinaryRoots = @()
        foreach ($processId in @(& $adapter.ListProcessIds | Select-Object -Unique)) {
            if ($null -eq $processId) { continue }
            $snapshot = & $adapter.GetProcess ([int]$processId) $null
            if ($null -eq $snapshot -or $snapshot.Mode -cne 'Ordinary' -or -not $snapshot.IsTopLevel) { continue }
            if ($snapshot.SessionId -ne $currentSessionId -or $snapshot.UserSid -cne $currentUserSid) { continue }
            if (-not (Test-CcodOrdinalIgnoreCase $snapshot.Path $package.ExecutablePath) -or $snapshot.PackageFamilyName -cne $package.FamilyName) { continue }
            $ordinaryRoots += $snapshot
        }
        if ($ordinaryRoots.Count -gt 0) {
            $adopted = @($ordinaryRoots | Sort-Object CreationTimeUtc, Pid)[0]
            return New-CcodStartResult -Outcome 'Adopted' -Snapshot $adopted -Process $null
        }
        $arguments = @()
    } else {
        if (-not $PSBoundParameters.ContainsKey('RendererPort') -or -not $PSBoundParameters.ContainsKey('MainPort') -or
            [int]$RendererPort -eq [int]$MainPort) {
            return New-CcodStartResult -Outcome 'PortUnavailable' -Snapshot $null -Process $null
        }
        foreach ($port in @([int]$RendererPort, [int]$MainPort)) {
            if (-not (& $adapter.TestLoopbackPortAvailable $port '127.0.0.1')) {
                return New-CcodStartResult -Outcome 'PortUnavailable' -Snapshot $null -Process $null
            }
        }
        $arguments = @(
            '--remote-debugging-address=127.0.0.1',
            "--remote-debugging-port=$([int]$RendererPort)",
            "--inspect=127.0.0.1:$([int]$MainPort)"
        )
    }

    try {
        $process = & $adapter.StartProcess ([string]$package.ExecutablePath) $arguments $null
    } catch [Net.Sockets.SocketException] {
        if ($Mode -ceq 'Special' -and $_.Exception.SocketErrorCode -eq [Net.Sockets.SocketError]::AddressAlreadyInUse) {
            return New-CcodStartResult -Outcome 'PortUnavailable' -Snapshot $null -Process $null
        }
        throw
    }
    if ($null -eq $process) { return New-CcodStartResult -Outcome 'Failed' -Snapshot $null -Process $null }
    return New-CcodStartResult -Outcome 'Started' -Snapshot $null -Process $process
}

Export-ModuleMember -Function Get-CcodProcessSnapshot, Test-CcodProcessMatch, Get-CcodVerifiedProcessTree, Find-CcodTransactionProcess, Stop-CcodProcessIfMatch, Start-CcodProcess, Get-CcodAvailableLoopbackPort, Wait-CcodPortClosed
